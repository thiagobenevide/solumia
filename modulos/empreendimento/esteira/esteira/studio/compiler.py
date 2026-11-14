"""Compilar → render → áudio final → verificar, para um formato (16:9 ou 9:16).

Pasta da produção: `<ep>/estudio/<16x9|9x16>/` com `index.html` (kit + mapa + estilo), `assets/` (kit copiado,
narração e mídia curada do episódio por link), `render/bruto.mp4` (HyperFrames, codificado na GPU), `final.mp4`
(loudnorm em duas passadas, −14 LUFS / −1 dBTP), `folha.jpg` e `relatorio.json` (portão final).
"""
import json
import re
import shutil
import subprocess
import wave
from pathlib import Path

from esteira.core import events
from esteira.studio import engine

KIT = Path(__file__).parent / "kit"
DIM = {"16:9": (1920, 1080), "9:16": (1080, 1920)}


def folder(project, fmt):
    return project.pasta / "estudio" / fmt.replace(":", "x")


def _link(origem, destino):
    destino.parent.mkdir(parents=True, exist_ok=True)
    if destino.is_symlink() or destino.exists():
        destino.unlink()
    destino.symlink_to(Path(origem).resolve())


def _words(project):
    """Palavras da narração editada; números partidos pelo Whisper ("81" ",7%") voltam a ser um só."""
    from esteira.studio import cut
    ws = []
    for p in cut.words(project):
        txt = p["p"].strip()
        if ws and re.fullmatch(r"[,.]?\d*%?|%", txt) and txt and re.search(r"\d$", ws[-1]["text"]):
            ws[-1]["text"] += txt
            ws[-1]["end"] = p["fim"]
        elif txt:
            ws.append({"text": txt, "start": p["ini"], "end": p["fim"]})
    return ws


def _media(project, destino):
    """Mídia curada do plano (imagem/vídeo por trecho), sem buracos entre um trecho e o seguinte."""
    from esteira.studio import cut
    plan = json.loads((project.pasta / "plano.json").read_text())
    new = cut.new(project)
    items = []
    for c in plan["cenas"]:
        file = project.pasta / (c.get("midia") or "")
        if not c.get("midia") or not file.is_file():
            continue
        _link(file, destino / "midia" / file.name)
        items.append({"ini": new(c["inicio"]), "fim": new(c["fim"]), "src": f"assets/midia/{file.name}",
                      "tipo": "video" if c.get("midia_tipo") == "video" or file.suffix == ".mp4" else "imagem",
                      "mov": c.get("movimento") or "zoom_in"})
    items.sort(key=lambda m: m["ini"])
    for a, b in zip(items, items[1:], strict=False):
        a["fim"] = b["ini"]
    if items:
        items[0]["ini"] = 0.0
        items[-1]["fim"] = plan.get("duracao") or items[-1]["fim"]
    return items


def _sfx(cenas, estilo):
    """Um som por entrada de cena, respeitando o teto por segundo (intervalo mínimo entre efeitos)."""
    rg = estilo.regras
    gap, last, sounds = 1.0 / max(rg.sfx_por_s, 0.05), -99.0, []
    from esteira.studio.style import SFX_KEY, SFX_DEFAULT
    level = rg.niveis.get("sfx", "media")
    for c in sorted(cenas, key=lambda c: c["t"]):
        # baixa: só as entradas principais; alta: toda cena ganha som (o padrão onde o estilo não escolheu)
        # a peça do acervo traz o som da entrada na ficha (`sfx.entrada`); o estilo pode trocar por cena
        name = rg.sfx.get(c["cena"]) or (SFX_DEFAULT.get(c["cena"]) or c.get("sfx") if level == "alta" else None)
        if level == "baixa" and c["cena"] not in SFX_KEY:
            continue
        if not name or c["t"] - last < gap:
            continue
        with wave.open(str(KIT / "sfx" / f"{name}.wav")) as w:
            duration = w.getnframes() / w.getframerate()
        sounds.append({"t": max(0.0, c["t"] - 0.05), "dur": round(duration, 3), "src": f"assets/sfx/{name}.wav", "vol": rg.sfx_volume})
        last = c["t"]
    return sounds


def _window(itens, de, ate, ini="t", fim="ate"):
    """Itens que tocam [de, ate], com os tempos deslocados para começar em 0 (trecho de um bloco)."""
    output = []
    for x in itens:
        if x[fim] <= de or x[ini] >= ate:
            continue
        y = {**x, ini: round(max(x[ini], de) - de, 3), fim: round(min(x[fim], ate) - de, 3)}
        if x[ini] < de:
            y["corte"] = round(de - x[ini] + x.get("corte", 0.0), 3)  # a mídia que já tinha começado entra no meio
        if "batidas" in x:
            y["batidas"] = {k: round(v - de, 3) for k, v in (x.get("batidas") or {}).items() if de <= v < ate}
        output.append(y)
    return output


def build(project, estilo, fmt, destino=None, ate=None, de=None):
    """Monta a pasta da produção e o index.html; devolve a pasta. `destino`/`ate`: amostra do estilo (outra pasta,
    só os primeiros `ate` segundos do mapa). `de` + `ate`: trecho [de, ate] (render de um bloco, para emendar)."""
    mapping = json.loads((project.pasta / "estudio" / "mapa.json").read_text())
    duration_total = mapping["duracao"]
    if de is not None:
        ate = ate if ate is not None else mapping["duracao"]
        mapping["cenas"] = _window(mapping["cenas"], de, ate)
        mapping["duracao"] = round(ate - de, 3)
    elif ate:
        mapping["duracao"] = min(mapping["duracao"], ate)
        mapping["cenas"] = [{**c, "ate": min(c["ate"], ate)} for c in mapping["cenas"] if c["t"] < ate - 1]
    p = destino or folder(project, fmt)
    a = p / "assets"
    a.mkdir(parents=True, exist_ok=True)
    for name in ("estudio.js", "estudio.css", "gsap.min.js"):
        shutil.copy(KIT / name, a / name)
    from esteira.studio import piece
    cards = {f.id: f for f in piece.list_all()}
    three = piece.join(a, sorted(cards))  # todas: uma peça pode cair em outra (anel sem porcentagem → contador)
    # mapa do diretor atual (titulo/valores no topo) → encaixes das peças migradas do kit
    mapping["cenas"] = [{**c, "encaixes": piece.legacy(c, cards[c["cena"]])} if c["cena"] in cards else c
                     for c in mapping["cenas"]]
    # peças do motor EffectCraft: renderizadas aqui (WebM com alfa por cena, `.ecproj` ao lado para editar à mão)
    from esteira.studio import ec
    for n, c in enumerate(mapping["cenas"]):
        f = cards.get(c["cena"])
        if f and f.motor == "effectcraft":
            ec.to_production(f.id, c, estilo, fmt, a / f"ec_{n:03d}.webm")
            c["ec_src"] = f"assets/ec_{n:03d}.webm"
    from esteira.studio import fonts
    skin = estilo.pele
    roles = ("fonte_destaque", "fonte_texto", "fonte_tecnica", "fonte_legenda", "fonte_editorial")
    (a / "fontes.css").write_text(fonts.css([getattr(skin, k) for k in roles], a))
    skin = skin.model_copy(update={k: fonts.resolve(getattr(skin, k)) for k in roles})
    shutil.copytree(KIT / "sfx", a / "sfx", dirs_exist_ok=True)
    from esteira.studio import cut
    _link(cut.audio(project), a / "narracao.wav")
    W, H = DIM[fmt]
    rg = estilo.regras
    keys = sorted({w for c in mapping["cenas"] for w in re.findall(r"\w{4,}", (c.get("ancora") or "").lower())})
    cfg = {"W": W, "H": H, "pele": skin.model_dump(), "efeitos": rg.efeitos, "visual": rg.visual.model_dump(),
           "legenda": {"ativa": rg.legenda.get(fmt, False), **rg.legenda_visual.model_dump(), "chaves": keys},
           # linguagem de movimento, layouts, regras de cor e ajuste de cada peça (abas do estilo no app)
           "movimento": estilo.movimento.model_dump(), "layouts": estilo.layouts.model_dump(),
           "regras_cor": estilo.regras_cor.model_dump(), "pecas": {k: v.model_dump() for k, v in estilo.pecas.items()}}
    sounds = _sfx(mapping["cenas"], estilo)
    duration = round(mapping["duracao"], 3)
    media = _media(project, a)
    if de is not None:
        media = _window(media, de, ate, "ini", "fim")
    lay = None
    if estilo.modo != "apresentador":
        _layouts_dark(mapping["cenas"], estilo.layouts.variacoes_dark)
    if estilo.modo == "apresentador":
        from esteira.studio import camera
        if not camera.exists(project):
            raise SystemExit("estilo de apresentador sem câmera: envie o vídeo da câmera do episódio (camera.mp4)")
        v = camera.cut_camera(project, duration_total if de is not None else duration)
        _link(v, a / "camera.mp4")
        segs = camera.layouts(mapping["cenas"], media, estilo.regras, duration, estilo.layouts.variacoes)
        ap = estilo.regras.apresentador
        from esteira.library import _probe
        cw, ch, _ = _probe(v)
        cfg["camera"] = {"src": "assets/camera.mp4", "foco": camera.face(v), "dim": [cw, ch], "punch": ap["punch"],
                         "inicio": de or 0.0,
                         "punch_impacto": round(1 + (ap["punch_impacto"] - 1) * rg.efeitos.get("zoom", 1.0), 3),
                         "segs": segs}
        lay = camera.summary(segs, duration)
    html = (KIT / "index.template.html").read_text()
    for k, v in {"__W__": W, "__H__": H, "__DUR__": duration, "__CFG__": json.dumps(cfg, ensure_ascii=False),
                 "__MIDIA__": json.dumps(media, ensure_ascii=False),
                 "__CENAS__": json.dumps(mapping["cenas"], ensure_ascii=False),
                 "__WORDS__": json.dumps(_words(project) if de is None else
                                         _window(_words(project), de, ate, "start", "end"), ensure_ascii=False),
                 "__DE__": de or 0,
                 "__SFX__": json.dumps(sounds), "__EC__": piece.videos_ec(mapping["cenas"]),
                 "__THREE__": piece.TAG_THREE if three else ""}.items():
        html = html.replace(k, str(v))
    (p / "index.html").write_text(html)
    (p / "producao.json").write_text(json.dumps({"estilo": estilo.id, "versao": estilo.versao, "formato": fmt,
                                                 "cenas": len(mapping["cenas"]), "sfx": len(sounds), "duracao": duration,
                                                 "layouts": lay}, indent=1))
    print(f"  {fmt}: {len(mapping['cenas'])} cenas · {len(sounds)} efeitos · {duration:.0f} s" + (f" · layouts {lay}" if lay else ""))
    return p


def _layouts_dark(cenas, variations):
    """Dark: peças cheias em rodízio (tela = motion sobre a mídia desfocada; lateral/flutuante = dados sobre a mídia;
    sólido = card sobre fundo na cor do estilo). O layout pedido pelo gatilho vence; capítulo fica na tela."""
    spin = 0
    for c in cenas:
        request = c.get("layout_pedido")
        if request in ("lateral", "flutuante", "solido", "galeria"):
            c["layout"] = request
        elif c.get("takeover") and not request and c["cena"] != "titulo_capitulo" and variations:
            lay = variations[spin % len(variations)]
            spin += 1
            if lay != "tela":
                c["layout"] = lay


def render(project, fmt, qualidade="high", p=None):
    p = p or folder(project, fmt)
    (p / "render").mkdir(exist_ok=True)
    with open(p / "render.log", "w") as log:
        engine.npx(["hyperframes", "lint"], p, log)
        engine.npx(["hyperframes", "render", "-q", qualidade, "--gpu", "-o", "render/bruto.mp4"], p, log)
    return p / "render" / "bruto.mp4"


def _has_audio(file):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0",
                        str(file)], capture_output=True, text=True)
    return bool(r.stdout.strip())


def render_span(project, estilo, fmt, de, ate, nome):
    """Compila e renderiza só [de, ate] (o bloco alterado) em `<formato>/trechos/<nome>/render/bruto.mp4`."""
    destination = folder(project, fmt) / "trechos" / nome
    shutil.rmtree(destination, ignore_errors=True)
    build(project, estilo, fmt, destino=destination, ate=ate, de=de)
    return render(project, fmt, p=destination)


def splice(project, fmt, de, ate, trecho):
    """Troca [de, ate] do `render/bruto.mp4` pelo trecho renderizado (vídeo e som da composição); o resto do vídeo
    não é renderizado de novo, só reencodado na emenda. Guarda o bruto anterior como `bruto.anterior.mp4`."""
    p = folder(project, fmt)
    raw = p / "render" / "bruto.mp4"
    if not raw.exists():
        raise SystemExit("sem render completo para emendar: renderize o vídeo inteiro antes")
    sound = _has_audio(raw) and _has_audio(trecho)
    v = (f"[0:v]trim=0:{de:.3f},setpts=PTS-STARTPTS[v0];[1:v]setpts=PTS-STARTPTS[v1];"
         f"[0:v]trim=start={ate:.3f},setpts=PTS-STARTPTS[v2];")
    a = (f"[0:a]atrim=0:{de:.3f},asetpts=PTS-STARTPTS[a0];[1:a]asetpts=PTS-STARTPTS[a1];"
         f"[0:a]atrim=start={ate:.3f},asetpts=PTS-STARTPTS[a2];") if sound else ""
    junta = "[v0][a0][v1][a1][v2][a2]concat=n=3:v=1:a=1[v][a]" if sound else "[v0][v1][v2]concat=n=3:v=1:a=0[v]"
    new = p / "render" / "bruto.novo.mp4"
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(raw), "-i", str(trecho), "-filter_complex", v + a + junta,
           "-map", "[v]", "-c:v", "libx264", "-preset", "fast", "-crf", "16", "-pix_fmt", "yuv420p"]
    cmd += ["-map", "[a]", "-c:a", "aac", "-b:a", "256k"] if sound else []
    subprocess.run(cmd + [str(new)], check=True)
    raw.replace(p / "render" / "bruto.anterior.mp4")
    new.replace(raw)
    return raw


def _measure(file, lufs, peak, extra=""):
    criteria = f"{extra}loudnorm=I={lufs}:TP={peak}:LRA=11:print_format=json"
    out = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(file), "-af", criteria, "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    return json.loads(out[out.rindex("{"):out.rindex("}") + 1])


def audio(project, estilo, fmt, p=None):
    """Loudnorm em duas passadas (medição + correção linear); vídeo copiado sem reencodar. Gera também a prévia leve."""
    p = p or folder(project, fmt)
    rg = estilo.regras
    raw, final = p / "render" / "bruto.mp4", p / "final.mp4"
    cap = rg.pico - 0.8  # o AAC estoura o pico depois do loudnorm: a margem mantém o final dentro do limite
    m = _measure(raw, rg.lufs, cap)
    criteria = (f"loudnorm=I={rg.lufs}:TP={cap}:LRA=11:measured_I={m['input_i']}:measured_TP={m['input_tp']}:"
              f"measured_LRA={m['input_lra']}:measured_thresh={m['input_thresh']}:offset={m['target_offset']}:linear=true")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(raw), "-c:v", "copy", "-af", criteria, "-ar", "48000",
                    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(final)], check=True)
    preview(final)
    return final


def preview(final):
    """`previa.mp4` ao lado do final: lado menor 540 px, H.264 leve e faststart, para assistir de fora da rede do PC
    sem baixar o arquivo cheio. Sai primeiro num temporário: o app só vê a prévia quando ela está inteira."""
    destination, tmp = final.with_name("previa.mp4"), final.with_name("previa.tmp.mp4")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(final),
                    "-vf", "scale='if(gt(iw,ih),-2,540)':'if(gt(iw,ih),540,-2)',fps=30", "-c:v", "libx264",
                    "-preset", "veryfast", "-crf", "30", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k",
                    "-movflags", "+faststart", str(tmp)], check=True)
    tmp.replace(destination)
    return destination


def _frame(video, t, destino):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{t:.2f}", "-i", str(video), "-frames:v", "1", "-q:v", "3",
                    str(destino)], check=True)


def verify(project, estilo, fmt, n_vision=8):
    """Portão final: loudness, folha de quadros e conferência visual (IA local) nos quadros das cenas."""
    from esteira.bench import Vision
    from esteira.ai import local
    p = folder(project, fmt)
    final = p / "final.mp4"
    mapping = json.loads((project.pasta / "estudio" / "mapa.json").read_text())
    medido = _measure(final, estilo.regras.lufs, estilo.regras.pico)
    lufs, peak = float(medido["input_i"]), float(medido["input_tp"])
    q = p / "quadros"
    shutil.rmtree(q, ignore_errors=True)
    q.mkdir()
    scenes = mapping["cenas"]
    target = scenes[:: max(1, len(scenes) // 12)][:12]
    frames = []
    for c in target:
        file = q / f"c{c['id']:03d}.jpg"
        _frame(final, (c["t"] + c["ate"]) / 2, file)
        frames.append((c, file))
    W, H = DIM[fmt]
    scale = "scale=480:-2" if W > H else "scale=270:-2"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-pattern_type", "glob", "-i", str(q / "c*.jpg"), "-vf",
                    f"{scale},tile={4 if W > H else 6}x{3 if W > H else 2}", "-frames:v", "1", str(p / "folha.jpg")])
    problems = []
    for n, (c, file) in enumerate(frames[:n_vision], 1):
        events.progress(n, min(n_vision, len(frames)), f"conferindo {c['cena']}")
        r = local.ask(local.prompt("estudio_visao"), Vision, model=local.VISION, images=[str(file)], max_tokens=200,
                            operation="studio_vision")
        if r:
            bad = [k for k, v in r.model_dump().items() if v]
            if bad:
                problems.append({"cena": c["id"], "tipo": c["cena"], "t": c["t"], "defeitos": bad, "quadro": file.name})
    prod = json.loads((p / "producao.json").read_text())
    rel = {"formato": fmt, "estilo": estilo.id, "versao": estilo.versao, "duracao": prod["duracao"],
           "cenas": prod["cenas"], "sfx": prod["sfx"], "sfx_por_s": round(prod["sfx"] / max(prod["duracao"], 1), 2),
           "takeover": round(sum(c["ate"] - c["t"] for c in scenes if c["takeover"]) / max(prod["duracao"], 1), 2),
           "lufs": lufs, "pico": peak, "visao": problems, "decisoes": mapping.get("decisoes", {}),
           "ritmo": mapping.get("ritmo"),
           "audio_ok": abs(lufs - estilo.regras.lufs) <= 0.5 and peak <= estilo.regras.pico + 0.3}
    rel["aprovado_auto"] = rel["audio_ok"] and not problems
    (p / "relatorio.json").write_text(json.dumps(rel, ensure_ascii=False, indent=1))
    print(f"  {fmt}: {lufs} LUFS · pico {peak} dBTP · {len(problems)} quadro(s) com defeito · "
          f"{'aprovado' if rel['aprovado_auto'] else 'precisa revisão'}")
    return rel
