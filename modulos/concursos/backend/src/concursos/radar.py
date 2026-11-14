"""Radar de concursos de TI abertos: de tempos em tempos lê as listagens do PCI Concursos
(nacional e por região) e separa os de TI. Para cada novo, a LLM local lê a notícia e trechos do
edital e tira vagas e salários de TI, período de inscrição, data/horário da prova, cidades de
aplicação e o link do edital. Cada local de prova ganha coordenadas (IBGE) e a rota de carro desde
a cidade de origem (Custódia/PE por padrão); o mais próximo vai para o mapa do app.

Dados em `<raiz>/radar/radar.json`; `estado` de cada item: `novo` → `detalhado` | `nao_ti` |
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

from concursos.geo import AGENT, Geo, haversine_km

logger = logging.getLogger("concursos.radar")

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
    """Esfera pelo nome do órgão (o explícito de estado vem antes: "Ministério Público do
    Estado", "Tribunal de Contas dos Municípios"); a listagem "nacional" do PCI é federal."""
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

SYSTEM_CLAUDE = """Você pesquisa na internet (WebSearch e WebFetch) concursos públicos brasileiros
com vagas de TI (desenvolvimento, sistemas, dados, redes, segurança, infraestrutura, suporte,
informática) para um candidato. Consulte várias fontes (PCI Concursos, JC Concursos, Folha Dirigida,
Estratégia, Gran, sites das bancas e dos órgãos) e confirme cada concurso em pelo menos uma fonte.
Inclua os com inscrição aberta e os previstos/autorizados (comissão formada, banca contratada,
edital iminente). "esfera": federal (União, autarquias, estatais, tribunais federais, institutos e
universidades federais, conselhos profissionais), estadual (estados e DF, TJ, TCE, MP e polícias
estaduais) ou municipal (prefeituras e câmaras). "uf" = UF do órgão; "BR" se for nacional.
"cidades_prova" = cidades onde as provas serão APLICADAS segundo o edital, não a cidade do órgão:
concursos federais e estaduais costumam aplicar nas capitais ou em cidades-polo; se o edital disser
"todas as capitais", liste as 27 capitais; sem edital ainda, use as da edição anterior ou [].
Não invente: o que não achar fica "" ou []; datas em AAAA-MM-DD; salário em reais
(número, remuneração inicial); "fonte_url" = página onde você confirmou; "resumo" com até 2 frases
(diga a fase, ex.: "Banca definida, edital previsto para março")."""


def _id_claude(orgao: str, uf: str) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", f"{orgao} {uf}".lower()).strip("-")
    return "claude-" + base[:100]

SYSTEM = """Você extrai dados de concursos públicos brasileiros para um candidato da área de TI.
Use SOMENTE o texto dado (notícia e trechos do edital); o que não estiver lá fica "" ou [].
Responda SOMENTE com JSON:
{"ti": true, "banca": "", "edital_url": "", "link_inscricao": "", "inscricoes_inicio": "AAAA-MM-DD",
 "inscricoes_fim": "AAAA-MM-DD", "data_prova": "AAAA-MM-DD", "horario_prova": "", "taxa": "",
 "sede": {"cidade": "", "uf": ""}, "cidades_prova": [{"cidade": "", "uf": ""}],
 "vagas_ti": [{"cargo": "", "vagas": 0, "cadastro_reserva": false, "salario": 0.0,
               "requisitos": ""}],
 "resumo": ""}
Regras: "ti" = há vaga de TI (desenvolvimento, sistemas, dados, redes, segurança, infraestrutura,
suporte, informática); "vagas_ti" só com esses cargos, salário em reais (número, remuneração
inicial); "edital_url" só um dos links de PDF listados; "cidades_prova" = cidades onde as provas
serão aplicadas (federais e estaduais costumam aplicar nas capitais ou em cidades-polo, não na
sede; se o texto disser que é na cidade da vaga ou da sede, use a sede); "resumo" com
até 2 frases."""


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
    """Itens da listagem do PCI: órgão, UF, vagas/salário, cargos, nível e fim das inscrições."""
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
    """Só o texto da notícia do PCI: sem menu, "Destaques" e as notícias relacionadas ao lado."""
    i = page.find('itemprop="articleBody"')
    if i < 0:
        return page
    end = min(
        (j for j in (page.find(k, i) for k in ('id="preparacao"', "lateralnoticias")) if j > 0),
        default=-1,
    )
    return page[i : end if end > 0 else i + 20000]


def sites_official(text: str) -> list[str]:
    """Endereços citados na notícia (banca, órgão), fora o próprio PCI."""
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
    """Parágrafos do edital que falam de local/data da prova, vagas, remuneração e inscrições."""
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
        transporte: httpx.AsyncBaseTransport | None = None,
        hoje: Callable[[], date] = date.today,
    ) -> None:
        self.raiz = Path(root).expanduser() / "radar"
        self.raiz.mkdir(parents=True, exist_ok=True)
        self.llm = llm
        self.origem_nome = origem
        self.geo = Geo(self.raiz, transporte)
        self._transporte = transporte
        self.hoje = hoje
        self._arquivo = self.raiz / "radar.json"
        self._trava = asyncio.Lock()
        self.coletando = False
        self.pesquisando_claude = False

    def _http(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=self._transporte, timeout=30, follow_redirects=True)

    def _ler(self) -> dict[str, Any]:
        if not self._arquivo.exists():
            return {"atualizado": None, "erro": "", "origem": None, "itens": {}}
        data: dict[str, Any] = json.loads(self._arquivo.read_text("utf-8"))
        return data

    def _gravar(self, dados: dict[str, Any]) -> None:
        tmp = self._arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1), "utf-8")
        tmp.replace(self._arquivo)

    def listar(self) -> dict[str, Any]:
        """Concursos de TI com inscrição aberta (ou sem data), do local de prova mais perto ao
        mais longe."""
        data = self._ler()
        today = self.hoje().isoformat()
        abertos = [
            i
            for i in data["itens"].values()
            if i["estado"] == "detalhado"
            and (i.get("inscricoes_fim") or i["inscricao_ate"] or "9999") >= today
        ]
        for i in abertos:
            if i.get("esfera") not in SPHERES:  # gravados antes da esfera existir (ou vazia)
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
        return self._ler()["itens"].get(id_)

    async def _origem(self) -> dict[str, Any]:
        o = await self.geo.municipio(*self.origem_nome)
        if not o:
            raise ValueError(f"Cidade de origem não encontrada: {self.origem_nome}")
        return o

    async def atualizar(self, limit_llm: int = LIMIT_LLM) -> dict[str, Any]:
        """Uma coleta: listagens → filtro de TI → detalhamento dos novos pela LLM local."""
        if self._trava.locked():
            return {"ja_rodando": True}
        async with self._trava:
            self.coletando = True
            try:
                return await self._atualizar(limit_llm)
            finally:
                self.coletando = False

    async def _atualizar(self, limit_llm: int) -> dict[str, Any]:
        data = self._ler()
        data["origem"] = await self._origem()
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
        # some o que fechou há mais de 30 dias
        cut = (self.hoje() - timedelta(30)).isoformat()
        for k in [
            k
            for k, v in items.items()
            if (v.get("inscricoes_fim") or v["inscricao_ate"] or "9999") < cut
        ]:
            del items[k]
        self._gravar(data)

        # o que falhou (ex.: worker desligado) volta para a fila, até TENTATIVAS vezes
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
                self._gravar(data)
                await asyncio.sleep(0.5)  # gentil com o PCI
        data["atualizado"] = _now()
        if not self.llm:
            data["erro"] = "LLM local indisponível: só a listagem foi lida."
        elif failures:
            data["erro"] = f"A LLM local falhou em {failures} edital(is): {last_failure}"
        else:
            data["erro"] = ""
        self._gravar(data)
        return {"novos": new, "detalhados": detalhados}

    async def _detalhar(self, item: dict[str, Any], origem: dict[str, Any]) -> bool:
        """Devolve se chamou a LLM (notícia sem TI é descartada sem ela)."""
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
            # os PDFs do PCI ficam atrás de captcha: o edital vem do site oficial citado na notícia
            pdfs: list[str] = []
            for site in sites_official(news_item)[:2]:
                pdfs += await self._pdfs_do_site(c, site)
            pdfs = list(dict.fromkeys(pdfs))[:8]
            notice = ""
            if pdfs:
                notice = await self._trechos_pdf(c, pdfs[0])
        assert self.llm is not None
        prompt = (
            f"Órgão: {item['orgao']} ({item['uf']})\n"
            f"Listagem: {item['vagas_txt']} | {item['cargos_txt']}\n"
            f"Inscrição até: {item['inscricao_ate']}\nLinks de PDF do site oficial:\n"
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
        await self._aplicar(item, d, origem)
        return True

    async def _aplicar(
        self, item: dict[str, Any], d: dict[str, Any], origem: dict[str, Any]
    ) -> None:
        """Grava no item os dados extraídos (LLM local ou Claude), com sede, locais e rotas."""
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
        await self._localizar(item, d.get("cidades_prova") or [], origem)
        item.update(estado="detalhado", detalhado_em=_now(), erro="")

    async def pesquisar_claude(self, execute: ExecuteClaude) -> dict[str, Any]:
        """Pesquisa na web pelo Claude Code (worker do PC): abertos e previstos para este ano e
        o próximo, que a listagem do PCI não traz, uma rodada por esfera (federal, estadual e
        municipal; uma busca só para o Brasil todo estoura o tempo e traz poucos). Os achados
        entram no radar como `detalhado`; a falha de uma esfera não perde as outras."""
        if self.pesquisando_claude:
            return {"ja_rodando": True}
        self.pesquisando_claude = True
        ids: set[str] = set()
        errors: list[str] = []
        try:
            origin = await self._origem()
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
                    # a coleta do PCI lê e grava o arquivo inteiro: espera ela terminar
                    async with self._trava:
                        ids |= await self._juntar_claude(r, origin, sphere)
                except Exception as e:
                    logger.exception("Falha na pesquisa %s do radar pelo Claude", sphere)
                    errors.append(f"{sphere}: {str(e)[:200] or type(e).__name__}")
        except Exception as e:
            logger.exception("Falha na pesquisa do radar pelo Claude")
            errors.append(str(e)[:300])
        finally:
            data = self._ler()
            data["claude"] = {"em": _now(), "achados": len(ids), "erro": "; ".join(errors)}
            self._gravar(data)
            self.pesquisando_claude = False
        if errors and not ids:
            return {"erro": "; ".join(errors)}
        return {"achados": len(ids)}

    def _prompt_claude(self, esfera: str, origem: dict[str, Any]) -> str:
        today = self.hoje()
        near = f"{origem['cidade']}/{origem['uf']}"
        target = {
            "federal": "FEDERAIS no Brasil todo (tribunais federais, eleitorais, do trabalho e "
            "superiores, MPU, ministérios, agências reguladoras, autarquias, INSS, IBGE, bancos "
            "e estatais federais, institutos e universidades federais, Concurso Nacional "
            "Unificado, Forças Armadas, conselhos profissionais). As provas costumam ser nas "
            "capitais: liste as cidades de aplicação do edital",
            "estadual": "ESTADUAIS e do DF, em todos os estados (governos, secretarias, TJ, TCE, "
            "assembleias, MP e defensorias estaduais, polícias, Detran, universidades e empresas "
            f"estaduais), com prioridade para o Nordeste e para os estados perto de {near}. As "
            "provas costumam ser na capital ou em cidades-polo: liste as do edital",
            "municipal": "MUNICIPAIS (prefeituras, câmaras, autarquias e consórcios municipais), "
            f"com prioridade para o Nordeste e para as cidades até uns 600 km de {near}",
        }[esfera]
        return (
            f"Hoje é {today.isoformat()}. Liste os concursos públicos {target}, com vagas de TI, "
            f"com inscrição aberta ou previstos para {today.year} e {today.year + 1}. "
            f'Use "esfera": "{esfera}". Traga o máximo que conseguir confirmar.'
        )

    async def _juntar_claude(
        self, r: dict[str, Any], origem: dict[str, Any], esfera: str
    ) -> set[str]:
        today = self.hoje()
        data = self._ler()
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
                await self._aplicar(item, c, origem)
            except Exception:
                logger.exception("Falha ao localizar %s", id_)
                continue
            items[id_] = item
            ids.add(id_)
        self._gravar(data)
        return ids

    async def _localizar(
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
            # edital sem cidades: federal → capitais; estadual → capital da UF; municipal → sede
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
        # rota de verdade só para os 3 mais perto em linha reta (o OSRM público é compartilhado)
        for loc in local_names[:3]:
            route = await self.geo.rota(origem, loc)
            loc.update(km=route["km"], horas=route["horas"], estimada=route["estimada"])
        with_route = [x for x in local_names if "km" in x]
        item["locais_prova"] = local_names
        item["mais_proximo"] = min(with_route, key=lambda x: x["km"]) if with_route else None

    async def _pdfs_do_site(self, c: httpx.AsyncClient, site: str) -> list[str]:
        """PDFs de edital da página oficial do concurso (com "edital" no link ou texto primeiro)."""
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

    async def _trechos_pdf(self, c: httpx.AsyncClient, url: str) -> str:
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

    async def rota(self, id_: str) -> dict[str, Any] | None:
        """Rota completa (com a linha da estrada) da origem até o local de prova mais próximo."""
        item = self.item(id_)
        if not item or not item.get("mais_proximo"):
            return None
        origin = await self._origem()
        route = await self.geo.rota(origin, item["mais_proximo"])
        return {"origem": origin, "destino": item["mais_proximo"], **route}

    async def rodar(self, interval_s: float, delay_s: float = 60) -> None:
        await asyncio.sleep(delay_s)  # não pesa no boot do servidor
        while True:
            try:
                await self.atualizar()
            except Exception:
                logger.exception("Falha na coleta do radar de concursos")
            await asyncio.sleep(interval_s)
