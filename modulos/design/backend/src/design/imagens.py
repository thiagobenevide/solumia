"""Imagens do quadro: busca no Google Imagens e cópia local da imagem escolhida.

A busca usa a API oficial do Google (Programmable Search / Custom Search JSON, `searchType=image`)
quando há chave; sem chave (o Google fechou a API para contas novas) ou se ela falhar, cai no Bing
Imagens, no Wikimedia Commons e, por último, no Openverse (APIs abertas, sem chave). Da VPS o Bing
costuma vir vazio (IP de datacenter): por isso o app busca primeiro do próprio aparelho. A imagem
escolhida é baixada para `imagens/<sha256>.<ext>`: o quadro guarda só o id e não depende do site
de origem continuar no ar."""

import asyncio
import hashlib
import html
import ipaddress
import json
import re
import socket
from pathlib import Path
from typing import Any

import httpx

URL_BUSCA = "https://www.googleapis.com/customsearch/v1"
# Tipo pedido no app → `imgType` da API (ícone: clip-art; figura: desenho de linhas).
TIPOS = {"foto": "photo", "icone": "clipart", "figura": "lineart"}
EXTENSOES = {
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/gif": "gif",
    "image/webp": "webp",
    "image/bmp": "bmp",
}
URL_BING = "https://www.bing.com/images/async"
FILTROS_BING = {
    "foto": "+filterui:photo-photo",
    "icone": "+filterui:photo-clipart",
    "figura": "+filterui:photo-linedrawing",
}
URL_OPENVERSE = "https://api.openverse.org/v1/images/"
URL_COMMONS = "https://commons.wikimedia.org/w/api.php"
NAVEGADOR = {
    "User-Agent": "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/130.0 Mobile Safari/537.36",
    "Accept-Language": "pt-BR,pt;q=0.9",
}
_M_BING = re.compile(r'\bm="([^"]+)"')
_TAMANHO_BING = re.compile(r"(\d+)\s*(?:&#215;|×|x)\s*(\d+)")
MAX_BYTES = 8 * 1024 * 1024
_ID = re.compile(r"^[0-9a-f]{64}\.(png|jpg|gif|webp|bmp)$")


class Invalida(Exception):
    pass


async def _so_internet(requisicao: httpx.Request) -> None:
    """Recusa endereço da rede interna (também nos redirecionamentos): a rota baixa a URL que o app
    manda, e a VPS não pode virar ponte para os serviços dela."""
    host = requisicao.url.host
    enderecos = await asyncio.to_thread(socket.getaddrinfo, host, None)
    if any(not ipaddress.ip_address(e[4][0]).is_global for e in enderecos):
        raise Invalida("Endereço interno não é permitido")


class Imagens:
    def __init__(self, raiz: str | Path, chave: str = "", cx: str = "") -> None:
        self.raiz = Path(raiz).expanduser() / "imagens"
        self.raiz.mkdir(parents=True, exist_ok=True)
        self.chave, self.cx = chave, cx

    async def buscar(self, q: str, tipo: str = "foto", pagina: int = 0) -> list[dict[str, Any]]:
        """Até 10 resultados por [pagina] (até a 10ª): Google com chave; senão Bing e Openverse."""
        pagina = min(pagina, 9)
        provedores = [self._bing, self._commons, self._openverse]
        if self.chave and self.cx:
            provedores.insert(0, self._google)
        erros = []
        for provedor in provedores:
            try:
                return await provedor(q, tipo, pagina)
            except (httpx.HTTPError, ValueError, KeyError, TypeError, Invalida) as e:
                erros.append(f"{provedor.__name__.strip('_')}: {e}")
        raise Invalida("Busca de imagens indisponível (" + "; ".join(erros) + ")")

    async def _google(self, q: str, tipo: str, pagina: int) -> list[dict[str, Any]]:
        params: dict[str, Any] = {
            "key": self.chave,
            "cx": self.cx,
            "q": q,
            "searchType": "image",
            "num": 10,
            "start": pagina * 10 + 1,
            "safe": "active",
        }
        if t := TIPOS.get(tipo):
            params["imgType"] = t
        async with httpx.AsyncClient(timeout=15) as cliente:
            r = await cliente.get(URL_BUSCA, params=params)
        if r.status_code != 200:
            raise Invalida(f"Google respondeu {r.status_code}")
        return [
            {
                "url": i.get("link", ""),
                "miniatura": i.get("image", {}).get("thumbnailLink", ""),
                "titulo": i.get("title", ""),
                "largura": i.get("image", {}).get("width", 0),
                "altura": i.get("image", {}).get("height", 0),
            }
            for i in r.json().get("items", [])
            if i.get("link")
        ]

    async def _bing(self, q: str, tipo: str, pagina: int) -> list[dict[str, Any]]:
        """Página `async` do Bing Imagens: cada resultado é um `<a class="iusc" m="{json}">` seguido
        do tamanho (`1299 × 866`)."""
        # Sem `adlt`: com ele o Bing ignora o filtro de tipo (padrão: busca segura moderada).
        params: dict[str, Any] = {"q": q, "first": pagina * 10 + 1, "count": 10, "mmasync": 1}
        if f := FILTROS_BING.get(tipo):
            # Sem `form=IRFLTR` o Bing ignora o filtro.
            params.update(qft=f, form="IRFLTR")
        async with httpx.AsyncClient(
            timeout=15, headers=NAVEGADOR, follow_redirects=True
        ) as cliente:
            r = await cliente.get(URL_BING, params=params)
        if r.status_code != 200:
            raise Invalida(f"Bing respondeu {r.status_code}")
        resultados = []
        for bloco in r.text.split('class="iusc"')[1:]:
            m = _M_BING.search(bloco)
            if not m:
                continue
            dados = json.loads(html.unescape(m.group(1)))
            if not dados.get("murl"):
                continue
            t = _TAMANHO_BING.search(bloco)
            resultados.append(
                {
                    "url": dados["murl"],
                    "miniatura": dados.get("turl", ""),
                    "titulo": html.unescape(dados.get("t", "")),
                    "largura": int(t.group(1)) if t else 0,
                    "altura": int(t.group(2)) if t else 0,
                }
            )
            if len(resultados) == 10:
                break
        if not resultados and pagina == 0:
            raise Invalida("Bing não devolveu resultados")
        return resultados

    async def _commons(self, q: str, tipo: str, pagina: int) -> list[dict[str, Any]]:
        """Wikimedia Commons (só arquivos de imagem); ícone/figura viram termos da busca."""
        termo = {"icone": " icon", "figura": " drawing"}.get(tipo, "")
        params: dict[str, Any] = {
            "action": "query",
            "format": "json",
            "generator": "search",
            "gsrnamespace": 6,
            "gsrsearch": f"{q}{termo} filetype:bitmap",
            "gsrlimit": 10,
            "gsroffset": pagina * 10,
            "prop": "imageinfo",
            "iiprop": "url|size|mime",
            "iiurlwidth": 300,
        }
        async with httpx.AsyncClient(
            timeout=15,
            headers={
                "User-Agent": "agent-design/1.0 (https://agent.local; busca de imagens) httpx"
            },
        ) as cliente:
            r = await cliente.get(URL_COMMONS, params=params)
        if r.status_code != 200:
            raise Invalida(f"Wikimedia respondeu {r.status_code}")
        paginas = sorted(
            r.json().get("query", {}).get("pages", {}).values(), key=lambda p: p.get("index", 0)
        )
        resultados = []
        for p in paginas:
            info = (p.get("imageinfo") or [{}])[0]
            if info.get("mime") not in EXTENSOES or not info.get("url"):
                continue
            resultados.append(
                {
                    "url": info["url"],
                    "miniatura": info.get("thumburl", ""),
                    "titulo": p.get("title", "").removeprefix("File:").rsplit(".", 1)[0],
                    "largura": info.get("width", 0),
                    "altura": info.get("height", 0),
                }
            )
        if not resultados and pagina == 0:
            raise Invalida("Wikimedia não devolveu resultados")
        return resultados

    async def _openverse(self, q: str, tipo: str, pagina: int) -> list[dict[str, Any]]:
        params: dict[str, Any] = {"q": q, "page_size": 10, "page": pagina + 1, "mature": "false"}
        if tipo == "foto":
            params["category"] = "photograph"
        elif tipo in ("icone", "figura"):
            params["category"] = "illustration,digitized_artwork"
        async with httpx.AsyncClient(
            timeout=15, headers={"User-Agent": "agent-design/1"}
        ) as cliente:
            r = await cliente.get(URL_OPENVERSE, params=params)
        if r.status_code != 200:
            raise Invalida(f"Openverse respondeu {r.status_code}")
        return [
            {
                "url": i["url"],
                "miniatura": i.get("thumbnail") or "",
                "titulo": i.get("title") or "",
                "largura": i.get("width") or 0,
                "altura": i.get("height") or 0,
            }
            for i in r.json().get("results", [])
            if i.get("url")
        ]

    async def baixar(self, url: str) -> dict[str, Any]:
        """Copia a imagem de [url] para a pasta; devolve `{id}` (o mesmo para a mesma imagem)."""
        if not url.startswith(("http://", "https://")):
            raise Invalida("Endereço inválido")
        cabecalhos = {"User-Agent": "agent-design/1"}
        async with (
            httpx.AsyncClient(
                timeout=20, follow_redirects=True, event_hooks={"request": [_so_internet]}
            ) as cliente,
            cliente.stream("GET", url, headers=cabecalhos) as r,
        ):
            tipo = r.headers.get("content-type", "").split(";")[0].strip().lower()
            if r.status_code != 200 or tipo not in EXTENSOES:
                raise Invalida("O endereço não devolveu uma imagem")
            dados = bytearray()
            async for parte in r.aiter_bytes():
                dados += parte
                if len(dados) > MAX_BYTES:
                    raise Invalida("Imagem maior que 8 MB")
        id_ = f"{hashlib.sha256(dados).hexdigest()}.{EXTENSOES[tipo]}"
        destino = self.raiz / id_
        if not destino.exists():
            destino.write_bytes(dados)
        return {"id": id_}

    def caminho(self, id_: str) -> Path:
        p = self.raiz / id_
        if not _ID.match(id_) or not p.exists():
            raise FileNotFoundError(id_)
        return p
