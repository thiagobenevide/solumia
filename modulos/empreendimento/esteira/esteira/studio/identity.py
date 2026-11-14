"""Fluxo A · identidade e estilo: o Claude analisa as referências do canal e propõe o guia (uma vez por estilo).

O Claude só entrega a REFERÊNCIA como dado (pele, fontes do catálogo, variações visuais do kit, guia e exemplos):
não escreve código nem entra na produção de cada vídeo, que fica com a IA local e o kit (custo por vídeo zero).

Referências (imagens enviadas pela aba Estúdio) ficam em `estudio/referencias/<estilo>/`; viram UMA folha
(o Claude lê com Read) + o estilo atual e o nicho no dossiê. A proposta grava uma versão nova do estilo
(destravado); a pessoa aprova o piloto e trava. É a parte de alto consumo de tokens, feita uma vez — a produção
de cada vídeo depois roda na IA local seguindo este guia.
"""
import subprocess

from pydantic import BaseModel, Field

from esteira.studio import style as E
from esteira.project import DATA

REFS = DATA / "estudio" / "referencias"


class Proposal(BaseModel):
    pele: E.Skin
    guia: str = Field(max_length=1200)
    exemplos: list[E.Example] = Field(max_length=10)
    cenas: list[str]
    takeover_max: float = Field(ge=0.2, le=0.8)
    sfx: dict[str, str]
    visual: E.Visual


def folder_refs(id_):
    p = REFS / id_
    p.mkdir(parents=True, exist_ok=True)
    return p


def _sheet(id_):
    """Até 12 referências numa grade 4×N de quadros 480×270 (uma imagem só para o Claude ler)."""
    imgs = sorted(f for f in folder_refs(id_).iterdir() if f.suffix.lower() in (".jpg", ".jpeg", ".png", ".webp"))[:12]
    if not imgs:
        return None
    destination = REFS / f"{id_}-folha.jpg"
    inputs = sum((["-i", str(i)] for i in imgs), [])
    frame = "scale=480:270:force_original_aspect_ratio=decrease,pad=480:270:(ow-iw)/2:(oh-ih)/2"
    filters = ";".join(f"[{n}]{frame}[v{n}]" for n in range(len(imgs)))
    if len(imgs) == 1:
        grade = f"{filters};[v0]null[out]"
    else:
        layout = "|".join(f"{(n % 4) * 480}_{(n // 4) * 270}" for n in range(len(imgs)))
        grade = f"{filters};{''.join(f'[v{n}]' for n in range(len(imgs)))}xstack=inputs={len(imgs)}:layout={layout}:fill=black[out]"
    subprocess.run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", grade, "-map", "[out]", "-frames:v", "1",
                    str(destination)], check=True)
    return destination


def propose(id_, niche=""):
    """Pede ao Claude a identidade do estilo a partir das referências; grava a versão nova e devolve o estilo."""
    from esteira.studio import fonts
    from esteira.ai import claude
    current = E.load(id_)
    sheet = _sheet(id_)
    dossier = (
        "You are the art director of a YouTube channel in Brazilian Portuguese. Propose the VISUAL IDENTITY and the "
        "editing GUIDE of this style, for a smaller local AI to follow later in each video (it only chooses scenes "
        "from a menu, so the guide has to be concrete: when to use each scene, tone, what to highlight).\n"
        f"Channel: {current.canal} · mode {current.modo} · niche: {niche or current.guia}\n"
        f"Current style (JSON): {current.model_dump_json()}\n"
        f"Possible scenes: {', '.join(E.SCENES)}. Possible sounds: {', '.join(E.SOUNDS)}.\n"
        f"Fonts (use only these): {', '.join(fonts.CATALOG)}; fonte_editorial is the serif for chapters and quotes.\n"
        "Kit variations ('visual', use these exact values): entradas (desfoque, deslizar, revelar, escala; the code "
        "alternates them), background of the motion scenes (veu, solido, gradiente), alinhamento (centro, esquerda), "
        "cartao (vidro, contorno, solido), cantos 0–3. Respond with data only; do not write code.\n"
        + ("The attached image is a sheet with the visual references sent: extract the palette (hex), mood and "
           "typography.\n" if sheet else "No visual references: propose from the niche.\n")
        + "Rules: colors as #rrggbb with high contrast between text and background; 'destaque' is the emphasis color; "
        "5 to 8 typical sentence→scene examples for the niche, with the sentences in Brazilian Portuguese; write the "
        "guide in Brazilian Portuguese; takeover_max between 0.35 and 0.65 (lots of motion graphics, but with room "
        "to breathe).")
    r = claude.query(dossier, Proposal, {"claude": {}}, f"estilo:{id_}", "estudio_identidade",
                         image=str(sheet) if sheet else None)
    if not r:
        raise RuntimeError("o Claude não respondeu (teto de custo ou erro); tente de novo")
    new = current.model_copy(update={
        "pele": r.pele.model_copy(update={k: fonts.resolve(v) for k, v in r.pele if k.startswith("fonte_")}),
        "guia": r.guia, "exemplos": r.exemplos, "travado": False,
        "regras": current.regras.model_copy(update={"visual": r.visual,
            "filtro": [c for c in E.SCENES if c not in r.cenas] if any(c in E.SCENES for c in r.cenas)
            else current.regras.filtro, "takeover_max": r.takeover_max,
            "sfx": {k: v for k, v in r.sfx.items() if k in E.SCENES and v in E.SOUNDS} or current.regras.sfx})})
    return E.save(new, forcar=True)
