"""Comandos no PC pedidos pelo chat: abrir site, pesquisar, abrir programa e desligar.

Só ações desta lista, nunca um comando de shell livre: o pedido vem pela internet
(app → VPS → worker).
Rodam no ambiente gráfico do worker (serviço systemd do usuário, com DISPLAY da sessão)."""

import asyncio
import shutil
import subprocess
from typing import Any
from urllib.parse import quote_plus, urlparse

TASK = "pc"

BROWSERS = {"brave": "brave-browser", "firefox": "firefox"}

# nome falado → executável; só os instalados aparecem como disponíveis
PROGRAMS = {
    "brave": "brave-browser",
    "navegador": "brave-browser",
    "firefox": "firefox",
    "arquivos": "caja",
    "terminal": "mate-terminal",
    "calculadora": "mate-calc",
    "spotify": "spotify",
    "steam": "steam",
    "vscode": "code",
    "obsidian": "obsidian",
    "discord": "discord",
}

SEARCHES = {
    "google": "https://www.google.com/search?q={}",
    "youtube": "https://www.youtube.com/results?search_query={}",
}


class CommandInvalid(ValueError):
    pass


def programs() -> list[str]:
    return sorted(n for n, exe in PROGRAMS.items() if shutil.which(exe))


def _post(*args: str) -> None:
    # sessão própria: o programa continua aberto se o worker reiniciar
    subprocess.Popen(
        args,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def _browser(nome: str) -> str:
    exe = BROWSERS.get((nome or "brave").lower())
    if exe is None or not shutil.which(exe):
        raise CommandInvalid(f"navegador {nome!r} não disponível")
    return exe


def _url(url: str) -> str:
    url = url.strip()
    if "://" not in url:
        url = "https://" + url
    if urlparse(url).scheme not in ("http", "https") or not urlparse(url).netloc:
        raise CommandInvalid(f"endereço inválido: {url!r}")
    return url


async def execute(payload: dict[str, Any]) -> dict[str, Any]:
    """`payload["acao"]`: `abrir_site` (url), `pesquisar` (consulta, onde=google|youtube),
    `abrir_programa` (nome), `desligar` (minutos=0) ou `cancelar_desligar`.
    Devolve `{"ok": True, "detalhe": "..."}`; pedido inválido levanta [ComandoInvalido]."""
    action = str(payload.get("acao", ""))
    if action == "abrir_site":
        url = _url(str(payload.get("url", "")))
        _post(_browser(str(payload.get("navegador", ""))), url)
        return {"ok": True, "detalhe": f"Abri {url}"}
    if action == "pesquisar":
        query = str(payload.get("consulta", "")).strip()
        where = str(payload.get("onde") or "google").lower()
        if not query or where not in SEARCHES:
            raise CommandInvalid("pesquisa sem consulta ou com destino desconhecido")
        url = SEARCHES[where].format(quote_plus(query))
        _post(_browser(str(payload.get("navegador", ""))), url)
        return {"ok": True, "detalhe": f"Pesquisei “{query}” no {where}"}
    if action == "abrir_programa":
        name = str(payload.get("nome", "")).lower().strip()
        exe = PROGRAMS.get(name)
        if exe is None or not shutil.which(exe):
            available = ", ".join(programs())
            raise CommandInvalid(f"programa {name!r} não disponível (há: {available})")
        _post(exe)
        return {"ok": True, "detalhe": f"Abri {name}"}
    if action == "desligar":
        minutes = max(0, int(payload.get("minutos", 0)))
        if minutes:
            await _run("shutdown", "-h", f"+{minutes}")
            return {"ok": True, "detalhe": f"PC desliga em {minutes} min"}
        # alguns segundos para a resposta chegar ao app antes de a rede cair
        _post("sh", "-c", "sleep 3; systemctl poweroff")
        return {"ok": True, "detalhe": "Desligando o PC"}
    if action == "cancelar_desligar":
        await _run("shutdown", "-c")
        return {"ok": True, "detalhe": "Desligamento cancelado"}
    raise CommandInvalid(f"ação {action!r} desconhecida")


async def _run(*args: str) -> None:
    process = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE
    )
    _, error = await process.communicate()
    if process.returncode:
        raise RuntimeError(error.decode(errors="replace").strip() or f"{args[0]} falhou")
