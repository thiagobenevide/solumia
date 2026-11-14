"""Leitura do log de eventos: estado de cada etapa (`./dark status`) e eventos filtrados (`./dark log`)."""
import json
import os
from datetime import datetime

from esteira.projeto import ep_id

ORDEM = ["transcrever", "limpar", "cenas", "curar", "buscar", "avaliar", "graficos", "montar", "quadros", "thumb"]


def eventos(pasta):
    arq = pasta / "log" / "eventos.jsonl"
    if not arq.exists():
        return []
    with open(arq) as f:
        return [json.loads(l) for l in f if l.strip()]


def _vivo(pid):
    try:
        os.kill(pid, 0)
        return True
    except (OSError, TypeError):
        return False


def etapas(pasta):
    """{etapa: {status, inicio, dur, msg, i, n, resta}} da última execução de cada etapa."""
    est = {}
    for ev in eventos(pasta):
        nome, tipo = ev["etapa"], ev["tipo"]
        if tipo == "inicio":
            est[nome] = {"status": "rodando", "inicio": ev["t"], "pid": ev.get("pid"), "msg": "", "avisos": 0}
            continue
        e = est.setdefault(nome, {"status": "?", "inicio": ev["t"], "msg": "", "avisos": 0})
        if tipo == "progresso":
            e.update(i=ev["i"], n=ev["n"], resta=ev.get("resta"), msg=ev["msg"] or e["msg"])
        elif tipo in ("saida", "aviso"):
            e["msg"] = ev["msg"]
            e["avisos"] += tipo == "aviso"
        elif tipo == "fim":
            e.update(status="ok", dur=ev.get("dur"))
        elif tipo == "erro":
            e.update(status="erro", dur=ev.get("dur"), msg=ev["msg"])
    for e in est.values():  # processo morto sem gravar fim (kill -9, queda de energia)
        if e["status"] == "rodando" and not _vivo(e.get("pid")):
            e["status"] = "abortado"
    return dict(sorted(est.items(), key=lambda kv: ORDEM.index(kv[0]) if kv[0] in ORDEM else 99))


def _tempo(s):
    if s is None:
        return "-"
    s = int(s)
    return f"{s // 3600}h{s % 3600 // 60:02d}m" if s >= 3600 else f"{s // 60}m{s % 60:02d}s"


def imprimir_status(pasta):
    est = etapas(pasta)
    if not est:
        print(f"{ep_id(pasta)}: nenhuma etapa registrada")
        return
    print(ep_id(pasta))
    marca = {"ok": "✓", "erro": "✗", "rodando": "▶", "abortado": "⚠", "?": "?"}
    for nome, e in est.items():
        quando = datetime.fromisoformat(e["inicio"]).strftime("%d/%m %H:%M")
        if e["status"] == "rodando":
            prog = f"{e.get('i', 0)}/{e.get('n', '?')} faltam {_tempo(e.get('resta'))}" if e.get("n") else "…"
            info = f"{prog} · {e['msg'][:70]}"
        else:
            info = f"{_tempo(e.get('dur'))} · {e['msg'][:80]}"
        avisos = f" ({e['avisos']} avisos)" if e["avisos"] else ""
        print(f"  {marca[e['status']]} {nome:12} {quando}  {info}{avisos}")


def imprimir_log(pasta, etapa=None, n=20, erros=False, debug=False):
    evs = [e for e in eventos(pasta) if (not etapa or e["etapa"] == etapa)
           and (debug or e["tipo"] not in ("debug", "progresso"))
           and (not erros or e["tipo"] in ("erro", "aviso"))]
    for e in evs[-n:]:
        extra = {k: v for k, v in e.items() if k not in ("t", "ep", "etapa", "tipo", "msg", "traceback")}
        print(f"{e['t'][11:19]} {e['etapa']:10} {e['tipo']:8} {e['msg'][:110]}" + (f" {extra}" if extra else ""))
        if e.get("traceback") and erros:
            print("    " + e["traceback"].strip().splitlines()[-1][:160])
