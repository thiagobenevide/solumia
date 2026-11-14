"""Registro de cada processo da esteira (`./dark <comando>` pesado, do terminal ou da fila): o que é, vaga, motor,
quando começou e como terminou. `cache/processos.jsonl` recebe uma linha no início e outra no fim (mesmo id).
O id vai para o ambiente (`ESTEIRA_PROC`) e o rastro marca cada registro com ele, para a página do processo.
"""
import atexit
import json
import os
import time

import psutil

from esteira.projeto import CACHE

ARQ = CACHE / "processos.jsonl"
_eu = {}


def _anexar(reg):
    ARQ.parent.mkdir(exist_ok=True)
    with open(ARQ, "a") as f:
        f.write(json.dumps(reg, ensure_ascii=False) + "\n")


def registrar(comando, alvo, args, vaga, motor):
    inicio = time.time()
    pid = os.getpid()
    pid_id = f"{int(inicio * 1000)}-{pid}"
    try:
        saida = os.readlink("/proc/self/fd/1")
    except OSError:
        saida = None
    _eu.update(id=pid_id)
    os.environ["ESTEIRA_PROC"] = pid_id
    _anexar({"id": pid_id, "ev": "inicio", "pid": pid, "comando": comando, "alvo": alvo, "args": args,
             "vaga": vaga, "motor": motor, "inicio": round(inicio, 2), "fila": os.environ.get("ESTEIRA_FILA"),
             "saida": saida if saida and saida.startswith("/") and os.path.isfile(saida) else None})
    return pid_id


def cancelado():
    _eu["cancelado"] = True


def falhou(erro):
    _eu["erro"] = f"{type(erro).__name__}: {erro}"[:300]


@atexit.register
def _fim():
    if _eu:
        _anexar({"id": _eu["id"], "ev": "fim", "fim": round(time.time(), 2), "ok": "erro" not in _eu,
                 "erro": _eu.get("erro", ""), "cancelado": _eu.get("cancelado", False)})


def listar(limite=200):
    """Processos (mais recentes primeiro) com estado: rodando | ok | erro | interrompido."""
    if not ARQ.exists():
        return []
    regs = {}
    with open(ARQ, "rb") as f:
        f.seek(max(0, ARQ.stat().st_size - 2_000_000))
        for linha in f.read().decode("utf-8", "replace").splitlines():
            try:
                r = json.loads(linha)
            except ValueError:
                continue
            if r.get("ev") == "inicio":
                regs[r["id"]] = r
            elif r.get("id") in regs:
                regs[r["id"]].update(r)
    saida = []
    for r in regs.values():
        if "fim" in r:
            r["estado"] = "cancelado" if r.get("cancelado") else "ok" if r.get("ok") else "erro"
        elif psutil.pid_exists(r["pid"]) and abs(psutil.Process(r["pid"]).create_time() - r["inicio"]) < 5:
            r["estado"] = "rodando"
        else:
            r["estado"] = "interrompido"  # morto sem passar pelo atexit (kill -9, queda)
        r["dur"] = round((r.get("fim") or time.time()) - r["inicio"])
        saida.append(r)
    return sorted(saida, key=lambda r: -r["inicio"])[:limite]


def obter(pid_id):
    return next((r for r in listar(2000) if r["id"] == pid_id), None)
