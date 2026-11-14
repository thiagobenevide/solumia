"""Perfis de ritmo do Estúdio (`docs/PLANO-ACERVO.md`, decisão 7): longo (15–45 min) e curto (30–60 s; Shorts,
Reels, TikTok). São dado, não código separado: `estudio/ritmos/<id>.json` (semente; a cópia editável fica em
`$AGENT_DATA/.../estudio/ritmos/`).

- Perfil do vídeo: `ritmo:` no frontmatter do roteiro, senão curto para o Short (roteiro em `Shorts/`, 9:16) e longo
  para o resto. Os curtos têm roteiro próprio (regra); corte de vídeo longo é exceção e manual.
- Na produção o perfil ajusta o estilo (como `com_niveis` e `com_modo`): números de ritmo das regras (`regras`, por
  cima), tetos de motion (`tetos`: o perfil só reduz), presença e legenda. O estilo salvo não muda.
- O diretor usa o perfil para o gancho (curto: peça nos primeiros `gancho_s`), a anti-repetição (a mesma peça não
  volta dentro de `anti_repeticao_s`) e a conferência de ritmo (trecho sem virada visual maior que `virada_s`).
"""
import json
import re
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field

from esteira.project import DADOS

SEMENTES = Path(__file__).parent / "ritmos"
PASTA = DADOS / "estudio" / "ritmos"


class Perfil(BaseModel):
    id: Literal["longo", "curto"]
    nome: str
    descricao: str = ""
    duracao_s: list[float] = Field(min_length=2, max_length=2)
    bloco_s: list[float] = Field(min_length=2, max_length=2)       # bloco (parágrafo) = unidade de decisão
    virada_s: list[float] = Field(min_length=2, max_length=2)      # algo muda na tela a cada X–Y s
    gancho_s: float | None = None                                  # peça antes disso (curto)
    anti_repeticao_s: float = 120                                  # a mesma peça não volta dentro dessa janela
    cota_3d_s: float = 300                                         # no máximo uma peça 3D (render pesado) por janela
    capitulos: bool = True
    peca_s: list[float] = Field(min_length=2, max_length=2)        # duração das peças
    regras: dict[str, float] = Field(default_factory=dict)         # por cima das regras do estilo
    tetos: dict[str, float] = Field(default_factory=dict)          # o perfil só reduz (ex.: takeover_max)
    presenca: dict[str, float | list[float]] = Field(default_factory=dict)
    legenda: dict[str, float | int | str] = Field(default_factory=dict)


def carregar(id_):
    arq = PASTA / f"{id_}.json"
    if not arq.exists():
        arq = SEMENTES / f"{id_}.json"
    if not arq.exists():
        raise KeyError(f"perfil de ritmo inexistente: {id_}")
    return Perfil.model_validate_json(arq.read_text())


def listar():
    return [carregar(a.stem) for a in sorted(SEMENTES.glob("*.json"))]


def salvar(perfil: Perfil):
    PASTA.mkdir(parents=True, exist_ok=True)
    (PASTA / f"{perfil.id}.json").write_text(perfil.model_dump_json(indent=1))
    return perfil


def do_roteiro(projeto):
    """`ritmo:` do frontmatter do roteiro (longo | curto) ou None."""
    arq = projeto.pasta / "roteiro_original.md"
    if not arq.exists():
        return None
    m = re.match(r"^---\n(.*?)\n---", arq.read_text(), re.S)
    r = re.search(r"(?m)^ritmo:\s*['\"]?(longo|curto)\b", m.group(1)) if m else None
    return r.group(1) if r else None


def id_do(projeto):
    """Perfil do vídeo: o do roteiro, senão curto para o Short e longo para o resto."""
    if r := do_roteiro(projeto):
        return r
    arq = projeto.pasta / "roteiro.json"
    short = bool(json.loads(arq.read_text()).get("short")) if arq.exists() else False
    return "curto" if short or projeto.vertical else "longo"


def perfil_do(projeto):
    return carregar(id_do(projeto))


def aplicar(estilo, perfil: Perfil):
    """Cópia do estilo para a produção com o ritmo do perfil (o estilo salvo não muda)."""
    rg = estilo.regras.model_dump()
    rg.update(perfil.regras)
    for k, teto in perfil.tetos.items():
        if k in rg:
            rg[k] = min(rg[k], teto)
    rg["legenda_visual"] = {**rg["legenda_visual"], **perfil.legenda}
    pres = {**estilo.presenca.model_dump(), **perfil.presenca}
    return estilo.model_copy(update={"regras": type(estilo.regras).model_validate(rg),
                                     "presenca": type(estilo.presenca).model_validate(pres)})


# ---------------------------------------------------------------- direção e conferência

def gancho(cenas, perfil: Perfil, frases):
    """Curto: se nenhuma peça começa nos primeiros `gancho_s`, a primeira frase ganha uma frase de impacto (o
    espectador decide nos 2 primeiros segundos). Devolve as cenas (a nova marcada `por: "ritmo"`)."""
    if not perfil.gancho_s or not frases:
        return cenas
    if any(c["t"] <= perfil.gancho_s and c["cena"] != "midia" for c in cenas):
        return cenas
    f = frases[0]
    fim = min(f["fim"] + 0.3, perfil.gancho_s + perfil.peca_s[1])
    if cenas:
        fim = min(fim, cenas[0]["t"] - 0.05)
    if fim - 0.0 < perfil.peca_s[0]:
        return cenas
    nova = {"frase_i": 0, "frase": f["texto"], "cena": "frase_destaque", "t": 0.0, "ate": round(fim, 3),
            "titulo": _curta(f["texto"]), "ancora": "", "valores": [], "por": "ritmo", "takeover": False}
    return [nova] + cenas


def _curta(texto, n=6):
    """As primeiras palavras da frase (frase de impacto do gancho), com a última em destaque."""
    ws = re.sub(r"[.!?…]+$", "", texto.strip()).split()[:n]
    if len(ws) > 1:
        ws[-1] = f"*{ws[-1]}*"
    return " ".join(ws)


# peça parecida para trocar na repetição (a alternativa precisa estar no cardápio do canal)
TROCAS = {"frase_destaque": "lettering", "lettering": "frase_destaque", "contador": "anel_percentual",
          "anel_percentual": "contador", "barras_comparacao": "ranking", "ranking": "barras_comparacao",
          "conceito_icone": "termo_tecnico", "termo_tecnico": "conceito_icone", "pergunta_destaque": "frase_destaque",
          "alerta": "carimbo", "carimbo": "alerta", "passo_a_passo": "lista_itens"}


def sem_capitulos(cenas, perfil: Perfil):
    """Perfil sem capítulos (curto): cartela de capítulo vira frase de impacto sobre a mídia."""
    if not perfil.capitulos:
        for c in cenas:
            if c["cena"] == "titulo_capitulo" and c.get("por") != "voce":
                c["cena"] = "frase_destaque"
    return cenas


def anti_repeticao(cenas, perfil: Perfil, trocas=None):
    """A mesma peça dentro de `anti_repeticao_s` troca pela parecida (`trocas[peça]`, se o canal tiver); sem
    alternativa, só vira mídia quando repete colada na anterior e não leva dado (número, itens); senão fica e a
    conferência avisa. Cenas da pessoa (`por: "voce"`) e de gatilho ficam. A IA tende a repetir o que funcionou: a
    anti-repetição é sempre código."""
    trocas = trocas or {}
    ultima, anterior = {}, None
    for c in cenas:
        if c["cena"] == "midia":
            continue
        t0 = ultima.get(c["cena"])
        if t0 is not None and c["t"] - t0 < perfil.anti_repeticao_s and c.get("por") not in ("voce", "gatilho"):
            alt = trocas.get(c["cena"])
            if alt and (ultima.get(alt) is None or c["t"] - ultima[alt] >= perfil.anti_repeticao_s):
                c["cena"], c["repeticao"] = alt, "trocada"
            elif anterior == c["cena"] and not c.get("valores"):
                c["cena"], c["repeticao"] = "midia", "virou_midia"
        if c["cena"] != "midia":
            ultima[c["cena"]] = c["t"]
            anterior = c["cena"]
    return cenas


def conferir(cenas, midia, duracao, perfil: Perfil):
    """Conferência de ritmo do mapa: trechos sem virada visual (nenhuma peça entrando nem mídia trocando) maiores
    que `virada_s[1]`, gancho do curto, peças fora de `peca_s` e duração do vídeo fora do perfil → avisos."""
    avisos = []
    trocas = sorted({0.0, duracao, *(c["t"] for c in cenas), *(c["ate"] for c in cenas),
                     *(m["ini"] for m in midia)})
    for a, b in zip(trocas, trocas[1:], strict=False):
        if b - a > perfil.virada_s[1] + 0.5:
            avisos.append({"tipo": "sem_virada", "t": round(a, 2), "texto": f"{b - a:.0f} s sem virada visual "
                           f"(o perfil {perfil.id} pede algo novo a cada {perfil.virada_s[0]:.0f}–{perfil.virada_s[1]:.0f} s)"})
    if perfil.gancho_s and not any(c["t"] <= perfil.gancho_s and c["cena"] != "midia" for c in cenas):
        avisos.append({"tipo": "gancho", "t": 0.0, "texto": f"nenhuma peça nos primeiros {perfil.gancho_s:.0f} s"})
    for c in cenas:
        d = c["ate"] - c["t"]
        if c["cena"] != "midia" and d > perfil.peca_s[1] + 0.5:
            avisos.append({"tipo": "peca_longa", "t": c["t"], "texto": f"{c['cena']} fica {d:.1f} s (máx. "
                           f"{perfil.peca_s[1]:.0f} s no perfil {perfil.id})"})
    usos = {}
    for c in cenas:
        if c["cena"] != "midia":
            usos.setdefault(c["cena"], []).append(c["t"])
    for peca_, ts in usos.items():
        for i, t in enumerate(ts):
            n = sum(1 for x in ts[i:] if x - t < perfil.anti_repeticao_s)
            if n >= 3:
                avisos.append({"tipo": "repeticao", "t": round(t, 2), "texto": f"{peca_} {n}× em "
                               f"{perfil.anti_repeticao_s:.0f} s (o acervo maior e a direção nova trazem alternativas)"})
                break
    if not perfil.duracao_s[0] <= duracao <= perfil.duracao_s[1]:
        avisos.append({"tipo": "duracao", "t": 0.0, "texto": f"vídeo de {duracao:.0f} s fora do perfil {perfil.id} "
                       f"({perfil.duracao_s[0]:.0f}–{perfil.duracao_s[1]:.0f} s)"})
    return avisos
