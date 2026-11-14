"""Estilo como dado: identidade visual do canal + regras das 6 etapas + exemplos (o "guia" que a IA local segue).

Estilos ficam em `$AGENT_DATA/empreendimento/estudio/estilos/<id>.json`; as sementes do repositório
(`estudio/estilos/*.json`) são copiadas na primeira leitura. Estilo travado não muda sem destravar (só a
versão nova vale para produções novas; cada produção grava a versão que usou).
Cada versão salva fica também em `estilos/versoes/<id>/v<N>.json`: nada é sobrescrito, e a produção pode usar uma
versão antiga pelo id `<id>@<N>`.
"""
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field, model_validator

from esteira.bench import SCENES
from esteira.studio import triggers
from esteira.studio.triggers import Trigger
from esteira.project import DATA

FOLDER = DATA / "estudio" / "estilos"
SEEDS = Path(__file__).parent / "estilos"
SOUNDS = ("boom", "click", "ding", "glitch", "pop", "riser", "shimmer", "stamp", "swoosh", "tick", "type", "whoosh")
COLOR = r"^#[0-9a-fA-F]{6}$"


class Skin(BaseModel):
    fundo: str = Field("#0b0b0d", pattern=COLOR)
    fundo2: str = Field("#1c1c22", pattern=COLOR)
    texto: str = Field("#ffffff", pattern=COLOR)
    destaque: str = Field("#f5c518", pattern=COLOR)
    apoio: str = Field("#ffe08a", pattern=COLOR)
    acento: str = Field("#b8b2a3", pattern=COLOR)
    fonte_destaque: str = "Plus Jakarta Sans"
    fonte_texto: str = "Plus Jakarta Sans"
    fonte_tecnica: str = "JetBrains Mono"
    fonte_editorial: str = "Playfair Display"  # capítulos, "vs", citações (serifa em itálico)
    fonte_legenda: str = "Plus Jakarta Sans"


class Example(BaseModel):
    frase: str
    cena: str
    titulo: str = ""


class Caption(BaseModel):
    """Aparência da legenda (liga/desliga por formato fica em `Regras.legenda`; a fonte em `Pele.fonte_legenda`)."""
    tamanho: float = Field(1.0, ge=0.6, le=1.8)  # multiplica o tamanho padrão do formato
    posicao: Literal["baixo", "meio", "rosto"] = "baixo"  # rosto: logo abaixo do queixo (modo apresentador, câmera cheia)
    palavras: int = Field(3, ge=1, le=3)  # palavras por vez
    destaque_chave: bool = True  # números e palavras-chave das cenas na cor de destaque
    caixa: Literal["normal", "alta"] = "normal"
    acabamento: Literal["sombra", "contorno", "caixa"] = "sombra"


INPUTS = ("desfoque", "deslizar", "revelar", "escala")


class Visual(BaseModel):
    """Variações das cenas do kit, como dado (nunca código): o compilador passa ao kit e o código alterna as entradas
    ao longo do vídeo. É o que dá cara própria ao estilo sem gerar código por vídeo nem chamar o Claude."""
    entradas: list[Literal[INPUTS]] = Field(default_factory=lambda: ["desfoque", "deslizar"], min_length=1)
    fundo: Literal["veu", "solido", "gradiente"] = "veu"  # fundo das cenas só de motion
    alinhamento: Literal["centro", "esquerda"] = "centro"
    cartao: Literal["vidro", "contorno", "solido"] = "vidro"  # etiquetas e cartões
    cantos: float = Field(1.0, ge=0, le=3)  # arredondamento (0 = reto)


LEVEL = Literal["baixa", "media", "alta", "personalizado"]
# o nível preenche os números das regras; "personalizado" = números ajustados à mão no Avançado
LEVELS = {
    "sfx": {"baixa": {"sfx_volume": 0.32, "sfx_por_s": 0.35},
            "media": {"sfx_volume": 0.45, "sfx_por_s": 0.8},
            "alta": {"sfx_volume": 0.55, "sfx_por_s": 1.2}},
    "motion": {"baixa": {"takeover_max": 0.3, "trecho_max_s": 7.0, "sobreposicao_max_s": 4.0, "dur_min": 1.6},
               "media": {"takeover_max": 0.55, "trecho_max_s": 5.0, "sobreposicao_max_s": 5.0, "dur_min": 1.2},
               "alta": {"takeover_max": 0.7, "trecho_max_s": 3.5, "sobreposicao_max_s": 6.0, "dur_min": 1.0}},
    "efeitos": {"baixa": {"efeitos": {"flash": 0.0, "zoom": 0.5, "brilho": 0.0, "grade": 0.5}},
                "media": {"efeitos": {"flash": 1.0, "zoom": 1.0, "brilho": 1.0, "grade": 1.0}},
                "alta": {"efeitos": {"flash": 1.6, "zoom": 1.5, "brilho": 1.4, "grade": 1.2}}},
}
BROLL = {"baixa": 0.2, "media": 0.3, "alta": 0.35}  # B-roll do apresentador acompanha o motion
SFX_KEY = ("contador", "cta", "titulo_capitulo", "pergunta_destaque")  # sfx baixa: só as entradas principais
SFX_DEFAULT = {"contador": "whoosh", "barras_comparacao": "swoosh", "versus": "whoosh", "passo_a_passo": "pop",
              "lista_itens": "pop", "linha_do_tempo": "swoosh", "citacao_estudo": "click", "conceito_icone": "pop",
              "pergunta_destaque": "ding", "titulo_capitulo": "shimmer", "frase_destaque": "swoosh", "cta": "click",
              "anel_percentual": "whoosh", "grade_proporcao": "tick", "equacao": "click", "grafico_linha": "swoosh",
              "ranking": "swoosh", "termo_tecnico": "type", "alerta": "ding", "lettering": "whoosh", "riscado": "swoosh",
              "carimbo": "stamp"}


class Rules(BaseModel):
    # o que o canal NÃO usa (cenas do kit, ids de peças do acervo, intenções ou temas das fichas); o cardápio é o
    # resto. A configuração do canal não carrega lista de cenas (docs/PLANO-ACERVO.md, decisão 4)
    filtro: list[str] = Field(default_factory=list)
    takeover_max: float = Field(0.55, ge=0, le=1)  # fração do tempo em cenas só de motion
    dur_min: float = 1.2  # cena mais curta que isso some (a frase cola na anterior)
    takeover_max_s: float = 6.0  # cena só de motion não passa disso
    sobreposicao_max_s: float = 5.0  # cena sobre a mídia não passa disso
    trecho_max_s: float = 5.0  # frase mais longa que isso é dividida nas vírgulas (algo novo a cada poucos segundos)
    sfx_por_s: float = 0.8  # teto de efeitos por segundo (R2)
    sfx_volume: float = Field(0.45, ge=0, le=1)
    sfx: dict[str, str] = Field(default_factory=dict)  # cena → som (SONS)
    legenda: dict[str, bool] = Field(default_factory=lambda: {"16:9": False, "9:16": True})
    legenda_visual: Caption = Field(default_factory=Caption)
    niveis: dict[str, LEVEL] = Field(default_factory=lambda: {"sfx": "alta", "motion": "alta", "efeitos": "alta"})
    # força de cada efeito visual (0 desliga): flash nas entradas, zoom (movimento da mídia, punch, socos), brilho e
    # grade do fundo das cenas de motion
    efeitos: dict[str, float] = Field(default_factory=lambda: {"flash": 1.0, "zoom": 1.0, "brilho": 1.0, "grade": 1.0})
    # modo apresentador: teto de tela só de motion e de B-roll (fração do tempo), punch-in base e o de impacto
    apresentador: dict[str, float] = Field(default_factory=lambda: {"tela_max": 0.07, "broll": 0.3, "punch": 1.06,
                                                                    "punch_impacto": 1.16})
    visual: Visual = Field(default_factory=Visual)
    lufs: float = -14.0
    pico: float = -1.0


    @model_validator(mode="before")
    @classmethod
    def _cardapio_old(cls, d):
        """Estilo salvo com `cenas` (cardápio permitido) vira `filtro` (o que fica de fora)."""
        if isinstance(d, dict) and "cenas" in d:
            d = dict(d)
            scenes = d.pop("cenas") or []
            d.setdefault("filtro", [c for c in SCENES if c not in scenes])
        return d

    def cardapio(self):
        """Cenas do kit que o canal usa (todas menos o filtro)."""
        return [c for c in SCENES if c not in self.filtro]


class RulesColor(BaseModel):
    """Regras que o motor aplica às cores (aba Identidade)."""
    um_destaque: bool = True  # no máximo 1 elemento em destaque por cena
    sem_mistura: bool = True  # nunca destaque, apoio e acento juntos na mesma cena
    inativos: float = Field(0.4, ge=0.1, le=1)  # itens inativos (lista, barras secundárias) em texto a X de opacidade
    sentido: bool = True  # apoio/acento só quando o dado tiver sentido positivo/negativo


CURVES = {"suave": "power3.out", "firme": "expo.out", "elastica": "back.out(1.6)", "linear": "none"}
FORBIDDABLE = ("bounce", "shake", "glitch", "flash", "3D", "som de dinheiro", "luz", "particulas")


class Motion(BaseModel):
    """Linguagem de movimento do canal: o kit lê e aplica em todas as peças."""
    curva: Literal[tuple(CURVES)] = "suave"
    ritmo: list[float] = Field(default_factory=lambda: [2.0, 4.0], min_length=2, max_length=2)  # algo muda a cada X–Y s
    entrada: Literal["fade_deslize", "fade", "escala", "revelar", "desfoque", "mascara"] = "fade_deslize"
    entrada_s: float = Field(0.4, ge=0.1, le=2)
    saida: Literal["fade", "deslize", "desfoque", "corte"] = "fade"
    saida_s: float = Field(0.25, ge=0.05, le=2)
    proibidos: list[str] = Field(default_factory=lambda: ["bounce", "shake", "glitch", "3D", "som de dinheiro"])


class Layouts(BaseModel):
    """Ajustes dos layouts do apresentador (aba Layouts e modos)."""
    split_lado: Literal["esquerda", "direita"] = "esquerda"  # lado do apresentador no SPLIT
    split_largura: float = Field(0.45, ge=0.25, le=0.6)  # largura do apresentador no SPLIT (16:9)
    painel_entrada: Literal["desliza", "fade", "corte"] = "desliza"
    painel_entrada_s: float = Field(0.4, ge=0.1, le=1.5)
    area_segura: float = Field(0.05, ge=0, le=0.15)
    vertical_peca: Literal["cima", "baixo"] = "cima"  # 9:16: onde fica a peça no SPLIT
    reservar_inferior: bool = True  # 9:16: 20% inferiores livres (UI do app)
    legenda_terco: bool = True  # 9:16: legenda no terço central
    peca_cheia_max_s: float = 6.0
    capitulo_s: list[float] = Field(default_factory=lambda: [2.0, 3.0], min_length=2, max_length=2)
    broll_max_s: float = 4.0
    # rodízio das peças que ocupam a tela: com o apresentador (no lugar do SPLIT fixo) e no dark (no lugar da peça
    # cheia); lateral/flutuante = dados sobre a imagem, sólido = card sobre fundo na cor do estilo
    variacoes: list[Literal["split", "lateral", "flutuante", "solido"]] = Field(
        default_factory=lambda: ["split", "lateral", "flutuante"])
    variacoes_dark: list[Literal["tela", "lateral", "flutuante", "solido"]] = Field(
        default_factory=lambda: ["tela", "flutuante", "lateral", "solido"])
    lado_dados: Literal["auto", "esquerda", "direita"] = "auto"  # auto = oposto ao rosto na gravação
    selo: str = Field("", max_length=40)  # selo de progresso fixo no canto ("● SELO | 02/05 capítulo"); vazio = sem


class Presence(BaseModel):
    fora_max_s: float = 6.0  # apresentador fora da tela no máximo
    peca_parada_s: float = 5.0  # peça parada; depois acrescenta detalhe
    mudanca_s: list[float] = Field(default_factory=lambda: [2.0, 4.0], min_length=2, max_length=2)
    mudanca_vertical_s: list[float] = Field(default_factory=lambda: [1.5, 3.0], min_length=2, max_length=2)


class Piece(BaseModel):
    """Ajuste de uma peça (cena do kit) neste estilo: animação relativa à palavra-âncora, fonte e cor. Se a IA pode
    escolher a peça sozinha continua sendo `regras.cenas` (o cardápio)."""
    entrada: str = ""  # vazio = a do Movimento
    atraso_q: int = Field(-3, ge=-30, le=30)  # quadros em relação à palavra-âncora (negativo = antes)
    contagem_s: float = Field(0.9, ge=0.1, le=4)  # contagem/preenchimento dos números
    curva: str = ""  # vazio = a do Movimento
    fonte: Literal["fonte_destaque", "fonte_texto", "fonte_tecnica", "fonte_editorial"] = "fonte_destaque"
    tamanho: float = Field(1.0, ge=0.5, le=2)  # multiplica o tamanho padrão
    cor: Literal["destaque", "gatilho"] = "gatilho"  # gatilho = a cor que a regra do gatilho escolher


class Style(BaseModel):
    id: str = Field(pattern=r"^[a-z0-9][a-z0-9-]{1,40}$")
    nome: str
    canal: str
    # só para amostra e teste do estilo: na produção vale o `modo:` do roteiro (producao.modo; decisão 5 do plano)
    modo: Literal["dark", "apresentador", "curso"] = "dark"
    formatos: list[Literal["16:9", "9:16"]] = Field(default_factory=lambda: ["16:9", "9:16"])
    pele: Skin = Field(default_factory=Skin)
    regras: Rules = Field(default_factory=Rules)
    guia: str = ""  # tom e notas do canal (escrito no Fluxo A), entra no prompt do diretor
    exemplos: list[Example] = Field(default_factory=list)
    regras_cor: RulesColor = Field(default_factory=RulesColor)
    tamanhos: dict[str, list[int]] = Field(default_factory=lambda: {  # px em 1080p por papel de fonte (mín, máx)
        "fonte_destaque": [180, 260], "fonte_texto": [40, 48], "fonte_tecnica": [24, 28], "fonte_legenda": [52, 60],
        "fonte_editorial": [110, 140]})
    bloquear: list[str] = Field(default_factory=lambda: ["URGENTE", "você não vai acreditar", "enriqueça"])
    movimento: Motion = Field(default_factory=Motion)
    layouts: Layouts = Field(default_factory=Layouts)
    presenca: Presence = Field(default_factory=Presence)
    gatilhos: list[Trigger] = Field(default_factory=triggers.default)
    pecas: dict[str, Piece] = Field(default_factory=dict)  # cena → ajuste (ausente = padrão)
    versao: int = 1
    travado: bool = False
    rotulo: str = ""  # nome opcional da versão (vazio = nome do estilo)
    salvo_em: str = ""


def apply_levels(rules: Rules, levels=None):
    """Regras com os números dos níveis (os do estilo, ou `niveis` por cima para uma produção só)."""
    nv = {**rules.niveis, **(levels or {})}
    data = rules.model_dump()
    for eixo, level in nv.items():
        data.update(LEVELS.get(eixo, {}).get(level, {}))
    if nv.get("motion") in BROLL:
        data["apresentador"] = {**data["apresentador"], "broll": BROLL[nv["motion"]]}
    data["niveis"] = nv
    return Rules.model_validate(data)


def with_mode(style: "Style", mode):
    """Cópia do estilo para o modo do vídeo (marcado no roteiro); o estilo salvo não muda."""
    return style if not mode or mode == style.modo else style.model_copy(update={"modo": mode})


def with_levels(style: "Style", levels=None):
    """Cópia do estilo para uma produção, com outro nível de som/motion/efeitos (o estilo salvo não muda)."""
    return style.model_copy(update={"regras": apply_levels(style.regras, levels)}) if levels else style


def _file(id_):
    return FOLDER / f"{id_}.json"


def _seed():
    FOLDER.mkdir(parents=True, exist_ok=True)
    for s in SEEDS.glob("*.json"):
        if not (FOLDER / s.name).exists():
            (FOLDER / s.name).write_text(s.read_text())


def list_all(channel=None):
    _seed()
    styles = [Style.model_validate_json(a.read_text()) for a in sorted(FOLDER.glob("*.json"))]
    return [e for e in styles if channel is None or e.canal == channel]


def load(id_):
    """`id` = versão atual; `id@N` = a versão N guardada."""
    _seed()
    id_, _, v = id_.partition("@")
    if not _file(id_).exists():
        raise KeyError(f"estilo inexistente: {id_}")
    current = Style.model_validate_json(_file(id_).read_text())
    if not v or int(v) == current.versao:
        return current
    file = _versions(id_) / f"v{int(v)}.json"
    if not file.exists():
        raise KeyError(f"versão inexistente: {id_}@{v}")
    return Style.model_validate_json(file.read_text())


def _versions(id_):
    return FOLDER / "versoes" / id_


def _store(style: Style):
    _versions(style.id).mkdir(parents=True, exist_ok=True)
    (_versions(style.id) / f"v{style.versao}.json").write_text(style.model_dump_json(indent=1))


def label(style: Style):
    """Como a versão aparece para escolher: `vN - nome` (nome da versão ou, sem ele, o do estilo)."""
    return f"v{style.versao} - {style.rotulo.strip() or style.nome}"


def versions(id_):
    """Todas as versões guardadas do estilo, da mais nova para a mais antiga."""
    current = load(id_)
    folder = _versions(id_)
    everything = {current.versao: current}
    if folder.is_dir():
        for a in folder.glob("v*.json"):
            e = Style.model_validate_json(a.read_text())
            everything.setdefault(e.versao, e)
    return [everything[v] for v in sorted(everything, reverse=True)]


def save(style: Style, forcar=False, new_version=True):
    """Grava como versão nova (a anterior fica guardada). Estilo travado só muda com `forcar` (destravar é explícito)."""
    _seed()
    if _file(style.id).exists():
        current = load(style.id)
        if current.travado and not forcar:
            raise PermissionError(f"estilo {style.id} travado: destrave antes de mudar")
        if not (_versions(current.id) / f"v{current.versao}.json").exists():
            _store(current)
        style.versao = current.versao + 1 if new_version else current.versao
    if new_version or not style.salvo_em:
        style.salvo_em = datetime.now().isoformat(timespec="seconds")
    style.regras = apply_levels(style.regras)
    _file(style.id).write_text(style.model_dump_json(indent=1))
    _store(style)
    return style


def new(channel, mode, formats, name=""):
    """Template novo do canal pelo tipo (modo + formatos), a partir do estilo do canal mais parecido."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,30}", channel):
        raise ValueError("canal: letras minúsculas, números e hífen")
    of_channel = list_all(channel)
    base = next((e for e in of_channel if e.modo == mode), None) or (of_channel[0] if of_channel else load("finlumia-dark"))
    root = f"{channel}-{mode}"
    id_, n = root, 2
    while _file(id_).exists():
        id_, n = f"{root}-{n}", n + 1
    e = base.model_copy(update={"id": id_, "canal": channel, "modo": mode, "formatos": formats, "versao": 1,
                                "travado": False, "rotulo": "", "exemplos": list(base.exemplos),
                                "nome": name.strip() or f"{channel.capitalize()} · {mode}" + (f" {n - 1}" if n > 2 else "")})
    Style.model_validate(e.model_dump())
    return save(e)


def new_channel(slug, name, niche="", color="#f5c518", mode="dark"):
    """Cria o estilo inicial de um canal novo (rede aberta); a identidade fina vem do Fluxo A."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,30}", slug):
        raise ValueError("slug: letras minúsculas, números e hífen")
    id_ = f"{slug}-{mode}"
    if _file(id_).exists():
        raise FileExistsError(f"já existe o estilo {id_}")
    base = load("finlumia-dark")
    e = Style(id=id_, nome=f"{name} · {mode}", canal=slug, modo=mode, pele=base.pele.model_copy(update={"destaque": color}),
               regras=base.regras, guia=f"Canal {name}. Nicho: {niche}." if niche else f"Canal {name}.")
    return save(e)


def duplicate(origin_id, new_id, name):
    """Template novo a partir de um estilo: tudo igual, destravado, versão 1 (o canal pode ser trocado depois)."""
    if _file(new_id).exists():
        raise FileExistsError(f"já existe o estilo {new_id}")
    base = load(origin_id)
    new = base.model_copy(update={"id": new_id, "nome": name, "versao": 1, "travado": False, "rotulo": ""})
    Style.model_validate(new.model_dump())  # valida o id
    return save(new)


def channels():
    """Canais da rede: os perfis da esteira + os que só existem como estilo."""
    from esteira.project import ROOT
    names = {p.stem for p in (ROOT / "perfis").glob("*.toml")}
    names |= {e.canal for e in list_all()}
    return sorted(names)


def json_skin(style: Style):
    return json.loads(style.pele.model_dump_json())
