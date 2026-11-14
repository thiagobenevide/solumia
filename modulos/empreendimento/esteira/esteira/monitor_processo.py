"""Monitor de UM processo da esteira (página /processos/<id>): o registro (comando, vaga, motor, estado), o que
faz agora (nó, barras, chamada de LLM com o texto parcial), recursos dele (CPU, RAM, VRAM), o caminho pelos nós
com o tempo em cada um, as chamadas de LLM, os eventos da etapa e o fim do log. Vivo ou já terminado.

O trace.jsonl (até 20 MB) é lido de forma incremental: cada processo guarda até onde já foi lido.
"""
import json
import time
from datetime import datetime
from pathlib import Path

from esteira import grafo
from esteira.core import processes, status, trace
from esteira.projeto import CACHE, pasta_ep

_lidos = {}  # id → {"pos", "nos", "chamadas", "caches"}
NOMES = {n[0]: n[1] for n in grafo.NOS}


def _meu(reg, r):
    """O registro do rastro é deste processo? (pelo id; registros antigos, sem id, pelo pid + janela)."""
    if reg.get("process"):
        return reg["process"] == r["id"]
    return reg.get("pid") == r["pid"] and r["start"] - 1 <= reg.get("t", 0) <= (r.get("end") or time.time()) + 1


def _historico(r):
    h = _lidos.setdefault(r["id"], {"pos": 0, "nos": [], "chamadas": [], "caches": 0})
    if not trace.LOG.exists():
        return h
    tam = trace.LOG.stat().st_size
    if tam < h["pos"]:  # o rastro foi rotacionado: relê
        h.update(pos=0, nos=[], chamadas=[], caches=0)
    if h["pos"] == 0:  # começa perto do início do processo (o rastro é cronológico)
        h["pos"] = _posicao_de(r["start"] - 2, tam)
    with open(trace.LOG, "rb") as f:
        f.seek(h["pos"])
        bloco = f.read()
    corte = bloco.rfind(b"\n") + 1
    h["pos"] += corte
    chave, pid = r["id"].encode(), f'"pid": {r["pid"]},'.encode()
    for linha in bloco[:corte].splitlines():
        if chave not in linha and pid not in linha:
            continue
        try:
            reg = json.loads(linha)
        except ValueError:
            continue
        if not _meu(reg, r):
            continue
        if reg["kind"] == "node":
            h["nos"].append({"t": reg["t"], "no": reg.get("node"), "fluxo": reg.get("flow"), "detalhe": reg.get("detail", ""),
                             "id_no": grafo.no_id(reg.get("flow"), reg.get("node"))})
        elif reg["kind"] == "call":
            h["chamadas"].append({k: (v[:1500] if isinstance(v, str) and k in ("input", "output") else v)
                                  for k, v in reg.items() if k not in ("schema", "pensamento")})
        elif reg["kind"] == "cache":
            h["caches"] += 1
    return h


def _posicao_de(t, tam):
    """Busca binária pelo byte onde começam os registros a partir do instante t."""
    lo, hi = 0, tam
    with open(trace.LOG, "rb") as f:
        while hi - lo > 65536:
            meio = (lo + hi) // 2
            f.seek(meio)
            f.readline()
            linha = f.readline()
            try:
                tm = json.loads(linha).get("t", 0)
            except ValueError:
                tm = 0
            lo, hi = (meio, hi) if tm < t else (lo, meio)
    return lo


def _caminho(nos, fim):
    """Nós visitados em ordem, com a duração de cada um (o último dura até agora ou até o fim)."""
    saida = []
    for i, n in enumerate(nos):
        if not n["no"]:
            continue
        ate = nos[i + 1]["t"] if i + 1 < len(nos) else fim
        saida.append(dict(n, nome=NOMES.get(n["id_no"], n["no"]), seg=round(ate - n["t"], 1)))
    return saida


def _cauda(arq, n=40):
    if not arq or not Path(arq).is_file():
        return []
    p = Path(arq)
    with open(p, "rb") as f:
        f.seek(max(0, p.stat().st_size - 12000))
        linhas = f.read().decode("utf-8", "replace").replace("\r", "\n").splitlines()
    return [l for l in linhas if l.strip()][-n:]


def _log_da_fila(r):
    if not r.get("queue"):
        return None
    if ":" in (r.get("target") or ""):
        return CACHE / "fila_logs" / f"fila_{r['queue']}.log"
    return pasta_ep(r["target"]) / "log" / f"fila_{r['queue']}.log"


def _eventos(r):
    alvo = r.get("target") or ""
    if not alvo or ":" in alvo or not pasta_ep(alvo).is_dir():
        return []
    ini = datetime.fromtimestamp(r["start"] - 1).isoformat()
    fim = datetime.fromtimestamp((r.get("end") or time.time()) + 1).isoformat()
    return [e for e in status.events(pasta_ep(alvo))
            if e.get("pid") == r["pid"] and ini <= e["t"] <= fim and e["kind"] != "debug"][-60:]


def detalhe(pid_id, monitor_atual):
    r = processes.get(pid_id)
    if not r:
        return None
    vivo = None
    if r["state"] == "running":
        vivo = next((v for v in grafo.vivos() if v.get("process") == pid_id or v.get("pid") == r["pid"]), None)
        if vivo:
            vivo["nome"] = NOMES.get(vivo.get("id_no"), vivo.get("node"))
    h = _historico(r)
    fim = r.get("end") or time.time()
    recursos = next((p for p in (monitor_atual or {}).get("esteira", []) if p["pid"] == r["pid"]), None)
    chamadas = h["chamadas"]
    tok = sum(c.get("output_tokens") or 0 for c in chamadas)
    resumo = {"chamadas": len(chamadas), "falhas": sum(not c.get("ok") for c in chamadas), "cache": h["caches"],
              "tokens_saida": tok, "custo_usd": round(sum(c.get("cost_usd") or 0 for c in chamadas), 4),
              "seg_llm": round(sum(c.get("seconds") or 0 for c in chamadas), 1)}
    return {"processo": r, "vivo": vivo, "recursos": recursos, "caminho": _caminho(h["nos"], fim),
            "chamadas": chamadas[-30:][::-1], "resumo": resumo, "eventos": _eventos(r)[::-1],
            "log": _cauda(r.get("output") or _log_da_fila(r))}
