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

from concursos.geo import AGENTE, Geo, haversine_km

logger = logging.getLogger("concursos.radar")

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]

REGIOES = ("nacional", "nordeste", "norte", "centrooeste", "sudeste", "sul")
URL_LISTA = "https://www.pciconcursos.com.br/concursos/{}/"
TI = re.compile(
    r"(?i)\b(T\.?I\b|tecnologia da informa|inform[aá]tica|sistemas? de informa|"
    r"desenvolv\w* de sistemas|programador|analista de sistemas|banco de dados|"
    r"ci[eê]ncia de dados|seguran[cç]a da informa|"
    r"cibern|redes de computa|infraestrutura de TI|suporte t[eé]cnico|software|computa[cç][aã]o|"
    r"intelig[eê]ncia artificial|devops|cloud)"
)
GENERICO = re.compile(r"(?i)v[aá]rios cargos|diversos cargos|cargos de n[ií]vel")
LIMITE_LLM = 12
"""Concursos detalhados pela LLM a cada coleta (os outros ficam para a próxima)."""
TENTATIVAS = 3
"""Coletas em que um concurso que deu erro na LLM volta para a fila."""

ExecutarClaude = Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]
"""`IA.executar` da API: `{prompt, sistema, esquema, limite_s, ferramentas}` → JSON do esquema."""

ESFERAS = ("federal", "estadual", "municipal")
_ESTADUAL = re.compile(
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


def esfera_do_orgao(orgao: str, regiao: str = "") -> str:
    """Esfera pelo nome do órgão (o explícito de estado vem antes: "Ministério Público do
    Estado", "Tribunal de Contas dos Municípios"); a listagem "nacional" do PCI é federal."""
    if _ESTADUAL.search(orgao):
        return "estadual"
    if _MUNICIPAL.search(orgao):
        return "municipal"
    if _FEDERAL.search(orgao) or regiao == "nacional":
        return "federal"
    return "estadual"


_TEXTO = {"type": "string"}
_CIDADE = {
    "type": "object",
    "properties": {"cidade": _TEXTO, "uf": _TEXTO},
    "required": ["cidade", "uf"],
}
ESQUEMA_CLAUDE = {
    "type": "object",
    "properties": {
        "concursos": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "orgao": _TEXTO,
                    "uf": _TEXTO,
                    "esfera": {"type": "string", "enum": list(ESFERAS)},
                    "situacao": {"type": "string", "enum": ["aberto", "previsto"]},
                    "fonte_url": _TEXTO,
                    "banca": _TEXTO,
                    "edital_url": _TEXTO,
                    "link_inscricao": _TEXTO,
                    "inscricoes_inicio": _TEXTO,
                    "inscricoes_fim": _TEXTO,
                    "data_prova": _TEXTO,
                    "horario_prova": _TEXTO,
                    "taxa": _TEXTO,
                    "nivel": _TEXTO,
                    "sede": _CIDADE,
                    "cidades_prova": {"type": "array", "items": _CIDADE},
                    "vagas_ti": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "cargo": _TEXTO,
                                "vagas": {"type": "integer"},
                                "cadastro_reserva": {"type": "boolean"},
                                "salario": {"type": "number"},
                                "requisitos": _TEXTO,
                            },
                            "required": ["cargo", "vagas", "salario"],
                        },
                    },
                    "resumo": _TEXTO,
                },
                "required": ["orgao", "uf", "situacao", "fonte_url", "vagas_ti", "resumo"],
            },
        }
    },
    "required": ["concursos"],
}

SISTEMA_CLAUDE = """Você pesquisa na internet (WebSearch e WebFetch) concursos públicos brasileiros
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

SISTEMA = """Você extrai dados de concursos públicos brasileiros para um candidato da área de TI.
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


def _agora() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _texto(pagina: str) -> str:
    pagina = re.sub(
        r"(?is)<(script|style|noscript|svg|nav|footer|header|form)[^>]*>.*?</\1>", " ", pagina
    )
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"(?s)<[^>]+>", " ", pagina))).strip()


def _data_br(texto: str) -> str:
    m = re.search(r"(\d{2})/(\d{2})/(\d{4})", texto)
    return f"{m[3]}-{m[2]}-{m[1]}" if m else ""


def _iso(texto: Any) -> str:
    t = str(texto or "")[:10]
    try:
        return date.fromisoformat(t).isoformat()
    except ValueError:
        return ""


def ler_listagem(pagina: str, regiao: str) -> list[dict[str, Any]]:
    """Itens da listagem do PCI: órgão, UF, vagas/salário, cargos, nível e fim das inscrições."""
    itens = []
    for bloco in pagina.split('data-url="')[1:]:
        url = bloco.split('"', 1)[0]
        fim = bloco.find('class="clear"')
        corpo = bloco[: fim if fim > 0 else 3000]
        orgao = re.search(r'class="ca"><a[^>]*>(.*?)</a>', corpo, re.S)
        titulo = re.search(r'class="ca"><a[^>]*title="([^"]*)"', corpo)
        uf = re.search(r'class="cc">(.*?)</div>', corpo, re.S)
        cd = re.search(r'class="cd">(.*?)</div>', corpo, re.S)
        ce = re.search(r'class="ce">(.*?)</div>', corpo, re.S)
        if not orgao or "pciconcursos.com.br/noticias/" not in url:
            continue
        partes = [_texto(p) for p in re.split(r"<br\s*/?>", cd[1])] if cd else []
        itens.append(
            {
                "id": url.rstrip("/").rsplit("/", 1)[-1][:120],
                "url": url,
                "orgao": _texto(orgao[1]),
                "titulo": html.unescape(titulo[1]) if titulo else "",
                "uf": _texto(uf[1])[:2].upper() if uf else "",
                "vagas_txt": partes[0] if partes else "",
                "cargos_txt": " ".join(partes[1:-1])
                if len(partes) > 2
                else (partes[1] if len(partes) > 1 else ""),
                "nivel": partes[-1] if len(partes) > 2 else "",
                "inscricao_ate": _data_br(_texto(ce[1])) if ce else "",
                "regiao": regiao,
            }
        )
    return itens


def corpo_noticia(pagina: str) -> str:
    """Só o texto da notícia do PCI: sem menu, "Destaques" e as notícias relacionadas ao lado."""
    i = pagina.find('itemprop="articleBody"')
    if i < 0:
        return pagina
    fim = min(
        (j for j in (pagina.find(k, i) for k in ('id="preparacao"', "lateralnoticias")) if j > 0),
        default=-1,
    )
    return pagina[i : fim if fim > 0 else i + 20000]


def sites_oficiais(texto: str) -> list[str]:
    """Endereços citados na notícia (banca, órgão), fora o próprio PCI."""
    achados = re.findall(
        r"(?i)\b((?:https?://)?(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:/[^\s,;()<>]*)?)", texto
    )
    saida = []
    for a in achados:
        a = a.rstrip(".")
        if "pciconcursos" in a or "." not in a.split("/")[0] or re.fullmatch(r"[\d.,]+", a):
            continue
        if not re.search(r"\.(br|org|com|gov|edu)(/|$)", a.split("?")[0] + "/"):
            continue
        saida.append(a if a.startswith("http") else "https://" + a)
    return list(dict.fromkeys(saida))


def trechos_edital(texto: str, limite: int = 7000) -> str:
    """Parágrafos do edital que falam de local/data da prova, vagas, remuneração e inscrições."""
    chave = re.compile(
        r"(?i)(ser[aã]o (realizad|aplicad)|cidades? de (prova|realiza)|local de prova|"
        r"data prov[aá]vel|"
        r"remunera|vencimento|inscri[cç][oõ]es|hor[aá]rio)"
    )
    linhas = [ln.strip() for ln in texto.splitlines() if ln.strip()]
    saida: list[str] = []
    total = 0
    for i, ln in enumerate(linhas):
        if chave.search(ln):
            trecho = " ".join(linhas[max(0, i - 1) : i + 3])
            saida.append(trecho)
            total += len(trecho)
            if total > limite:
                break
    return "\n".join(saida)


def _json(resposta: str) -> dict[str, Any]:
    m = re.search(r"\{.*\}", resposta, re.S)
    if not m:
        raise ValueError("a LLM não devolveu JSON")
    dados: dict[str, Any] = json.loads(m[0])
    return dados


class Radar:
    def __init__(
        self,
        raiz: str | Path,
        llm: ChatLLM | None,
        origem: tuple[str, str] = ("Custódia", "PE"),
        transporte: httpx.AsyncBaseTransport | None = None,
        hoje: Callable[[], date] = date.today,
    ) -> None:
        self.raiz = Path(raiz).expanduser() / "radar"
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
        dados: dict[str, Any] = json.loads(self._arquivo.read_text("utf-8"))
        return dados

    def _gravar(self, dados: dict[str, Any]) -> None:
        tmp = self._arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1), "utf-8")
        tmp.replace(self._arquivo)

    def listar(self) -> dict[str, Any]:
        """Concursos de TI com inscrição aberta (ou sem data), do local de prova mais perto ao
        mais longe."""
        dados = self._ler()
        hoje = self.hoje().isoformat()
        abertos = [
            i
            for i in dados["itens"].values()
            if i["estado"] == "detalhado"
            and (i.get("inscricoes_fim") or i["inscricao_ate"] or "9999") >= hoje
        ]
        for i in abertos:
            if i.get("esfera") not in ESFERAS:  # gravados antes da esfera existir (ou vazia)
                i["esfera"] = esfera_do_orgao(i["orgao"], i.get("regiao", ""))
        abertos.sort(key=lambda i: (i.get("mais_proximo") or {}).get("km", 99999))
        return {
            "atualizado": dados["atualizado"],
            "erro": dados.get("erro", ""),
            "origem": dados["origem"],
            "coletando": self.coletando,
            "pesquisando_claude": self.pesquisando_claude,
            "claude": dados.get("claude"),
            "itens": abertos,
            "pendentes": sum(1 for i in dados["itens"].values() if i["estado"] == "novo"),
            "falhas": sum(1 for i in dados["itens"].values() if i["estado"] == "erro"),
        }

    def item(self, id_: str) -> dict[str, Any] | None:
        return self._ler()["itens"].get(id_)

    async def _origem(self) -> dict[str, Any]:
        o = await self.geo.municipio(*self.origem_nome)
        if not o:
            raise ValueError(f"Cidade de origem não encontrada: {self.origem_nome}")
        return o

    async def atualizar(self, limite_llm: int = LIMITE_LLM) -> dict[str, Any]:
        """Uma coleta: listagens → filtro de TI → detalhamento dos novos pela LLM local."""
        if self._trava.locked():
            return {"ja_rodando": True}
        async with self._trava:
            self.coletando = True
            try:
                return await self._atualizar(limite_llm)
            finally:
                self.coletando = False

    async def _atualizar(self, limite_llm: int) -> dict[str, Any]:
        dados = self._ler()
        dados["origem"] = await self._origem()
        itens: dict[str, Any] = dados["itens"]
        novos = 0
        async with self._http() as c:
            for regiao in REGIOES:
                try:
                    r = await c.get(URL_LISTA.format(regiao), headers={"User-Agent": AGENTE})
                    r.raise_for_status()
                except httpx.HTTPError as e:
                    logger.warning("PCI %s: %s", regiao, e)
                    continue
                for i in ler_listagem(r.text, regiao):
                    if i["id"] in itens:
                        itens[i["id"]].update(
                            inscricao_ate=i["inscricao_ate"] or itens[i["id"]]["inscricao_ate"]
                        )
                        continue
                    texto = f"{i['titulo']} {i['cargos_txt']}"
                    if TI.search(texto) or GENERICO.search(texto):
                        itens[i["id"]] = {
                            **i,
                            "esfera": esfera_do_orgao(i["orgao"], regiao),
                            "estado": "novo",
                            "visto_em": _agora(),
                        }
                        novos += 1
        # some o que fechou há mais de 30 dias
        corte = (self.hoje() - timedelta(30)).isoformat()
        for k in [
            k
            for k, v in itens.items()
            if (v.get("inscricoes_fim") or v["inscricao_ate"] or "9999") < corte
        ]:
            del itens[k]
        self._gravar(dados)

        # o que falhou (ex.: worker desligado) volta para a fila, até TENTATIVAS vezes
        for v in itens.values():
            if v["estado"] == "erro" and v.get("tentativas", 1) < TENTATIVAS:
                v["estado"] = "novo"

        detalhados = falhas = 0
        ultima_falha = ""
        if self.llm:
            for i in [v for v in itens.values() if v["estado"] == "novo"]:
                if detalhados >= limite_llm:
                    break
                try:
                    if await self._detalhar(i, dados["origem"]):
                        detalhados += 1
                except Exception as e:
                    logger.exception("Falha ao detalhar %s", i["id"])
                    ultima_falha = str(e)[:300] or type(e).__name__
                    i.update(
                        estado="erro", erro=ultima_falha, tentativas=i.get("tentativas", 0) + 1
                    )
                    detalhados += 1
                    falhas += 1
                self._gravar(dados)
                await asyncio.sleep(0.5)  # gentil com o PCI
        dados["atualizado"] = _agora()
        if not self.llm:
            dados["erro"] = "LLM local indisponível: só a listagem foi lida."
        elif falhas:
            dados["erro"] = f"A LLM local falhou em {falhas} edital(is): {ultima_falha}"
        else:
            dados["erro"] = ""
        self._gravar(dados)
        return {"novos": novos, "detalhados": detalhados}

    async def _detalhar(self, item: dict[str, Any], origem: dict[str, Any]) -> bool:
        """Devolve se chamou a LLM (notícia sem TI é descartada sem ela)."""
        async with self._http() as c:
            r = await c.get(item["url"], headers={"User-Agent": AGENTE})
            r.raise_for_status()
            pagina = r.text
            noticia = _texto(corpo_noticia(pagina))
            if not TI.search(noticia):
                item.update(estado="nao_ti")
                return False
            provas = re.search(r'class="li_provas"><a href="([^"]+)"', pagina)
            item["provas_url"] = provas[1] if provas else ""
            # os PDFs do PCI ficam atrás de captcha: o edital vem do site oficial citado na notícia
            pdfs: list[str] = []
            for site in sites_oficiais(noticia)[:2]:
                pdfs += await self._pdfs_do_site(c, site)
            pdfs = list(dict.fromkeys(pdfs))[:8]
            edital = ""
            if pdfs:
                edital = await self._trechos_pdf(c, pdfs[0])
        assert self.llm is not None
        prompt = (
            f"Órgão: {item['orgao']} ({item['uf']})\n"
            f"Listagem: {item['vagas_txt']} | {item['cargos_txt']}\n"
            f"Inscrição até: {item['inscricao_ate']}\nLinks de PDF do site oficial:\n"
            + "\n".join(pdfs)
            + f"\n\n<noticia>\n{noticia[:12000]}\n</noticia>\n"
            + (f"\n<trechos_do_edital>\n{edital}\n</trechos_do_edital>" if edital else "")
        )
        d = _json(
            await self.llm(
                [{"role": "system", "content": SISTEMA}, {"role": "user", "content": prompt}]
            )
        )
        if not d.get("ti") or not d.get("vagas_ti"):
            item.update(estado="nao_ti")
            return True
        edital_url = str(d.get("edital_url") or "")
        d["edital_url"] = edital_url if edital_url in pdfs else (pdfs[0] if pdfs else "")
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
        item.update(estado="detalhado", detalhado_em=_agora(), erro="")

    async def pesquisar_claude(self, executar: ExecutarClaude) -> dict[str, Any]:
        """Pesquisa na web pelo Claude Code (worker do PC): abertos e previstos para este ano e
        o próximo, que a listagem do PCI não traz, uma rodada por esfera (federal, estadual e
        municipal; uma busca só para o Brasil todo estoura o tempo e traz poucos). Os achados
        entram no radar como `detalhado`; a falha de uma esfera não perde as outras."""
        if self.pesquisando_claude:
            return {"ja_rodando": True}
        self.pesquisando_claude = True
        ids: set[str] = set()
        erros: list[str] = []
        try:
            origem = await self._origem()
            for esfera in ESFERAS:
                try:
                    r = await executar(
                        {
                            "prompt": self._prompt_claude(esfera, origem),
                            "sistema": SISTEMA_CLAUDE,
                            "esquema": ESQUEMA_CLAUDE,
                            "limite_s": 900,
                            "effort": "medium",
                            "ferramentas": "WebSearch,WebFetch",
                        }
                    )
                    # a coleta do PCI lê e grava o arquivo inteiro: espera ela terminar
                    async with self._trava:
                        ids |= await self._juntar_claude(r, origem, esfera)
                except Exception as e:
                    logger.exception("Falha na pesquisa %s do radar pelo Claude", esfera)
                    erros.append(f"{esfera}: {str(e)[:200] or type(e).__name__}")
        except Exception as e:
            logger.exception("Falha na pesquisa do radar pelo Claude")
            erros.append(str(e)[:300])
        finally:
            dados = self._ler()
            dados["claude"] = {"em": _agora(), "achados": len(ids), "erro": "; ".join(erros)}
            self._gravar(dados)
            self.pesquisando_claude = False
        if erros and not ids:
            return {"erro": "; ".join(erros)}
        return {"achados": len(ids)}

    def _prompt_claude(self, esfera: str, origem: dict[str, Any]) -> str:
        hoje = self.hoje()
        perto = f"{origem['cidade']}/{origem['uf']}"
        alvo = {
            "federal": "FEDERAIS no Brasil todo (tribunais federais, eleitorais, do trabalho e "
            "superiores, MPU, ministérios, agências reguladoras, autarquias, INSS, IBGE, bancos "
            "e estatais federais, institutos e universidades federais, Concurso Nacional "
            "Unificado, Forças Armadas, conselhos profissionais). As provas costumam ser nas "
            "capitais: liste as cidades de aplicação do edital",
            "estadual": "ESTADUAIS e do DF, em todos os estados (governos, secretarias, TJ, TCE, "
            "assembleias, MP e defensorias estaduais, polícias, Detran, universidades e empresas "
            f"estaduais), com prioridade para o Nordeste e para os estados perto de {perto}. As "
            "provas costumam ser na capital ou em cidades-polo: liste as do edital",
            "municipal": "MUNICIPAIS (prefeituras, câmaras, autarquias e consórcios municipais), "
            f"com prioridade para o Nordeste e para as cidades até uns 600 km de {perto}",
        }[esfera]
        return (
            f"Hoje é {hoje.isoformat()}. Liste os concursos públicos {alvo}, com vagas de TI, "
            f"com inscrição aberta ou previstos para {hoje.year} e {hoje.year + 1}. "
            f'Use "esfera": "{esfera}". Traga o máximo que conseguir confirmar.'
        )

    async def _juntar_claude(
        self, r: dict[str, Any], origem: dict[str, Any], esfera: str
    ) -> set[str]:
        hoje = self.hoje()
        dados = self._ler()
        itens: dict[str, Any] = dados["itens"]
        ids: set[str] = set()
        for c in r.get("concursos") or []:
            if not isinstance(c, dict) or not c.get("orgao") or not c.get("vagas_ti"):
                continue
            uf = str(c.get("uf") or "")[:2].upper()
            id_ = _id_claude(str(c["orgao"]), uf)
            fim = _iso(c.get("inscricoes_fim"))
            if fim and fim < hoje.isoformat():
                continue
            item = itens.get(id_) or {
                "id": id_,
                "titulo": "",
                "vagas_txt": "",
                "cargos_txt": "",
                "regiao": "",
                "visto_em": _agora(),
            }
            item.update(
                orgao=str(c["orgao"]),
                uf=uf,
                esfera=c.get("esfera") if c.get("esfera") in ESFERAS else esfera,
                url=str(c.get("fonte_url") or ""),
                nivel=str(c.get("nivel") or ""),
                inscricao_ate=fim,
                fonte="claude",
                situacao=str(c.get("situacao") or ""),
                pdfs=[],
            )
            try:
                await self._aplicar(item, c, origem)
            except Exception:
                logger.exception("Falha ao localizar %s", id_)
                continue
            itens[id_] = item
            ids.add(id_)
        self._gravar(dados)
        return ids

    async def _localizar(
        self, item: dict[str, Any], cidades: list[Any], origem: dict[str, Any]
    ) -> None:
        locais = []
        for cp in cidades[:30]:
            if not isinstance(cp, dict):
                continue
            m = await self.geo.municipio(str(cp.get("cidade") or ""), str(cp.get("uf") or ""))
            if m and not m["aproximado"]:
                locais.append(m)
        if not locais:
            # edital sem cidades: federal → capitais; estadual → capital da UF; municipal → sede
            esfera = item.get("esfera") or esfera_do_orgao(item["orgao"])
            supostos = []
            if esfera == "federal":
                supostos = await self.geo.capitais()
            elif esfera == "estadual" and item.get("uf"):
                supostos = [m for m in [await self.geo.municipio("", item["uf"])] if m]
            if item.get("sede") and esfera != "federal":
                supostos.append(item["sede"])
            vistos = set()
            for m in supostos:
                if (m["cidade"], m["uf"]) not in vistos:
                    vistos.add((m["cidade"], m["uf"]))
                    locais.append({**m, "suposto": True})
        orig = (origem["lat"], origem["lon"])
        for loc in locais:
            loc["km_reta"] = round(haversine_km(orig, (loc["lat"], loc["lon"])))
        locais.sort(key=lambda x: x["km_reta"])
        # rota de verdade só para os 3 mais perto em linha reta (o OSRM público é compartilhado)
        for loc in locais[:3]:
            rota = await self.geo.rota(origem, loc)
            loc.update(km=rota["km"], horas=rota["horas"], estimada=rota["estimada"])
        com_rota = [x for x in locais if "km" in x]
        item["locais_prova"] = locais
        item["mais_proximo"] = min(com_rota, key=lambda x: x["km"]) if com_rota else None

    async def _pdfs_do_site(self, c: httpx.AsyncClient, site: str) -> list[str]:
        """PDFs de edital da página oficial do concurso (com "edital" no link ou texto primeiro)."""
        try:
            r = await c.get(site, headers={"User-Agent": AGENTE}, timeout=20)
            r.raise_for_status()
        except httpx.HTTPError:
            return []
        if "html" not in r.headers.get("content-type", "html"):
            return []
        links = re.findall(r'(?is)<a[^>]+href="([^"]+\.pdf[^"]*)"[^>]*>(.*?)</a>', r.text)
        com_edital = [h for h, t in links if "edital" in (h + _texto(t)).lower()]
        outros = [h for h, _ in links if h not in com_edital]
        return [urljoin(str(r.url), h) for h in com_edital + outros]

    async def _trechos_pdf(self, c: httpx.AsyncClient, url: str) -> str:
        try:
            r = await c.get(url, headers={"User-Agent": AGENTE})
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
        return trechos_edital(p.stdout)

    async def rota(self, id_: str) -> dict[str, Any] | None:
        """Rota completa (com a linha da estrada) da origem até o local de prova mais próximo."""
        item = self.item(id_)
        if not item or not item.get("mais_proximo"):
            return None
        origem = await self._origem()
        rota = await self.geo.rota(origem, item["mais_proximo"])
        return {"origem": origem, "destino": item["mais_proximo"], **rota}

    async def rodar(self, intervalo_s: float, atraso_s: float = 60) -> None:
        await asyncio.sleep(atraso_s)  # não pesa no boot do servidor
        while True:
            try:
                await self.atualizar()
            except Exception:
                logger.exception("Falha na coleta do radar de concursos")
            await asyncio.sleep(intervalo_s)
