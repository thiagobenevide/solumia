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

from esteira.estudio import motor
from esteira.nucleo import eventos

KIT = Path(__file__).parent / "kit"
DIM = {"16:9": (1920, 1080), "9:16": (1080, 1920)}


def pasta(projeto, formato):
    return projeto.pasta / "estudio" / formato.replace(":", "x")


def _link(origem, destino):
    destino.parent.mkdir(parents=True, exist_ok=True)
    if destino.is_symlink() or destino.exists():
        destino.unlink()
    destino.symlink_to(Path(origem).resolve())


def _palavras(projeto):
    """Palavras da narração editada; números partidos pelo Whisper ("81" ",7%") voltam a ser um só."""
    from esteira.estudio import corte
    ws = []
    for p in corte.palavras(projeto):
        txt = p["p"].strip()
        if ws and re.fullmatch(r"[,.]?\d*%?|%", txt) and txt and re.search(r"\d$", ws[-1]["text"]):
            ws[-1]["text"] += txt
            ws[-1]["end"] = p["fim"]
        elif txt:
            ws.append({"text": txt, "start": p["ini"], "end": p["fim"]})
    return ws


def _midia(projeto, destino):
    """Mídia curada do plano (imagem/vídeo por trecho), sem buracos entre um trecho e o seguinte."""
    from esteira.estudio import corte
    plano = json.loads((projeto.pasta / "plano.json").read_text())
    novo = corte.novo(projeto)
    itens = []
    for c in plano["cenas"]:
        arq = projeto.pasta / (c.get("midia") or "")
        if not c.get("midia") or not arq.is_file():
            continue
        _link(arq, destino / "midia" / arq.name)
        itens.append({"ini": novo(c["inicio"]), "fim": novo(c["fim"]), "src": f"assets/midia/{arq.name}",
                      "tipo": "video" if c.get("midia_tipo") == "video" or arq.suffix == ".mp4" else "imagem",
                      "mov": c.get("movimento") or "zoom_in"})
    itens.sort(key=lambda m: m["ini"])
    for a, b in zip(itens, itens[1:], strict=False):
        a["fim"] = b["ini"]
    if itens:
        itens[0]["ini"] = 0.0
        itens[-1]["fim"] = plano.get("duracao") or itens[-1]["fim"]
    return itens


def _sfx(cenas, estilo):
    """Um som por entrada de cena, respeitando o teto por segundo (intervalo mínimo entre efeitos)."""
    rg = estilo.regras
    gap, ultimo, sons = 1.0 / max(rg.sfx_por_s, 0.05), -99.0, []
    from esteira.estudio.estilo import SFX_CHAVE, SFX_PADRAO
    nivel = rg.niveis.get("sfx", "media")
    for c in sorted(cenas, key=lambda c: c["t"]):
        # baixa: só as entradas principais; alta: toda cena ganha som (o padrão onde o estilo não escolheu)
        # a peça do acervo traz o som da entrada na ficha (`sfx.entrada`); o estilo pode trocar por cena
        nome = rg.sfx.get(c["cena"]) or (SFX_PADRAO.get(c["cena"]) or c.get("sfx") if nivel == "alta" else None)
        if nivel == "baixa" and c["cena"] not in SFX_CHAVE:
            continue
        if not nome or c["t"] - ultimo < gap:
            continue
        with wave.open(str(KIT / "sfx" / f"{nome}.wav")) as w:
            dur = w.getnframes() / w.getframerate()
        sons.append({"t": max(0.0, c["t"] - 0.05), "dur": round(dur, 3), "src": f"assets/sfx/{nome}.wav", "vol": rg.sfx_volume})
        ultimo = c["t"]
    return sons


def _janela(itens, de, ate, ini="t", fim="ate"):
    """Itens que tocam [de, ate], com os tempos deslocados para começar em 0 (trecho de um bloco)."""
    saida = []
    for x in itens:
        if x[fim] <= de or x[ini] >= ate:
            continue
        y = {**x, ini: round(max(x[ini], de) - de, 3), fim: round(min(x[fim], ate) - de, 3)}
        if x[ini] < de:
            y["corte"] = round(de - x[ini] + x.get("corte", 0.0), 3)  # a mídia que já tinha começado entra no meio
        if "batidas" in x:
            y["batidas"] = {k: round(v - de, 3) for k, v in (x.get("batidas") or {}).items() if de <= v < ate}
        saida.append(y)
    return saida


def compilar(projeto, estilo, formato, destino=None, ate=None, de=None):
    """Monta a pasta da produção e o index.html; devolve a pasta. `destino`/`ate`: amostra do estilo (outra pasta,
    só os primeiros `ate` segundos do mapa). `de` + `ate`: trecho [de, ate] (render de um bloco, para emendar)."""
    mapa = json.loads((projeto.pasta / "estudio" / "mapa.json").read_text())
    duracao_total = mapa["duracao"]
    if de is not None:
        ate = ate if ate is not None else mapa["duracao"]
        mapa["cenas"] = _janela(mapa["cenas"], de, ate)
        mapa["duracao"] = round(ate - de, 3)
    elif ate:
        mapa["duracao"] = min(mapa["duracao"], ate)
        mapa["cenas"] = [{**c, "ate": min(c["ate"], ate)} for c in mapa["cenas"] if c["t"] < ate - 1]
    p = destino or pasta(projeto, formato)
    a = p / "assets"
    a.mkdir(parents=True, exist_ok=True)
    for nome in ("estudio.js", "estudio.css", "gsap.min.js"):
        shutil.copy(KIT / nome, a / nome)
    from esteira.estudio import peca
    fichas = {f.id: f for f in peca.listar()}
    tres = peca.juntar(a, sorted(fichas))  # todas: uma peça pode cair em outra (anel sem porcentagem → contador)
    # mapa do diretor atual (titulo/valores no topo) → encaixes das peças migradas do kit
    mapa["cenas"] = [{**c, "encaixes": peca.legado(c, fichas[c["cena"]])} if c["cena"] in fichas else c
                     for c in mapa["cenas"]]
    # peças do motor EffectCraft: renderizadas aqui (WebM com alfa por cena, `.ecproj` ao lado para editar à mão)
    from esteira.estudio import ec
    for n, c in enumerate(mapa["cenas"]):
        f = fichas.get(c["cena"])
        if f and f.motor == "effectcraft":
            ec.para_producao(f.id, c, estilo, formato, a / f"ec_{n:03d}.webm")
            c["ec_src"] = f"assets/ec_{n:03d}.webm"
    from esteira.estudio import fontes
    pele = estilo.pele
    papeis = ("fonte_destaque", "fonte_texto", "fonte_tecnica", "fonte_legenda", "fonte_editorial")
    (a / "fontes.css").write_text(fontes.css([getattr(pele, k) for k in papeis], a))
    pele = pele.model_copy(update={k: fontes.resolver(getattr(pele, k)) for k in papeis})
    shutil.copytree(KIT / "sfx", a / "sfx", dirs_exist_ok=True)
    from esteira.estudio import corte
    _link(corte.audio(projeto), a / "narracao.wav")
    W, H = DIM[formato]
    rg = estilo.regras
    chaves = sorted({w for c in mapa["cenas"] for w in re.findall(r"\w{4,}", (c.get("ancora") or "").lower())})
    cfg = {"W": W, "H": H, "pele": pele.model_dump(), "efeitos": rg.efeitos, "visual": rg.visual.model_dump(),
           "legenda": {"ativa": rg.legenda.get(formato, False), **rg.legenda_visual.model_dump(), "chaves": chaves},
           # linguagem de movimento, layouts, regras de cor e ajuste de cada peça (abas do estilo no app)
           "movimento": estilo.movimento.model_dump(), "layouts": estilo.layouts.model_dump(),
           "regras_cor": estilo.regras_cor.model_dump(), "pecas": {k: v.model_dump() for k, v in estilo.pecas.items()}}
    sons = _sfx(mapa["cenas"], estilo)
    dur = round(mapa["duracao"], 3)
    midia = _midia(projeto, a)
    if de is not None:
        midia = _janela(midia, de, ate, "ini", "fim")
    lay = None
    if estilo.modo != "apresentador":
        _layouts_dark(mapa["cenas"], estilo.layouts.variacoes_dark)
    if estilo.modo == "apresentador":
        from esteira.estudio import camera
        if not camera.existe(projeto):
            raise SystemExit("estilo de apresentador sem câmera: envie o vídeo da câmera do episódio (camera.mp4)")
        v = camera.cortar(projeto, duracao_total if de is not None else dur)
        _link(v, a / "camera.mp4")
        segs = camera.layouts(mapa["cenas"], midia, estilo.regras, dur, estilo.layouts.variacoes)
        ap = estilo.regras.apresentador
        from esteira.acervo import _sonda
        cw, ch, _ = _sonda(v)
        cfg["camera"] = {"src": "assets/camera.mp4", "foco": camera.rosto(v), "dim": [cw, ch], "punch": ap["punch"],
                         "inicio": de or 0.0,
                         "punch_impacto": round(1 + (ap["punch_impacto"] - 1) * rg.efeitos.get("zoom", 1.0), 3),
                         "segs": segs}
        lay = camera.resumo(segs, dur)
    html = (KIT / "index.template.html").read_text()
    for k, v in {"__W__": W, "__H__": H, "__DUR__": dur, "__CFG__": json.dumps(cfg, ensure_ascii=False),
                 "__MIDIA__": json.dumps(midia, ensure_ascii=False),
                 "__CENAS__": json.dumps(mapa["cenas"], ensure_ascii=False),
                 "__WORDS__": json.dumps(_palavras(projeto) if de is None else
                                         _janela(_palavras(projeto), de, ate, "start", "end"), ensure_ascii=False),
                 "__DE__": de or 0,
                 "__SFX__": json.dumps(sons), "__EC__": peca.videos_ec(mapa["cenas"]),
                 "__THREE__": peca.TAG_THREE if tres else ""}.items():
        html = html.replace(k, str(v))
    (p / "index.html").write_text(html)
    (p / "producao.json").write_text(json.dumps({"estilo": estilo.id, "versao": estilo.versao, "formato": formato,
                                                 "cenas": len(mapa["cenas"]), "sfx": len(sons), "duracao": dur,
                                                 "layouts": lay}, indent=1))
    print(f"  {formato}: {len(mapa['cenas'])} cenas · {len(sons)} efeitos · {dur:.0f} s" + (f" · layouts {lay}" if lay else ""))
    return p


def _layouts_dark(cenas, variacoes):
    """Dark: peças cheias em rodízio (tela = motion sobre a mídia desfocada; lateral/flutuante = dados sobre a mídia;
    sólido = card sobre fundo na cor do estilo). O layout pedido pelo gatilho vence; capítulo fica na tela."""
    giro = 0
    for c in cenas:
        pedido = c.get("layout_pedido")
        if pedido in ("lateral", "flutuante", "solido", "galeria"):
            c["layout"] = pedido
        elif c.get("takeover") and not pedido and c["cena"] != "titulo_capitulo" and variacoes:
            lay = variacoes[giro % len(variacoes)]
            giro += 1
            if lay != "tela":
                c["layout"] = lay


def render(projeto, formato, qualidade="high", p=None):
    p = p or pasta(projeto, formato)
    (p / "render").mkdir(exist_ok=True)
    with open(p / "render.log", "w") as log:
        motor.npx(["hyperframes", "lint"], p, log)
        motor.npx(["hyperframes", "render", "-q", qualidade, "--gpu", "-o", "render/bruto.mp4"], p, log)
    return p / "render" / "bruto.mp4"


def _tem_audio(arq):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0",
                        str(arq)], capture_output=True, text=True)
    return bool(r.stdout.strip())


def render_trecho(projeto, estilo, formato, de, ate, nome):
    """Compila e renderiza só [de, ate] (o bloco alterado) em `<formato>/trechos/<nome>/render/bruto.mp4`."""
    destino = pasta(projeto, formato) / "trechos" / nome
    shutil.rmtree(destino, ignore_errors=True)
    compilar(projeto, estilo, formato, destino=destino, ate=ate, de=de)
    return render(projeto, formato, p=destino)


def emendar(projeto, formato, de, ate, trecho):
    """Troca [de, ate] do `render/bruto.mp4` pelo trecho renderizado (vídeo e som da composição); o resto do vídeo
    não é renderizado de novo, só reencodado na emenda. Guarda o bruto anterior como `bruto.anterior.mp4`."""
    p = pasta(projeto, formato)
    bruto = p / "render" / "bruto.mp4"
    if not bruto.exists():
        raise SystemExit("sem render completo para emendar: renderize o vídeo inteiro antes")
    som = _tem_audio(bruto) and _tem_audio(trecho)
    v = (f"[0:v]trim=0:{de:.3f},setpts=PTS-STARTPTS[v0];[1:v]setpts=PTS-STARTPTS[v1];"
         f"[0:v]trim=start={ate:.3f},setpts=PTS-STARTPTS[v2];")
    a = (f"[0:a]atrim=0:{de:.3f},asetpts=PTS-STARTPTS[a0];[1:a]asetpts=PTS-STARTPTS[a1];"
         f"[0:a]atrim=start={ate:.3f},asetpts=PTS-STARTPTS[a2];") if som else ""
    junta = "[v0][a0][v1][a1][v2][a2]concat=n=3:v=1:a=1[v][a]" if som else "[v0][v1][v2]concat=n=3:v=1:a=0[v]"
    novo = p / "render" / "bruto.novo.mp4"
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(bruto), "-i", str(trecho), "-filter_complex", v + a + junta,
           "-map", "[v]", "-c:v", "libx264", "-preset", "fast", "-crf", "16", "-pix_fmt", "yuv420p"]
    cmd += ["-map", "[a]", "-c:a", "aac", "-b:a", "256k"] if som else []
    subprocess.run(cmd + [str(novo)], check=True)
    bruto.replace(p / "render" / "bruto.anterior.mp4")
    novo.replace(bruto)
    return bruto


def _medir(arq, lufs, pico, extra=""):
    filtro = f"{extra}loudnorm=I={lufs}:TP={pico}:LRA=11:print_format=json"
    out = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(arq), "-af", filtro, "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    return json.loads(out[out.rindex("{"):out.rindex("}") + 1])


def audio(projeto, estilo, formato, p=None):
    """Loudnorm em duas passadas (medição + correção linear); vídeo copiado sem reencodar. Gera também a prévia leve."""
    p = p or pasta(projeto, formato)
    rg = estilo.regras
    bruto, final = p / "render" / "bruto.mp4", p / "final.mp4"
    teto = rg.pico - 0.8  # o AAC estoura o pico depois do loudnorm: a margem mantém o final dentro do limite
    m = _medir(bruto, rg.lufs, teto)
    filtro = (f"loudnorm=I={rg.lufs}:TP={teto}:LRA=11:measured_I={m['input_i']}:measured_TP={m['input_tp']}:"
              f"measured_LRA={m['input_lra']}:measured_thresh={m['input_thresh']}:offset={m['target_offset']}:linear=true")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(bruto), "-c:v", "copy", "-af", filtro, "-ar", "48000",
                    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(final)], check=True)
    previa(final)
    return final


def previa(final):
    """`previa.mp4` ao lado do final: lado menor 540 px, H.264 leve e faststart, para assistir de fora da rede do PC
    sem baixar o arquivo cheio. Sai primeiro num temporário: o app só vê a prévia quando ela está inteira."""
    destino, tmp = final.with_name("previa.mp4"), final.with_name("previa.tmp.mp4")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(final),
                    "-vf", "scale='if(gt(iw,ih),-2,540)':'if(gt(iw,ih),540,-2)',fps=30", "-c:v", "libx264",
                    "-preset", "veryfast", "-crf", "30", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k",
                    "-movflags", "+faststart", str(tmp)], check=True)
    tmp.replace(destino)
    return destino


def _quadro(video, t, destino):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{t:.2f}", "-i", str(video), "-frames:v", "1", "-q:v", "3",
                    str(destino)], check=True)


def verificar(projeto, estilo, formato, n_visao=8):
    """Portão final: loudness, folha de quadros e conferência visual (IA local) nos quadros das cenas."""
    from esteira.bancada import Visao
    from esteira.ia import local
    p = pasta(projeto, formato)
    final = p / "final.mp4"
    mapa = json.loads((projeto.pasta / "estudio" / "mapa.json").read_text())
    medido = _medir(final, estilo.regras.lufs, estilo.regras.pico)
    lufs, pico = float(medido["input_i"]), float(medido["input_tp"])
    q = p / "quadros"
    shutil.rmtree(q, ignore_errors=True)
    q.mkdir()
    cenas = mapa["cenas"]
    alvo = cenas[:: max(1, len(cenas) // 12)][:12]
    quadros = []
    for c in alvo:
        arq = q / f"c{c['id']:03d}.jpg"
        _quadro(final, (c["t"] + c["ate"]) / 2, arq)
        quadros.append((c, arq))
    W, H = DIM[formato]
    escala = "scale=480:-2" if W > H else "scale=270:-2"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-pattern_type", "glob", "-i", str(q / "c*.jpg"), "-vf",
                    f"{escala},tile={4 if W > H else 6}x{3 if W > H else 2}", "-frames:v", "1", str(p / "folha.jpg")])
    problemas = []
    for n, (c, arq) in enumerate(quadros[:n_visao], 1):
        eventos.progresso(n, min(n_visao, len(quadros)), f"conferindo {c['cena']}")
        r = local.perguntar(local.prompt("estudio_visao"), Visao, modelo=local.VISAO, imagens=[str(arq)], max_tokens=200,
                            operacao="estudio_visao")
        if r:
            ruins = [k for k, v in r.model_dump().items() if v]
            if ruins:
                problemas.append({"cena": c["id"], "tipo": c["cena"], "t": c["t"], "defeitos": ruins, "quadro": arq.name})
    prod = json.loads((p / "producao.json").read_text())
    rel = {"formato": formato, "estilo": estilo.id, "versao": estilo.versao, "duracao": prod["duracao"],
           "cenas": prod["cenas"], "sfx": prod["sfx"], "sfx_por_s": round(prod["sfx"] / max(prod["duracao"], 1), 2),
           "takeover": round(sum(c["ate"] - c["t"] for c in cenas if c["takeover"]) / max(prod["duracao"], 1), 2),
           "lufs": lufs, "pico": pico, "visao": problemas, "decisoes": mapa.get("decisoes", {}),
           "ritmo": mapa.get("ritmo"),
           "audio_ok": abs(lufs - estilo.regras.lufs) <= 0.5 and pico <= estilo.regras.pico + 0.3}
    rel["aprovado_auto"] = rel["audio_ok"] and not problemas
    (p / "relatorio.json").write_text(json.dumps(rel, ensure_ascii=False, indent=1))
    print(f"  {formato}: {lufs} LUFS · pico {pico} dBTP · {len(problemas)} quadro(s) com defeito · "
          f"{'aprovado' if rel['aprovado_auto'] else 'precisa revisão'}")
    return rel
