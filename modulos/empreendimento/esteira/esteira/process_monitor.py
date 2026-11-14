"""Monitor de UM processo da esteira (página /processos/<id>): o registro (comando, vaga, motor, estado), o que
faz agora (nó, barras, chamada de LLM com o texto parcial), recursos dele (CPU, RAM, VRAM), o caminho pelos nós
com o tempo em cada um, as chamadas de LLM, os eventos da etapa e o fim do log. Vivo ou já terminado.

O trace.jsonl (até 20 MB) é lido de forma incremental: cada processo guarda até onde já foi lido.
"""
import json
import time
from datetime import datetime
from pathlib import Path

from esteira import graph
from esteira.core import processes, status, trace
from esteira.project import CACHE, folder_ep

_read = {}  # id → {"pos", "nos", "chamadas", "caches"}
NAMES = {n[0]: n[1] for n in graph.NODES}


def _my(reg, r):
    """O registro do rastro é deste processo? (pelo id; registros antigos, sem id, pelo pid + janela)."""
    if reg.get("process"):
        return reg["process"] == r["id"]
    return reg.get("pid") == r["pid"] and r["start"] - 1 <= reg.get("t", 0) <= (r.get("end") or time.time()) + 1


def _history(r):
    h = _read.setdefault(r["id"], {"pos": 0, "nos": [], "chamadas": [], "caches": 0})
    if not trace.LOG.exists():
        return h
    size = trace.LOG.stat().st_size
    if size < h["pos"]:  # o rastro foi rotacionado: relê
        h.update(pos=0, nos=[], chamadas=[], caches=0)
    if h["pos"] == 0:  # começa perto do início do processo (o rastro é cronológico)
        h["pos"] = _position_of(r["start"] - 2, size)
    with open(trace.LOG, "rb") as f:
        f.seek(h["pos"])
        block = f.read()
    cut = block.rfind(b"\n") + 1
    h["pos"] += cut
    key, pid = r["id"].encode(), f'"pid": {r["pid"]},'.encode()
    for line in block[:cut].splitlines():
        if key not in line and pid not in line:
            continue
        try:
            reg = json.loads(line)
        except ValueError:
            continue
        if not _my(reg, r):
            continue
        if reg["kind"] == "node":
            h["nos"].append({"t": reg["t"], "no": reg.get("node"), "fluxo": reg.get("flow"), "detalhe": reg.get("detail", ""),
                             "id_no": graph.node_id(reg.get("flow"), reg.get("node"))})
        elif reg["kind"] == "call":
            h["chamadas"].append({k: (v[:1500] if isinstance(v, str) and k in ("input", "output") else v)
                                  for k, v in reg.items() if k not in ("schema", "pensamento")})
        elif reg["kind"] == "cache":
            h["caches"] += 1
    return h


def _position_of(t, tam):
    """Busca binária pelo byte onde começam os registros a partir do instante t."""
    lo, hi = 0, tam
    with open(trace.LOG, "rb") as f:
        while hi - lo > 65536:
            meio = (lo + hi) // 2
            f.seek(meio)
            f.readline()
            line = f.readline()
            try:
                tm = json.loads(line).get("t", 0)
            except ValueError:
                tm = 0
            lo, hi = (meio, hi) if tm < t else (lo, meio)
    return lo


def _path(nos, fim):
    """Nós visitados em ordem, com a duração de cada um (o último dura até agora ou até o fim)."""
    output = []
    for i, n in enumerate(nos):
        if not n["no"]:
            continue
        until = nos[i + 1]["t"] if i + 1 < len(nos) else fim
        output.append(dict(n, nome=NAMES.get(n["id_no"], n["no"]), seg=round(until - n["t"], 1)))
    return output


def _tail(file, n=40):
    if not file or not Path(file).is_file():
        return []
    p = Path(file)
    with open(p, "rb") as f:
        f.seek(max(0, p.stat().st_size - 12000))
        lines = f.read().decode("utf-8", "replace").replace("\r", "\n").splitlines()
    return [l for l in lines if l.strip()][-n:]


def _log_of_queue(r):
    if not r.get("queue"):
        return None
    if ":" in (r.get("target") or ""):
        return CACHE / "fila_logs" / f"fila_{r['queue']}.log"
    return folder_ep(r["target"]) / "log" / f"fila_{r['queue']}.log"


def _events(r):
    target = r.get("target") or ""
    if not target or ":" in target or not folder_ep(target).is_dir():
        return []
    start = datetime.fromtimestamp(r["start"] - 1).isoformat()
    end = datetime.fromtimestamp((r.get("end") or time.time()) + 1).isoformat()
    return [e for e in status.events(folder_ep(target))
            if e.get("pid") == r["pid"] and start <= e["t"] <= end and e["kind"] != "debug"][-60:]


def detail(pid_id, monitor_current):
    r = processes.get(pid_id)
    if not r:
        return None
    vivo = None
    if r["state"] == "running":
        vivo = next((v for v in graph.live() if v.get("process") == pid_id or v.get("pid") == r["pid"]), None)
        if vivo:
            vivo["nome"] = NAMES.get(vivo.get("id_no"), vivo.get("node"))
    h = _history(r)
    end = r.get("end") or time.time()
    recursos = next((p for p in (monitor_current or {}).get("esteira", []) if p["pid"] == r["pid"]), None)
    calls = h["chamadas"]
    tok = sum(c.get("output_tokens") or 0 for c in calls)
    summary = {"chamadas": len(calls), "falhas": sum(not c.get("ok") for c in calls), "cache": h["caches"],
              "tokens_saida": tok, "custo_usd": round(sum(c.get("cost_usd") or 0 for c in calls), 4),
              "seg_llm": round(sum(c.get("seconds") or 0 for c in calls), 1)}
    return {"processo": r, "vivo": vivo, "recursos": recursos, "caminho": _path(h["nos"], end),
            "chamadas": calls[-30:][::-1], "resumo": summary, "eventos": _events(r)[::-1],
            "log": _tail(r.get("output") or _log_of_queue(r))}
