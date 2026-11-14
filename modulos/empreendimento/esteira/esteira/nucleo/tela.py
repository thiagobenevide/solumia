"""Abre programas com janela na sessão gráfica do PC, mesmo com o painel rodando como serviço."""
import os
import subprocess

_VARIAVEIS = ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "XDG_SESSION_TYPE")


class SemTela(RuntimeError):
    """O programa não conseguiu abrir a janela no PC."""


def _ambiente():
    """O serviço sobe no boot, antes do login, e herda um ambiente sem DISPLAY; quem conhece a sessão
    aberta depois é o gerenciador do systemd do usuário."""
    env = dict(os.environ)
    if env.get("DISPLAY") or env.get("WAYLAND_DISPLAY"):
        return env
    try:
        r = subprocess.run(["systemctl", "--user", "show-environment"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return env
    for linha in r.stdout.splitlines():
        nome, _, valor = linha.partition("=")
        if nome in _VARIAVEIS:
            env[nome] = valor
    return env


def abrir_programa(*cmd):
    """Abre sem prender quem chamou. Levanta SemTela se não há sessão ou se o programa cai ao abrir."""
    env = _ambiente()
    if not (env.get("DISPLAY") or env.get("WAYLAND_DISPLAY")):
        raise SemTela(f"{cmd[0]}: não há sessão gráfica aberta no PC")
    p = subprocess.Popen(cmd, env=env, start_new_session=True, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        codigo = p.wait(timeout=2)
    except subprocess.TimeoutExpired:
        return
    # Código 0 aqui é normal: o programa pode ter entregado o arquivo a uma janela já aberta.
    if codigo:
        raise SemTela(f"{cmd[0]} fechou ao abrir (código {codigo})")
