"""Estúdio: produção de vídeo por estilo (vídeo + estilo → corte aprovado → diretor → render → portão final).

Plano e decisões: `docs/PLANO-ESTUDIO.md`. Fluxo de uma produção (`./dark studio <ep>`, ou o botão Produzir da aba
Estúdio): `corte.analisar` (corte pelo som da narração editada) → portão 1 (emendas revisadas e corte aprovado) →
apontamento no roteiro (`apontamento.py`: cena por trecho, confirmado pela pessoa) → `diretor.dirigir` (mapa.json, IA local) → por formato: `compilar` →
`render` (HyperFrames, GPU) → `audio` (−14 LUFS) → `verificar` (relatório; portão final).
Aprovações ficam em `<ep>/estudio/aprovacoes.json` e cada uma vira dado em `bancada/aprovacoes.jsonl`.
"""
import json
from datetime import datetime

from esteira.project import Project, folder_ep

STAGES = ("dirigir", "compilar", "render", "audio", "verificar")
GATES = ("corte", "mapa", "final_16x9", "final_9x16")


def _aprov_file(project):
    return project.folder_path / "estudio" / "aprovacoes.json"


def approvals(project):
    file = _aprov_file(project)
    return json.loads(file.read_text()) if file.exists() else {}


def approve(ep, gate, aprovado=True, note=""):
    """Grava a decisão do portão e a guarda na base de aprovações (gabarito futuro / fine-tune)."""
    from esteira.bench import FOLDER
    if gate not in GATES:
        raise ValueError(f"portão inválido: {gate}")
    project = Project(folder_ep(ep))
    if gate == "corte" and aprovado:
        from esteira.studio import cut
        e = cut.state(project)
        if not e["feito"] or not e["atualizado"]:
            raise ValueError("faça (ou refaça) o corte pelo som antes de aprovar: aba Estúdio → Corte → Cortar pelo som")
        if e.get("cortadas"):
            raise ValueError(f"{e['cortadas']} palavra(s) cortada(s) no corte pelo som: reverta as emendas em volta "
                             "delas (aba Estúdio → Corte) antes de aprovar")
    if gate == "mapa" and aprovado:  # direção por bloco: as escolhas aprovadas ensinam a bancada
        file = project.folder_path / "estudio" / "mapa.json"
        if file.exists() and (m := json.loads(file.read_text())).get("direcao") == "blocos":
            from esteira.studio import direction
            direction.approve_map(ep, m)
    d = approvals(project)
    reg = {"aprovado": aprovado, "nota": note, "em": datetime.now().isoformat(timespec="seconds")}
    d[gate] = reg
    _aprov_file(project).parent.mkdir(exist_ok=True)
    _aprov_file(project).write_text(json.dumps(d, ensure_ascii=False, indent=1))
    FOLDER.mkdir(parents=True, exist_ok=True)
    with open(FOLDER / "aprovacoes.jsonl", "a") as f:
        f.write(json.dumps({"ep": ep, "portao": gate, **reg}, ensure_ascii=False) + "\n")
    return d


def template(project):
    """Template (`id@N`) escolhido para o episódio na aba Roteiros, ou None."""
    file = project.folder_path / "estudio" / "template.json"
    return json.loads(file.read_text()).get("estilo") if file.exists() else None


def choose_template(project, ref):
    file = project.folder_path / "estudio" / "template.json"
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(json.dumps({"estilo": ref}))


def style_default(project):
    from esteira.studio import style
    if ref := template(project):
        try:
            return style.load(ref)
        except KeyError:
            pass
    mode = project.cfg.get("producao", {}).get("modo", "dark")
    candidates = style.list_all(project.canal)
    return next((e for e in candidates if e.modo == mode), candidates[0] if candidates else None)


def status(ep):
    """O que já existe da produção (para o app): mapa, e por formato compilado/render/final/relatório."""
    project = Project(folder_ep(ep))
    base = project.folder_path / "estudio"
    mapping = base / "mapa.json"
    from esteira.studio import marking, cut
    ap = marking.load(project)
    from esteira.studio import rhythm
    r = {"ep": ep, "canal": project.canal, "aprovacoes": approvals(project), "mapa": None, "formatos": {},
         "ritmo": rhythm.id_of(project), "modo": project.cfg.get("producao", {}).get("modo", "dark"),
         "corte": cut.state(project), "camera": None, "template": template(project),
         "apontamento": {"confirmado": ap.get("confirmado", False), "marcas": len(ap.get("marcas", {}))}}
    from esteira import production
    if production.camera(project):
        r["camera"] = production.info_camera(project)
    if mapping.exists():
        m = json.loads(mapping.read_text())
        r["mapa"] = {"cenas": len(m["cenas"]), "estilo": m["estilo"], "versao": m["versao"], "decisoes": m.get("decisoes"),
                     "ritmo": m.get("ritmo")}
    for fmt in ("16x9", "9x16"):
        p = base / fmt
        if not p.exists():
            continue
        rel = p / "relatorio.json"
        r["formatos"][fmt] = {"compilado": (p / "index.html").exists(), "render": (p / "render" / "bruto.mp4").exists(),
                              "final": (p / "final.mp4").exists(), "previa": (p / "previa.mp4").exists(), "folha": (p / "folha.jpg").exists(),
                              "relatorio": json.loads(rel.read_text()) if rel.exists() else None}
    return r


def style_of_map(project, mapping):
    """O estilo com que o mapa foi dirigido (versão guardada), no modo e no ritmo do vídeo."""
    from esteira import production
    from esteira.studio import style, rhythm
    try:
        base = style.load(f"{mapping['estilo']}@{mapping['versao']}")
    except KeyError:  # versão antiga não guardada: a atual, avisando
        from esteira.core import events
        events.warning(f"estilo {mapping['estilo']} v{mapping['versao']} não está guardado; usando a versão atual")
        base = style.load(mapping["estilo"])
    est = style.with_mode(base, production.mode(project))
    return rhythm.apply(est, rhythm.profile_of(project))


def window_of_block(mapping, block):
    """[de, ate] do bloco no vídeo (direção por bloco), com uma folga que cai na pausa entre blocos."""
    bls = mapping.get("blocos") or []
    b = next((x for x in bls if x["i"] == block), None)
    if b is None:
        raise ValueError(f"bloco inexistente: {block}")
    following = next((x for x in bls if x["i"] == block + 1), None)
    previous = next((x for x in bls if x["i"] == block - 1), None)
    de = max(0.0, (previous["fim"] + b["ini"]) / 2 if previous else 0.0)
    until = min(mapping["duracao"], (b["fim"] + following["ini"]) / 2 if following else mapping["duracao"])
    return round(de, 3), round(until, 3)


def render_block(ep, block, formats=None):
    """Render só do bloco alterado: trecho [de, ate] → emenda no bruto → loudness e prévia de novo."""
    from esteira.studio import compiler
    from esteira.ai import local
    project = Project(folder_ep(ep))
    mapping = json.loads((project.folder_path / "estudio" / "mapa.json").read_text())
    est = style_of_map(project, mapping)
    de, until = window_of_block(mapping, block)
    done = []
    for fmt in formats or [f.replace("x", ":") for f in ("16x9", "9x16") if (compiler.folder(project, f.replace("x", ":")) / "render" / "bruto.mp4").exists()]:
        local.free_gpu()
        span = compiler.render_span(project, est, fmt, de, until, f"bloco{block:03d}")
        compiler.splice(project, fmt, de, until, span)
        compiler.audio(project, est, fmt)
        done.append(fmt)
        print(f"  bloco {block} ({de:.1f}–{until:.1f} s) refeito em {fmt}")
    if not done:
        raise SystemExit("nenhum formato com render completo para emendar")
    return done


def produce(ep, style_id=None, formats=None, stages=STAGES, without_gate=False, intensidade=None):
    """`intensidade` ({"sfx"|"motion"|"efeitos": "baixa"|"media"|"alta"}) vale só para esta produção."""
    from esteira.core import events
    from esteira.studio import compiler, director, style, engine
    from esteira.ai import local
    project = Project(folder_ep(ep))
    est = style.load(style_id) if style_id else style_default(project)
    if not est:
        raise SystemExit(f"nenhum estilo para o canal {project.canal}: crie um na aba Estúdio")
    est = style.with_levels(est, intensidade)
    from esteira import production
    est = style.with_mode(est, production.mode(project))  # o modo é do vídeo (roteiro), não da configuração do canal
    from esteira.studio import rhythm
    profile = rhythm.profile_of(project)  # longo ou curto: o ritmo também é do vídeo
    est = rhythm.apply(est, profile)
    formats = formats or est.formatos
    if not without_gate and not approvals(project).get("corte", {}).get("aprovado"):
        raise SystemExit("portão 1: aprove o corte do áudio antes (aba Estúdio → Corte)")
    from esteira.studio import marking
    if not without_gate and "dirigir" in stages and not marking.confirmed(project):
        raise SystemExit("apontamento: marque as cenas no roteiro e confirme (aba Estúdio → Apontamento)")
    if any(e in stages for e in ("render", "audio")) and not engine.ready():
        raise SystemExit("motor de render incompleto: instale as dependências (aba Estúdio → Dependências)")
    print(f"  estúdio: {ep} · estilo {est.id} v{est.versao} · {', '.join(formats)} · níveis {est.regras.niveis} · "
          f"ritmo {profile.id} · modo {est.modo}")
    if "dirigir" in stages:
        from esteira.core import options
        with events.stage(project, "estudio-dirigir"):
            if options.read().get("direction", "blocks") == "blocks":  # direção por bloco com o acervo de peças
                from esteira.studio import direction
                direction.direct(project, est, profile, formats)
            else:
                director.direct(project, est, profile)
    for fmt in formats:
        if "compilar" in stages:
            with events.stage(project, f"estudio-compilar-{fmt}"):
                compiler.build(project, est, fmt)
        if "render" in stages:
            local.free_gpu()
            with events.stage(project, f"estudio-render-{fmt}"):
                compiler.render(project, fmt)
        if "audio" in stages:
            with events.stage(project, f"estudio-audio-{fmt}"):
                compiler.audio(project, est, fmt)
        if "verificar" in stages:
            with events.stage(project, f"estudio-verificar-{fmt}"):
                compiler.verify(project, est, fmt)
    return status(ep)
