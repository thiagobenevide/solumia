"""Vagas de emprego (seção Vagas do Empreendimento): o Claude Code pesquisa na web as vagas que
batem com o perfil (cargos, local, remoto) e elas ficam numa lista para acompanhar.

Dados em `<raiz>/vagas/vagas.json`: `perfil`, `itens` (id → vaga) e `claude` (última pesquisa).
`estado` de cada vaga: `nova` → `interesse` | `candidatei` | `descartada`. Cada vaga ganha `geo`
(município do IBGE, `{}` quando não deu para localizar) para o mapa, e `curriculo` (id em
[Curriculos]) quando o Claude adapta o currículo padrão a ela."""

import hashlib
import json
import logging
import re
from collections.abc import Awaitable, Callable
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any

from concursos.curriculos import Curriculos
from concursos.geo import Geo

logger = logging.getLogger("concursos.vagas")

ExecutarClaude = Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]

ESTADOS = ("nova", "interesse", "candidatei", "descartada")
MODALIDADES = ("remoto", "hibrido", "presencial")
CONTRATOS = ("clt", "pj", "estagio", "outro", "nao_informado")
UFS = {
    *("AC", "AL", "AP", "AM", "BA", "CE", "DF", "ES", "GO", "MA", "MT", "MS", "MG", "PA"),
    *("PB", "PR", "PE", "PI", "RJ", "RN", "RS", "RO", "RR", "SC", "SP", "SE", "TO"),
}
PERFIL_PADRAO: dict[str, Any] = {
    "areas": ["Desenvolvimento de software", "Engenharia de dados"],
    "cargos": "Desenvolvedor, Engenheiro de software, Engenheiro de dados, Data engineer, "
    "Analytics engineer, Desenvolvedor Python",
    "empresas": [],
    "local": "Custódia/PE",
    "modalidades": ["remoto", "hibrido", "presencial"],
    "senioridade": "",
    "observacoes": "",
}

# Uma rodada do Claude por área × grupo de fontes: uma busca só para tudo estoura o tempo e traz
# poucas. A chave vai em `fonte` da vaga quando o Claude não diz qual foi.
FONTES: dict[str, str] = {
    "linkedin": "no LinkedIn Vagas (linkedin.com/jobs, busque por site:linkedin.com/jobs/view)",
    "plataformas": "nas plataformas de recrutamento que as empresas usam: Gupy (*.gupy.io), "
    "Greenhouse (boards.greenhouse.io, job-boards.greenhouse.io), Lever (jobs.lever.co), "
    "Workable (apply.workable.com), Solides (*.vagas.solides.com.br), InHire (*.inhire.app), "
    "Recrutei, Abler/Kenoby, Pandapé, Teamtailor, SmartRecruiters e Ashby (busque por "
    "site:<domínio> com o cargo)",
    "carreiras": "nos sites de carreira próprios das empresas (páginas /carreiras, /careers, "
    "/trabalhe-conosco): bancos e fintechs (Itaú, Bradesco, Nubank, Inter, C6, PicPay, "
    "Mercado Pago, Stone, PagBank), varejo e e-commerce (Magalu, Americanas, Via, Mercado "
    "Livre), tecnologia (iFood, TOTVS, CI&T, Stefanini, Zup, Accenture, ThoughtWorks, Globant), "
    "big techs e empresas estrangeiras que contratam no Brasil remoto",
    "agregadores": "nos agregadores e sites de vagas de TI: Indeed, Glassdoor, Programathor, "
    "GeekHunter, Remotar, Trampos, Vagas.com, Catho, InfoJobs, BNE, Revelo, Hipsters.jobs, "
    "We Work Remotely e RemoteOK (estas só as que aceitam Brasil)",
}

_TEXTO = {"type": "string"}
ESQUEMA_CLAUDE = {
    "type": "object",
    "properties": {
        "vagas": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "titulo": _TEXTO,
                    "empresa": _TEXTO,
                    "local": _TEXTO,
                    "cidade": _TEXTO,
                    "uf": _TEXTO,
                    "modalidade": {"type": "string", "enum": list(MODALIDADES)},
                    "contrato": {"type": "string", "enum": list(CONTRATOS)},
                    "salario": _TEXTO,
                    "senioridade": _TEXTO,
                    "url": _TEXTO,
                    "publicada_em": _TEXTO,
                    "fonte": _TEXTO,
                    "resumo": _TEXTO,
                },
                "required": ["titulo", "empresa", "modalidade", "contrato", "url", "resumo"],
            },
        }
    },
    "required": ["vagas"],
}

SISTEMA_CLAUDE = """Você pesquisa na internet (WebSearch e WebFetch) vagas de emprego abertas no
Brasil (CLT, PJ ou estágio) para um candidato. Consulte várias fontes (LinkedIn, Gupy, Indeed,
Glassdoor, Catho, Programathor, GeekHunter, sites de carreira das empresas) e só traga vagas que
você confirmou abertas, com o link direto da vaga em "url". "modalidade": remoto, hibrido ou
presencial. "contrato": clt, pj, estagio, outro (temporário, cooperado…) ou nao_informado,
como a vaga anuncia. "cidade" e "uf" (sigla): onde é a vaga (nas remotas, a sede da empresa;
vazios se não souber). "salario" como anunciado (vazio se não informado). "publicada_em" em
AAAA-MM-DD quando souber. "fonte": onde a vaga está publicada (LinkedIn, Gupy, Greenhouse,
site da empresa…). "resumo": 1–2 frases com stack/requisitos principais. Não invente dados nem
repita a mesma vaga."""

SISTEMA_CURRICULO = """Você adapta currículos a vagas de emprego. Recebe a vaga e o currículo base
em Markdown; se precisar, abra o link da vaga (WebFetch) para ler os requisitos. Devolva em
"markdown" o currículo completo, em português, na mesma estrutura do base: reescreva o resumo e
reordene competências e experiências para destacar o que a vaga pede, usando as palavras-chave
dela. Não invente experiências, empresas, datas, formações, números nem certificações que não
estejam no base; trechos entre colchetes [assim] ficam como estão."""
ESQUEMA_CURRICULO = {
    "type": "object",
    "properties": {"markdown": _TEXTO},
    "required": ["markdown"],
}


def _agora() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _cidade_uf(v: dict[str, Any]) -> tuple[str, str]:
    """Cidade e UF da vaga: dos campos do Claude ou do texto de `local` ("Recife/PE", "São
    Paulo, SP", "Remoto - SP"…); só a UF vira a capital no mapa."""
    uf = str(v.get("uf") or "").strip().upper()
    if uf in UFS:
        return str(v.get("cidade") or "").strip(), uf
    local = str(v.get("local") or "")
    m = re.search(r"([^,/()|–-]+?)\s*[,/–-]\s*([A-Z]{2})\b", local)
    if m and m.group(2) in UFS:
        return m.group(1).strip(), m.group(2)
    ufs = [u for u in re.findall(r"\b[A-Z]{2}\b", local) if u in UFS]
    return ("", ufs[0]) if ufs else ("", "")


def _id(empresa: str, titulo: str, url: str) -> str:
    base = f"{empresa}|{titulo}".lower() if empresa.strip() else url.strip().lower()
    return hashlib.sha1(re.sub(r"\s+", " ", base).encode()).hexdigest()[:12]


class Vagas:
    def __init__(
        self, raiz: Path | str, hoje: Callable[[], date] = date.today, geo: Geo | None = None
    ) -> None:
        self.arquivo = Path(raiz).expanduser() / "vagas" / "vagas.json"
        self.hoje = hoje
        self.geo = geo
        self.curriculos = Curriculos(raiz)
        self.pesquisando = False
        self.progresso = ""
        self.gerando: set[str] = set()
        self.erros_curriculo: dict[str, str] = {}

    def _ler(self) -> dict[str, Any]:
        if not self.arquivo.exists():
            return {"perfil": dict(PERFIL_PADRAO), "itens": {}, "claude": None}
        dados: dict[str, Any] = json.loads(self.arquivo.read_text())
        dados.setdefault("perfil", dict(PERFIL_PADRAO))
        dados.setdefault("itens", {})
        return dados

    def _gravar(self, dados: dict[str, Any]) -> None:
        self.arquivo.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1))
        tmp.replace(self.arquivo)

    def listar(self) -> dict[str, Any]:
        dados = self._ler()
        itens = sorted(
            dados["itens"].values(),
            key=lambda v: (v.get("publicada_em") or "", v.get("visto_em") or ""),
            reverse=True,
        )
        for v in itens:
            if v.get("curriculo") and not self.curriculos.existe(v["curriculo"]):
                v.pop("curriculo")
        return {
            "perfil": dados["perfil"],
            "vagas": itens,
            "gerando_curriculo": sorted(self.gerando),
            "erros_curriculo": self.erros_curriculo,
            "claude": dados.get("claude"),
            "pesquisando": self.pesquisando,
            "progresso": self.progresso,
        }

    def salvar_perfil(self, perfil: dict[str, Any]) -> dict[str, Any]:
        dados = self._ler()
        dados["perfil"] = {**PERFIL_PADRAO, **perfil}
        self._gravar(dados)
        return dados["perfil"]

    def marcar(self, id_: str, estado: str) -> dict[str, Any] | None:
        dados = self._ler()
        vaga = dados["itens"].get(id_)
        if vaga is None:
            return None
        vaga["estado"] = estado
        self._gravar(dados)
        return dict(vaga)

    def remover(self, id_: str) -> bool:
        dados = self._ler()
        if dados["itens"].pop(id_, None) is None:
            return False
        self._gravar(dados)
        return True

    async def localizar(self) -> None:
        """Põe `geo` nas vagas que ainda não tentaram (o CSV de municípios fica em cache)."""
        if self.geo is None:
            return
        achados: dict[str, dict[str, Any]] = {}
        for id_, v in self._ler()["itens"].items():
            if "geo" in v:
                continue
            cidade, uf = _cidade_uf(v)
            try:
                m = await self.geo.municipio(cidade, uf) if uf else None
            except Exception:
                logger.warning("Sem os municípios do IBGE para o mapa das vagas", exc_info=True)
                break
            achados[id_] = m or {}
        if not achados:
            return
        # relê: a pesquisa pode ter gravado no meio
        dados = self._ler()
        for id_, m in achados.items():
            if id_ in dados["itens"]:
                dados["itens"][id_]["geo"] = m
        self._gravar(dados)

    async def gerar_curriculo(self, id_: str, executar: ExecutarClaude) -> dict[str, Any]:
        """Adapta o currículo padrão à vaga pelo Claude Code e grava como `vaga-<id>`."""
        vaga = self._ler()["itens"].get(id_)
        base = self.curriculos.padrao()
        if vaga is None or base is None:
            self.gerando.discard(id_)
            return {"erro": "vaga ou currículo padrão não encontrado"}
        self.gerando.add(id_)
        self.erros_curriculo.pop(id_, None)
        try:
            campos = ("titulo", "empresa", "local", "modalidade", "contrato", "senioridade")
            linhas = [f"{k}: {vaga[k]}" for k in campos if vaga.get(k)]
            prompt = "\n".join(
                [
                    "Vaga:",
                    *linhas,
                    f"resumo: {vaga.get('resumo', '')}",
                    f"link: {vaga.get('url', '')}",
                    "",
                    "Currículo base:",
                    "",
                    base["conteudo"],
                ]
            )
            r = await executar(
                {
                    "prompt": prompt,
                    "sistema": SISTEMA_CURRICULO,
                    "esquema": ESQUEMA_CURRICULO,
                    "limite_s": 600,
                    "effort": "medium",
                    "ferramentas": "WebFetch",
                }
            )
            markdown = str(r.get("markdown") or "").strip()
            if not markdown:
                raise ValueError("o Claude não devolveu o currículo")
            nome = " · ".join(str(vaga[k]) for k in ("titulo", "empresa") if vaga.get(k))
            c = self.curriculos.salvar(f"vaga-{id_}", nome, markdown + "\n", vaga=id_)
            dados = self._ler()
            if id_ in dados["itens"]:
                dados["itens"][id_]["curriculo"] = c["id"]
                self._gravar(dados)
            return c
        except Exception as e:
            logger.exception("Falha ao gerar o currículo da vaga %s", id_)
            self.erros_curriculo[id_] = str(e)[:200] or type(e).__name__
            return {"erro": self.erros_curriculo[id_]}
        finally:
            self.gerando.discard(id_)

    def _rodadas(self, perfil: dict[str, Any]) -> list[tuple[str, str]]:
        """(rótulo, prompt) de cada rodada: área × fonte e, se houver, as empresas acompanhadas."""
        hoje = self.hoje().isoformat()
        modos = ", ".join(perfil.get("modalidades") or MODALIDADES)
        # cidade opcional: vazia, as presenciais e híbridas vêm do Brasil todo
        local = str(perfil.get("local", PERFIL_PADRAO["local"])).strip()
        perto = (
            f"As presenciais e híbridas só perto de {local} (até uns 300 km) ou nas capitais do "
            "Nordeste; as remotas, do Brasil todo."
            if local
            else "Vagas do Brasil todo."
        )
        comum = [
            f"Modalidades aceitas: {modos}. {perto}",
            f"Cargos que servem: {perfil.get('cargos') or PERFIL_PADRAO['cargos']}.",
        ]
        if perfil.get("senioridade"):
            comum.append(f"Senioridade: {perfil['senioridade']}.")
        if perfil.get("observacoes"):
            comum.append(f"Observações do candidato: {perfil['observacoes']}.")
        comum.append("Priorize as publicadas nos últimos 30 dias. Traga o máximo que confirmar.")
        rodadas = [
            (
                f"{area} · {fonte}",
                " ".join([f"Hoje é {hoje}. Liste vagas abertas de {area} {onde}.", *comum]),
            )
            for area in perfil.get("areas") or PERFIL_PADRAO["areas"]
            for fonte, onde in FONTES.items()
        ]
        areas = perfil.get("areas") or PERFIL_PADRAO["areas"]
        empresas = [e for e in perfil.get("empresas") or [] if str(e).strip()]
        if empresas:
            rodadas.append(
                (
                    "empresas acompanhadas",
                    " ".join(
                        [
                            f"Hoje é {hoje}. Abra o site de carreiras (ou a página na Gupy, "
                            "Greenhouse, Lever etc.) de cada uma destas empresas e liste as vagas "
                            f"abertas de {', '.join(areas)}: {', '.join(map(str, empresas))}.",
                            *comum,
                        ]
                    ),
                )
            )
        return rodadas

    async def pesquisar_claude(self, executar: ExecutarClaude) -> dict[str, Any]:
        """Pesquisa pelo Claude Code (worker do PC), uma rodada por área × fonte; a falha de uma
        não perde as outras. As vagas achadas entram como `nova` e as já vistas mantêm o estado
        que o usuário marcou."""
        if self.pesquisando:
            return {"ja_rodando": True}
        self.pesquisando = True
        erros: list[str] = []
        achadas = 0
        try:
            rodadas = self._rodadas(self._ler()["perfil"])
            for n, (rotulo, prompt) in enumerate(rodadas, 1):
                self.progresso = f"{n}/{len(rodadas)} · {rotulo}"
                try:
                    r = await executar(
                        {
                            "prompt": prompt,
                            "sistema": SISTEMA_CLAUDE,
                            "esquema": ESQUEMA_CLAUDE,
                            "limite_s": 900,
                            "effort": "medium",
                            "ferramentas": "WebSearch,WebFetch",
                        }
                    )
                    achadas += self._juntar(r, rotulo)
                except Exception as e:
                    logger.exception("Falha na pesquisa de vagas (%s)", rotulo)
                    erros.append(f"{rotulo}: {str(e)[:150] or type(e).__name__}")
        finally:
            dados = self._ler()
            dados["claude"] = {"em": _agora(), "achadas": achadas, "erro": "; ".join(erros)}
            self._gravar(dados)
            self.pesquisando = False
            self.progresso = ""
        await self.localizar()
        if erros and not achadas:
            return {"erro": "; ".join(erros)}
        return {"achadas": achadas}

    def _juntar(self, r: dict[str, Any], rodada: str = "") -> int:
        dados = self._ler()
        itens: dict[str, Any] = dados["itens"]
        n = 0
        for v in r.get("vagas") or []:
            if not isinstance(v, dict) or not v.get("titulo"):
                continue
            campos = {
                k: str(v.get(k) or "")
                for k in (
                    "titulo",
                    "empresa",
                    "local",
                    "cidade",
                    "uf",
                    "modalidade",
                    "contrato",
                    "salario",
                    "senioridade",
                    "url",
                    "publicada_em",
                    "fonte",
                    "resumo",
                )
            }
            campos["area"] = rodada.split(" · ")[0] if " · " in rodada else ""
            campos["fonte"] = campos["fonte"] or rodada.split(" · ")[-1]
            id_ = _id(campos["empresa"], campos["titulo"], campos["url"])
            antiga = itens.get(id_) or {"id": id_, "estado": "nova", "visto_em": _agora()}
            if (campos["cidade"], campos["uf"]) != (antiga.get("cidade", ""), antiga.get("uf", "")):
                antiga.pop("geo", None)  # mudou o lugar: localiza de novo
            # área e fonte ficam as da primeira rodada que achou a vaga
            for k in ("area", "fonte"):
                campos[k] = antiga.get(k) or campos[k]
            itens[id_] = {**antiga, **campos, "atualizada_em": _agora()}
            n += 1
        self._gravar(dados)
        return n
