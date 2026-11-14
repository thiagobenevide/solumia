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
    destino = REFS / f"{id_}-folha.jpg"
    entradas = sum((["-i", str(i)] for i in imgs), [])
    quadro = "scale=480:270:force_original_aspect_ratio=decrease,pad=480:270:(ow-iw)/2:(oh-ih)/2"
    filtros = ";".join(f"[{n}]{quadro}[v{n}]" for n in range(len(imgs)))
    if len(imgs) == 1:
        grade = f"{filtros};[v0]null[out]"
    else:
        layout = "|".join(f"{(n % 4) * 480}_{(n // 4) * 270}" for n in range(len(imgs)))
        grade = f"{filtros};{''.join(f'[v{n}]' for n in range(len(imgs)))}xstack=inputs={len(imgs)}:layout={layout}:fill=black[out]"
    subprocess.run(["ffmpeg", "-v", "error", "-y", *entradas, "-filter_complex", grade, "-map", "[out]", "-frames:v", "1",
                    str(destino)], check=True)
    return destino


def propose(id_, nicho=""):
    """Pede ao Claude a identidade do estilo a partir das referências; grava a versão nova e devolve o estilo."""
    from esteira.studio import fonts
    from esteira.ai import claude
    atual = E.load(id_)
    folha = _sheet(id_)
    dossie = (
        "Você é diretor de arte de um canal do YouTube. Proponha a IDENTIDADE VISUAL e o GUIA de edição deste estilo, "
        "para uma IA local menor seguir depois em cada vídeo (ela só escolhe cenas de um cardápio, então o guia tem "
        "que ser concreto: quando usar cada cena, tom, o que destacar).\n"
        f"Canal: {atual.canal} · modo {atual.modo} · nicho: {nicho or atual.guia}\n"
        f"Estilo atual (JSON): {atual.model_dump_json()}\n"
        f"Cenas possíveis: {', '.join(E.SCENES)}. Sons possíveis: {', '.join(E.SOUNDS)}.\n"
        f"Fontes (use só estas): {', '.join(fonts.CATALOG)}; fonte_editorial é a serifa dos capítulos e citações.\n"
        "Variações do kit ('visual'): entradas (desfoque, deslizar, revelar, escala; o código alterna), fundo das "
        "cenas de motion (veu, solido, gradiente), alinhamento (centro, esquerda), cartao (vidro, contorno, solido), "
        "cantos 0–3. Responda só com dados; não escreva código.\n"
        + ("A imagem anexada é uma folha com as referências visuais enviadas: extraia paleta (hex), clima e tipografia.\n"
           if folha else "Sem referências visuais: proponha a partir do nicho.\n")
        + "Regras: cores em #rrggbb com contraste alto entre texto e fundo; 'destaque' é a cor de ênfase; 5 a 8 "
        "exemplos frase→cena típicos do nicho; takeover_max entre 0,35 e 0,65 (muito motion graphics, mas com respiro).")
    r = claude.query(dossie, Proposal, {"claude": {}}, f"estilo:{id_}", "estudio_identidade",
                         image=str(folha) if folha else None)
    if not r:
        raise RuntimeError("o Claude não respondeu (teto de custo ou erro); tente de novo")
    novo = atual.model_copy(update={
        "pele": r.pele.model_copy(update={k: fonts.resolve(v) for k, v in r.pele if k.startswith("fonte_")}),
        "guia": r.guia, "exemplos": r.exemplos, "travado": False,
        "regras": atual.regras.model_copy(update={"visual": r.visual,
            "filtro": [c for c in E.SCENES if c not in r.cenas] if any(c in E.SCENES for c in r.cenas)
            else atual.regras.filtro, "takeover_max": r.takeover_max,
            "sfx": {k: v for k, v in r.sfx.items() if k in E.SCENES and v in E.SOUNDS} or atual.regras.sfx})})
    return E.save(novo, forcar=True)
