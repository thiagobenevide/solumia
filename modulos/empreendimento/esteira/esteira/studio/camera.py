"""Modo apresentador do Estúdio: a câmera cortada igual ao áudio, o enquadramento do rosto e o layout de cada trecho.

- `cortar`: a câmera do episódio (`producao.camera`, sincronizada com o WAV em `camera.json`) segue os dois cortes —
  as tomadas da esteira (`producao.trechos_camera`) e o corte pelo som (`corte.json`). Cada quadro de saída aponta
  para o quadro da câmera que corresponde a ele, então não há deriva; sai `<ep>/estudio/corte/camera.mp4` (NVENC).
- `rosto`: centro e altura do rosto (OpenCV, mediana de ~24 quadros) para o `object-position` e o punch-in.
- `layouts`: FULL (câmera cheia com punch-in; punch extra em frase de impacto), SPLIT (peça + câmera num card),
  `lateral`/`flutuante` (câmera cheia, dados no lado livre: véu em degradê ou card de vidro em perspectiva),
  `tela` e `solido` (sem o apresentador, ≤ `tela_max`) e `broll` (mídia curada no lugar da câmera, ≤ `broll`).
"""
import json
import subprocess

import numpy as np

from esteira import production
from esteira.studio import cut

FPS = 30
SCREEN = ("titulo_capitulo",)        # cenas que podem tirar o apresentador da tela (capítulo)
IMPACT = ("frase_destaque", "pergunta_destaque", "lettering", "carimbo")


def exists(project):
    return production.camera(project) is not None


def destination(project):
    return cut.folder(project) / "camera.mp4"


def _in_camera(trechos, t):
    """Tempo da narração editada → tempo na câmera (pelos intervalos da esteira + offset do WAV)."""
    for start, cam, duration in trechos:
        if t < start + duration or (start, cam, duration) == trechos[-1]:
            return cam + max(0.0, t - start)
    return t


def _edited(segs, T):
    """Tempo de saída (narração cortada pelo som) → tempo na narração editada; no respiro a câmera segue rodando."""
    t = 0.0
    for a, b, r in segs:
        if T < t + (b - a) + r:
            return a + (T - t)
        t += (b - a) + r
    return segs[-1][1] + (T - t)  # depois do fim da fala a câmera continua rodando


def frames(project, duration):
    """[(início na câmera, nº de quadros)]: corridas de quadros contíguos da câmera para a saída."""
    spans = production.spans_camera(project)
    c = cut.load(project)
    segs = c["segmentos"] if c else [[0.0, duration, 0.0]]
    n = int(round(duration * FPS))
    sources = [_in_camera(spans, _edited(segs, k / FPS)) for k in range(n)]
    runs = []
    for k, s in enumerate(sources):
        if runs and abs(s - (runs[-1][0] + runs[-1][1] / FPS)) < 0.5 / FPS:
            runs[-1][1] += 1
        else:
            runs.append([s, 1])
    return runs


def cut_camera(project, duration):
    """Gera a câmera cortada (sem som; a voz é a narração). Refaz só se o corte ou a câmera mudaram."""
    cam = production.camera(project)
    if not cam:
        raise SystemExit("modo apresentador sem câmera: ponha o vídeo como camera.mp4 no episódio")
    runs = frames(project, duration)
    output = destination(project)
    output.parent.mkdir(parents=True, exist_ok=True)
    mark = output.with_suffix(".json")
    key = {"corridas": runs, "camera": str(cam.resolve()), "mtime": cam.resolve().stat().st_mtime_ns}
    if output.exists() and mark.exists() and json.loads(mark.read_text()) == key:
        return output
    parts = [f"[0:v]trim=start={s:.4f}:end={s + q / FPS:.4f},setpts=PTS-STARTPTS,fps={FPS},"
              f"tpad=stop=2:stop_mode=clone,trim=end_frame={q}[v{i}];" for i, (s, q) in enumerate(runs)]
    parts.append("".join(f"[v{i}]" for i in range(len(runs))) + f"concat=n={len(runs)}:v=1:a=0,"
                  "scale=-2:'min(1080,ih)',format=yuv420p[v]")
    script = output.with_suffix(".filtro")
    script.write_text("\n".join(parts))
    base = ["ffmpeg", "-v", "error", "-y", "-i", str(cam), "-filter_complex_script", str(script), "-map", "[v]",
            "-r", str(FPS), "-g", str(FPS)]
    if subprocess.run(base + ["-c:v", "h264_nvenc", "-preset", "p4", "-cq", "21", str(output)]).returncode != 0:
        subprocess.run(base + ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", str(output)], check=True)
    mark.write_text(json.dumps(key))
    print(f"  câmera cortada: {len(runs)} trechos · {duration:.0f} s → {output.name}")
    return output


def face(video, samples=24):
    """{"x", "y", "h"} do rosto (frações do quadro: centro e altura), mediana das amostras; centro alto sem rosto."""
    import cv2
    cap = cv2.VideoCapture(str(video))
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) or 1
    det = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
    found = []
    for k in np.linspace(0, n - 1, samples).astype(int):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(k))
        ok, q = cap.read()
        if not ok:
            continue
        H, W = q.shape[:2]
        cinza = cv2.cvtColor(q, cv2.COLOR_BGR2GRAY)
        rostos = det.detectMultiScale(cinza, 1.1, 6, minSize=(H // 12, H // 12))
        if len(rostos):
            x, y, w, h = max(rostos, key=lambda r: r[2] * r[3])
            found.append(((x + w / 2) / W, (y + h / 2) / H, h / H))
    cap.release()
    if not found:
        return {"x": 0.5, "y": 0.35, "h": 0.3, "achado": False}
    x, y, h = np.median(np.array(found), axis=0)
    return {"x": round(float(x), 3), "y": round(float(y), 3), "h": round(float(h), 3), "achado": True}


SEM_PRESENTER = ("tela", "solido")  # tiram o apresentador da tela: contam no teto `tela_max`


def layouts(cenas, midia, regras, duration, variations=("split",)):
    """Layout de cada trecho → [{t, ate, layout, punch}] cobrindo o vídeo; grava `layout` em cada cena.
    `variacoes`: rodízio das peças cheias com o apresentador (split, lateral, flutuante, sólido)."""
    ap = regras.apresentador
    screen_max, broll_max = ap.get("tela_max", 0.07), ap.get("broll", 0.3)
    marks = []
    screen = 0.0
    spin = 0
    for c in cenas:
        request = c.get("layout_pedido")  # o gatilho do estilo escolheu o layout
        fits = screen + (c["ate"] - c["t"]) <= screen_max * duration
        if request in ("full", "split", "broll", "lateral", "flutuante", "galeria") or (request in SEM_PRESENTER and fits):
            c["layout"] = request
            screen += (c["ate"] - c["t"]) if request in SEM_PRESENTER else 0
        elif request == "solido":
            c["layout"] = "flutuante"  # sem orçamento para tirar o apresentador: o card flutua sobre a câmera
        elif c.get("takeover"):
            pode = c["cena"] in SCREEN and fits
            if pode:
                c["layout"] = "tela"
            else:
                lay = (list(variations) or ["split"])[spin % max(len(variations), 1)]
                spin += 1
                c["layout"] = "flutuante" if lay == "solido" and not fits else lay
                pode = c["layout"] == "solido"
            screen += (c["ate"] - c["t"]) if pode else 0
        else:
            c["layout"] = "full"
        marks.append({"t": c["t"], "ate": c["ate"], "layout": c["layout"], "punch": c["cena"] in IMPACT})
    # B-roll: itens de mídia longos fora das cenas de motion, um sim um não, até o teto
    broll, alterna = 0.0, False
    for m in midia:
        free = not any(x["t"] < m["fim"] and x["ate"] > m["ini"] and x["layout"] != "full" for x in marks)
        if m["fim"] - m["ini"] < 1.5 or not free or m["ini"] < 2.0:
            continue
        alterna = not alterna
        if alterna and broll + (m["fim"] - m["ini"]) <= broll_max * duration:
            marks.append({"t": m["ini"], "ate": m["fim"], "layout": "broll", "punch": False})
            broll += m["fim"] - m["ini"]
    # linha do tempo: o que não é cena especial é FULL; motion/B-roll ganham da FULL de cena sobre a mídia
    weight = {"full": 0, "broll": 1, "split": 2, "tela": 2, "lateral": 2, "flutuante": 2, "solido": 2, "galeria": 2}
    points = sorted({0.0, duration, *[x["t"] for x in marks], *[x["ate"] for x in marks]})
    segs = []
    for a, b in zip(points, points[1:], strict=False):
        if b - a < 1e-3:
            continue
        active = [x for x in marks if x["t"] <= a and x["ate"] >= b]
        top = max(active, key=lambda x: weight[x["layout"]], default={"layout": "full", "punch": False})
        lay, punch = top["layout"], top["punch"] if top["layout"] == "full" else False
        if segs and segs[-1]["layout"] == lay and segs[-1]["punch"] == punch:
            segs[-1]["ate"] = round(b, 3)
        else:
            segs.append({"t": round(a, 3), "ate": round(b, 3), "layout": lay, "punch": punch})
    return segs


def summary(segs, duration):
    return {k: round(sum(s["ate"] - s["t"] for s in segs if s["layout"] == k) / max(duration, 1), 2)
            for k in ("full", "split", "broll", "tela", "lateral", "flutuante", "solido", "galeria")}
