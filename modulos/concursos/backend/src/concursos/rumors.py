"""Rumores de concursos de TI (federais, estaduais e municipais): pedidos de autorização, comissões,
bancas em escolha e previsões noticiadas, cada um com a fonte. Quem o usuário acompanha é
reverificado de tempos em tempos pelo Claude Code; o que sair de novo vira novidade e alerta
(o notificador do painel manda como push).

Tudo fica em `<concursos_dir>/radar/rumores.json`."""

import asyncio
import json
import logging
import re
from collections.abc import Awaitable, Callable
from datetime import date, datetime
from pathlib import Path
from typing import Any

logger = logging.getLogger("concursos.rumors")

ExecutarClaude = Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]

ESFERAS = ("federal", "estadual", "municipal")
FASES = ("rumor", "solicitado", "autorizado", "comissao", "banca", "edital")
_TEXTO = {"type": "string"}

ESQUEMA_BUSCA = {
    "type": "object",
    "properties": {
        "rumores": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "orgao": _TEXTO,
                    "uf": _TEXTO,
                    "esfera": {"type": "string", "enum": list(ESFERAS)},
                    "fase": {"type": "string", "enum": list(FASES)},
                    "cargos_ti": {"type": "array", "items": _TEXTO},
                    "vagas_previstas": {"type": "integer"},
                    "fonte_nome": _TEXTO,
                    "fonte_url": _TEXTO,
                    "data_noticia": _TEXTO,
                    "resumo": _TEXTO,
                },
                "required": ["orgao", "uf", "esfera", "fase", "cargos_ti", "fonte_url", "resumo"],
            },
        }
    },
    "required": ["rumores"],
}

ESQUEMA_NOVIDADES = {
    "type": "object",
    "properties": {
        "novidades": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": _TEXTO,
                    "fase": {"type": "string", "enum": list(FASES)},
                    "texto": _TEXTO,
                    "fonte_nome": _TEXTO,
                    "fonte_url": _TEXTO,
                    "data": _TEXTO,
                },
                "required": ["id", "texto", "fonte_url"],
            },
        }
    },
    "required": ["novidades"],
}

SISTEMA = """Você pesquisa na internet (WebSearch e WebFetch) RUMORES e PREVISÕES de concursos
públicos brasileiros que tenham ou devam ter cargos de TI (analista/técnico de TI, desenvolvimento,
sistemas, dados, redes, segurança da informação, infraestrutura, suporte, informática).
Rumor = concurso ainda SEM edital: pedido de autorização, autorização publicada, previsão na LOA ou
no orçamento, comissão organizadora formada, banca em escolha/contratada, declarações de gestores.
Consulte várias fontes (PCI Concursos, JC Concursos, Folha Dirigida, Estratégia, Gran, Direção,
Diário Oficial, sites dos órgãos e das bancas) e só traga o que achou numa página real.
"fase": rumor | solicitado | autorizado | comissao | banca | edital (edital já publicado).
"esfera": federal, estadual (estados e DF) ou municipal. "uf" = UF do órgão; "BR" se nacional.
Não invente: o que não achar fica "" ou []; datas em AAAA-MM-DD; "fonte_nome" = nome do site;
"fonte_url" = página onde você leu; "resumo" com até 2 frases sobre o estágio atual."""


def _agora() -> str:
    return datetime.now().isoformat(timespec="seconds")


def id_rumor(orgao: str, uf: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", f"{orgao} {uf}".lower()).strip("-")[:100]


class Rumores:
    def __init__(self, raiz: str | Path, hoje: Callable[[], date] = date.today) -> None:
        pasta = Path(raiz).expanduser() / "radar"
        pasta.mkdir(parents=True, exist_ok=True)
        self._arquivo = pasta / "rumores.json"
        self.hoje = hoje
        self.pesquisando = False
        self._trava = asyncio.Lock()

    def _ler(self) -> dict[str, Any]:
        if not self._arquivo.exists():
            return {"itens": {}, "busca": None}
        dados: dict[str, Any] = json.loads(self._arquivo.read_text("utf-8"))
        return dados

    def _gravar(self, dados: dict[str, Any]) -> None:
        tmp = self._arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1), "utf-8")
        tmp.replace(self._arquivo)

    def listar(self) -> dict[str, Any]:
        """Acompanhados primeiro, depois do mais recente ao mais antigo."""
        dados = self._ler()
        itens = sorted(
            dados["itens"].values(),
            key=lambda i: (i.get("data_noticia") or i["visto_em"][:10]),
            reverse=True,
        )
        itens.sort(key=lambda i: not i.get("acompanhado"))
        return {"pesquisando": self.pesquisando, "busca": dados.get("busca"), "itens": itens}

    def acompanhar(self, id_: str, sim: bool) -> dict[str, Any] | None:
        dados = self._ler()
        item = dados["itens"].get(id_)
        if item is None:
            return None
        item["acompanhado"] = sim
        self._gravar(dados)
        return item  # type: ignore[no-any-return]

    def alertas(self) -> list[dict[str, Any]]:
        """Novidades de hoje dos rumores acompanhados (o notificador manda cada uma uma vez)."""
        hoje = self.hoje().isoformat()
        return [
            {
                "nivel": "aviso",
                "texto": f"Rumor {i['orgao']}: {n['texto']}",
                "concurso": i["orgao"],
                "rumor_id": i["id"],
            }
            for i in self._ler()["itens"].values()
            if i.get("acompanhado")
            for n in i.get("novidades", [])
            if n["registrada_em"][:10] == hoje
        ]

    async def pesquisar(self, executar: ExecutarClaude, consulta: str = "") -> dict[str, Any]:
        """Busca rumores pelo Claude Code (opcionalmente filtrando por [consulta], ex. "TRF5",
        "Pernambuco", "Analista de dados") e depois procura novidades dos acompanhados."""
        if self.pesquisando:
            return {"ja_rodando": True}
        self.pesquisando = True
        achados, erro = 0, ""
        try:
            hoje = self.hoje()
            foco = f' Foque em: "{consulta}".' if consulta.strip() else ""
            r = await executar(
                {
                    "prompt": f"Hoje é {hoje.isoformat()}. Liste os rumores e previsões de "
                    f"concursos com cargos de TI nas esferas federal, estadual e municipal, "
                    f"noticiados nos últimos 12 meses, para {hoje.year} e {hoje.year + 1}.{foco} "
                    "Traga o máximo que conseguir confirmar, cada um com a fonte.",
                    "sistema": SISTEMA,
                    "esquema": ESQUEMA_BUSCA,
                    "limite_s": 900,
                    "effort": "medium",
                    "ferramentas": "WebSearch,WebFetch",
                }
            )
            async with self._trava:
                achados = self._juntar(r.get("rumores") or [])
            await self._verificar(executar)
        except Exception as e:
            logger.exception("Falha na pesquisa de rumores")
            erro = str(e)[:300] or type(e).__name__
        finally:
            dados = self._ler()
            dados["busca"] = {
                "em": _agora(),
                "consulta": consulta,
                "achados": achados,
                "erro": erro,
            }
            self._gravar(dados)
            self.pesquisando = False
        return {"erro": erro} if erro else {"achados": achados}

    def _juntar(self, rumores: list[Any]) -> int:
        dados = self._ler()
        itens: dict[str, Any] = dados["itens"]
        n = 0
        for r in rumores:
            if not isinstance(r, dict) or not r.get("orgao") or not r.get("fonte_url"):
                continue
            uf = str(r.get("uf") or "")[:2].upper()
            id_ = id_rumor(str(r["orgao"]), uf)
            fase = r.get("fase") if r.get("fase") in FASES else "rumor"
            fonte = {"nome": str(r.get("fonte_nome") or ""), "url": str(r["fonte_url"])}
            item = itens.get(id_)
            if item is None:
                item = itens[id_] = {
                    "id": id_,
                    "acompanhado": False,
                    "novidades": [],
                    "fontes": [],
                    "visto_em": _agora(),
                }
            elif FASES.index(fase) < FASES.index(item.get("fase") or "rumor"):
                fase = item["fase"]  # notícia mais antiga que a fase conhecida: a fase não volta
            elif item.get("acompanhado") and fase != item.get("fase"):
                self._novidade(item, f"Mudou para {fase}: {r.get('resumo', '')}", fonte, fase)
            item.update(
                orgao=str(r["orgao"]),
                uf=uf,
                esfera=r.get("esfera") if r.get("esfera") in ESFERAS else "",
                fase=fase,
                cargos_ti=[str(c) for c in r.get("cargos_ti") or []],
                vagas_previstas=int(r.get("vagas_previstas") or 0),
                data_noticia=str(r.get("data_noticia") or ""),
                resumo=str(r.get("resumo") or ""),
                atualizado_em=_agora(),
            )
            if fonte["url"] not in {f["url"] for f in item["fontes"]}:
                item["fontes"].append(fonte)
            n += 1
        self._gravar(dados)
        return n

    def _novidade(self, item: dict[str, Any], texto: str, fonte: dict[str, str], fase: str) -> None:
        item["novidades"].append(
            {"texto": texto, "fonte": fonte, "fase": fase, "registrada_em": _agora()}
        )

    async def _verificar(self, executar: ExecutarClaude) -> int:
        """Pede ao Claude o que saiu depois da última notícia conhecida de cada acompanhado."""
        acompanhados = [i for i in self._ler()["itens"].values() if i.get("acompanhado")]
        if not acompanhados:
            return 0
        def ultima(i: dict[str, Any]) -> str:
            if i["novidades"]:
                return str(i["novidades"][-1]["registrada_em"][:10])
            return str(i.get("data_noticia") or "?")

        lista = "\n".join(
            f'- id "{i["id"]}": {i["orgao"]} ({i["uf"]}), fase {i["fase"]}, '
            f"última notícia {ultima(i)}: {i.get('resumo', '')}"
            for i in acompanhados
        )
        r = await executar(
            {
                "prompt": f"Hoje é {self.hoje().isoformat()}. Para cada concurso abaixo, procure o "
                "que saiu DEPOIS da última notícia indicada (autorização, comissão, banca, edital, "
                "datas, vagas de TI). Devolva só novidades reais, com o mesmo id; nada novo = não "
                f"inclua.\n{lista}",
                "sistema": SISTEMA,
                "esquema": ESQUEMA_NOVIDADES,
                "limite_s": 600,
                "effort": "medium",
                "ferramentas": "WebSearch,WebFetch",
            }
        )
        async with self._trava:
            dados = self._ler()
            n = 0
            for nov in r.get("novidades") or []:
                item = dados["itens"].get(str(nov.get("id", "")))
                if not item or not item.get("acompanhado") or not nov.get("texto"):
                    continue
                fonte = {"nome": str(nov.get("fonte_nome") or ""), "url": str(nov["fonte_url"])}
                ja = {(x["fonte"]["url"], x["texto"]) for x in item["novidades"]}
                if (fonte["url"], nov["texto"]) in ja:
                    continue
                fase = nov.get("fase") if nov.get("fase") in FASES else item["fase"]
                self._novidade(item, str(nov["texto"]), fonte, fase)
                item["fase"] = fase
                if fonte["url"] not in {f["url"] for f in item["fontes"]}:
                    item["fontes"].append(fonte)
                n += 1
            self._gravar(dados)
        return n

    async def rodar(
        self, executar: ExecutarClaude, intervalo_s: float, atraso_s: float = 600
    ) -> None:
        """Reverifica os acompanhados de tempos em tempos (sem busca nova de rumores)."""
        await asyncio.sleep(atraso_s)
        while True:
            if not self.pesquisando:
                self.pesquisando = True
                try:
                    await self._verificar(executar)
                except Exception:
                    logger.exception("Falha ao reverificar os rumores acompanhados")
                finally:
                    self.pesquisando = False
            await asyncio.sleep(intervalo_s)
