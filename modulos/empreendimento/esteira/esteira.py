#!/usr/bin/env python3
"""Dark video pipeline: narration + script → scenes → media → edit in FilmCraft → thumbnail.

Usage:
  ./dark all <project>            runs every stage in sequence
  ./dark transcribe <project>     1. narration → transcricao.json (timed words)
  ./dark clean <project>          1b. cuts retakes and off-script speech → narracao.wav + cortes.txt
  ./dark parts <project>          script in numbered parts to record with "Corte/Cancela parte N"
  ./dark scenes <project>         2. script + transcription → plano.json (scenes and search terms)
  ./dark curate <project> [--redo]   2b. local LLM: search term, media kind and mood of each scene
  ./dark evaluate <project>       3a. local vision grades the media of each scene and swaps what does not fit
  ./dark graphics <project> [--render-only]   3b. animated graphics (quotes, numbers, chapters) → graficos/
  ./dark fetch <project> [--redo] [--scenes 3,5]
                                  3. downloads images/videos of each scene to midia/
  ./dark review <project> [--scenes 3,5]   sheets revisao_NN.jpg (16 scenes each) to check the media
  ./dark summary <project> [--scenes 3,5] [--no-text]   plan in one line per scene
  ./dark words <project> [--from S] [--to S]   time of each spoken word
  ./dark adjust <project> [file.jsonl]   applies partial edits to the plan (JSON Lines, or stdin)
  ./dark frames <project> [--n 8]   sheet quadros.jpg with frames of final.mp4
  ./dark assemble <project>       4. builds the timeline in FilmCraft → projeto.fcproj + final.mp4
  ./dark open <project>           opens projeto.fcproj in FilmCraft (manual editing)
  ./dark export <project>         re-exports final.mp4 from the hand-edited projeto.fcproj
  ./dark thumb <project>          5. thumbnails (concepts → RealVisXL → 3 variants for A/B testing)
  ./dark scripts [channel] [--status S]   scripts of the Obsidian vault
  ./dark import <channel:NNN[letter] | file.md> [--audio X.wav]   creates the project (script, sources, audio);
                                  channel:5a = Short 005a (9:16), channel:5 = long video 005 (16:9)
  ./dark script <channel:N> [--to M]   writes scripts of the plan to the vault (local LLM, open sources, no Claude)
  ./dark library [stats|search terms|import|describe]   media kept and reused across videos
  ./dark panel [--port 8765]      web panel (pick scripts, follow along, review cuts and scenes)
  ./dark status [<project>]       stages: done, running (with estimate), failed
  ./dark log <project> [--stage assemble] [--errors] [--debug]   latest events

<project> is the episode "channel-NNN" (folder projetos/<canal>/<NNN>/, created by `import`) or a path.
"""

import argparse
import sys
from pathlib import Path

from esteira.core import events
from esteira.projeto import RAIZ, Projeto, episodios, pasta_ep


def resolve(name):
    p = Path(name)
    return Projeto(p if p.exists() and "/" in name else pasta_ep(name))


def stage(name):
    def run(a):
        p = resolve(a.project)
        print(f"▶ {name}: {p.ep}")
        with events.stage(p, name):
            _run(name, p, a)
    return run


def _run(name, p, a):
    if name == "transcribe":
        from esteira.transcrever import transcrever
        transcrever(p, p.cfg)
    elif name == "clean":
        from esteira.cortes import aplicar
        aplicar(p, refazer=a.redo)
    elif name == "scenes":
        from esteira.cenas import gerar_cenas
        gerar_cenas(p)
    elif name == "fetch":
        from esteira.midia import buscar
        buscar(p, refazer=a.redo, cenas=_scene_ids(a.scenes))
    elif name == "review":
        from esteira.midia import revisar
        revisar(p, cenas=_scene_ids(a.scenes))
    elif name == "frames":
        from esteira.midia import quadros
        quadros(p, a.n)
    elif name == "curate":
        from esteira.curadoria import curar
        curar(p, refazer=a.redo)
    elif name == "evaluate":
        from esteira.avaliar import avaliar
        avaliar(p)
    elif name == "graphics":
        from esteira.graficos import plano
        if not a.render_only:
            from esteira.graficos import chaves
            chaves.planejar(p, plano.planejar(p), refazer=True)  # animated keywords in the gaps between graphics
        plano.renderizar(p)
    elif name == "assemble":
        from esteira.montar import montar
        montar(p, exportar=not a.no_export)
    elif name == "studio":  # only through `all`: the order to produce everything stands in for the cut and marking gates
        from esteira import estudio
        from esteira.descricao import gerar as gerar_descricao
        from esteira.estudio import corte
        corte.analisar(p)
        if n := corte.estado(p).get("cortadas"):
            raise SystemExit(f"the sound cut clipped {n} word(s): revert the splices around them "
                             "(Studio tab → Cut) and produce through the Studio")
        estudio.produzir(a.project, sem_portao=True)
        print(f"  description with the source links: {gerar_descricao(p).name}")
    elif name == "thumb":
        from esteira.thumbs import thumbs
        thumbs(p)
    elif name == "export":
        from esteira.montar import exportar_manual
        exportar_manual(p)


def _scene_ids(text):
    if not text:
        return None
    ids = []
    for x in text.split(","):
        ids.append(int(x))
    return ids


def cmd_compact(a):
    # No "▶ stage" line: the output is read by Claude, every line costs tokens.
    from esteira import resumo as r
    p = resolve(a.project)
    if a.cmd == "summary":
        r.resumo(p, a.scenes, a.no_text)
    elif a.cmd == "words":
        r.palavras(p, a.start, a.end)
    else:
        r.ajustar(p, a.file)


def cmd_parts(a):
    from esteira import claquete
    p = resolve(a.project)
    if not p.roteiro():
        raise SystemExit("the project has no roteiro.txt")
    parts = claquete.do_projeto(p)
    target = p.caminho("partes.txt")
    target.write_text(claquete.texto_para_leitura(parts))
    print(f"{len(parts)} parts → {target}")


def cmd_all(a):
    from_scratch = getattr(a, "redo", False)
    a.no_export, a.scenes, a.render_only = False, None, False
    from esteira import estudio
    # channel with a Studio style: the edit comes from the piece library (per-block direction), not from FilmCraft
    last = ("graphics", "assemble", "thumb")
    if estudio.estilo_padrao(resolve(a.project)):
        last = ("studio", "thumb")
    for name in ("clean", "scenes", "curate", "fetch", "evaluate", *last):
        # from scratch: cuts and curation are decided again; the fetch keeps good media of scenes that did not change
        a.redo = from_scratch and name in ("clean", "curate")
        try:
            stage(name)(a)
        except Exception as e:
            _diagnose(resolve(a.project), name, e)
            raise


def _diagnose(p, name, error):
    """Error in a stage of `all`: Claude reads the traceback + the end of the log and records cause and action."""
    import traceback

    from esteira.core import status
    from esteira.ai import claude
    from pydantic import BaseModel

    class Diagnosis(BaseModel):
        cause: str
        action: str

    log = "\n".join(f"{e['stage']} {e['kind']} {e['message'][:160]}" for e in status.events(p.pasta)[-25:])
    d = claude.query(f"The stage '{name}' of the video pipeline failed.\n\nTraceback:\n"
                         f"{traceback.format_exc(limit=8)[-2500:]}\n\nLatest events:\n{log}\n\n"
                         "State the likely cause (1 sentence) and the concrete action for the operator "
                         "(1-2 sentences). Write both in Brazilian Portuguese.",
                         Diagnosis, p.cfg, p.ep, f"diagnosis: error in {name}")
    if d:  # only the warning: the stage stays marked as failed in the status
        print(f"  ! diagnosis: {d.cause} → {d.action}")
        events.Stage(p, name).record("warning", f"diagnosis: {d.cause} → {d.action}")


def cmd_status(a):
    from esteira.core import status
    if a.project:
        status.print_status(resolve(a.project).pasta)
        return
    for folder in episodios():
        if (folder / "log" / "events.jsonl").exists():
            status.print_status(folder)


def cmd_log(a):
    from esteira.core import status
    status.print_log(resolve(a.project).pasta, a.stage, a.n, a.errors, a.debug)


def _sources_config():
    import tomllib
    return tomllib.loads((RAIZ / "config.toml").read_text())["fontes"]


def cmd_scripts(a):
    from esteira.fontes import obsidian
    for r in obsidian.listar(_sources_config()["vault"], a.channel):
        if not a.status or r["status"] == a.status:
            print(f"{r['canal']:15} {str(r['numero'] or '-') + r['short']:>5} {r['formato']:5} {r['status']:10} {r['titulo'][:66]}")


def cmd_import(a):
    from esteira.fontes import obsidian
    from esteira.fontes.importar import importar
    md = Path(a.script)
    if not md.exists():  # "finlumia:3" → script number 3 of the channel
        channel, _, number = a.script.partition(":")
        found = []
        for r in obsidian.listar(_sources_config()["vault"], channel):
            if f"{r['numero']}{r['short']}" == number.lstrip("0"):
                found.append(r)
        if len(found) != 1:
            raise SystemExit(f"script not found: {a.script} (use channel:number or the path of the .md)")
        md = Path(found[0]["caminho"])
    importar(md, a.audio, a.name, a.camera, a.mode)


def cmd_library(a):
    from esteira import acervo
    if a.action == "import":
        print(f"  {acervo.importar_projetos()} episode media files registered in the library")
    elif a.action == "describe":
        print(f"  {acervo.descrever(a.n)} items described by the local vision model")
    elif a.action == "search":
        for r in acervo.listar(" ".join(a.terms), limite=a.n):
            print(f"{r['id']:28} {r['tipo']:6} {r['orientacao']:8} {len(r['usos'])} uses  {', '.join(r['termos'])[:60]}")
    else:
        e = acervo.estatisticas()
        print(f"  library {acervo.pasta()}: {e['itens']} items ({e['videos']} videos, {e['imagens']} images), "
              f"{e['gb']} GB; {e['descritos']} described; {e['usos']} uses ({e['reusados']} media files used)")
        for k, v in sorted(e["por_provedor"].items()):
            print(f"    {k:20} {v}")


def _print_line(message):
    print(f"  {message}", flush=True)


def _csv(text):
    if not text:
        return None
    return text.split(",")


def cmd_bench(a):
    from esteira import bancada
    if a.action == "generate":
        print(f"  answer key: {bancada.gerar()}")
        return
    if a.action == "run":
        from esteira.ai import llama
        models = _csv(a.models)
        if models is None:
            models = []
            for m in llama.models() or []:
                models.append(m["id"])
        bancada.rodar(models, _csv(a.tasks), a.n, progresso=_print_line)
    print("\n".join(bancada.tabela()))


def cmd_studio(a):
    from esteira import estudio
    stages = _csv(a.stages) or estudio.ETAPAS
    intensity = None
    if a.intensity:
        intensity = {}
        for pair in a.intensity.split(","):
            key, value = pair.split("=", 1)
            intensity[key] = value
    estudio.produzir(a.project, a.style, _csv(a.formats), stages, a.no_gate, intensity)


def cmd_studio_cut(a):
    from esteira.estudio import corte
    from esteira.projeto import Projeto, pasta_ep
    corte.analisar(Projeto(pasta_ep(a.project)))


def cmd_studio_install(a):
    from esteira.estudio import motor
    print(f"  {motor.instalar(_print_line)}")


def cmd_studio_style(a):
    from esteira.estudio import identidade
    e = identidade.propor(a.target, a.niche or "")
    print(f"  style {e.id} v{e.versao}: {e.pele.destaque} · {len(e.exemplos)} examples")


def cmd_studio_factory(a):
    from esteira.estudio import fabrica
    order_id = a.target.removeprefix("fabrica:")
    p = fabrica.rodar(order_id, visual=not a.no_vision)
    print(f"  factory {order_id}: {p.situacao} · {len(p.pecas)} piece(s) · {p.descartadas} discarded · US$ {p.gasto_usd:.2f}")


def cmd_studio_piece_preview(a):
    from esteira.estudio import peca
    piece_id = a.target
    if ":" in a.target:
        piece_id = a.target.split(":")[1]
    print(f"  preview: {peca.previa(piece_id, a.style, a.format)}")


def cmd_studio_channel_proof(a):
    from esteira.estudio import peca
    r = peca.prova_canais(a.styles)
    print(f"  skin proof: {len(r['pecas'])} piece(s) × {len(a.styles)} style(s) · {len(r['problemas'])} problem(s)")
    for x in r["problemas"]:
        print(f"    {x['peca']} · {x['estilo']} · {x['formato']}: {x['erro']}")


def cmd_studio_block(a):
    from esteira import estudio
    estudio.renderizar_bloco(a.ep, a.block, a.formats or None)


def cmd_training(a):
    from esteira.estudio import treino
    if a.action == "export":
        r = treino.exportar()
        counts = []
        for task, x in r["tarefas"].items():
            counts.append(f"{task} {x['treino']}+{x['validacao']}")
        print(f"  training base in {r['pasta']}: " + ", ".join(counts))
    else:
        print(f"  trained model: {treino.treinar(a.base, a.epochs)} (pick it in Options)")


def cmd_dataset(a):
    from esteira.dataset import indice
    if a.action == "reindex":
        print(f"  {indice.reindexar()} records in the index")
        return
    if a.action == "export":
        from esteira.dataset import exportar
        r = exportar.exportar(_csv(a.tasks))
        counts = []
        for task, x in r["tarefas"].items():
            counts.append(f"{task} {x['sft']}+{x['val']} sft, {x['dpo']} dpo, {x['eval']} eval")
        print(f"  export in {r['pasta']}: " + ", ".join(counts))
        return
    if a.action == "translate":
        from esteira.dataset import traduzir
        for line in traduzir.tudo():
            print(f"  {line}")
        return
    if a.action == "edits":
        from esteira.dataset import edicoes
        for line in edicoes.varrer():
            print(f"  {line}")
        return
    if a.action == "train":
        from esteira.dataset import treino_app
        m = treino_app.treinar(a.app, a.base, a.epochs, forcar=a.force)
        print(f"  adapter {m['nome']} ({m['casos_treino']} cases, loss {m['perda']}); promote: "
              f"./dark dataset promote --app {a.app} --name {m['nome']}")
        return
    if a.action == "promote":
        from esteira.dataset import treino_app
        r = treino_app.promover(a.app, a.name, a.n)
        print(f"  {r['nome']}: {'PROMOTED' if r['promovido'] else 'not promoted'} · scores {r['notas']}")
        return
    for task, x in indice.situacao().items():
        print(f"  {task:18} {x['total']:5} records · sft {x.get('sft', 0):4}/{x['minimo']:<5} · dpo {x.get('dpo_ruim', 0):4}"
              f" · pending {x.get('pendente', 0):4}{'  READY' if x['pronta'] else ''}")


def cmd_studio_sample(a):
    from esteira.estudio import amostra
    amostra.gerar(a.target)


def cmd_script(a):
    from esteira.roteirista import gerar
    gerar(a.target, a.to)


def cmd_panel(a):
    import uvicorn
    print(f"panel at http://localhost:{a.port}  (Ctrl+C to quit)")
    uvicorn.run("esteira.web.app:app", host=a.host, port=a.port, log_level="warning")


def cmd_open(a):
    from esteira.montar import abrir
    abrir(resolve(a.project))


LIGHT = {"parts", "status", "log", "summary", "words", "scripts", "panel", "adjust", "import", "open"}  # no slot


def _on_cancel(*_):
    """Cancel in the panel sends SIGTERM: leaves through the normal path (record, trace, slot)."""
    from esteira.core import processes
    processes.cancelled()
    sys.exit(143)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    for name in ("transcribe", "clean", "scenes", "curate", "fetch", "evaluate", "review", "graphics", "frames",
                 "assemble", "thumb", "export"):
        s = sub.add_parser(name)
        s.add_argument("project")
        if name in ("fetch", "review"):
            s.add_argument("--scenes", help="only these scenes, e.g. 3,5,8")
        if name == "frames":
            s.add_argument("--n", type=int, default=8, help="how many frames")
        if name == "fetch":
            s.add_argument("--redo", action="store_true", help="swaps the media for another result")
        if name == "curate":
            s.add_argument("--redo", action="store_true", help="curates again the scenes already curated too")
            s.add_argument("--engine", choices=["local", "claude"],
                           help="claude: does not use the GPU and runs alongside another process (counts toward the [claude] cap)")
        if name == "clean":
            s.add_argument("--redo", action="store_true", help="decides the cuts again (ignores cortes.json)")
        if name == "graphics":
            s.add_argument("--render-only", action="store_true", help="does not replan; only renders graficos.json")
        if name == "assemble":
            s.add_argument("--no-export", action="store_true", help="only saves the .fcproj project")
        s.set_defaults(f=stage(name))

    s = sub.add_parser("open", help="opens projeto.fcproj in FilmCraft for manual editing")
    s.add_argument("project")
    s.set_defaults(f=cmd_open)

    s = sub.add_parser("parts", help="script in numbered parts to record with \"Corte parte N\"")
    s.add_argument("project")
    s.set_defaults(f=cmd_parts)

    s = sub.add_parser("summary", help="plan in one line per scene")
    s.add_argument("project")
    s.add_argument("--scenes", help="only these scenes, e.g. 3,5,8")
    s.add_argument("--no-text", action="store_true", help="omits the spoken text")
    s.set_defaults(f=cmd_compact)

    s = sub.add_parser("words", help="time of each spoken word")
    s.add_argument("project")
    s.add_argument("--from", dest="start", type=float, default=0.0)
    s.add_argument("--to", dest="end", type=float)
    s.set_defaults(f=cmd_compact)

    s = sub.add_parser("adjust", help="applies partial edits (JSON Lines) to plano.json")
    s.add_argument("project")
    s.add_argument("file", nargs="?", help=".jsonl file (default: stdin)")
    s.set_defaults(f=cmd_compact)

    s = sub.add_parser("scripts", help="scripts of the Obsidian vault")
    s.add_argument("channel", nargs="?")
    s.add_argument("--status", help="e.g. rascunho, gravado")
    s.set_defaults(f=cmd_scripts)

    s = sub.add_parser("script", help="writes script(s) of the plan to the vault with the local LLM and open sources")
    s.add_argument("target", help="channel:N (e.g. finlumia:41)")
    s.add_argument("--to", type=int, help="up to video M (batch)")
    s.add_argument("--engine", choices=["local", "claude"],
                   help="claude: writes with Claude (no GPU; runs alongside another process; counts toward the cap)")
    s.set_defaults(f=cmd_script)

    s = sub.add_parser("library", help="downloaded, reusable media (statistics, search, import, describe)")
    s.add_argument("action", nargs="?", default="stats", choices=["stats", "search", "import", "describe"])
    s.add_argument("terms", nargs="*")
    s.add_argument("--n", type=int, default=20)
    s.set_defaults(f=cmd_library)

    s = sub.add_parser("studio", help="produces the episode video in the Studio (style → map → render → final gate)")
    s.add_argument("project")
    s.add_argument("--style", help="style id (default: the channel's style for the episode mode)")
    s.add_argument("--formats", help="16:9,9:16 (default: the style's)")
    s.add_argument("--stages", help="dirigir,compilar,render,audio,verificar (default: all)")
    s.add_argument("--no-gate", action="store_true", help="does not require the approved cut (test)")
    s.add_argument("--intensity", help="this production only: sfx=alta,motion=baixa,efeitos=media")
    s.set_defaults(f=cmd_studio)

    s = sub.add_parser("studio-cut", help="sound cut of the edited narration (fillers, breaths, pauses) → gate 1")
    s.add_argument("project")
    s.set_defaults(f=cmd_studio_cut)

    s = sub.add_parser("studio-install", help="installs Node, HyperFrames and Chromium of the render engine")
    s.add_argument("target", nargs="?", default="motor")
    s.set_defaults(f=cmd_studio_install)

    s = sub.add_parser("studio-style", help="Flow A: Claude proposes the style identity from the references")
    s.add_argument("target", help="style id")
    s.add_argument("--niche")
    s.add_argument("--engine", choices=["claude"], default="claude")
    s.set_defaults(f=cmd_studio_style)

    s = sub.add_parser("studio-factory", help="piece factory: Claude generates the pieces of the order, the gate checks")
    s.add_argument("target", help="fabrica:<order id>")
    s.add_argument("--no-vision", action="store_true", help="skips the local visual check of the proof frames")
    s.add_argument("--engine", choices=["claude"], default="claude")
    s.set_defaults(f=cmd_studio_factory)

    s = sub.add_parser("studio-piece-preview", help="short MP4 of a library piece in the skin of a style")
    s.add_argument("target", help="peca:<id>")
    s.add_argument("--style", required=True)
    s.add_argument("--format", choices=["16:9", "9:16"])
    s.set_defaults(f=cmd_studio_piece_preview)

    s = sub.add_parser("studio-channel-proof", help="every approved piece in the skin of each style (skin swap)")
    s.add_argument("target", nargs="?", default="acervo")
    s.add_argument("--styles", nargs="+", required=True)
    s.set_defaults(f=cmd_studio_channel_proof)

    s = sub.add_parser("studio-block", help="renders only the changed block: segment → splice into the raw → loudness and preview")
    s.add_argument("ep")
    s.add_argument("--block", type=int, required=True)
    s.add_argument("--formats", nargs="*", choices=["16:9", "9:16"])
    s.set_defaults(f=cmd_studio_block)

    s = sub.add_parser("training", help="approval base → training conversations; trains the LoRA of the local model (GPU)")
    s.add_argument("target", help="queue label (e.g. treino:lora); ignored")
    s.add_argument("action", choices=["export", "train"])
    s.add_argument("--base", default="unsloth/gemma-4-12b-it")
    s.add_argument("--epochs", type=float, default=2.0)
    s.set_defaults(f=cmd_training)

    s = sub.add_parser("dataset", help="Craft Apps dataset: status, reindex, export, translate, edits")
    s.add_argument("action", nargs="?", default="status",
                   choices=["status", "reindex", "export", "translate", "edits", "train", "promote"])
    s.add_argument("--tasks", help="comma-separated tasks (export)")
    s.add_argument("--app", choices=["effectcraft", "filmcraft", "photocraft"])
    s.add_argument("--base", default="unsloth/gemma-4-12b-it")
    s.add_argument("--epochs", type=float, default=2.0)
    s.add_argument("--force", action="store_true", help="trains below the minimum (smoke test)")
    s.add_argument("--name", help="adapter to promote (e.g. fc-v1)")
    s.add_argument("--n", type=int, help="gold cases in the promotion bench")
    s.set_defaults(f=cmd_dataset)

    s = sub.add_parser("studio-sample", help="30 s example of the template in its formats (vertical and horizontal)")
    s.add_argument("target", help="style id or id@version")
    s.set_defaults(f=cmd_studio_sample)

    s = sub.add_parser("bench", help="measures the local models on the Studio tasks (answer key in bancada/)")
    s.add_argument("action", nargs="?", default="show", choices=["show", "generate", "run"])
    s.add_argument("--models", help="comma-separated router ids (default: all)")
    s.add_argument("--tasks", help="intencao,cena,legenda,corte,visao (default: all)")
    s.add_argument("--n", type=int, help="only the first N cases of each task")
    s.set_defaults(f=cmd_bench)

    s = sub.add_parser("import", help="creates the project from a vault script")
    s.add_argument("script", help="channel:number (e.g. finlumia:3) or path of the .md")
    s.add_argument("--audio", help="narration WAV (default: the most likely one in ~/Music/Youtube)")
    s.add_argument("--name", help="project folder name (default: canal-NNN)")
    s.add_argument("--camera", help="camera video (presenter mode; default: the most likely one next to the WAV)")
    s.add_argument("--mode", choices=["dark", "apresentador"], help="default: `modo:` of the script or of the profile")
    s.set_defaults(f=cmd_import)

    s = sub.add_parser("status", help="state of each stage (every project if omitted)")
    s.add_argument("project", nargs="?")
    s.set_defaults(f=cmd_status)

    s = sub.add_parser("log", help="latest events of a project")
    s.add_argument("project")
    s.add_argument("--stage")
    s.add_argument("--n", type=int, default=20)
    s.add_argument("--errors", action="store_true", help="only errors and warnings")
    s.add_argument("--debug", action="store_true", help="includes FilmCraft calls and progress")
    s.set_defaults(f=cmd_log)

    s = sub.add_parser("panel", help="web panel: library, live production, cuts, scenes, costs")
    s.add_argument("--port", type=int, default=8765)
    s.add_argument("--host", default="127.0.0.1")
    s.set_defaults(f=cmd_panel)

    s = sub.add_parser("all")
    s.add_argument("project")
    s.add_argument("--redo", action="store_true",
                   help="from scratch: retranscribes and decides the cuts again, redoes the curation and every stage")
    s.set_defaults(f=cmd_all)

    a = ap.parse_args()
    if a.cmd in LIGHT or (a.cmd == "library" and a.action in ("stats", "search")) or (a.cmd == "bench" and a.action != "run"):
        return a.f(a)
    # heavy process: registers (Monitor → Processes) and waits for the machine slot (or the Claude one)
    import os
    import signal

    from esteira.core import locks, options, processes
    engine = getattr(a, "engine", None) or options.read()["engine"]
    os.environ["ESTEIRA_ENGINE"] = engine
    if getattr(a, "engine", None):
        os.environ["ESTEIRA_ENGINE_FIXED"] = "1"  # explicit --engine applies to every operation
    if getattr(a, "project", None) and pasta_ep(a.project).is_dir():
        os.environ["ESTEIRA_EP"] = a.project
    target = getattr(a, "project", None) or getattr(a, "target", None) or ""
    slot = locks.slot(a.cmd, engine)
    os.environ["ESTEIRA_SLOT"] = slot
    process_id = processes.register(a.cmd, target, sys.argv[2:], slot, engine)
    signal.signal(signal.SIGTERM, _on_cancel)
    locks.acquire(slot, " ".join(sys.argv[1:])[:120], process=process_id)
    try:
        a.f(a)
    except BaseException as e:
        if not (isinstance(e, SystemExit) and e.code in (0, None)):
            processes.failed(e)
        raise


if __name__ == "__main__":
    sys.exit(main())
