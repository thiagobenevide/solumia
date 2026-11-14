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

ExecuteClaude = Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]

SPHERES = ("federal", "estadual", "municipal")
PHASES = ("rumor", "solicitado", "autorizado", "comissao", "banca", "edital")
_TEXT = {"type": "string"}

SCHEMA_SEARCH = {
    "type": "object",
    "properties": {
        "rumores": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "orgao": _TEXT,
                    "uf": _TEXT,
                    "esfera": {"type": "string", "enum": list(SPHERES)},
                    "fase": {"type": "string", "enum": list(PHASES)},
                    "cargos_ti": {"type": "array", "items": _TEXT},
                    "vagas_previstas": {"type": "integer"},
                    "fonte_nome": _TEXT,
                    "fonte_url": _TEXT,
                    "data_noticia": _TEXT,
                    "resumo": _TEXT,
                },
                "required": ["orgao", "uf", "esfera", "fase", "cargos_ti", "fonte_url", "resumo"],
            },
        }
    },
    "required": ["rumores"],
}

SCHEMA_UPDATES = {
    "type": "object",
    "properties": {
        "novidades": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": _TEXT,
                    "fase": {"type": "string", "enum": list(PHASES)},
                    "texto": _TEXT,
                    "fonte_nome": _TEXT,
                    "fonte_url": _TEXT,
                    "data": _TEXT,
                },
                "required": ["id", "texto", "fonte_url"],
            },
        }
    },
    "required": ["novidades"],
}

SYSTEM = """Você pesquisa na internet (WebSearch e WebFetch) RUMORES e PREVISÕES de concursos
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


def _now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def id_rumor(orgao: str, uf: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", f"{orgao} {uf}".lower()).strip("-")[:100]


class Rumors:
    def __init__(self, root: str | Path, hoje: Callable[[], date] = date.today) -> None:
        folder = Path(root).expanduser() / "radar"
        folder.mkdir(parents=True, exist_ok=True)
        self._arquivo = folder / "rumores.json"
        self.hoje = hoje
        self.pesquisando = False
        self._trava = asyncio.Lock()

    def _ler(self) -> dict[str, Any]:
        if not self._arquivo.exists():
            return {"itens": {}, "busca": None}
        data: dict[str, Any] = json.loads(self._arquivo.read_text("utf-8"))
        return data

    def _gravar(self, dados: dict[str, Any]) -> None:
        tmp = self._arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1), "utf-8")
        tmp.replace(self._arquivo)

    def listar(self) -> dict[str, Any]:
        """Acompanhados primeiro, depois do mais recente ao mais antigo."""
        data = self._ler()
        items = sorted(
            data["itens"].values(),
            key=lambda i: (i.get("data_noticia") or i["visto_em"][:10]),
            reverse=True,
        )
        items.sort(key=lambda i: not i.get("acompanhado"))
        return {"pesquisando": self.pesquisando, "busca": data.get("busca"), "itens": items}

    def acompanhar(self, id_: str, sim: bool) -> dict[str, Any] | None:
        data = self._ler()
        item = data["itens"].get(id_)
        if item is None:
            return None
        item["acompanhado"] = sim
        self._gravar(data)
        return item  # type: ignore[no-any-return]

    def alertas(self) -> list[dict[str, Any]]:
        """Novidades de hoje dos rumores acompanhados (o notificador manda cada uma uma vez)."""
        today = self.hoje().isoformat()
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
            if n["registrada_em"][:10] == today
        ]

    async def pesquisar(self, execute: ExecuteClaude, query: str = "") -> dict[str, Any]:
        """Busca rumores pelo Claude Code (opcionalmente filtrando por [consulta], ex. "TRF5",
        "Pernambuco", "Analista de dados") e depois procura novidades dos acompanhados."""
        if self.pesquisando:
            return {"ja_rodando": True}
        self.pesquisando = True
        found, error = 0, ""
        try:
            today = self.hoje()
            focus = f' Foque em: "{query}".' if query.strip() else ""
            r = await execute(
                {
                    "prompt": f"Hoje é {today.isoformat()}. Liste os rumores e previsões de "
                    f"concursos com cargos de TI nas esferas federal, estadual e municipal, "
                    f"noticiados nos últimos 12 meses, para {today.year} e {today.year + 1}.{focus} "
                    "Traga o máximo que conseguir confirmar, cada um com a fonte.",
                    "sistema": SYSTEM,
                    "esquema": SCHEMA_SEARCH,
                    "limite_s": 900,
                    "effort": "medium",
                    "ferramentas": "WebSearch,WebFetch",
                }
            )
            async with self._trava:
                found = self._juntar(r.get("rumores") or [])
            await self._verificar(execute)
        except Exception as e:
            logger.exception("Falha na pesquisa de rumores")
            error = str(e)[:300] or type(e).__name__
        finally:
            data = self._ler()
            data["busca"] = {
                "em": _now(),
                "consulta": query,
                "achados": found,
                "erro": error,
            }
            self._gravar(data)
            self.pesquisando = False
        return {"erro": error} if error else {"achados": found}

    def _juntar(self, rumors: list[Any]) -> int:
        data = self._ler()
        items: dict[str, Any] = data["itens"]
        n = 0
        for r in rumors:
            if not isinstance(r, dict) or not r.get("orgao") or not r.get("fonte_url"):
                continue
            uf = str(r.get("uf") or "")[:2].upper()
            id_ = id_rumor(str(r["orgao"]), uf)
            fase = r.get("fase") if r.get("fase") in PHASES else "rumor"
            source = {"nome": str(r.get("fonte_nome") or ""), "url": str(r["fonte_url"])}
            item = items.get(id_)
            if item is None:
                item = items[id_] = {
                    "id": id_,
                    "acompanhado": False,
                    "novidades": [],
                    "fontes": [],
                    "visto_em": _now(),
                }
            elif PHASES.index(fase) < PHASES.index(item.get("fase") or "rumor"):
                fase = item["fase"]  # notícia mais antiga que a fase conhecida: a fase não volta
            elif item.get("acompanhado") and fase != item.get("fase"):
                self._novidade(item, f"Mudou para {fase}: {r.get('resumo', '')}", source, fase)
            item.update(
                orgao=str(r["orgao"]),
                uf=uf,
                esfera=r.get("esfera") if r.get("esfera") in SPHERES else "",
                fase=fase,
                cargos_ti=[str(c) for c in r.get("cargos_ti") or []],
                vagas_previstas=int(r.get("vagas_previstas") or 0),
                data_noticia=str(r.get("data_noticia") or ""),
                resumo=str(r.get("resumo") or ""),
                atualizado_em=_now(),
            )
            if source["url"] not in {f["url"] for f in item["fontes"]}:
                item["fontes"].append(source)
            n += 1
        self._gravar(data)
        return n

    def _novidade(self, item: dict[str, Any], text: str, fonte: dict[str, str], fase: str) -> None:
        item["novidades"].append(
            {"texto": text, "fonte": fonte, "fase": fase, "registrada_em": _now()}
        )

    async def _verificar(self, execute: ExecuteClaude) -> int:
        """Pede ao Claude o que saiu depois da última notícia conhecida de cada acompanhado."""
        acompanhados = [i for i in self._ler()["itens"].values() if i.get("acompanhado")]
        if not acompanhados:
            return 0
        def ultima(i: dict[str, Any]) -> str:
            if i["novidades"]:
                return str(i["novidades"][-1]["registrada_em"][:10])
            return str(i.get("data_noticia") or "?")

        items = "\n".join(
            f'- id "{i["id"]}": {i["orgao"]} ({i["uf"]}), fase {i["fase"]}, '
            f"última notícia {ultima(i)}: {i.get('resumo', '')}"
            for i in acompanhados
        )
        r = await execute(
            {
                "prompt": f"Hoje é {self.hoje().isoformat()}. Para cada concurso abaixo, procure o "
                "que saiu DEPOIS da última notícia indicada (autorização, comissão, banca, edital, "
                "datas, vagas de TI). Devolva só novidades reais, com o mesmo id; nada novo = não "
                f"inclua.\n{items}",
                "sistema": SYSTEM,
                "esquema": SCHEMA_UPDATES,
                "limite_s": 600,
                "effort": "medium",
                "ferramentas": "WebSearch,WebFetch",
            }
        )
        async with self._trava:
            data = self._ler()
            n = 0
            for nov in r.get("novidades") or []:
                item = data["itens"].get(str(nov.get("id", "")))
                if not item or not item.get("acompanhado") or not nov.get("texto"):
                    continue
                source = {"nome": str(nov.get("fonte_nome") or ""), "url": str(nov["fonte_url"])}
                ja = {(x["fonte"]["url"], x["texto"]) for x in item["novidades"]}
                if (source["url"], nov["texto"]) in ja:
                    continue
                fase = nov.get("fase") if nov.get("fase") in PHASES else item["fase"]
                self._novidade(item, str(nov["texto"]), source, fase)
                item["fase"] = fase
                if source["url"] not in {f["url"] for f in item["fontes"]}:
                    item["fontes"].append(source)
                n += 1
            self._gravar(data)
        return n

    async def rodar(
        self, execute: ExecuteClaude, interval_s: float, delay_s: float = 600
    ) -> None:
        """Reverifica os acompanhados de tempos em tempos (sem busca nova de rumores)."""
        await asyncio.sleep(delay_s)
        while True:
            if not self.pesquisando:
                self.pesquisando = True
                try:
                    await self._verificar(execute)
                except Exception:
                    logger.exception("Falha ao reverificar os rumores acompanhados")
                finally:
                    self.pesquisando = False
            await asyncio.sleep(interval_s)
