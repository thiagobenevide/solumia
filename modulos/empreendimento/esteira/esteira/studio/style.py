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

from esteira.bench import CENAS
from esteira.studio import triggers
from esteira.studio.triggers import Gatilho
from esteira.project import DADOS

PASTA = DADOS / "estudio" / "estilos"
SEMENTES = Path(__file__).parent / "estilos"
SONS = ("boom", "click", "ding", "glitch", "pop", "riser", "shimmer", "stamp", "swoosh", "tick", "type", "whoosh")
COR = r"^#[0-9a-fA-F]{6}$"


class Pele(BaseModel):
    fundo: str = Field("#0b0b0d", pattern=COR)
    fundo2: str = Field("#1c1c22", pattern=COR)
    texto: str = Field("#ffffff", pattern=COR)
    destaque: str = Field("#f5c518", pattern=COR)
    apoio: str = Field("#ffe08a", pattern=COR)
    acento: str = Field("#b8b2a3", pattern=COR)
    fonte_destaque: str = "Plus Jakarta Sans"
    fonte_texto: str = "Plus Jakarta Sans"
    fonte_tecnica: str = "JetBrains Mono"
    fonte_editorial: str = "Playfair Display"  # capítulos, "vs", citações (serifa em itálico)
    fonte_legenda: str = "Plus Jakarta Sans"


class Exemplo(BaseModel):
    frase: str
    cena: str
    titulo: str = ""


class Legenda(BaseModel):
    """Aparência da legenda (liga/desliga por formato fica em `Regras.legenda`; a fonte em `Pele.fonte_legenda`)."""
    tamanho: float = Field(1.0, ge=0.6, le=1.8)  # multiplica o tamanho padrão do formato
    posicao: Literal["baixo", "meio", "rosto"] = "baixo"  # rosto: logo abaixo do queixo (modo apresentador, câmera cheia)
    palavras: int = Field(3, ge=1, le=3)  # palavras por vez
    destaque_chave: bool = True  # números e palavras-chave das cenas na cor de destaque
    caixa: Literal["normal", "alta"] = "normal"
    acabamento: Literal["sombra", "contorno", "caixa"] = "sombra"


ENTRADAS = ("desfoque", "deslizar", "revelar", "escala")


class Visual(BaseModel):
    """Variações das cenas do kit, como dado (nunca código): o compilador passa ao kit e o código alterna as entradas
    ao longo do vídeo. É o que dá cara própria ao estilo sem gerar código por vídeo nem chamar o Claude."""
    entradas: list[Literal[ENTRADAS]] = Field(default_factory=lambda: ["desfoque", "deslizar"], min_length=1)
    fundo: Literal["veu", "solido", "gradiente"] = "veu"  # fundo das cenas só de motion
    alinhamento: Literal["centro", "esquerda"] = "centro"
    cartao: Literal["vidro", "contorno", "solido"] = "vidro"  # etiquetas e cartões
    cantos: float = Field(1.0, ge=0, le=3)  # arredondamento (0 = reto)


NIVEL = Literal["baixa", "media", "alta", "personalizado"]
# o nível preenche os números das regras; "personalizado" = números ajustados à mão no Avançado
NIVEIS = {
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
SFX_CHAVE = ("contador", "cta", "titulo_capitulo", "pergunta_destaque")  # sfx baixa: só as entradas principais
SFX_PADRAO = {"contador": "whoosh", "barras_comparacao": "swoosh", "versus": "whoosh", "passo_a_passo": "pop",
              "lista_itens": "pop", "linha_do_tempo": "swoosh", "citacao_estudo": "click", "conceito_icone": "pop",
              "pergunta_destaque": "ding", "titulo_capitulo": "shimmer", "frase_destaque": "swoosh", "cta": "click",
              "anel_percentual": "whoosh", "grade_proporcao": "tick", "equacao": "click", "grafico_linha": "swoosh",
              "ranking": "swoosh", "termo_tecnico": "type", "alerta": "ding", "lettering": "whoosh", "riscado": "swoosh",
              "carimbo": "stamp"}


class Regras(BaseModel):
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
    legenda_visual: Legenda = Field(default_factory=Legenda)
    niveis: dict[str, NIVEL] = Field(default_factory=lambda: {"sfx": "alta", "motion": "alta", "efeitos": "alta"})
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
    def _cardapio_antigo(cls, d):
        """Estilo salvo com `cenas` (cardápio permitido) vira `filtro` (o que fica de fora)."""
        if isinstance(d, dict) and "cenas" in d:
            d = dict(d)
            cenas = d.pop("cenas") or []
            d.setdefault("filtro", [c for c in CENAS if c not in cenas])
        return d

    def cardapio(self):
        """Cenas do kit que o canal usa (todas menos o filtro)."""
        return [c for c in CENAS if c not in self.filtro]


class RegrasCor(BaseModel):
    """Regras que o motor aplica às cores (aba Identidade)."""
    um_destaque: bool = True  # no máximo 1 elemento em destaque por cena
    sem_mistura: bool = True  # nunca destaque, apoio e acento juntos na mesma cena
    inativos: float = Field(0.4, ge=0.1, le=1)  # itens inativos (lista, barras secundárias) em texto a X de opacidade
    sentido: bool = True  # apoio/acento só quando o dado tiver sentido positivo/negativo


CURVAS = {"suave": "power3.out", "firme": "expo.out", "elastica": "back.out(1.6)", "linear": "none"}
PROIBIVEIS = ("bounce", "shake", "glitch", "flash", "3D", "som de dinheiro", "luz", "particulas")


class Movimento(BaseModel):
    """Linguagem de movimento do canal: o kit lê e aplica em todas as peças."""
    curva: Literal[tuple(CURVAS)] = "suave"
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


class Presenca(BaseModel):
    fora_max_s: float = 6.0  # apresentador fora da tela no máximo
    peca_parada_s: float = 5.0  # peça parada; depois acrescenta detalhe
    mudanca_s: list[float] = Field(default_factory=lambda: [2.0, 4.0], min_length=2, max_length=2)
    mudanca_vertical_s: list[float] = Field(default_factory=lambda: [1.5, 3.0], min_length=2, max_length=2)


class Peca(BaseModel):
    """Ajuste de uma peça (cena do kit) neste estilo: animação relativa à palavra-âncora, fonte e cor. Se a IA pode
    escolher a peça sozinha continua sendo `regras.cenas` (o cardápio)."""
    entrada: str = ""  # vazio = a do Movimento
    atraso_q: int = Field(-3, ge=-30, le=30)  # quadros em relação à palavra-âncora (negativo = antes)
    contagem_s: float = Field(0.9, ge=0.1, le=4)  # contagem/preenchimento dos números
    curva: str = ""  # vazio = a do Movimento
    fonte: Literal["fonte_destaque", "fonte_texto", "fonte_tecnica", "fonte_editorial"] = "fonte_destaque"
    tamanho: float = Field(1.0, ge=0.5, le=2)  # multiplica o tamanho padrão
    cor: Literal["destaque", "gatilho"] = "gatilho"  # gatilho = a cor que a regra do gatilho escolher


class Estilo(BaseModel):
    id: str = Field(pattern=r"^[a-z0-9][a-z0-9-]{1,40}$")
    nome: str
    canal: str
    # só para amostra e teste do estilo: na produção vale o `modo:` do roteiro (producao.modo; decisão 5 do plano)
    modo: Literal["dark", "apresentador", "curso"] = "dark"
    formatos: list[Literal["16:9", "9:16"]] = Field(default_factory=lambda: ["16:9", "9:16"])
    pele: Pele = Field(default_factory=Pele)
    regras: Regras = Field(default_factory=Regras)
    guia: str = ""  # tom e notas do canal (escrito no Fluxo A), entra no prompt do diretor
    exemplos: list[Exemplo] = Field(default_factory=list)
    regras_cor: RegrasCor = Field(default_factory=RegrasCor)
    tamanhos: dict[str, list[int]] = Field(default_factory=lambda: {  # px em 1080p por papel de fonte (mín, máx)
        "fonte_destaque": [180, 260], "fonte_texto": [40, 48], "fonte_tecnica": [24, 28], "fonte_legenda": [52, 60],
        "fonte_editorial": [110, 140]})
    bloquear: list[str] = Field(default_factory=lambda: ["URGENTE", "você não vai acreditar", "enriqueça"])
    movimento: Movimento = Field(default_factory=Movimento)
    layouts: Layouts = Field(default_factory=Layouts)
    presenca: Presenca = Field(default_factory=Presenca)
    gatilhos: list[Gatilho] = Field(default_factory=triggers.padrao)
    pecas: dict[str, Peca] = Field(default_factory=dict)  # cena → ajuste (ausente = padrão)
    versao: int = 1
    travado: bool = False
    rotulo: str = ""  # nome opcional da versão (vazio = nome do estilo)
    salvo_em: str = ""


def aplicar_niveis(regras: Regras, niveis=None):
    """Regras com os números dos níveis (os do estilo, ou `niveis` por cima para uma produção só)."""
    nv = {**regras.niveis, **(niveis or {})}
    dados = regras.model_dump()
    for eixo, nivel in nv.items():
        dados.update(NIVEIS.get(eixo, {}).get(nivel, {}))
    if nv.get("motion") in BROLL:
        dados["apresentador"] = {**dados["apresentador"], "broll": BROLL[nv["motion"]]}
    dados["niveis"] = nv
    return Regras.model_validate(dados)


def com_modo(estilo: "Estilo", modo):
    """Cópia do estilo para o modo do vídeo (marcado no roteiro); o estilo salvo não muda."""
    return estilo if not modo or modo == estilo.modo else estilo.model_copy(update={"modo": modo})


def com_niveis(estilo: "Estilo", niveis=None):
    """Cópia do estilo para uma produção, com outro nível de som/motion/efeitos (o estilo salvo não muda)."""
    return estilo.model_copy(update={"regras": aplicar_niveis(estilo.regras, niveis)}) if niveis else estilo


def _arq(id_):
    return PASTA / f"{id_}.json"


def _semear():
    PASTA.mkdir(parents=True, exist_ok=True)
    for s in SEMENTES.glob("*.json"):
        if not (PASTA / s.name).exists():
            (PASTA / s.name).write_text(s.read_text())


def listar(canal=None):
    _semear()
    estilos = [Estilo.model_validate_json(a.read_text()) for a in sorted(PASTA.glob("*.json"))]
    return [e for e in estilos if canal is None or e.canal == canal]


def carregar(id_):
    """`id` = versão atual; `id@N` = a versão N guardada."""
    _semear()
    id_, _, v = id_.partition("@")
    if not _arq(id_).exists():
        raise KeyError(f"estilo inexistente: {id_}")
    atual = Estilo.model_validate_json(_arq(id_).read_text())
    if not v or int(v) == atual.versao:
        return atual
    arq = _versoes(id_) / f"v{int(v)}.json"
    if not arq.exists():
        raise KeyError(f"versão inexistente: {id_}@{v}")
    return Estilo.model_validate_json(arq.read_text())


def _versoes(id_):
    return PASTA / "versoes" / id_


def _guardar(estilo: Estilo):
    _versoes(estilo.id).mkdir(parents=True, exist_ok=True)
    (_versoes(estilo.id) / f"v{estilo.versao}.json").write_text(estilo.model_dump_json(indent=1))


def rotulo(estilo: Estilo):
    """Como a versão aparece para escolher: `vN - nome` (nome da versão ou, sem ele, o do estilo)."""
    return f"v{estilo.versao} - {estilo.rotulo.strip() or estilo.nome}"


def versoes(id_):
    """Todas as versões guardadas do estilo, da mais nova para a mais antiga."""
    atual = carregar(id_)
    pasta = _versoes(id_)
    todas = {atual.versao: atual}
    if pasta.is_dir():
        for a in pasta.glob("v*.json"):
            e = Estilo.model_validate_json(a.read_text())
            todas.setdefault(e.versao, e)
    return [todas[v] for v in sorted(todas, reverse=True)]


def salvar(estilo: Estilo, forcar=False, nova_versao=True):
    """Grava como versão nova (a anterior fica guardada). Estilo travado só muda com `forcar` (destravar é explícito)."""
    _semear()
    if _arq(estilo.id).exists():
        atual = carregar(estilo.id)
        if atual.travado and not forcar:
            raise PermissionError(f"estilo {estilo.id} travado: destrave antes de mudar")
        if not (_versoes(atual.id) / f"v{atual.versao}.json").exists():
            _guardar(atual)
        estilo.versao = atual.versao + 1 if nova_versao else atual.versao
    if nova_versao or not estilo.salvo_em:
        estilo.salvo_em = datetime.now().isoformat(timespec="seconds")
    estilo.regras = aplicar_niveis(estilo.regras)
    _arq(estilo.id).write_text(estilo.model_dump_json(indent=1))
    _guardar(estilo)
    return estilo


def novo(canal, modo, formatos, nome=""):
    """Template novo do canal pelo tipo (modo + formatos), a partir do estilo do canal mais parecido."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,30}", canal):
        raise ValueError("canal: letras minúsculas, números e hífen")
    do_canal = listar(canal)
    base = next((e for e in do_canal if e.modo == modo), None) or (do_canal[0] if do_canal else carregar("finlumia-dark"))
    raiz = f"{canal}-{modo}"
    id_, n = raiz, 2
    while _arq(id_).exists():
        id_, n = f"{raiz}-{n}", n + 1
    e = base.model_copy(update={"id": id_, "canal": canal, "modo": modo, "formatos": formatos, "versao": 1,
                                "travado": False, "rotulo": "", "exemplos": list(base.exemplos),
                                "nome": nome.strip() or f"{canal.capitalize()} · {modo}" + (f" {n - 1}" if n > 2 else "")})
    Estilo.model_validate(e.model_dump())
    return salvar(e)


def novo_canal(slug, nome, nicho="", cor="#f5c518", modo="dark"):
    """Cria o estilo inicial de um canal novo (rede aberta); a identidade fina vem do Fluxo A."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,30}", slug):
        raise ValueError("slug: letras minúsculas, números e hífen")
    id_ = f"{slug}-{modo}"
    if _arq(id_).exists():
        raise FileExistsError(f"já existe o estilo {id_}")
    base = carregar("finlumia-dark")
    e = Estilo(id=id_, nome=f"{nome} · {modo}", canal=slug, modo=modo, pele=base.pele.model_copy(update={"destaque": cor}),
               regras=base.regras, guia=f"Canal {nome}. Nicho: {nicho}." if nicho else f"Canal {nome}.")
    return salvar(e)


def duplicar(origem_id, novo_id, nome):
    """Template novo a partir de um estilo: tudo igual, destravado, versão 1 (o canal pode ser trocado depois)."""
    if _arq(novo_id).exists():
        raise FileExistsError(f"já existe o estilo {novo_id}")
    base = carregar(origem_id)
    novo = base.model_copy(update={"id": novo_id, "nome": nome, "versao": 1, "travado": False, "rotulo": ""})
    Estilo.model_validate(novo.model_dump())  # valida o id
    return salvar(novo)


def canais():
    """Canais da rede: os perfis da esteira + os que só existem como estilo."""
    from esteira.project import RAIZ
    nomes = {p.stem for p in (RAIZ / "perfis").glob("*.toml")}
    nomes |= {e.canal for e in listar()}
    return sorted(nomes)


def json_pele(estilo: Estilo):
    return json.loads(estilo.pele.model_dump_json())
