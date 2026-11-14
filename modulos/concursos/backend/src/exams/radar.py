"""Radar of open IT exams: every so often it reads the PCI Concursos listings (national and per
region) and picks the IT ones. For each new one, the local LLM reads the news and excerpts of the
notice and extracts IT openings and salaries, registration period, exam date/time, exam cities and
the notice link. Each exam location gets coordinates (IBGE) and the car route from the home city
(Custódia/PE by default); the closest goes to the app map.

Data in `<root>/radar/radar.json`; `estado` of each item: `novo` → `detalhado` | `nao_ti` |
`erro`."""

import asyncio
import html
import json
import logging
import re
import subprocess
import tempfile
from collections.abc import Awaitable, Callable
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any
from urllib.parse import urljoin

import httpx

from exams.geo import AGENT, Geo, haversine_km

logger = logging.getLogger("exams.radar")

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]

REGIONS = ("nacional", "nordeste", "norte", "centrooeste", "sudeste", "sul")
URL_LIST = "https://www.pciconcursos.com.br/concursos/{}/"
TI = re.compile(
    r"(?i)\b(T\.?I\b|tecnologia da informa|inform[aá]tica|sistemas? de informa|"
    r"desenvolv\w* de sistemas|programador|analista de sistemas|banco de dados|"
    r"ci[eê]ncia de dados|seguran[cç]a da informa|"
    r"cibern|redes de computa|infraestrutura de TI|suporte t[eé]cnico|software|computa[cç][aã]o|"
    r"intelig[eê]ncia artificial|devops|cloud)"
)
GENERIC = re.compile(r"(?i)v[aá]rios cargos|diversos cargos|cargos de n[ií]vel")
LIMIT_LLM = 12
"""Concursos detalhados pela LLM a cada coleta (os outros ficam para a próxima)."""
ATTEMPTS = 3
"""Coletas em que um concurso que deu erro na LLM volta para a fila."""

ExecuteClaude = Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]
"""`IA.executar` da API: `{prompt, sistema, esquema, limite_s, ferramentas}` → JSON do esquema."""

SPHERES = ("federal", "estadual", "municipal")
_STATE = re.compile(
    r"(?i)estadual|do estado|governo d[eo]|tribunal de justi|tribunal de contas d|assembleia"
    r"|pol[ií]cia (militar|civil|penal)|bombeiros|\bdetran|\btce\b|\btj[a-z]{2}\b|\bsefaz"
)
_MUNICIPAL = re.compile(r"(?i)prefeitura|c[aâ]mara (?!dos deputados)|munic[ií]p")
_FEDERAL = re.compile(
    r"(?i)federal|nacional|unificado|\btr[eft]\b|\btr[eft][ -]?\d|\bt[rs][eft]-|\bst[fjm]\b"
    r"|\btst\b|\btcu\b|\bmp[uft]\b|\binss\b|\bibge\b|\bibama\b|\bicmbio\b|\bagu\b"
    r"|\bcgu\b|\bdpu\b|\bdnit\b|\bebserh\b|\bserpro\b|\bdataprev\b|\bbnb\b|banco do"
    r"|caixa econ|\bbacen\b|petrobras|correios|minist[eé]rio|ag[eê]ncia|senado|c[aâ]mara dos"
    r"|\b(anatel|aneel|anac|anvisa|ancine|antt|antaq|anp|ans|ana)\b|\bif[a-z]{2,5}\b"
    r"|\bembrapa\b|\bfiocruz\b|\bcnpq\b|\binpe\b|\bprf\b|\bpf\b"
    r"|ex[eé]rcito|marinha|aeron[aá]utica|conselho (regional|federal)"
)


def sphere_of_agency(orgao: str, region: str = "") -> str:
    """Government level from the agency name (the explicit state one comes first: "Ministério
    Público do Estado", "Tribunal de Contas dos Municípios"); the PCI "nacional" listing is
    federal."""
    if _STATE.search(orgao):
        return "estadual"
    if _MUNICIPAL.search(orgao):
        return "municipal"
    if _FEDERAL.search(orgao) or region == "nacional":
        return "federal"
    return "estadual"


_TEXT = {"type": "string"}
_CITY = {
    "type": "object",
    "properties": {"cidade": _TEXT, "uf": _TEXT},
    "required": ["cidade", "uf"],
}
SCHEMA_CLAUDE = {
    "type": "object",
    "properties": {
        "concursos": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "orgao": _TEXT,
                    "uf": _TEXT,
                    "esfera": {"type": "string", "enum": list(SPHERES)},
                    "situacao": {"type": "string", "enum": ["aberto", "previsto"]},
                    "fonte_url": _TEXT,
                    "banca": _TEXT,
                    "edital_url": _TEXT,
                    "link_inscricao": _TEXT,
                    "inscricoes_inicio": _TEXT,
                    "inscricoes_fim": _TEXT,
                    "data_prova": _TEXT,
                    "horario_prova": _TEXT,
                    "taxa": _TEXT,
                    "nivel": _TEXT,
                    "sede": _CITY,
                    "cidades_prova": {"type": "array", "items": _CITY},
                    "vagas_ti": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "cargo": _TEXT,
                                "vagas": {"type": "integer"},
                                "cadastro_reserva": {"type": "boolean"},
                                "salario": {"type": "number"},
                                "requisitos": _TEXT,
                            },
                            "required": ["cargo", "vagas", "salario"],
                        },
                    },
                    "resumo": _TEXT,
                },
                "required": ["orgao", "uf", "situacao", "fonte_url", "vagas_ti", "resumo"],
            },
        }
    },
    "required": ["concursos"],
}

SYSTEM_CLAUDE = """You search the internet (WebSearch and WebFetch) for Brazilian public service
exams (concursos públicos) with IT positions (development, systems, data, networks, security,
infrastructure, support, informatics) for a candidate. Check several sources (PCI Concursos, JC
Concursos, Folha Dirigida, Estratégia, Gran, exam board and agency sites) and confirm each exam in
at least one source. Include the ones with open registration and the planned/authorized ones
(committee formed, board hired, notice imminent). "esfera": federal (Union, federal agencies, state
companies, federal courts, federal institutes and universities, professional councils), estadual
(states and DF, TJ, TCE, MP and state police) or municipal (city halls and councils). "uf" = state
of the agency; "BR" if national. "cidades_prova" = cities where the exams will be HELD according to
the notice, not the agency's city: federal and state exams are usually held in the capitals or in
hub cities; if the notice says "todas as capitais", list the 27 capitals; with no notice yet, use
the previous edition's or []. Do not invent: whatever you cannot find stays "" or []; dates as
YYYY-MM-DD; salary in reais (number, starting pay); "fonte_url" = page where you confirmed it;
"resumo" with up to 2 sentences in Brazilian Portuguese (state the phase, e.g.: "Banca definida,
edital previsto para março")."""


def _id_claude(orgao: str, uf: str) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", f"{orgao} {uf}".lower()).strip("-")
    return "claude-" + base[:100]

SYSTEM = """You extract data about Brazilian public service exams for a candidate in the IT field.
Use ONLY the given text (news item and excerpts of the notice); whatever is not there stays "" or
[].
Respond ONLY with JSON:
{"ti": true, "banca": "", "edital_url": "", "link_inscricao": "", "inscricoes_inicio": "YYYY-MM-DD",
 "inscricoes_fim": "YYYY-MM-DD", "data_prova": "YYYY-MM-DD", "horario_prova": "", "taxa": "",
 "sede": {"cidade": "", "uf": ""}, "cidades_prova": [{"cidade": "", "uf": ""}],
 "vagas_ti": [{"cargo": "", "vagas": 0, "cadastro_reserva": false, "salario": 0.0,
               "requisitos": ""}],
 "resumo": ""}
Rules: "ti" = there is an IT position (development, systems, data, networks, security,
infrastructure, support, informatics); "vagas_ti" only with those positions, salary in reais
(number, starting pay); "edital_url" only one of the listed PDF links; "cidades_prova" = cities
where the exams will be held (federal and state exams are usually held in the capitals or hub
cities, not at the headquarters; if the text says it is in the position's or the headquarters' city,
use the headquarters); "resumo" with up to 2 sentences in Brazilian Portuguese."""


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _text(page: str) -> str:
    page = re.sub(
        r"(?is)<(script|style|noscript|svg|nav|footer|header|form)[^>]*>.*?</\1>", " ", page
    )
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"(?s)<[^>]+>", " ", page))).strip()


def _data_br(text: str) -> str:
    m = re.search(r"(\d{2})/(\d{2})/(\d{4})", text)
    return f"{m[3]}-{m[2]}-{m[1]}" if m else ""


def _iso(text: Any) -> str:
    t = str(text or "")[:10]
    try:
        return date.fromisoformat(t).isoformat()
    except ValueError:
        return ""


def read_listing(page: str, region: str) -> list[dict[str, Any]]:
    """PCI listing items: agency, state, openings/salary, positions, level and registration end."""
    items = []
    for block in page.split('data-url="')[1:]:
        url = block.split('"', 1)[0]
        end = block.find('class="clear"')
        body = block[: end if end > 0 else 3000]
        agency = re.search(r'class="ca"><a[^>]*>(.*?)</a>', body, re.S)
        title = re.search(r'class="ca"><a[^>]*title="([^"]*)"', body)
        uf = re.search(r'class="cc">(.*?)</div>', body, re.S)
        cd = re.search(r'class="cd">(.*?)</div>', body, re.S)
        ce = re.search(r'class="ce">(.*?)</div>', body, re.S)
        if not agency or "pciconcursos.com.br/noticias/" not in url:
            continue
        parts = [_text(p) for p in re.split(r"<br\s*/?>", cd[1])] if cd else []
        items.append(
            {
                "id": url.rstrip("/").rsplit("/", 1)[-1][:120],
                "url": url,
                "orgao": _text(agency[1]),
                "titulo": html.unescape(title[1]) if title else "",
                "uf": _text(uf[1])[:2].upper() if uf else "",
                "vagas_txt": parts[0] if parts else "",
                "cargos_txt": " ".join(parts[1:-1])
                if len(parts) > 2
                else (parts[1] if len(parts) > 1 else ""),
                "nivel": parts[-1] if len(parts) > 2 else "",
                "inscricao_ate": _data_br(_text(ce[1])) if ce else "",
                "regiao": region,
            }
        )
    return items


def body_news_item(page: str) -> str:
    """Only the PCI news text: without the menu, "Destaques" and the related news on the side."""
    i = page.find('itemprop="articleBody"')
    if i < 0:
        return page
    end = min(
        (j for j in (page.find(k, i) for k in ('id="preparacao"', "lateralnoticias")) if j > 0),
        default=-1,
    )
    return page[i : end if end > 0 else i + 20000]


def sites_official(text: str) -> list[str]:
    """Addresses cited in the news (board, agency), except PCI itself."""
    found = re.findall(
        r"(?i)\b((?:https?://)?(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:/[^\s,;()<>]*)?)", text
    )
    output = []
    for a in found:
        a = a.rstrip(".")
        if "pciconcursos" in a or "." not in a.split("/")[0] or re.fullmatch(r"[\d.,]+", a):
            continue
        if not re.search(r"\.(br|org|com|gov|edu)(/|$)", a.split("?")[0] + "/"):
            continue
        output.append(a if a.startswith("http") else "https://" + a)
    return list(dict.fromkeys(output))


def spans_notice(text: str, limite: int = 7000) -> str:
    """Notice paragraphs about exam location/date, openings, pay and registration."""
    key = re.compile(
        r"(?i)(ser[aã]o (realizad|aplicad)|cidades? de (prova|realiza)|local de prova|"
        r"data prov[aá]vel|"
        r"remunera|vencimento|inscri[cç][oõ]es|hor[aá]rio)"
    )
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    output: list[str] = []
    total = 0
    for i, ln in enumerate(lines):
        if key.search(ln):
            span = " ".join(lines[max(0, i - 1) : i + 3])
            output.append(span)
            total += len(span)
            if total > limite:
                break
    return "\n".join(output)


def _json(answer: str) -> dict[str, Any]:
    m = re.search(r"\{.*\}", answer, re.S)
    if not m:
        raise ValueError("a LLM não devolveu JSON")
    data: dict[str, Any] = json.loads(m[0])
    return data


class Radar:
    def __init__(
        self,
        root: str | Path,
        llm: ChatLLM | None,
        origem: tuple[str, str] = ("Custódia", "PE"),
        transport: httpx.AsyncBaseTransport | None = None,
        hoje: Callable[[], date] = date.today,
    ) -> None:
        self.root = Path(root).expanduser() / "radar"
        self.root.mkdir(parents=True, exist_ok=True)
        self.llm = llm
        self.origin_name = origem
        self.geo = Geo(self.root, transport)
        self._transporte = transport
        self.hoje = hoje
        self._arquivo = self.root / "radar.json"
        self._lock = asyncio.Lock()
        self.coletando = False
        self.pesquisando_claude = False

    def _http(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=self._transporte, timeout=30, follow_redirects=True)

    def _read(self) -> dict[str, Any]:
        if not self._arquivo.exists():
            return {"atualizado": None, "erro": "", "origem": None, "itens": {}}
        data: dict[str, Any] = json.loads(self._arquivo.read_text("utf-8"))
        return data

    def _write(self, dados: dict[str, Any]) -> None:
        tmp = self._arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1), "utf-8")
        tmp.replace(self._arquivo)

    def list_all(self) -> dict[str, Any]:
        """IT exams with open registration (or no date), from the closest exam location to the
        farthest."""
        data = self._read()
        today = self.hoje().isoformat()
        abertos = [
            i
            for i in data["itens"].values()
            if i["estado"] == "detalhado"
            and (i.get("inscricoes_fim") or i["inscricao_ate"] or "9999") >= today
        ]
        for i in abertos:
            # saved before the government level existed (or empty)
            if i.get("esfera") not in SPHERES:
                i["esfera"] = sphere_of_agency(i["orgao"], i.get("regiao", ""))
        abertos.sort(key=lambda i: (i.get("mais_proximo") or {}).get("km", 99999))
        return {
            "atualizado": data["atualizado"],
            "erro": data.get("erro", ""),
            "origem": data["origem"],
            "coletando": self.coletando,
            "pesquisando_claude": self.pesquisando_claude,
            "claude": data.get("claude"),
            "itens": abertos,
            "pendentes": sum(1 for i in data["itens"].values() if i["estado"] == "novo"),
            "falhas": sum(1 for i in data["itens"].values() if i["estado"] == "erro"),
        }

    def item(self, id_: str) -> dict[str, Any] | None:
        return self._read()["itens"].get(id_)

    async def _origin(self) -> dict[str, Any]:
        o = await self.geo.municipio(*self.origin_name)
        if not o:
            raise ValueError(f"Cidade de origem não encontrada: {self.origin_name}")
        return o

    async def atualizar(self, limit_llm: int = LIMIT_LLM) -> dict[str, Any]:
        """One collection: listings → IT filter → details of the new ones by the local LLM."""
        if self._lock.locked():
            return {"ja_rodando": True}
        async with self._lock:
            self.coletando = True
            try:
                return await self._update(limit_llm)
            finally:
                self.coletando = False

    async def _update(self, limit_llm: int) -> dict[str, Any]:
        data = self._read()
        data["origem"] = await self._origin()
        items: dict[str, Any] = data["itens"]
        new = 0
        async with self._http() as c:
            for region in REGIONS:
                try:
                    r = await c.get(URL_LIST.format(region), headers={"User-Agent": AGENT})
                    r.raise_for_status()
                except httpx.HTTPError as e:
                    logger.warning("PCI %s: %s", region, e)
                    continue
                for i in read_listing(r.text, region):
                    if i["id"] in items:
                        items[i["id"]].update(
                            inscricao_ate=i["inscricao_ate"] or items[i["id"]]["inscricao_ate"]
                        )
                        continue
                    text = f"{i['titulo']} {i['cargos_txt']}"
                    if TI.search(text) or GENERIC.search(text):
                        items[i["id"]] = {
                            **i,
                            "esfera": sphere_of_agency(i["orgao"], region),
                            "estado": "novo",
                            "visto_em": _now(),
                        }
                        new += 1
        # what closed more than 30 days ago goes away
        cut = (self.hoje() - timedelta(30)).isoformat()
        for k in [
            k
            for k, v in items.items()
            if (v.get("inscricoes_fim") or v["inscricao_ate"] or "9999") < cut
        ]:
            del items[k]
        self._write(data)

        # what failed (e.g. worker off) goes back to the queue, up to the max attempts
        for v in items.values():
            if v["estado"] == "erro" and v.get("tentativas", 1) < ATTEMPTS:
                v["estado"] = "novo"

        detalhados = failures = 0
        last_failure = ""
        if self.llm:
            for i in [v for v in items.values() if v["estado"] == "novo"]:
                if detalhados >= limit_llm:
                    break
                try:
                    if await self._detalhar(i, data["origem"]):
                        detalhados += 1
                except Exception as e:
                    logger.exception("Falha ao detalhar %s", i["id"])
                    last_failure = str(e)[:300] or type(e).__name__
                    i.update(
                        estado="erro", erro=last_failure, tentativas=i.get("tentativas", 0) + 1
                    )
                    detalhados += 1
                    failures += 1
                self._write(data)
                await asyncio.sleep(0.5)  # be gentle with PCI
        data["atualizado"] = _now()
        if not self.llm:
            data["erro"] = "LLM local indisponível: só a listagem foi lida."
        elif failures:
            data["erro"] = f"A LLM local falhou em {failures} edital(is): {last_failure}"
        else:
            data["erro"] = ""
        self._write(data)
        return {"novos": new, "detalhados": detalhados}

    async def _detalhar(self, item: dict[str, Any], origem: dict[str, Any]) -> bool:
        """Returns whether the LLM was called (news without IT is discarded without it)."""
        async with self._http() as c:
            r = await c.get(item["url"], headers={"User-Agent": AGENT})
            r.raise_for_status()
            page = r.text
            news_item = _text(body_news_item(page))
            if not TI.search(news_item):
                item.update(estado="nao_ti")
                return False
            provas = re.search(r'class="li_provas"><a href="([^"]+)"', page)
            item["provas_url"] = provas[1] if provas else ""
            # PCI PDFs sit behind a captcha: the notice comes from the official site cited in the
            # news
            pdfs: list[str] = []
            for site in sites_official(news_item)[:2]:
                pdfs += await self._pdfs_of_site(c, site)
            pdfs = list(dict.fromkeys(pdfs))[:8]
            notice = ""
            if pdfs:
                notice = await self._spans_pdf(c, pdfs[0])
        assert self.llm is not None
        prompt = (
            f"Agency: {item['orgao']} ({item['uf']})\n"
            f"Listing: {item['vagas_txt']} | {item['cargos_txt']}\n"
            f"Registration until: {item['inscricao_ate']}\nPDF links from the official site:\n"
            + "\n".join(pdfs)
            + f"\n\n<noticia>\n{news_item[:12000]}\n</noticia>\n"
            + (f"\n<trechos_do_edital>\n{notice}\n</trechos_do_edital>" if notice else "")
        )
        d = _json(
            await self.llm(
                [{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}]
            )
        )
        if not d.get("ti") or not d.get("vagas_ti"):
            item.update(estado="nao_ti")
            return True
        notice_url = str(d.get("edital_url") or "")
        d["edital_url"] = notice_url if notice_url in pdfs else (pdfs[0] if pdfs else "")
        item["pdfs"] = pdfs
        await self._apply(item, d, origem)
        return True

    async def _apply(
        self, item: dict[str, Any], d: dict[str, Any], origem: dict[str, Any]
    ) -> None:
        """Writes the extracted data (local LLM or Claude) into the item, with headquarters,
        locations and routes."""
        item.update(
            banca=str(d.get("banca") or ""),
            edital_url=str(d.get("edital_url") or ""),
            link_inscricao=str(d.get("link_inscricao") or ""),
            inscricoes_inicio=_iso(d.get("inscricoes_inicio")),
            inscricoes_fim=_iso(d.get("inscricoes_fim")) or item["inscricao_ate"],
            data_prova=_iso(d.get("data_prova")),
            horario_prova=str(d.get("horario_prova") or ""),
            taxa=str(d.get("taxa") or ""),
            resumo=str(d.get("resumo") or ""),
            vagas_ti=[
                {
                    "cargo": str(v.get("cargo") or ""),
                    "vagas": int(v.get("vagas") or 0),
                    "cadastro_reserva": bool(v.get("cadastro_reserva")),
                    "salario": float(v.get("salario") or 0),
                    "requisitos": str(v.get("requisitos") or ""),
                }
                for v in d.get("vagas_ti") or []
                if v.get("cargo")
            ],
        )
        item["total_vagas_ti"] = sum(v["vagas"] for v in item["vagas_ti"])
        item["salario_max"] = max((v["salario"] for v in item["vagas_ti"]), default=0)
        sede_d = d.get("sede") or {}
        item["sede"] = await self.geo.municipio(
            str(sede_d.get("cidade") or ""), str(sede_d.get("uf") or item["uf"])
        )
        await self._locate(item, d.get("cidades_prova") or [], origem)
        item.update(estado="detalhado", detalhado_em=_now(), erro="")

    async def search_claude(self, execute: ExecuteClaude) -> dict[str, Any]:
        """Web search through Claude Code (PC worker): open and expected for this year and the next,
        which the PCI listing does not bring, one round per level (federal, state and municipal;
        a single search for all of Brazil times out and brings few). Found ones enter the radar
        as `detalhado`; one level failing does not lose the others."""
        if self.pesquisando_claude:
            return {"ja_rodando": True}
        self.pesquisando_claude = True
        ids: set[str] = set()
        errors: list[str] = []
        try:
            origin = await self._origin()
            for sphere in SPHERES:
                try:
                    r = await execute(
                        {
                            "prompt": self._prompt_claude(sphere, origin),
                            "sistema": SYSTEM_CLAUDE,
                            "esquema": SCHEMA_CLAUDE,
                            "limite_s": 900,
                            "effort": "medium",
                            "ferramentas": "WebSearch,WebFetch",
                        }
                    )
                    # the PCI collection reads and writes the whole file: wait for it to finish
                    async with self._lock:
                        ids |= await self._join_claude(r, origin, sphere)
                except Exception as e:
                    logger.exception("Falha na pesquisa %s do radar pelo Claude", sphere)
                    errors.append(f"{sphere}: {str(e)[:200] or type(e).__name__}")
        except Exception as e:
            logger.exception("Falha na pesquisa do radar pelo Claude")
            errors.append(str(e)[:300])
        finally:
            data = self._read()
            data["claude"] = {"em": _now(), "achados": len(ids), "erro": "; ".join(errors)}
            self._write(data)
            self.pesquisando_claude = False
        if errors and not ids:
            return {"erro": "; ".join(errors)}
        return {"achados": len(ids)}

    def _prompt_claude(self, esfera: str, origem: dict[str, Any]) -> str:
        today = self.hoje()
        near = f"{origem['cidade']}/{origem['uf']}"
        target = {
            "federal": "FEDERAL ones across Brazil (federal, electoral, labor and superior "
            "courts, MPU, ministries, regulatory agencies, federal agencies, INSS, IBGE, federal "
            "banks and state companies, federal institutes and universities, Concurso Nacional "
            "Unificado, Armed Forces, professional councils). The exams are usually held in the "
            "capitals: list the exam cities from the notice",
            "estadual": "STATE and DF ones, in every state (governments, departments, TJ, TCE, "
            "legislative assemblies, state MP and public defenders, police, Detran, state "
            "universities and companies), giving priority to the Northeast and to the states "
            f"near {near}. The exams are usually held in the capital or in hub cities: list the "
            "ones from the notice",
            "municipal": "MUNICIPAL ones (city halls, city councils, municipal agencies and "
            "consortia), giving priority to the Northeast and to cities up to about 600 km from "
            f"{near}",
        }[esfera]
        return (
            f"Today is {today.isoformat()}. List the public service exams {target}, with IT "
            f"positions, with open registration or planned for {today.year} and "
            f'{today.year + 1}. Use "esfera": "{esfera}". Bring as many as you can confirm.'
        )

    async def _join_claude(
        self, r: dict[str, Any], origem: dict[str, Any], esfera: str
    ) -> set[str]:
        today = self.hoje()
        data = self._read()
        items: dict[str, Any] = data["itens"]
        ids: set[str] = set()
        for c in r.get("concursos") or []:
            if not isinstance(c, dict) or not c.get("orgao") or not c.get("vagas_ti"):
                continue
            uf = str(c.get("uf") or "")[:2].upper()
            id_ = _id_claude(str(c["orgao"]), uf)
            end = _iso(c.get("inscricoes_fim"))
            if end and end < today.isoformat():
                continue
            item = items.get(id_) or {
                "id": id_,
                "titulo": "",
                "vagas_txt": "",
                "cargos_txt": "",
                "regiao": "",
                "visto_em": _now(),
            }
            item.update(
                orgao=str(c["orgao"]),
                uf=uf,
                esfera=c.get("esfera") if c.get("esfera") in SPHERES else esfera,
                url=str(c.get("fonte_url") or ""),
                nivel=str(c.get("nivel") or ""),
                inscricao_ate=end,
                fonte="claude",
                situacao=str(c.get("situacao") or ""),
                pdfs=[],
            )
            try:
                await self._apply(item, c, origem)
            except Exception:
                logger.exception("Falha ao localizar %s", id_)
                continue
            items[id_] = item
            ids.add(id_)
        self._write(data)
        return ids

    async def _locate(
        self, item: dict[str, Any], cidades: list[Any], origem: dict[str, Any]
    ) -> None:
        local_names = []
        for cp in cidades[:30]:
            if not isinstance(cp, dict):
                continue
            m = await self.geo.municipio(str(cp.get("cidade") or ""), str(cp.get("uf") or ""))
            if m and not m["aproximado"]:
                local_names.append(m)
        if not local_names:
            # notice without cities: federal → capitals; state → state capital; municipal →
            # headquarters
            sphere = item.get("esfera") or sphere_of_agency(item["orgao"])
            supostos = []
            if sphere == "federal":
                supostos = await self.geo.capitais()
            elif sphere == "estadual" and item.get("uf"):
                supostos = [m for m in [await self.geo.municipio("", item["uf"])] if m]
            if item.get("sede") and sphere != "federal":
                supostos.append(item["sede"])
            seen = set()
            for m in supostos:
                if (m["cidade"], m["uf"]) not in seen:
                    seen.add((m["cidade"], m["uf"]))
                    local_names.append({**m, "suposto": True})
        orig = (origem["lat"], origem["lon"])
        for loc in local_names:
            loc["km_reta"] = round(haversine_km(orig, (loc["lat"], loc["lon"])))
        local_names.sort(key=lambda x: x["km_reta"])
        # real route only for the 3 closest in a straight line (the public OSRM is shared)
        for loc in local_names[:3]:
            route = await self.geo.route(origem, loc)
            loc.update(km=route["km"], horas=route["horas"], estimada=route["estimada"])
        with_route = [x for x in local_names if "km" in x]
        item["locais_prova"] = local_names
        item["mais_proximo"] = min(with_route, key=lambda x: x["km"]) if with_route else None

    async def _pdfs_of_site(self, c: httpx.AsyncClient, site: str) -> list[str]:
        """Notice PDFs from the official exam page (with "edital" in the link or text first)."""
        try:
            r = await c.get(site, headers={"User-Agent": AGENT}, timeout=20)
            r.raise_for_status()
        except httpx.HTTPError:
            return []
        if "html" not in r.headers.get("content-type", "html"):
            return []
        links = re.findall(r'(?is)<a[^>]+href="([^"]+\.pdf[^"]*)"[^>]*>(.*?)</a>', r.text)
        with_notice = [h for h, t in links if "edital" in (h + _text(t)).lower()]
        outros = [h for h, _ in links if h not in with_notice]
        return [urljoin(str(r.url), h) for h in with_notice + outros]

    async def _spans_pdf(self, c: httpx.AsyncClient, url: str) -> str:
        try:
            r = await c.get(url, headers={"User-Agent": AGENT})
            r.raise_for_status()
        except httpx.HTTPError:
            return ""
        if not r.content.startswith(b"%PDF") or len(r.content) > 40 << 20:
            return ""
        with tempfile.NamedTemporaryFile(suffix=".pdf") as f:
            f.write(r.content)
            f.flush()
            try:
                p = await asyncio.to_thread(
                    subprocess.run,
                    ["pdftotext", "-layout", f.name, "-"],
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
            except (FileNotFoundError, subprocess.TimeoutExpired):
                return ""
        return spans_notice(p.stdout)

    async def route(self, id_: str) -> dict[str, Any] | None:
        """Full route (with the road line) from home to the closest exam location."""
        item = self.item(id_)
        if not item or not item.get("mais_proximo"):
            return None
        origin = await self._origin()
        route = await self.geo.route(origin, item["mais_proximo"])
        return {"origem": origin, "destino": item["mais_proximo"], **route}

    async def rodar(self, interval_s: float, delay_s: float = 60) -> None:
        await asyncio.sleep(delay_s)  # does not weigh on server boot
        while True:
            try:
                await self.atualizar()
            except Exception:
                logger.exception("Falha na coleta do radar de concursos")
            await asyncio.sleep(interval_s)
