"""Etapa 4: monta a timeline no FilmCraft a partir do plano.json e exporta o vídeo.

Faixas: V1 cenas · V2 camada de ajuste (cor dark + vinheta)
        V4 gráficos animados (graficos.json, com alfa) ou, sem eles, textos do FilmCraft · A1 narração · A2 trilha
"""

import threading
import time
from contextlib import contextmanager
from pathlib import Path

from esteira.core import events
from esteira.core.display import open_program
from esteira.filmcraft import FilmCraft, ticks
from esteira.media import duration_media
from esteira.n1 import filmcraft as N1
from esteira.project import ROOT


def _path(value, name):
    """Caminho da config: absoluto, com ~ ou relativo à pasta da esteira. Ausente → aviso e None."""
    if not value:
        return None
    p = Path(value).expanduser()
    p = p if p.is_absolute() else ROOT / p
    if not p.exists():
        print(f"  aviso: {name} não encontrado em {p}; seguindo sem")
        return None
    return p


def _scenes_with_media(plan):
    """Cenas sem mídia são absorvidas pela anterior (ou pela seguinte, se for a primeira)."""
    output = []
    pending_start = None
    for c in plan["cenas"]:
        if c.get("midia"):
            c = dict(c)
            if pending_start is not None:
                c["inicio"], pending_start = pending_start, None
            output.append(c)
        elif output:
            output[-1]["fim"] = c["fim"]
        else:
            pending_start = c["inicio"]
    if not output:
        raise SystemExit("nenhuma cena tem mídia; rode buscar")
    output[-1]["fim"] = plan["duracao"]
    return output


STRONG = {"glitch", "flash", "zoom_blur", "flicker", "light_leak", "chroma_leak", "whip", "cross_zoom"}


class _Transitions:
    """Transição de entrada de cada cena pelo clima (perfil do canal), com rodízio dentro do clima, efeito
    forte (glitch, flash…) no máximo a cada `intervalo_forte` s e mergulho no preto nas viradas de capítulo."""

    def __init__(self, cfg, chapters):
        ef = cfg.get("efeitos", {})
        self.transition_map = ef.get("transicao", {})
        self.default_transition = cfg["edicao"]["transicao"]
        self.strong_interval = ef.get("intervalo_forte", 20)
        self.chapters = sorted(chapters)
        self.last_strong, self.spin = -1e9, {}

    def pick(self, scene):
        t = scene["inicio"]
        if any(abs(t - c) <= 1.5 for c in self.chapters):
            return "dip_to_black"
        options = self.transition_map.get(scene.get("clima"), [self.default_transition]) or [self.default_transition]
        k = self.spin.get(scene.get("clima"), 0)
        self.spin[scene.get("clima")] = k + 1
        effect = options[k % len(options)]
        if effect in STRONG:
            if t - self.last_strong < self.strong_interval:
                return next((o for o in options if o not in STRONG), self.default_transition)
            self.last_strong = t
        return effect


PUNCH, PUNCH_DURATION, PUNCHES_MAX = 6, 0.12, 2  # % de zoom de impacto, s que ele leva, máximo por cena


def _captions_srt(project, destination, max_words=7, max_seg=3.0):
    if project.path_of("alinhamento.json").exists():
        words = project.load_json("alinhamento.json")
    else:
        words = project.load_json("transcricao.json")["palavras"]
    blocks, current = [], []
    for w in words:
        end_of_sentence = w["p"].endswith((".", "!", "?"))
        # Não deixa a última palavra da frase sozinha numa legenda.
        if current and not end_of_sentence and (len(current) >= max_words or w["fim"] - current[0]["ini"] > max_seg):
            blocks.append(current)
            current = []
        current.append(w)
        if end_of_sentence:
            blocks.append(current)
            current = []
    if current:
        blocks.append(current)

    def tc(s):
        ms = int(round(s * 1000))
        return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"

    lines = []
    for i, b in enumerate(blocks, 1):
        lines += [str(i), f"{tc(b[0]['ini'])} --> {tc(b[-1]['fim'])}", " ".join(w["p"] for w in b), ""]
    destination.write_text("\n".join(lines))


@contextmanager
def _beat(arquivo, duration, interval=10):
    """Enquanto o FilmCraft exporta (chamada bloqueante), registra tempo e tamanho do arquivo."""
    stop = threading.Event()

    def bater():
        t0, n = time.monotonic(), 0
        while not stop.wait(interval):
            n += 1
            mb = arquivo.stat().st_size / 1e6 if arquivo.exists() else 0
            events.debug("exportando", seg=round(time.monotonic() - t0), mb=round(mb, 1), video_s=duration)
            if n % 6 == 0:  # no terminal, uma linha por minuto
                print(f"  exportando… {int(time.monotonic() - t0)}s, {mb:.0f} MB")

    th = threading.Thread(target=bater, daemon=True)
    th.start()
    try:
        yield
    finally:
        stop.set()


def assemble(project, export=True):
    _store_edit_manual(project)
    cfg = project.cfg
    e = cfg["edicao"]
    plan = project.load_json("plano.json")
    from esteira import production
    cam = production.camera(project) if production.mode(project) == "apresentador" else None
    if cam:  # apresentador: câmera na V1 o tempo todo; mídia de banco só nas cenas de B-roll (V2)
        production.mark_presenter(project, plan)
        scenes = [c for c in plan["cenas"] if c.get("midia") and not c.get("camera")]
    else:
        scenes = _scenes_with_media(plan)
    duration = plan["duracao"]
    from esteira import photos
    scenes = photos.treat(project, scenes)
    if e["legendas"]:
        _captions_srt(project, project.path_of("legendas.srt"))
    doc, medias = assembly(project, plan, scenes, cam)
    fc = FilmCraft()
    try:
        ex = N1.Executor(fc, medias, style(cfg))
        ex.apply_doc(doc)
        n_graphic = sum(1 for o in doc.ops if o.op == "colocar" and o.trilha == "grafismo")
        n_keys = sum(1 for o in doc.ops if o.op == "texto" and o.estilo == "pop")
        print(f"  {sum(1 for o in doc.ops if o.op == 'colocar' and o.midia.startswith('cena:'))} cenas"
              + (f", {n_graphic} gráficos na V4" if n_graphic else "") + (f", {n_keys} palavras-chave na V3" if n_keys else ""))

        from esteira.description import generate as gerar_descricao
        print(f"  descrição com os links das fontes: {gerar_descricao(project).name}")

        fcproj = project.path_of("projeto.fcproj")
        fc.run("file.saveAs", path=str(fcproj))
        _sign(project)
        print(f"  projeto salvo: {fcproj} (`./dark open {project.ep}` para editar à mão)")

        _dataset(project, plan, doc, ex.trace, cam, medias)
        if export:
            _export(fc, project, duration)
    finally:
        fc.close()


def style(cfg):
    """Fonte e cores por papel para o executor N1 (a pele do canal vem do perfil)."""
    e = cfg["edicao"]
    return {"fonte": e["fonte"], "fonte_estilo": e["fonte_estilo"],
            "cores": {"texto": "#ffffff", "destaque": e["destaque_cor"],
                      "acento": cfg.get("graficos", {}).get("cor", "#ffd400")}}


def assembly(project, plan, scenes, cam):
    """Plano do episódio → montagem em N1 do FilmCraft + mídias referenciadas. É o que o modelo local aprende a
    escrever na tarefa `montar` (o executor transforma em comandos da app)."""
    cfg = project.cfg
    e, au = cfg["edicao"], cfg["audio"]
    w, h = cfg["video"]["largura"], cfg["video"]["altura"]
    duration = plan["duracao"]
    fmt = cfg["video"].get("formato", "16:9")
    seq = {"op": "sequencia", "nome": plan.get("titulo") or project.ep, "formato": fmt, "fps": cfg["video"]["fps"]}
    if (w, h) != N1.FORMATS.get(fmt):
        seq.update(largura=w, altura=h)
    ops = [seq, {"op": "colocar", "id": "narracao", "midia": "narracao", "trilha": "narracao", "em": 0},
           {"op": "tipo_audio", "alvo": "narracao", "tipo": "dialogo"}]
    medias = {"narracao": {"caminho": project.audio()}}

    lane = "base"
    if cam:  # apresentador: a câmera cortada igual à narração, sem o som dela
        from esteira import production
        medias["cam"] = {"caminho": cam.resolve()}
        ic = production.info_camera(project)
        # preenche o quadro (4K, 720p ou câmera deitada num Short 9:16), cortando o excesso
        scale = round(100 * max(w / (ic.get("largura") or w), h / (ic.get("altura") or h)), 3)
        spans = production.spans_camera(project)
        for k, (t_tl, t_cam, d) in enumerate(spans):
            ops.append({"op": "colocar", "id": f"cam{k}", "midia": "cam", "trilha": "base", "em": t_tl,
                        "origem": t_cam, "dur": d})
            if scale != 100:
                ops.append({"op": "enquadrar", "alvo": f"cam{k}", "zoom": scale})
        print(f"  câmera: {len(spans)} trechos na V1; {len(scenes)} cenas de B-roll na V2")
        lane = "apoio"

    graphics = [g for g in (project.load_json("graficos.json") if project.path_of("graficos.json").exists()
                            else []) if g.get("arquivo") and (project.folder_path / g["arquivo"]).exists()]
    keys = project.load_json("chaves.json") if project.path_of("chaves.json").exists() else []
    trans = _Transitions(cfg, [g["inicio"] for g in graphics if g.get("origem") == "capitulo"])
    # socos de zoom: cada palavra-chave e cada número no instante em que é dito
    punches = [k["inicio"] + 0.08 for k in keys] + [g["ancora"] for g in graphics if g.get("ancora")]
    zooms = cfg.get("efeitos", {}).get("zoom", {})
    names = []
    for i, scene in enumerate(scenes):
        ref, name = f"cena:{scene['id']}", f"c{scene['id']}"
        medias[ref] = {"caminho": project.folder_path / scene["midia"]}
        start, end = scene["inicio"], scene["fim"]
        ops.append({"op": "colocar", "id": name, "midia": ref, "trilha": lane, "em": start, "dur": end - start})
        ops.append({"op": "ken_burns", "alvo": name, "movimento": scene.get("movimento", "zoom_in"),
                    "zoom": zooms.get(scene.get("clima"), e["zoom"]),
                    "socos": sorted(t for t in punches if start + 0.3 < t < end - 0.6)})
        q = e["transicao_frames"]
        if cam:  # B-roll entra e sai da câmera com fusão curta
            ops += [{"op": "transicao", "alvo": name, "tipo": "cross_dissolve", "borda": b, "quadros": q}
                    for b in ("entrada", "saida")]
        else:
            ops.append({"op": "transicao", "alvo": name, "tipo": "dip_to_black" if i == 0 else trans.pick(scene),
                        "quadros": q})
        names.append(name)
    if names and not cam:
        ops.append({"op": "transicao", "alvo": names[-1], "tipo": "dip_to_black", "borda": "saida",
                    "quadros": e["transicao_frames"] * 2})

    # Cor "dark": camada de ajuste sobre as cenas (no modo apresentador, só com `[producao] grade_camera = true`)
    if e.get("grade_cor", "dark") == "dark" and (not cam or cfg.get("producao", {}).get("grade_camera", False)):
        ops.append({"op": "cor", "acima_de": "apoio" if cam else "base", "dur": duration, "ajustes": {
            "exposicao": -0.35, "contraste": 18, "saturacao": 80, "temperatura": -12, "filme": 12, "vinheta": -2.2}})

    # Gráficos animados (EffectCraft/HTML com alfa) por cima de tudo, fora da correção de cor
    for n, g in enumerate(graphics, 1):
        medias[f"grafico:{n}"] = {"caminho": project.folder_path / g["arquivo"]}
        ops.append({"op": "colocar", "id": f"g{n}", "midia": f"grafico:{n}", "trilha": "grafismo", "em": g["inicio"]})

    # Sem gráficos: título e palavras em destaque como texto do FilmCraft
    slack = 2 / cfg["video"]["fps"]  # o arredondamento para quadros não pode encostar um texto no outro
    free = 0.0                       # quando a faixa de texto fica livre
    if e["titulo_inicio"] and plan.get("titulo") and not graphics:
        duration_title = min(4.0, scenes[0]["fim"] - 0.6)
        ops.append({"op": "texto", "id": "titulo", "conteudo": plan["titulo"].upper(), "em": 0.6, "dur": duration_title,
                    "tamanho": e["destaque_tamanho"] * 0.8 / h, "pos": (0.5, 0.55), "cor": "destaque"})
        free = 0.6 + duration_title + slack
    highlights = [] if graphics or keys else sorted((d for c in plan["cenas"] for d in c.get("destaques", [])),
                                                     key=lambda d: d["inicio"])
    for n, (d, prox) in enumerate(zip(highlights, highlights[1:] + [None])):
        # um destaque sai antes do seguinte entrar (e não entra sobre o título), na mesma faixa
        start = max(d["inicio"], free)
        end = min(d["inicio"] + e["destaque_segundos"], (prox["inicio"] - slack) if prox else duration, duration - 0.1)
        if end - start >= 0.8:
            ops.append({"op": "texto", "id": f"d{n}", "conteudo": d["texto"].upper(), "em": start, "dur": end - start,
                        "tamanho": e["destaque_tamanho"] / h, "pos": (0.5, 0.82), "cor": "destaque"})
            free = end + slack

    # Palavras-chave com "pop" (chaves.json, já agendadas fora dos gráficos da V4)
    for n, k in enumerate(keys):
        size = 118 if len(k["texto"]) <= 12 else 92 if len(k["texto"]) <= 20 else 72
        ops.append({"op": "texto", "id": f"k{n}", "conteudo": k["texto"], "em": k["inicio"], "dur": k["dur"],
                    "tamanho": size / h, "pos": (0.5, {"baixo": 0.80, "centro": 0.50, "alto": 0.22}[k["pos"]]),
                    "cor": "acento" if k["cor"] == "destaque" else "texto", "estilo": "pop"})

    # Trilha de fundo em loop, com ducking sob a narração
    music = _path(au.get("musica"), "trilha")
    if music:
        medias["musica"] = {"caminho": music, "dur": duration_media(music)}
        ops.append({"op": "musica", "ate": duration, "ganho_db": au["musica_db"]})

    if e["legendas"]:
        medias["legendas"] = {"caminho": project.path_of("legendas.srt")}
        ops.append({"op": "legendas", "tamanho": e.get("legenda_tamanho", 54) / h,
                    "margem": e.get("legenda_margem", 0.06)})
    return N1.Assembly.model_validate({"ops": ops}), medias


def _dataset(project, plan, doc, trace, cam, medias=None):
    """A montagem vira registro `montar` (origem `traducao`: veio do código determinístico); nunca derruba a etapa."""
    try:
        from esteira.dataset import registry as R
        cfg = project.cfg
        ctx = {"formato": cfg["video"].get("formato", "16:9"), "modo": "apresentador" if cam else "dark",
               "duracao": plan["duracao"], "canal": getattr(project, "canal", "") or "",
               "cenas": [{k: c.get(k) for k in ("id", "inicio", "fim", "clima", "midia_tipo", "movimento")}
                         for c in plan["cenas"] if c.get("midia")],
               "graficos": [{k: g.get(k) for k in ("inicio", "modelo", "origem", "ancora")}
                            for g in (project.load_json("graficos.json")
                                      if project.path_of("graficos.json").exists() else [])],
               "chaves": project.load_json("chaves.json") if project.path_of("chaves.json").exists() else [],
               "receita": {"edicao": {k: cfg["edicao"].get(k) for k in ("zoom", "transicao_frames", "legendas",
                                                                          "grade_cor", "titulo_inicio")},
                           "efeitos": cfg.get("efeitos", {}), "musica_db": cfg["audio"].get("musica_db")}}
        R.write("montar", group=f"ep:{project.ep}", context=ctx, output=doc.model_dump(mode="json"),
                 origin="traducao", n0=trace, versions={"n1": N1.VERSION, "app": "filmcraft"},
                 extra={"episodio": project.ep, "fcproj": "projeto.fcproj",
                        "midias": {k: Path(str(v["caminho"])).name for k, v in (medias or {}).items()}})
    except Exception as e:  # noqa: BLE001
        events.warning(f"dataset: montagem de {project.ep} não gravada ({e})")


def _export(fc, project, duration):
    e, au = project.cfg["edicao"], project.cfg["audio"]
    final = project.path_of("final.mp4")
    print("  exportando final.mp4…")
    with _beat(final, duration):
        fc.run("file.exportMedia", path=str(final), format="h264", bitrateMode="crf", crf=18,
               hardwareEncoding="auto", loudnessLufs=au["loudness_lufs"],
               burnCaptions=bool(e["legendas"]), wait=True)
    print(f"  {final} ({duration_media(final):.1f}s)")


# Edição manual: o .fcproj é do usuário depois de montado. A assinatura registra a versão gerada pela
# esteira; se o arquivo mudou, foi editado à mão e é guardado antes de uma nova montagem.

def _hash(file):
    import hashlib
    return hashlib.sha1(file.read_bytes()).hexdigest()


def _sign(project):
    project.path_of("log").mkdir(exist_ok=True)
    project.path_of("log/fcproj.sha1").write_text(_hash(project.path_of("projeto.fcproj")))


def _store_edit_manual(project):
    fcproj, signature = project.path_of("projeto.fcproj"), project.path_of("log/fcproj.sha1")
    if not fcproj.exists() or (signature.exists() and signature.read_text() == _hash(fcproj)):
        return
    copy = fcproj.with_name(f"projeto.manual-{time.strftime('%Y%m%d-%H%M')}.fcproj")
    fcproj.rename(copy)
    events.warning(f"projeto.fcproj tinha edição manual: guardado em {copy.name}")
    try:  # a edição vira dado (corrigir_montagem) antes da nova montagem
        from esteira.dataset import edits
        edits.fcproj_edited(project, copy)
    except Exception as e:  # noqa: BLE001
        events.warning(f"dataset: edição manual de {project.ep} não levantada ({e})")


def _open_reconnected(fc, project):
    """Abre o projeto.fcproj no FilmCraft (MCP); se a pasta do episódio mudou de lugar, religa a mídia pela
    pasta do projeto e salva. Mantém a assinatura se o arquivo ainda era o gerado pela esteira."""
    fcproj, signature = project.path_of("projeto.fcproj"), project.path_of("log/fcproj.sha1")
    if not fcproj.exists():
        raise SystemExit("sem projeto.fcproj: rode `./dark assemble` antes")
    of_esteira = signature.exists() and signature.read_text() == _hash(fcproj)
    missing = fc.run("file.open", path=str(fcproj)).get("missingMedia", 0)
    if missing:
        fc.run("media.autoRelink", folder=str(project.folder_path))
        fc.run("file.saveAs", path=str(fcproj))
        if of_esteira:
            _sign(project)
        print(f"  {missing} mídias religadas a partir de {project.folder_path}")


def export_manual(project):
    """Reexporta final.mp4 a partir do projeto.fcproj como está (depois de editar à mão no FilmCraft)."""
    fc = FilmCraft()
    try:
        _open_reconnected(fc, project)
        _export(fc, project, project.load_json("plano.json")["duracao"])
    finally:
        fc.close()


def open_file(project):
    """Abre o projeto.fcproj na interface do FilmCraft, desacoplado do terminal."""
    fc = FilmCraft()
    try:
        _open_reconnected(fc, project)
    finally:
        fc.close()
    fcproj = project.path_of("projeto.fcproj")
    open_program("filmcraft", str(fcproj))
    print(f"  FilmCraft aberto: {fcproj}\n  depois de editar e salvar: ./dark export {project.ep}")
