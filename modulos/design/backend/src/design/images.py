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

URL_SEARCH = "https://www.googleapis.com/customsearch/v1"
# Tipo pedido no app → `imgType` da API (ícone: clip-art; figura: desenho de linhas).
KINDS = {"foto": "photo", "icone": "clipart", "figura": "lineart"}
EXTENSIONS = {
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/gif": "gif",
    "image/webp": "webp",
    "image/bmp": "bmp",
}
URL_BING = "https://www.bing.com/images/async"
FILTERS_BING = {
    "foto": "+filterui:photo-photo",
    "icone": "+filterui:photo-clipart",
    "figura": "+filterui:photo-linedrawing",
}
URL_OPENVERSE = "https://api.openverse.org/v1/images/"
URL_COMMONS = "https://commons.wikimedia.org/w/api.php"
BROWSER = {
    "User-Agent": "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/130.0 Mobile Safari/537.36",
    "Accept-Language": "pt-BR,pt;q=0.9",
}
_M_BING = re.compile(r'\bm="([^"]+)"')
_SIZE_BING = re.compile(r"(\d+)\s*(?:&#215;|×|x)\s*(\d+)")
MAX_BYTES = 8 * 1024 * 1024
_ID = re.compile(r"^[0-9a-f]{64}\.(png|jpg|gif|webp|bmp)$")


class Invalid(Exception):
    pass


async def _only_internet(requisicao: httpx.Request) -> None:
    """Recusa endereço da rede interna (também nos redirecionamentos): a rota baixa a URL que o app
    manda, e a VPS não pode virar ponte para os serviços dela."""
    host = requisicao.url.host
    enderecos = await asyncio.to_thread(socket.getaddrinfo, host, None)
    if any(not ipaddress.ip_address(e[4][0]).is_global for e in enderecos):
        raise Invalid("Endereço interno não é permitido")


class Images:
    def __init__(self, root: str | Path, chave: str = "", cx: str = "") -> None:
        self.root = Path(root).expanduser() / "imagens"
        self.root.mkdir(parents=True, exist_ok=True)
        self.key, self.cx = chave, cx

    async def fetch(self, q: str, tipo: str = "foto", page: int = 0) -> list[dict[str, Any]]:
        """Até 10 resultados por [pagina] (até a 10ª): Google com chave; senão Bing e Openverse."""
        page = min(page, 9)
        providers = [self._bing, self._commons, self._openverse]
        if self.key and self.cx:
            providers.insert(0, self._google)
        errors = []
        for provider in providers:
            try:
                return await provider(q, tipo, page)
            except (httpx.HTTPError, ValueError, KeyError, TypeError, Invalid) as e:
                errors.append(f"{provider.__name__.strip('_')}: {e}")
        raise Invalid("Busca de imagens indisponível (" + "; ".join(errors) + ")")

    async def _google(self, q: str, tipo: str, page: int) -> list[dict[str, Any]]:
        params: dict[str, Any] = {
            "key": self.key,
            "cx": self.cx,
            "q": q,
            "searchType": "image",
            "num": 10,
            "start": page * 10 + 1,
            "safe": "active",
        }
        if t := KINDS.get(tipo):
            params["imgType"] = t
        async with httpx.AsyncClient(timeout=15) as cliente:
            r = await cliente.get(URL_SEARCH, params=params)
        if r.status_code != 200:
            raise Invalid(f"Google respondeu {r.status_code}")
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

    async def _bing(self, q: str, tipo: str, page: int) -> list[dict[str, Any]]:
        """Página `async` do Bing Imagens: cada resultado é um `<a class="iusc" m="{json}">` seguido
        do tamanho (`1299 × 866`)."""
        # Sem `adlt`: com ele o Bing ignora o filtro de tipo (padrão: busca segura moderada).
        params: dict[str, Any] = {"q": q, "first": page * 10 + 1, "count": 10, "mmasync": 1}
        if f := FILTERS_BING.get(tipo):
            # Sem `form=IRFLTR` o Bing ignora o filtro.
            params.update(qft=f, form="IRFLTR")
        async with httpx.AsyncClient(
            timeout=15, headers=BROWSER, follow_redirects=True
        ) as cliente:
            r = await cliente.get(URL_BING, params=params)
        if r.status_code != 200:
            raise Invalid(f"Bing respondeu {r.status_code}")
        results = []
        for block in r.text.split('class="iusc"')[1:]:
            m = _M_BING.search(block)
            if not m:
                continue
            data = json.loads(html.unescape(m.group(1)))
            if not data.get("murl"):
                continue
            t = _SIZE_BING.search(block)
            results.append(
                {
                    "url": data["murl"],
                    "miniatura": data.get("turl", ""),
                    "titulo": html.unescape(data.get("t", "")),
                    "largura": int(t.group(1)) if t else 0,
                    "altura": int(t.group(2)) if t else 0,
                }
            )
            if len(results) == 10:
                break
        if not results and page == 0:
            raise Invalid("Bing não devolveu resultados")
        return results

    async def _commons(self, q: str, tipo: str, page: int) -> list[dict[str, Any]]:
        """Wikimedia Commons (só arquivos de imagem); ícone/figura viram termos da busca."""
        term = {"icone": " icon", "figura": " drawing"}.get(tipo, "")
        params: dict[str, Any] = {
            "action": "query",
            "format": "json",
            "generator": "search",
            "gsrnamespace": 6,
            "gsrsearch": f"{q}{term} filetype:bitmap",
            "gsrlimit": 10,
            "gsroffset": page * 10,
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
            raise Invalid(f"Wikimedia respondeu {r.status_code}")
        pages = sorted(
            r.json().get("query", {}).get("pages", {}).values(), key=lambda p: p.get("index", 0)
        )
        results = []
        for p in pages:
            info = (p.get("imageinfo") or [{}])[0]
            if info.get("mime") not in EXTENSIONS or not info.get("url"):
                continue
            results.append(
                {
                    "url": info["url"],
                    "miniatura": info.get("thumburl", ""),
                    "titulo": p.get("title", "").removeprefix("File:").rsplit(".", 1)[0],
                    "largura": info.get("width", 0),
                    "altura": info.get("height", 0),
                }
            )
        if not results and page == 0:
            raise Invalid("Wikimedia não devolveu resultados")
        return results

    async def _openverse(self, q: str, tipo: str, page: int) -> list[dict[str, Any]]:
        params: dict[str, Any] = {"q": q, "page_size": 10, "page": page + 1, "mature": "false"}
        if tipo == "foto":
            params["category"] = "photograph"
        elif tipo in ("icone", "figura"):
            params["category"] = "illustration,digitized_artwork"
        async with httpx.AsyncClient(
            timeout=15, headers={"User-Agent": "agent-design/1"}
        ) as cliente:
            r = await cliente.get(URL_OPENVERSE, params=params)
        if r.status_code != 200:
            raise Invalid(f"Openverse respondeu {r.status_code}")
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

    async def download(self, url: str) -> dict[str, Any]:
        """Copia a imagem de [url] para a pasta; devolve `{id}` (o mesmo para a mesma imagem)."""
        if not url.startswith(("http://", "https://")):
            raise Invalid("Endereço inválido")
        headers = {"User-Agent": "agent-design/1"}
        async with (
            httpx.AsyncClient(
                timeout=20, follow_redirects=True, event_hooks={"request": [_only_internet]}
            ) as cliente,
            cliente.stream("GET", url, headers=headers) as r,
        ):
            kind = r.headers.get("content-type", "").split(";")[0].strip().lower()
            if r.status_code != 200 or kind not in EXTENSIONS:
                raise Invalid("O endereço não devolveu uma imagem")
            data = bytearray()
            async for part in r.aiter_bytes():
                data += part
                if len(data) > MAX_BYTES:
                    raise Invalid("Imagem maior que 8 MB")
        id_ = f"{hashlib.sha256(data).hexdigest()}.{EXTENSIONS[kind]}"
        destination = self.root / id_
        if not destination.exists():
            destination.write_bytes(data)
        return {"id": id_}

    def caminho(self, id_: str) -> Path:
        p = self.root / id_
        if not _ID.match(id_) or not p.exists():
            raise FileNotFoundError(id_)
        return p
