"""Comandos no PC pedidos pelo chat: abrir site, pesquisar, abrir programa e desligar.

Só ações desta lista, nunca um comando de shell livre: o pedido vem pela internet
(app → VPS → worker).
Rodam no ambiente gráfico do worker (serviço systemd do usuário, com DISPLAY da sessão)."""

import asyncio
import shutil
import subprocess
from typing import Any
from urllib.parse import quote_plus, urlparse

TAREFA = "pc"

NAVEGADORES = {"brave": "brave-browser", "firefox": "firefox"}

# nome falado → executável; só os instalados aparecem como disponíveis
PROGRAMAS = {
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

BUSCAS = {
    "google": "https://www.google.com/search?q={}",
    "youtube": "https://www.youtube.com/results?search_query={}",
}


class ComandoInvalido(ValueError):
    pass


def programas() -> list[str]:
    return sorted(n for n, exe in PROGRAMAS.items() if shutil.which(exe))


def _lancar(*args: str) -> None:
    # sessão própria: o programa continua aberto se o worker reiniciar
    subprocess.Popen(
        args,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def _navegador(nome: str) -> str:
    exe = NAVEGADORES.get((nome or "brave").lower())
    if exe is None or not shutil.which(exe):
        raise ComandoInvalido(f"navegador {nome!r} não disponível")
    return exe


def _url(url: str) -> str:
    url = url.strip()
    if "://" not in url:
        url = "https://" + url
    if urlparse(url).scheme not in ("http", "https") or not urlparse(url).netloc:
        raise ComandoInvalido(f"endereço inválido: {url!r}")
    return url


async def executar(payload: dict[str, Any]) -> dict[str, Any]:
    """`payload["acao"]`: `abrir_site` (url), `pesquisar` (consulta, onde=google|youtube),
    `abrir_programa` (nome), `desligar` (minutos=0) ou `cancelar_desligar`.
    Devolve `{"ok": True, "detalhe": "..."}`; pedido inválido levanta [ComandoInvalido]."""
    acao = str(payload.get("acao", ""))
    if acao == "abrir_site":
        url = _url(str(payload.get("url", "")))
        _lancar(_navegador(str(payload.get("navegador", ""))), url)
        return {"ok": True, "detalhe": f"Abri {url}"}
    if acao == "pesquisar":
        consulta = str(payload.get("consulta", "")).strip()
        onde = str(payload.get("onde") or "google").lower()
        if not consulta or onde not in BUSCAS:
            raise ComandoInvalido("pesquisa sem consulta ou com destino desconhecido")
        url = BUSCAS[onde].format(quote_plus(consulta))
        _lancar(_navegador(str(payload.get("navegador", ""))), url)
        return {"ok": True, "detalhe": f"Pesquisei “{consulta}” no {onde}"}
    if acao == "abrir_programa":
        nome = str(payload.get("nome", "")).lower().strip()
        exe = PROGRAMAS.get(nome)
        if exe is None or not shutil.which(exe):
            disponiveis = ", ".join(programas())
            raise ComandoInvalido(f"programa {nome!r} não disponível (há: {disponiveis})")
        _lancar(exe)
        return {"ok": True, "detalhe": f"Abri {nome}"}
    if acao == "desligar":
        minutos = max(0, int(payload.get("minutos", 0)))
        if minutos:
            await _rodar("shutdown", "-h", f"+{minutos}")
            return {"ok": True, "detalhe": f"PC desliga em {minutos} min"}
        # alguns segundos para a resposta chegar ao app antes de a rede cair
        _lancar("sh", "-c", "sleep 3; systemctl poweroff")
        return {"ok": True, "detalhe": "Desligando o PC"}
    if acao == "cancelar_desligar":
        await _rodar("shutdown", "-c")
        return {"ok": True, "detalhe": "Desligamento cancelado"}
    raise ComandoInvalido(f"ação {acao!r} desconhecida")


async def _rodar(*args: str) -> None:
    proc = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE
    )
    _, erro = await proc.communicate()
    if proc.returncode:
        raise RuntimeError(erro.decode(errors="replace").strip() or f"{args[0]} falhou")
