"""IT exam rumors (federal, state and municipal): authorization requests, committees, boards being
chosen and reported forecasts, each with its source. The ones the user follows are rechecked every
so often by Claude Code; anything new becomes news and an alert (the dashboard notifier sends it as
push).

Everything lives in `<concursos_dir>/radar/rumores.json`."""

import asyncio
import json
import logging
import re
from collections.abc import Awaitable, Callable
from datetime import date, datetime
from pathlib import Path
from typing import Any

logger = logging.getLogger("exams.rumors")

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

SYSTEM = """You search the internet (WebSearch and WebFetch) for RUMORS and FORECASTS of Brazilian
public service exams that have or should have IT positions (IT analyst/technician, development,
systems, data, networks, information security, infrastructure, support, informatics). Rumor = an
exam still WITHOUT a notice: authorization request, published authorization, forecast in the LOA or
the budget, organizing committee formed, board being chosen/hired, statements by officials. Check
several sources (PCI Concursos, JC Concursos, Folha Dirigida, Estratégia, Gran, Direção, Diário
Oficial, agency and board sites) and only bring what you found on a real page. "fase": rumor |
solicitado | autorizado | comissao | banca | edital (notice already published). "esfera": federal,
estadual (states and DF) or municipal. "uf" = state of the agency; "BR" if national. Do not invent:
whatever you cannot find stays "" or []; dates as YYYY-MM-DD; "fonte_nome" = site name; "fonte_url"
= page where you read it; "resumo" with up to 2 sentences in Brazilian Portuguese about the current
stage."""


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
        self._lock = asyncio.Lock()

    def _read(self) -> dict[str, Any]:
        if not self._arquivo.exists():
            return {"itens": {}, "busca": None}
        data: dict[str, Any] = json.loads(self._arquivo.read_text("utf-8"))
        return data

    def _write(self, dados: dict[str, Any]) -> None:
        tmp = self._arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1), "utf-8")
        tmp.replace(self._arquivo)

    def list_all(self) -> dict[str, Any]:
        """Followed ones first, then from newest to oldest."""
        data = self._read()
        items = sorted(
            data["itens"].values(),
            key=lambda i: (i.get("data_noticia") or i["visto_em"][:10]),
            reverse=True,
        )
        items.sort(key=lambda i: not i.get("acompanhado"))
        return {"pesquisando": self.pesquisando, "busca": data.get("busca"), "itens": items}

    def track(self, id_: str, sim: bool) -> dict[str, Any] | None:
        data = self._read()
        item = data["itens"].get(id_)
        if item is None:
            return None
        item["acompanhado"] = sim
        self._write(data)
        return item  # type: ignore[no-any-return]

    def alerts(self) -> list[dict[str, Any]]:
        """Today's news of the followed rumors (the notifier sends each one once)."""
        today = self.hoje().isoformat()
        return [
            {
                "nivel": "aviso",
                "texto": f"Rumor {i['orgao']}: {n['texto']}",
                "concurso": i["orgao"],
                "rumor_id": i["id"],
            }
            for i in self._read()["itens"].values()
            if i.get("acompanhado")
            for n in i.get("novidades", [])
            if n["registrada_em"][:10] == today
        ]

    async def pesquisar(self, execute: ExecuteClaude, query: str = "") -> dict[str, Any]:
        """Searches rumors through Claude Code (optionally filtered by a query, e.g. "TRF5",
        "Pernambuco", "Analista de dados") and then looks for news of the followed ones."""
        if self.pesquisando:
            return {"ja_rodando": True}
        self.pesquisando = True
        found, error = 0, ""
        try:
            today = self.hoje()
            focus = f' Focus on: "{query}".' if query.strip() else ""
            r = await execute(
                {
                    "prompt": f"Today is {today.isoformat()}. List the rumors and forecasts of "
                    f"exams with IT positions in the federal, state and municipal spheres, "
                    f"reported in the last 12 months, for {today.year} and {today.year + 1}."
                    f"{focus} "
                    "Bring as many as you can confirm, each one with its source.",
                    "sistema": SYSTEM,
                    "esquema": SCHEMA_SEARCH,
                    "limite_s": 900,
                    "effort": "medium",
                    "ferramentas": "WebSearch,WebFetch",
                }
            )
            async with self._lock:
                found = self._join(r.get("rumores") or [])
            await self._verify(execute)
        except Exception as e:
            logger.exception("Falha na pesquisa de rumores")
            error = str(e)[:300] or type(e).__name__
        finally:
            data = self._read()
            data["busca"] = {
                "em": _now(),
                "consulta": query,
                "achados": found,
                "erro": error,
            }
            self._write(data)
            self.pesquisando = False
        return {"erro": error} if error else {"achados": found}

    def _join(self, rumors: list[Any]) -> int:
        data = self._read()
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
                fase = item["fase"]  # news older than the known phase: the phase does not go back
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
        self._write(data)
        return n

    def _novidade(self, item: dict[str, Any], text: str, fonte: dict[str, str], fase: str) -> None:
        item["novidades"].append(
            {"texto": text, "fonte": fonte, "fase": fase, "registrada_em": _now()}
        )

    async def _verify(self, execute: ExecuteClaude) -> int:
        """Asks Claude what came out after the last known news of each followed one."""
        acompanhados = [i for i in self._read()["itens"].values() if i.get("acompanhado")]
        if not acompanhados:
            return 0

        def ultima(i: dict[str, Any]) -> str:
            if i["novidades"]:
                return str(i["novidades"][-1]["registrada_em"][:10])
            return str(i.get("data_noticia") or "?")

        items = "\n".join(
            f'- id "{i["id"]}": {i["orgao"]} ({i["uf"]}), phase {i["fase"]}, '
            f"last news {ultima(i)}: {i.get('resumo', '')}"
            for i in acompanhados
        )
        r = await execute(
            {
                "prompt": f"Today is {self.hoje().isoformat()}. For each exam below, look for what "
                "came out AFTER the last news item indicated (authorization, committee, board, "
                "notice, dates, IT positions). Return only real news, with the same id; nothing "
                f"new = do not include it.\n{items}",
                "sistema": SYSTEM,
                "esquema": SCHEMA_UPDATES,
                "limite_s": 600,
                "effort": "medium",
                "ferramentas": "WebSearch,WebFetch",
            }
        )
        async with self._lock:
            data = self._read()
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
            self._write(data)
        return n

    async def rodar(self, execute: ExecuteClaude, interval_s: float, delay_s: float = 600) -> None:
        """Rechecks the followed ones every so often (without a new rumor search)."""
        await asyncio.sleep(delay_s)
        while True:
            if not self.pesquisando:
                self.pesquisando = True
                try:
                    await self._verify(execute)
                except Exception:
                    logger.exception("Falha ao reverificar os rumores acompanhados")
                finally:
                    self.pesquisando = False
            await asyncio.sleep(interval_s)
