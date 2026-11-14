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

from concursos.resumes import Resumes
from concursos.geo import Geo

logger = logging.getLogger("concursos.jobs")

ExecuteClaude = Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]

STATES = ("nova", "interesse", "candidatei", "descartada")
MODALITIES = ("remoto", "hibrido", "presencial")
CONTRACTS = ("clt", "pj", "estagio", "outro", "nao_informado")
UFS = {
    *("AC", "AL", "AP", "AM", "BA", "CE", "DF", "ES", "GO", "MA", "MT", "MS", "MG", "PA"),
    *("PB", "PR", "PE", "PI", "RJ", "RN", "RS", "RO", "RR", "SC", "SP", "SE", "TO"),
}
PROFILE_DEFAULT: dict[str, Any] = {
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
SOURCES: dict[str, str] = {
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

_TEXT = {"type": "string"}
SCHEMA_CLAUDE = {
    "type": "object",
    "properties": {
        "vagas": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "titulo": _TEXT,
                    "empresa": _TEXT,
                    "local": _TEXT,
                    "cidade": _TEXT,
                    "uf": _TEXT,
                    "modalidade": {"type": "string", "enum": list(MODALITIES)},
                    "contrato": {"type": "string", "enum": list(CONTRACTS)},
                    "salario": _TEXT,
                    "senioridade": _TEXT,
                    "url": _TEXT,
                    "publicada_em": _TEXT,
                    "fonte": _TEXT,
                    "resumo": _TEXT,
                },
                "required": ["titulo", "empresa", "modalidade", "contrato", "url", "resumo"],
            },
        }
    },
    "required": ["vagas"],
}

SYSTEM_CLAUDE = """Você pesquisa na internet (WebSearch e WebFetch) vagas de emprego abertas no
Brasil (CLT, PJ ou estágio) para um candidato. Consulte várias fontes (LinkedIn, Gupy, Indeed,
Glassdoor, Catho, Programathor, GeekHunter, sites de carreira das empresas) e só traga vagas que
você confirmou abertas, com o link direto da vaga em "url". "modalidade": remoto, hibrido ou
presencial. "contrato": clt, pj, estagio, outro (temporário, cooperado…) ou nao_informado,
como a vaga anuncia. "cidade" e "uf" (sigla): onde é a vaga (nas remotas, a sede da empresa;
vazios se não souber). "salario" como anunciado (vazio se não informado). "publicada_em" em
AAAA-MM-DD quando souber. "fonte": onde a vaga está publicada (LinkedIn, Gupy, Greenhouse,
site da empresa…). "resumo": 1–2 frases com stack/requisitos principais. Não invente dados nem
repita a mesma vaga."""

SYSTEM_RESUME = """Você adapta currículos a vagas de emprego. Recebe a vaga e o currículo base
em Markdown; se precisar, abra o link da vaga (WebFetch) para ler os requisitos. Devolva em
"markdown" o currículo completo, em português, na mesma estrutura do base: reescreva o resumo e
reordene competências e experiências para destacar o que a vaga pede, usando as palavras-chave
dela. Não invente experiências, empresas, datas, formações, números nem certificações que não
estejam no base; trechos entre colchetes [assim] ficam como estão."""
SCHEMA_RESUME = {
    "type": "object",
    "properties": {"markdown": _TEXT},
    "required": ["markdown"],
}


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _city_uf(v: dict[str, Any]) -> tuple[str, str]:
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


def _id(company: str, titulo: str, url: str) -> str:
    base = f"{company}|{titulo}".lower() if company.strip() else url.strip().lower()
    return hashlib.sha1(re.sub(r"\s+", " ", base).encode()).hexdigest()[:12]


class Slots:
    def __init__(
        self, root: Path | str, hoje: Callable[[], date] = date.today, geo: Geo | None = None
    ) -> None:
        self.arquivo = Path(root).expanduser() / "vagas" / "vagas.json"
        self.hoje = hoje
        self.geo = geo
        self.curriculos = Resumes(root)
        self.pesquisando = False
        self.progresso = ""
        self.gerando: set[str] = set()
        self.erros_curriculo: dict[str, str] = {}

    def _ler(self) -> dict[str, Any]:
        if not self.arquivo.exists():
            return {"perfil": dict(PROFILE_DEFAULT), "itens": {}, "claude": None}
        data: dict[str, Any] = json.loads(self.arquivo.read_text())
        data.setdefault("perfil", dict(PROFILE_DEFAULT))
        data.setdefault("itens", {})
        return data

    def _gravar(self, dados: dict[str, Any]) -> None:
        self.arquivo.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1))
        tmp.replace(self.arquivo)

    def listar(self) -> dict[str, Any]:
        data = self._ler()
        items = sorted(
            data["itens"].values(),
            key=lambda v: (v.get("publicada_em") or "", v.get("visto_em") or ""),
            reverse=True,
        )
        for v in items:
            if v.get("curriculo") and not self.curriculos.existe(v["curriculo"]):
                v.pop("curriculo")
        return {
            "perfil": data["perfil"],
            "vagas": items,
            "gerando_curriculo": sorted(self.gerando),
            "erros_curriculo": self.erros_curriculo,
            "claude": data.get("claude"),
            "pesquisando": self.pesquisando,
            "progresso": self.progresso,
        }

    def salvar_perfil(self, profile: dict[str, Any]) -> dict[str, Any]:
        data = self._ler()
        data["perfil"] = {**PROFILE_DEFAULT, **profile}
        self._gravar(data)
        return data["perfil"]

    def marcar(self, id_: str, estado: str) -> dict[str, Any] | None:
        data = self._ler()
        slot = data["itens"].get(id_)
        if slot is None:
            return None
        slot["estado"] = estado
        self._gravar(data)
        return dict(slot)

    def remover(self, id_: str) -> bool:
        data = self._ler()
        if data["itens"].pop(id_, None) is None:
            return False
        self._gravar(data)
        return True

    async def localizar(self) -> None:
        """Põe `geo` nas vagas que ainda não tentaram (o CSV de municípios fica em cache)."""
        if self.geo is None:
            return
        found: dict[str, dict[str, Any]] = {}
        for id_, v in self._ler()["itens"].items():
            if "geo" in v:
                continue
            city, uf = _city_uf(v)
            try:
                m = await self.geo.municipio(city, uf) if uf else None
            except Exception:
                logger.warning("Sem os municípios do IBGE para o mapa das vagas", exc_info=True)
                break
            found[id_] = m or {}
        if not found:
            return
        # relê: a pesquisa pode ter gravado no meio
        data = self._ler()
        for id_, m in found.items():
            if id_ in data["itens"]:
                data["itens"][id_]["geo"] = m
        self._gravar(data)

    async def gerar_curriculo(self, id_: str, execute: ExecuteClaude) -> dict[str, Any]:
        """Adapta o currículo padrão à vaga pelo Claude Code e grava como `vaga-<id>`."""
        slot = self._ler()["itens"].get(id_)
        base = self.curriculos.padrao()
        if slot is None or base is None:
            self.gerando.discard(id_)
            return {"erro": "vaga ou currículo padrão não encontrado"}
        self.gerando.add(id_)
        self.erros_curriculo.pop(id_, None)
        try:
            fields = ("titulo", "empresa", "local", "modalidade", "contrato", "senioridade")
            lines = [f"{k}: {slot[k]}" for k in fields if slot.get(k)]
            prompt = "\n".join(
                [
                    "Vaga:",
                    *lines,
                    f"resumo: {slot.get('resumo', '')}",
                    f"link: {slot.get('url', '')}",
                    "",
                    "Currículo base:",
                    "",
                    base["conteudo"],
                ]
            )
            r = await execute(
                {
                    "prompt": prompt,
                    "sistema": SYSTEM_RESUME,
                    "esquema": SCHEMA_RESUME,
                    "limite_s": 600,
                    "effort": "medium",
                    "ferramentas": "WebFetch",
                }
            )
            markdown = str(r.get("markdown") or "").strip()
            if not markdown:
                raise ValueError("o Claude não devolveu o currículo")
            name = " · ".join(str(slot[k]) for k in ("titulo", "empresa") if slot.get(k))
            c = self.curriculos.salvar(f"vaga-{id_}", name, markdown + "\n", vaga=id_)
            data = self._ler()
            if id_ in data["itens"]:
                data["itens"][id_]["curriculo"] = c["id"]
                self._gravar(data)
            return c
        except Exception as e:
            logger.exception("Falha ao gerar o currículo da vaga %s", id_)
            self.erros_curriculo[id_] = str(e)[:200] or type(e).__name__
            return {"erro": self.erros_curriculo[id_]}
        finally:
            self.gerando.discard(id_)

    def _rodadas(self, profile: dict[str, Any]) -> list[tuple[str, str]]:
        """(rótulo, prompt) de cada rodada: área × fonte e, se houver, as empresas acompanhadas."""
        today = self.hoje().isoformat()
        modes = ", ".join(profile.get("modalidades") or MODALITIES)
        # cidade opcional: vazia, as presenciais e híbridas vêm do Brasil todo
        local = str(profile.get("local", PROFILE_DEFAULT["local"])).strip()
        near = (
            f"As presenciais e híbridas só perto de {local} (até uns 300 km) ou nas capitais do "
            "Nordeste; as remotas, do Brasil todo."
            if local
            else "Vagas do Brasil todo."
        )
        common = [
            f"Modalidades aceitas: {modes}. {near}",
            f"Cargos que servem: {profile.get('cargos') or PROFILE_DEFAULT['cargos']}.",
        ]
        if profile.get("senioridade"):
            common.append(f"Senioridade: {profile['senioridade']}.")
        if profile.get("observacoes"):
            common.append(f"Observações do candidato: {profile['observacoes']}.")
        common.append("Priorize as publicadas nos últimos 30 dias. Traga o máximo que confirmar.")
        rounds = [
            (
                f"{area} · {source}",
                " ".join([f"Hoje é {today}. Liste vagas abertas de {area} {where}.", *common]),
            )
            for area in profile.get("areas") or PROFILE_DEFAULT["areas"]
            for source, where in SOURCES.items()
        ]
        areas = profile.get("areas") or PROFILE_DEFAULT["areas"]
        empresas = [e for e in profile.get("empresas") or [] if str(e).strip()]
        if empresas:
            rounds.append(
                (
                    "empresas acompanhadas",
                    " ".join(
                        [
                            f"Hoje é {today}. Abra o site de carreiras (ou a página na Gupy, "
                            "Greenhouse, Lever etc.) de cada uma destas empresas e liste as vagas "
                            f"abertas de {', '.join(areas)}: {', '.join(map(str, empresas))}.",
                            *common,
                        ]
                    ),
                )
            )
        return rounds

    async def pesquisar_claude(self, execute: ExecuteClaude) -> dict[str, Any]:
        """Pesquisa pelo Claude Code (worker do PC), uma rodada por área × fonte; a falha de uma
        não perde as outras. As vagas achadas entram como `nova` e as já vistas mantêm o estado
        que o usuário marcou."""
        if self.pesquisando:
            return {"ja_rodando": True}
        self.pesquisando = True
        errors: list[str] = []
        found = 0
        try:
            rounds = self._rodadas(self._ler()["perfil"])
            for n, (label, prompt) in enumerate(rounds, 1):
                self.progresso = f"{n}/{len(rounds)} · {label}"
                try:
                    r = await execute(
                        {
                            "prompt": prompt,
                            "sistema": SYSTEM_CLAUDE,
                            "esquema": SCHEMA_CLAUDE,
                            "limite_s": 900,
                            "effort": "medium",
                            "ferramentas": "WebSearch,WebFetch",
                        }
                    )
                    found += self._juntar(r, label)
                except Exception as e:
                    logger.exception("Falha na pesquisa de vagas (%s)", label)
                    errors.append(f"{label}: {str(e)[:150] or type(e).__name__}")
        finally:
            data = self._ler()
            data["claude"] = {"em": _now(), "achadas": found, "erro": "; ".join(errors)}
            self._gravar(data)
            self.pesquisando = False
            self.progresso = ""
        await self.localizar()
        if errors and not found:
            return {"erro": "; ".join(errors)}
        return {"achadas": found}

    def _juntar(self, r: dict[str, Any], rounded: str = "") -> int:
        data = self._ler()
        items: dict[str, Any] = data["itens"]
        n = 0
        for v in r.get("vagas") or []:
            if not isinstance(v, dict) or not v.get("titulo"):
                continue
            fields = {
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
            fields["area"] = rounded.split(" · ")[0] if " · " in rounded else ""
            fields["fonte"] = fields["fonte"] or rounded.split(" · ")[-1]
            id_ = _id(fields["empresa"], fields["titulo"], fields["url"])
            old = items.get(id_) or {"id": id_, "estado": "nova", "visto_em": _now()}
            if (fields["cidade"], fields["uf"]) != (old.get("cidade", ""), old.get("uf", "")):
                old.pop("geo", None)  # mudou o lugar: localiza de novo
            # área e fonte ficam as da primeira rodada que achou a vaga
            for k in ("area", "fonte"):
                fields[k] = old.get(k) or fields[k]
            items[id_] = {**old, **fields, "atualizada_em": _now()}
            n += 1
        self._gravar(data)
        return n
