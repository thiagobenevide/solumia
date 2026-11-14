"""Tradução do material existente para o dataset (`docs/PLANO-DATASET.md` F4): montagens dos episódios já
produzidos (N1 do FilmCraft, sem abrir a app), candidatas de thumb com a escolha das vagas A/B, peças do acervo
(EffectCraft em N1 e HTML) com o estado da revisão. Idempotente: o que já está no registro não se repete.
"""
import json

from esteira.dataset import registry as R
from esteira.project import Project, episodes


def _tem(grupo, tarefa, **extra):
    return R.last(grupo, tarefa, **extra) is not None


def assembly(project: Project) -> str | None:
    """N1 da montagem do episódio pelo plano atual (`origem: traducao`). → id do registro."""
    from esteira import assemble, production
    if not project.caminho("plano.json").exists():
        return None
    plan = project.load_json("plano.json")
    cam = production.camera(project) if production.mode(project) == "apresentador" else None
    scenes = ([c for c in plan["cenas"] if c.get("midia") and not c.get("camera")] if cam
             else assemble._scenes_with_media(plan))
    if not scenes:
        return None
    doc, medias = assemble.assembly(project, plan, scenes, cam)
    assemble._dataset(project, plan, doc, None, cam, medias)
    r = R.last(f"ep:{project.ep}", "montar")
    return r and r["id"]


def thumbs(project: Project) -> int:
    """Candidatas de `thumbs/ranking.json` → `thumb_compor` em N1; as que estão nas vagas A/B ficam `escolhida`."""
    from esteira import thumbs as T
    from esteira.n1 import photocraft as N1
    rk = project.caminho("thumbs/ranking.json")
    if not rk.exists():
        return 0
    cfg = project.cfg.get("thumb", {})
    w, h = cfg.get("largura", 1280), cfg.get("altura", 720)
    slots = {project.caminho(f"thumb_{k}.png").read_bytes() for k in (1, 2, 3) if project.caminho(f"thumb_{k}.png").exists()}
    ctx = T._context(project)
    n = 0
    for x in json.loads(rk.read_text()):
        if _tem(f"thumb:{project.ep}", "thumb_compor", arquivo=x["arquivo"]):
            continue
        data = T.data_thumb(x["conceito"], project.caminho(f"thumbs/{x['fundo']}").as_uri(), project.cfg)
        doc = N1.of_data_thumb(data, w, h)
        png = project.caminho(f"thumbs/{x['arquivo']}")
        chosen = png.exists() and png.read_bytes() in slots
        R.write("thumb_compor", grupo=f"thumb:{project.ep}", origem="traducao",
                 contexto={**ctx, "canal": getattr(project, "canal", "") or "", "fundo": x["fundo"],
                           "cena_en": x["conceito"].get("cena_en")},
                 saida=doc.model_dump(mode="json"), versoes={"n1": N1.VERSION, "app": "photocraft"},
                 humano={"veredito": "escolhida", "nota": None, "motivo": None, "comentario": "vaga A/B",
                         "em": R._now()} if chosen else None,
                 metricas={"nota_visao": x.get("nota"), "problema": x.get("problema")},
                 extra={"episodio": project.ep, "arquivo": x["arquivo"]})
        n += 1
    return n


def pieces() -> int:
    """Peças do acervo: EffectCraft com `peca.n1.json` → `peca_animar`; HTML → `peca_html` (base do porte)."""
    from esteira.studio import piece as P
    vered = {"aprovada": "aprovada", "rascunho": None, "revisao": None}
    n = 0
    for d in sorted(P.FOLDER.iterdir()):
        if not (d / "ficha.json").exists():
            continue
        card = json.loads((d / "ficha.json").read_text())
        if (d / "peca.n1.json").exists():
            task, output = "peca_animar", {"peca_n1": json.loads((d / "peca.n1.json").read_text()), "ficha": card}
        elif (d / "peca.js").exists():
            task = "peca_html"
            output = {"peca_js": (d / "peca.js").read_text(),
                     "peca_css": (d / "peca.css").read_text() if (d / "peca.css").exists() else "", "ficha": card}
        else:
            continue
        if _tem(f"peca:{d.name}", task, peca=d.name, versao=card.get("versao")):
            continue
        v = vered.get(card.get("estado"))
        R.write(task, grupo=f"peca:{d.name}", origem="traducao",
                 contexto={"pedido": {"tipo": "acervo", "texto": card.get("comunica", "")}, "modo": "nova",
                           "motor": card.get("motor"), "intencoes": card.get("intencoes")},
                 saida=output, portao={"ok": True, "erros": [], "render_s": None},
                 humano={"veredito": v, "nota": None, "motivo": None, "comentario": None, "em": R._now()} if v else None,
                 extra={"peca": d.name, "versao": card.get("versao"), "origem_peca": card.get("origem")})
        n += 1
    return n


def translate_all() -> list[str]:
    lines = []
    for folder in episodes():
        try:
            p = Project(folder)
        except SystemExit:
            continue
        parts = []
        if not _tem(f"ep:{p.ep}", "montar"):
            try:
                if assembly(p):
                    parts.append("montagem")
            except (KeyError, ValueError, FileNotFoundError) as e:
                parts.append(f"montagem falhou ({e})")
        try:
            if k := thumbs(p):
                parts.append(f"{k} thumbs")
        except (KeyError, ValueError, FileNotFoundError) as e:
            parts.append(f"thumbs falharam ({e})")
        if parts:
            lines.append(f"{p.ep}: " + ", ".join(parts))
    lines.append(f"peças do acervo: {pieces()} novas")
    from esteira.dataset import index
    index.reindex()
    return lines
