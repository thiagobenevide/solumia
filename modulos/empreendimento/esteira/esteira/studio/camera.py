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
TELA = ("titulo_capitulo",)        # cenas que podem tirar o apresentador da tela (capítulo)
IMPACTO = ("frase_destaque", "pergunta_destaque", "lettering", "carimbo")


def existe(projeto):
    return production.camera(projeto) is not None


def destino(projeto):
    return cut.pasta(projeto) / "camera.mp4"


def _na_camera(trechos, t):
    """Tempo da narração editada → tempo na câmera (pelos intervalos da esteira + offset do WAV)."""
    for ini, cam, dur in trechos:
        if t < ini + dur or (ini, cam, dur) == trechos[-1]:
            return cam + max(0.0, t - ini)
    return t


def _editada(segs, T):
    """Tempo de saída (narração cortada pelo som) → tempo na narração editada; no respiro a câmera segue rodando."""
    t = 0.0
    for a, b, r in segs:
        if T < t + (b - a) + r:
            return a + (T - t)
        t += (b - a) + r
    return segs[-1][1] + (T - t)  # depois do fim da fala a câmera continua rodando


def quadros(projeto, duracao):
    """[(início na câmera, nº de quadros)]: corridas de quadros contíguos da câmera para a saída."""
    trechos = production.trechos_camera(projeto)
    c = cut.carregar(projeto)
    segs = c["segmentos"] if c else [[0.0, duracao, 0.0]]
    n = int(round(duracao * FPS))
    fontes = [_na_camera(trechos, _editada(segs, k / FPS)) for k in range(n)]
    corridas = []
    for k, s in enumerate(fontes):
        if corridas and abs(s - (corridas[-1][0] + corridas[-1][1] / FPS)) < 0.5 / FPS:
            corridas[-1][1] += 1
        else:
            corridas.append([s, 1])
    return corridas


def cortar(projeto, duracao):
    """Gera a câmera cortada (sem som; a voz é a narração). Refaz só se o corte ou a câmera mudaram."""
    cam = production.camera(projeto)
    if not cam:
        raise SystemExit("modo apresentador sem câmera: ponha o vídeo como camera.mp4 no episódio")
    corridas = quadros(projeto, duracao)
    saida = destino(projeto)
    saida.parent.mkdir(parents=True, exist_ok=True)
    marca = saida.with_suffix(".json")
    chave = {"corridas": corridas, "camera": str(cam.resolve()), "mtime": cam.resolve().stat().st_mtime_ns}
    if saida.exists() and marca.exists() and json.loads(marca.read_text()) == chave:
        return saida
    partes = [f"[0:v]trim=start={s:.4f}:end={s + q / FPS:.4f},setpts=PTS-STARTPTS,fps={FPS},"
              f"tpad=stop=2:stop_mode=clone,trim=end_frame={q}[v{i}];" for i, (s, q) in enumerate(corridas)]
    partes.append("".join(f"[v{i}]" for i in range(len(corridas))) + f"concat=n={len(corridas)}:v=1:a=0,"
                  "scale=-2:'min(1080,ih)',format=yuv420p[v]")
    script = saida.with_suffix(".filtro")
    script.write_text("\n".join(partes))
    base = ["ffmpeg", "-v", "error", "-y", "-i", str(cam), "-filter_complex_script", str(script), "-map", "[v]",
            "-r", str(FPS), "-g", str(FPS)]
    if subprocess.run(base + ["-c:v", "h264_nvenc", "-preset", "p4", "-cq", "21", str(saida)]).returncode != 0:
        subprocess.run(base + ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", str(saida)], check=True)
    marca.write_text(json.dumps(chave))
    print(f"  câmera cortada: {len(corridas)} trechos · {duracao:.0f} s → {saida.name}")
    return saida


def rosto(video, amostras=24):
    """{"x", "y", "h"} do rosto (frações do quadro: centro e altura), mediana das amostras; centro alto sem rosto."""
    import cv2
    cap = cv2.VideoCapture(str(video))
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) or 1
    det = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
    achados = []
    for k in np.linspace(0, n - 1, amostras).astype(int):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(k))
        ok, q = cap.read()
        if not ok:
            continue
        H, W = q.shape[:2]
        cinza = cv2.cvtColor(q, cv2.COLOR_BGR2GRAY)
        rostos = det.detectMultiScale(cinza, 1.1, 6, minSize=(H // 12, H // 12))
        if len(rostos):
            x, y, w, h = max(rostos, key=lambda r: r[2] * r[3])
            achados.append(((x + w / 2) / W, (y + h / 2) / H, h / H))
    cap.release()
    if not achados:
        return {"x": 0.5, "y": 0.35, "h": 0.3, "achado": False}
    x, y, h = np.median(np.array(achados), axis=0)
    return {"x": round(float(x), 3), "y": round(float(y), 3), "h": round(float(h), 3), "achado": True}


SEM_APRESENTADOR = ("tela", "solido")  # tiram o apresentador da tela: contam no teto `tela_max`


def layouts(cenas, midia, regras, duracao, variacoes=("split",)):
    """Layout de cada trecho → [{t, ate, layout, punch}] cobrindo o vídeo; grava `layout` em cada cena.
    `variacoes`: rodízio das peças cheias com o apresentador (split, lateral, flutuante, sólido)."""
    ap = regras.apresentador
    tela_max, broll_max = ap.get("tela_max", 0.07), ap.get("broll", 0.3)
    marcas = []
    tela = 0.0
    giro = 0
    for c in cenas:
        pedido = c.get("layout_pedido")  # o gatilho do estilo escolheu o layout
        cabe = tela + (c["ate"] - c["t"]) <= tela_max * duracao
        if pedido in ("full", "split", "broll", "lateral", "flutuante", "galeria") or (pedido in SEM_APRESENTADOR and cabe):
            c["layout"] = pedido
            tela += (c["ate"] - c["t"]) if pedido in SEM_APRESENTADOR else 0
        elif pedido == "solido":
            c["layout"] = "flutuante"  # sem orçamento para tirar o apresentador: o card flutua sobre a câmera
        elif c.get("takeover"):
            pode = c["cena"] in TELA and cabe
            if pode:
                c["layout"] = "tela"
            else:
                lay = (list(variacoes) or ["split"])[giro % max(len(variacoes), 1)]
                giro += 1
                c["layout"] = "flutuante" if lay == "solido" and not cabe else lay
                pode = c["layout"] == "solido"
            tela += (c["ate"] - c["t"]) if pode else 0
        else:
            c["layout"] = "full"
        marcas.append({"t": c["t"], "ate": c["ate"], "layout": c["layout"], "punch": c["cena"] in IMPACTO})
    # B-roll: itens de mídia longos fora das cenas de motion, um sim um não, até o teto
    broll, alterna = 0.0, False
    for m in midia:
        livre = not any(x["t"] < m["fim"] and x["ate"] > m["ini"] and x["layout"] != "full" for x in marcas)
        if m["fim"] - m["ini"] < 1.5 or not livre or m["ini"] < 2.0:
            continue
        alterna = not alterna
        if alterna and broll + (m["fim"] - m["ini"]) <= broll_max * duracao:
            marcas.append({"t": m["ini"], "ate": m["fim"], "layout": "broll", "punch": False})
            broll += m["fim"] - m["ini"]
    # linha do tempo: o que não é cena especial é FULL; motion/B-roll ganham da FULL de cena sobre a mídia
    peso = {"full": 0, "broll": 1, "split": 2, "tela": 2, "lateral": 2, "flutuante": 2, "solido": 2, "galeria": 2}
    pontos = sorted({0.0, duracao, *[x["t"] for x in marcas], *[x["ate"] for x in marcas]})
    segs = []
    for a, b in zip(pontos, pontos[1:], strict=False):
        if b - a < 1e-3:
            continue
        ativos = [x for x in marcas if x["t"] <= a and x["ate"] >= b]
        top = max(ativos, key=lambda x: peso[x["layout"]], default={"layout": "full", "punch": False})
        lay, punch = top["layout"], top["punch"] if top["layout"] == "full" else False
        if segs and segs[-1]["layout"] == lay and segs[-1]["punch"] == punch:
            segs[-1]["ate"] = round(b, 3)
        else:
            segs.append({"t": round(a, 3), "ate": round(b, 3), "layout": lay, "punch": punch})
    return segs


def resumo(segs, duracao):
    return {k: round(sum(s["ate"] - s["t"] for s in segs if s["layout"] == k) / max(duracao, 1), 2)
            for k in ("full", "split", "broll", "tela", "lateral", "flutuante", "solido", "galeria")}
