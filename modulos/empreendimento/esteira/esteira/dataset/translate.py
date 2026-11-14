"""Tradução do material existente para o dataset (`docs/PLANO-DATASET.md` F4): montagens dos episódios já
produzidos (N1 do FilmCraft, sem abrir a app), candidatas de thumb com a escolha das vagas A/B, peças do acervo
(EffectCraft em N1 e HTML) com o estado da revisão. Idempotente: o que já está no registro não se repete.
"""
import json

from esteira.dataset import registry as R
from esteira.project import Project, episodes


def _tem(grupo, tarefa, **extra):
    return R.last(grupo, tarefa, **extra) is not None


def assembly(projeto: Project) -> str | None:
    """N1 da montagem do episódio pelo plano atual (`origem: traducao`). → id do registro."""
    from esteira import assemble, production
    if not projeto.caminho("plano.json").exists():
        return None
    plano = projeto.carregar_json("plano.json")
    cam = production.camera(projeto) if production.mode(projeto) == "apresentador" else None
    cenas = ([c for c in plano["cenas"] if c.get("midia") and not c.get("camera")] if cam
             else assemble._scenes_with_media(plano))
    if not cenas:
        return None
    doc, midias = assemble.assembly(projeto, plano, cenas, cam)
    assemble._dataset(projeto, plano, doc, None, cam, midias)
    r = R.last(f"ep:{projeto.ep}", "montar")
    return r and r["id"]


def thumbs(projeto: Project) -> int:
    """Candidatas de `thumbs/ranking.json` → `thumb_compor` em N1; as que estão nas vagas A/B ficam `escolhida`."""
    from esteira import thumbs as T
    from esteira.n1 import photocraft as N1
    rk = projeto.caminho("thumbs/ranking.json")
    if not rk.exists():
        return 0
    cfg = projeto.cfg.get("thumb", {})
    w, h = cfg.get("largura", 1280), cfg.get("altura", 720)
    vagas = {projeto.caminho(f"thumb_{k}.png").read_bytes() for k in (1, 2, 3) if projeto.caminho(f"thumb_{k}.png").exists()}
    ctx = T._context(projeto)
    n = 0
    for x in json.loads(rk.read_text()):
        if _tem(f"thumb:{projeto.ep}", "thumb_compor", arquivo=x["arquivo"]):
            continue
        dados = T.data_thumb(x["conceito"], projeto.caminho(f"thumbs/{x['fundo']}").as_uri(), projeto.cfg)
        doc = N1.of_data_thumb(dados, w, h)
        png = projeto.caminho(f"thumbs/{x['arquivo']}")
        escolhida = png.exists() and png.read_bytes() in vagas
        R.write("thumb_compor", grupo=f"thumb:{projeto.ep}", origem="traducao",
                 contexto={**ctx, "canal": getattr(projeto, "canal", "") or "", "fundo": x["fundo"],
                           "cena_en": x["conceito"].get("cena_en")},
                 saida=doc.model_dump(mode="json"), versoes={"n1": N1.VERSION, "app": "photocraft"},
                 humano={"veredito": "escolhida", "nota": None, "motivo": None, "comentario": "vaga A/B",
                         "em": R._now()} if escolhida else None,
                 metricas={"nota_visao": x.get("nota"), "problema": x.get("problema")},
                 extra={"episodio": projeto.ep, "arquivo": x["arquivo"]})
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
        ficha = json.loads((d / "ficha.json").read_text())
        if (d / "peca.n1.json").exists():
            tarefa, saida = "peca_animar", {"peca_n1": json.loads((d / "peca.n1.json").read_text()), "ficha": ficha}
        elif (d / "peca.js").exists():
            tarefa = "peca_html"
            saida = {"peca_js": (d / "peca.js").read_text(),
                     "peca_css": (d / "peca.css").read_text() if (d / "peca.css").exists() else "", "ficha": ficha}
        else:
            continue
        if _tem(f"peca:{d.name}", tarefa, peca=d.name, versao=ficha.get("versao")):
            continue
        v = vered.get(ficha.get("estado"))
        R.write(tarefa, grupo=f"peca:{d.name}", origem="traducao",
                 contexto={"pedido": {"tipo": "acervo", "texto": ficha.get("comunica", "")}, "modo": "nova",
                           "motor": ficha.get("motor"), "intencoes": ficha.get("intencoes")},
                 saida=saida, portao={"ok": True, "erros": [], "render_s": None},
                 humano={"veredito": v, "nota": None, "motivo": None, "comentario": None, "em": R._now()} if v else None,
                 extra={"peca": d.name, "versao": ficha.get("versao"), "origem_peca": ficha.get("origem")})
        n += 1
    return n


def translate_all() -> list[str]:
    linhas = []
    for pasta in episodes():
        try:
            p = Project(pasta)
        except SystemExit:
            continue
        partes = []
        if not _tem(f"ep:{p.ep}", "montar"):
            try:
                if assembly(p):
                    partes.append("montagem")
            except (KeyError, ValueError, FileNotFoundError) as e:
                partes.append(f"montagem falhou ({e})")
        try:
            if k := thumbs(p):
                partes.append(f"{k} thumbs")
        except (KeyError, ValueError, FileNotFoundError) as e:
            partes.append(f"thumbs falharam ({e})")
        if partes:
            linhas.append(f"{p.ep}: " + ", ".join(partes))
    linhas.append(f"peças do acervo: {pieces()} novas")
    from esteira.dataset import index
    index.reindex()
    return linhas
