"""Vagas da máquina: só um processo pesado por vez (GPU de 16 GB, CPU e disco são um só). Exceção: um processo
que só usa o Claude (`--motor claude` em `curar` ou `roteiro`, sem GPU nem LLM local) ocupa a vaga "claude" e
pode rodar junto com o da vaga "maquina".

Trava por fcntl em `cache/travas/<vaga>.lock` (o sistema solta sozinho se o processo morrer, mesmo com kill -9);
quem está usando fica em `<vaga>.json`, para quem espera (CLI, fila, painel) saber por quem.
"""
import atexit
import fcntl
import json
import os
import time

import psutil

from esteira.projeto import CACHE

DIR = CACHE / "travas"
CLAUDE_OK = {"curar", "roteiro", "estudio-estilo", "estudio-fabrica"}  # etapas cujo único trabalho pesado é o LLM; as outras usam GPU/ffmpeg/render
VAGAS = ("maquina", "claude")
_seguras = {}


def vaga(comando, motor="local"):
    return "claude" if motor == "claude" and comando in CLAUDE_OK else "maquina"


def dono(v):
    """Quem ocupa a vaga agora ({pid, comando, desde, proc}) ou None."""
    try:
        d = json.loads((DIR / f"{v}.json").read_text())
    except (OSError, ValueError):
        return None
    return d if psutil.pid_exists(d.get("pid", -1)) and d.get("pid") != os.getpid() else None


def livre(v):
    return dono(v) is None


def ocupar(v, comando, esperar=True, proc=None):
    """Toma a vaga `v` até o processo terminar. esperar=False: devolve False se estiver ocupada."""
    from esteira.nucleo import rastro
    DIR.mkdir(parents=True, exist_ok=True)
    f = open(DIR / f"{v}.lock", "w")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        if not esperar:
            f.close()
            return False
        d = dono(v) or {}
        msg = f"aguardando a vaga {v}: ocupada por `{d.get('comando', '?')}` (pid {d.get('pid', '?')})"
        print(f"⏳ {msg}", flush=True)
        rastro.detalhe(msg)
        fcntl.flock(f, fcntl.LOCK_EX)
        print(f"▶ vaga {v} liberada", flush=True)
    _seguras[v] = f
    (DIR / f"{v}.json").write_text(json.dumps({"pid": os.getpid(), "comando": comando, "desde": time.time(),
                                               "proc": proc}, ensure_ascii=False))
    return True


@atexit.register
def _soltar():
    for v in list(_seguras):
        try:
            (DIR / f"{v}.json").unlink(missing_ok=True)
        except OSError:
            pass
