"""Monitor da máquina para o painel: GPU (uso, potência, temperatura, VRAM), CPU (uso, temperatura, potência
pelo RAPL), RAM, processos da esteira com o que cada um está escrevendo, modelo carregado no Ollama e arquivos
alterados há pouco. Só lê (nvidia-smi, /proc, /sys); não interrompe nada. Uma thread amostra a cada 2 s,
guarda 10 min de histórico e integra a energia gasta desde que o painel abriu.
"""
import json
import os
import subprocess
import threading
import time
import urllib.request
from collections import deque
from pathlib import Path

import psutil

from esteira import library
from esteira.project import CACHE, PROJECTS

INTERVAL = 2.0
HIST = deque(maxlen=300)
_state = {"atual": {}, "arquivos": [], "energia_wh": {"gpu": 0.0, "cpu": 0.0}, "desde": time.time()}
_lock = threading.Lock()
RAPL = Path("/sys/class/powercap/intel-rapl:0")

# Processo → (rótulo, motor). O motor diz quem trabalha: Python, LLM local, GPU (outro modelo) ou Claude.
CATEGORIES = [
    ("llama-server", "llama.cpp (LLM local)", "local"),
    ("esteira.py", "Esteira", "py"), ("artigo.py", "artigo (PDFs)", "py"),
    ("filmcraft", "FilmCraft", "py"), ("effectcraft", "EffectCraft", "py"), ("photocraft", "PhotoCraft", "py"), ("ffmpeg", "ffmpeg", "py"),
    ("chrome-headless", "Chromium (gráficos)", "py"), ("headless_shell", "Chromium (gráficos)", "py"),
    ("gerar_fundos", "RealVisXL (thumbs)", "gpu"), (".venv-img", "RealVisXL (thumbs)", "gpu"),
]


def _gpu():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=name,utilization.gpu,power.draw,power.limit,temperature.gpu,"
                              "memory.used,memory.total,fan.speed,clocks.sm", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=5).stdout.strip().split(", ")
        apps = subprocess.run(["nvidia-smi", "--query-compute-apps=pid,used_memory", "--format=csv,noheader,nounits"],
                              capture_output=True, text=True, timeout=5).stdout.strip().splitlines()
    except (OSError, subprocess.TimeoutExpired):
        return None
    num = lambda s: float(s) if s.replace(".", "", 1).isdigit() else None
    n = [num(x) for x in out[1:]]
    vram = {int(a.split(", ")[0]): float(a.split(", ")[1]) for a in apps if ", " in a}
    return {"nome": out[0], "uso": n[0], "watts": n[1], "limite_w": n[2], "temp": n[3], "vram_mb": n[4],
            "vram_total_mb": n[5], "ventoinha": n[6], "clock_mhz": n[7], "por_pid": vram}


def _rapl():
    try:
        return int((RAPL / "energy_uj").read_text()), int((RAPL / "max_energy_range_uj").read_text())
    except (OSError, ValueError):
        return None


def _temp_cpu():
    t = psutil.sensors_temperatures() if hasattr(psutil, "sensors_temperatures") else {}
    for key in ("k10temp", "coretemp", "zenpower"):
        if t.get(key):
            return round(max(x.current for x in t[key]), 1)
    return None


def _ollama():
    """Modelos na VRAM agora (llama.cpp; a chave `ollama` ficou pelo app e o grafo). Tamanho = o do GGUF."""
    from esteira.ai import llama
    ms = llama.models()
    if ms is None:
        return None
    return [{"modelo": m["id"], "vram_gb": llama.gb(m["id"])} for m in ms if m["status"]["value"] == "loaded"]


def _output_of(pid):
    """Últimas linhas do arquivo para onde o processo escreve (stdout redirecionado para arquivo)."""
    try:
        target = os.readlink(f"/proc/{pid}/fd/1")
    except OSError:
        return None, []
    p = Path(target)
    if not p.is_file():
        return None, []
    try:
        with open(p, "rb") as f:
            f.seek(max(0, p.stat().st_size - 4000))
            lines = f.read().decode("utf-8", "replace").replace("\r", "\n").splitlines()
    except OSError:
        return target, []
    return target, [l for l in lines if l.strip()][-6:]


def _processes(vram):
    output, groups = [], {}
    for p in psutil.process_iter(["pid", "name", "cmdline", "create_time", "cpu_percent", "memory_info"]):
        args = p.info["cmdline"] or []
        cmd = " ".join(args)
        if not cmd:
            continue
        # só o executável e o script (até 3 argumentos sem espaço): um shell que só cita "esteira.py" no texto não conta
        head = [a for a in args[:3] if " " not in a]
        if p.info["name"] == "claude" and "-p" in args and "--json-schema" in args:
            cat = ("Claude (consulta da esteira)", "claude")
        else:
            cat = next(((r, m) for key, r, m in CATEGORIES if any(key in a for a in head)), None)
        if not cat:
            continue
        rot, engine = cat
        info = {"pid": p.info["pid"], "rotulo": rot, "motor": engine, "cpu": p.info["cpu_percent"] or 0.0,
                "ram_mb": round(p.info["memory_info"].rss / 2**20) if p.info["memory_info"] else 0,
                "vram_mb": vram.get(p.info["pid"], 0), "desde": p.info["create_time"]}
        if rot == "Esteira" or rot.startswith(("artigo", "Claude")):
            args = (cmd.split("esteira.py", 1)[-1].strip() if "esteira.py" in cmd else
                    "artigo " + cmd.split("artigo.py", 1)[-1].strip() if "artigo.py" in cmd else cmd[-120:])
            file, lines = _output_of(p.info["pid"])
            output.append(dict(info, comando=args[:160], log=file, linhas=lines))
        else:
            g = groups.setdefault(rot, dict(info, n=0, cpu=0.0, ram_mb=0, vram_mb=0))
            g["n"] += 1
            g["cpu"] += info["cpu"]
            g["ram_mb"] += info["ram_mb"]
            g["vram_mb"] += info["vram_mb"]
    return sorted(output, key=lambda x: x["desde"]), sorted(groups.values(), key=lambda g: -g["cpu"])


def _files_recent(roots, minutes=15, limit=25):
    """Arquivos alterados nos últimos `minutos` (profundidade limitada; ignora mídia pesada e caches)."""
    now, found = time.time(), []
    for root, prof in roots:
        root = Path(root).expanduser()
        if not root.exists():
            continue
        base = len(root.parts)
        for d, subs, arqs in os.walk(root):
            level = len(Path(d).parts) - base
            subs[:] = [s for s in subs if not s.startswith(".") and s not in ("midia", "__pycache__", "quadros")
                       and level < prof]
            for a in arqs:
                c = Path(d) / a
                try:
                    m = c.stat().st_mtime
                except OSError:
                    continue
                if now - m < minutes * 60:
                    found.append({"caminho": str(c).replace(str(Path.home()), "~"), "seg": round(now - m)})
    return sorted(found, key=lambda x: x["seg"])[:limit]


def _sample(roots):
    psutil.cpu_percent()
    for p in psutil.process_iter(["cpu_percent"]):
        pass
    r0, t0, n = _rapl(), time.time(), 0
    while True:
        time.sleep(INTERVAL)
        try:
            g = _gpu()
            r1, t1 = _rapl(), time.time()
            dt = t1 - t0
            cpu_w = None
            if r0 and r1:
                d = r1[0] - r0[0] if r1[0] >= r0[0] else r1[0] + r1[1] - r0[0]
                cpu_w = round(d / 1e6 / dt, 1)
            r0, t0 = r1, t1
            mem = psutil.virtual_memory()
            esteira, groups = _processes(g["por_pid"] if g else {})
            current = {"t": t1, "gpu": {k: v for k, v in (g or {}).items() if k != "por_pid"} or None,
                     "cpu": {"uso": psutil.cpu_percent(), "temp": _temp_cpu(), "watts": cpu_w,
                             "nucleos": psutil.cpu_count()},
                     "ram": {"usada_gb": round(mem.used / 2**30, 1), "total_gb": round(mem.total / 2**30, 1)},
                     "ollama": _ollama(), "esteira": esteira, "grupos": groups}
            with _lock:
                e = _state["energia_wh"]
                if g and g["watts"]:
                    e["gpu"] += g["watts"] * dt / 3600
                if cpu_w:
                    e["cpu"] += cpu_w * dt / 3600
                _state["atual"] = current
                HIST.append({"t": round(t1), "gpu_uso": g and g["uso"], "gpu_w": g and g["watts"],
                             "gpu_temp": g and g["temp"], "cpu_uso": current["cpu"]["uso"], "cpu_w": cpu_w,
                             "cpu_temp": current["cpu"]["temp"]})
            if n % 5 == 0:  # arquivos a cada ~10 s
                arqs = _files_recent(roots)
                with _lock:
                    _state["arquivos"] = arqs
            n += 1
        except Exception as ex:  # o monitor nunca derruba o painel
            with _lock:
                _state["erro"] = str(ex)[:200]


def start(cfg):
    f = cfg.get("fontes", {})
    vault = Path(f.get("vault", "~/Documents/github/obsidian")).expanduser()
    roots = [(PROJECTS, 3), (vault / "Notas" / "Empreendimento" / "YouTube", 3),
              (Path(f.get("artigos", vault / "Referências" / "Artigos")).expanduser(), 1), (CACHE, 1),
              (library.folder(), 1)]
    threading.Thread(target=_sample, args=(roots,), daemon=True).start()


def state(rate_kwh):
    with _lock:
        e = dict(_state)
        kwh = (e["energia_wh"]["gpu"] + e["energia_wh"]["cpu"]) / 1000
        e["energia"] = {"gpu_wh": round(e["energia_wh"]["gpu"], 1), "cpu_wh": round(e["energia_wh"]["cpu"], 1),
                        "kwh": round(kwh, 3), "reais": round(kwh * rate_kwh, 2), "tarifa": rate_kwh,
                        "horas": round((time.time() - e["desde"]) / 3600, 2)}
        e["hist"] = list(HIST)
        return e
