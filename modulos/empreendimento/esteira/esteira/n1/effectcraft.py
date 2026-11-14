"""N1 do EffectCraft: peça como documento declarativo (elementos + animações) e o compilador N1 → script da app.

O compilador resolve em Python tudo o que depende dos dados da peça (encaixes, botões, batidas, formato) e gera
o corpo da peça chamando os auxiliares provados de `estudio/pecas/_ec/nucleo.jsx` (bloco, linha, retangulo,
entrar, contagem…), que o `effectcraft-cli script` executa. Ninguém escreve script: o modelo escreve N1.

Unidades: x em fração da largura, y em fração da altura, tamanhos de texto/forma em fração do lado menor.
Tempo: número = segundos depois de T0; "@<batida>" = instante dito (com padrão em `batidas_padrao`);
"T0+0.2"; o sufixo "v" multiplica pela velocidade (`botao_velocidade`), ex.: "@numero+0.5v".
`se` liga elemento/animação a um botão (`{"botao": "enfase", "igual": "traco"}`) ou a um encaixe preenchido.
`vertical` sobrescreve campos no 9:16. Textos aceitam `{{encaixe}}` e `*destaque*`.
"""
import json
import math
import re
from typing import Annotated, Any, Literal

from pydantic import AfterValidator, BaseModel, BeforeValidator, Field

APP = "effectcraft"
VERSION = 1

RoleColor = Literal["fundo", "fundo2", "texto", "destaque", "apoio", "acento"]
RoleSource = Literal["fD", "fT", "fM", "fE", "fL"]


def _norm_time(v):
    """O que modelos escrevem fora do padrão (a gramática não força o `pattern`): espaços, número em texto,
    "0.5v" sem base, "+0.2" → forma canônica; o resto o padrão reprova."""
    if not isinstance(v, str):
        return v
    s = re.sub(r"\s+", "", v).replace(",", ".")
    if re.fullmatch(r"\d+(\.\d+)?", s):
        return float(s)
    if re.fullmatch(r"[+-]?\d+(\.\d+)?v?([+-]\d+(\.\d+)?v?)*", s):
        return "T0" + (s if s[0] in "+-" else "+" + s)
    return s


def _norm_duration(v):
    if not isinstance(v, str):
        return v
    s = re.sub(r"\s+", "", v).lstrip("+").replace(",", ".")
    return float(s) if re.fullmatch(r"\d+(\.\d+)?s?", s) and (s := s.rstrip("s")) else s


def _positive(v: float) -> float:
    return max(v, 0.002)  # 0 (linha fina, traço que ainda vai crescer) vira um fio: a forma existe


Time = Annotated[float | Annotated[str, Field(pattern=r"^(T0|@[a-z_]+)([+-]\d+(\.\d+)?v?)*$")],
                  BeforeValidator(_norm_time)]
Duration = Annotated[float | Annotated[str, Field(pattern=r"^\d+(\.\d+)?v$", description="sufixo v: × velocidade")],
                    BeforeValidator(_norm_duration)]
Positive = Annotated[float, Field(ge=0), AfterValidator(_positive)]


def _norm_value(v):
    """Valor de chave escrito como texto ("100%", "1,2", "[100, 100]") → número ou lista."""
    if isinstance(v, str):
        nums = [float(n.replace(",", ".")) for n in re.findall(r"-?\d+(?:[.,]\d+)?", v)]
        return nums[0] if len(nums) == 1 else nums or v
    if isinstance(v, list):
        return [_norm_value(x) if isinstance(x, str) else x for x in v]
    return v


Value = Annotated[float | list[float], BeforeValidator(_norm_value)]
SizeText = Annotated[float, Field(gt=0), AfterValidator(lambda v: min(v, 0.6))]


class _M(BaseModel):
    model_config = {"extra": "forbid"}


class Cond(_M):
    botao: str | None = None
    igual: str | None = None
    encaixe: str | None = None


Condition = Cond | list[Cond] | None


def conditions(se: Condition) -> list[Cond]:
    return [] if se is None else se if isinstance(se, list) else [se]


class _El(_M):
    nome: str
    se: Condition = None
    vertical: dict[str, Any] = Field(default_factory=dict)


class After(_M):
    nome: str = Field(description="texto de referência: este começa logo depois dele")
    folga: float = 0.0


class Text(_El):
    tipo: Literal["texto"]
    conteudo: str
    nivel: Literal["titulo", "destaque", "numero", "corpo", "rotulo"] | None = Field(
        None, description="tamanho pelo papel do texto (dentro de caixa, no lugar de tam)")
    x: float | None = Field(None, ge=-0.5, le=1.5, description="só fora de caixa")
    y: float | None = Field(None, ge=-0.5, le=1.5, description="só fora de caixa: topo (com largura) ou linha de base")
    largura: float | None = Field(None, gt=0, le=1.5, description="com largura: parágrafo; sem: uma linha")
    fonte: RoleSource = "fT"
    peso: int = Field(400, ge=100, le=900)
    tam: SizeText | None = None
    cor: RoleColor = "texto"
    alinhar: Literal["esquerda", "centro", "direita"] = "esquerda"
    caps: bool = False
    italico: bool = False
    tracking: int = 0
    entrelinha: float | None = None
    numero: bool = Field(False, description="o conteúdo é um número dito: formata pt-BR e pode `contar`")
    unidade_de: str | None = Field(None, description="mostra a unidade (o que vem depois) do texto-número indicado")
    apos: After | None = None


class Rectangle(_El):
    tipo: Literal["retangulo"]
    x: float | None = Field(None, description="só fora de caixa")
    y: float | None = Field(None, description="só fora de caixa")
    w: Positive | None = Field(None, description="fração do lado menor; dentro de caixa, sem w/h preenche a célula")
    h: Positive | None = Field(None, description="fração do lado menor (ex.: 0.006 = linha fina)")
    cor: RoleColor = "destaque"
    opacidade: float = Field(100, ge=0, le=100)
    raio: float = 0
    proporcional: bool = Field(False, description="num `repetir` de pares dentro de caixa: o tamanho segue o valor do "
                               "item (barra/pilar: altura na célula alta, largura na célula larga)")
    escala_valor: float | None = Field(None, description="interno: valor do item ÷ maior valor")
    ancora_esq: bool = False
    centralizar: bool = Field(False, description="x é o centro (não o canto)")


class Ellipse(_El):
    tipo: Literal["elipse"]
    x: float | None = Field(None, description="centro; só fora de caixa")
    y: float | None = Field(None, description="centro; só fora de caixa")
    d: Positive | None = Field(None, description="diâmetro, fração do lado menor; dentro de caixa, sem d ocupa a célula")
    cor: RoleColor = "destaque"
    contorno: float = Field(0, ge=0, description="espessura, fração do lado menor (0 = cheio)")
    inicio: float = Field(0, ge=0, le=1, description="arco: começo, fração da volta a partir do topo (horário)")
    fim: float = Field(1, ge=0, le=1, description="arco: fim, fração da volta (1 = volta inteira)")
    fatia: bool = Field(False, description="num `repetir` de pares: o arco do item vai da soma dos valores anteriores "
                        "à soma com o dele (rosca de percentuais); arco sempre com contorno")


Element = Annotated[Text | Rectangle | Ellipse, Field(discriminator="tipo")]


class _Anim(_M):
    alvo: str
    se: Condition = None


class Enter(_Anim):
    anim: Literal["entrar"]
    de: Literal["baixo", "esq", "dir", "aparecer", "escala"] = "baixo"
    t: Time = 0
    dur: Duration = 0.6


class Plot(_Anim):
    anim: Literal["tracar"]
    t: Time = 0
    dur: Duration = 0.8
    vertical: bool = False


class Count(_Anim):
    anim: Literal["contar"]
    t: Time = 0
    dur: Duration = 0.9


class Keys(_Anim):
    anim: Literal["chaves"]
    prop: Literal["escala", "opacidade", "posicao", "rotacao"]
    pares: list[tuple[Time, Value]]


class Blur(_Anim):
    anim: Literal["desfocar"]
    pares: list[tuple[Time, Annotated[float, BeforeValidator(_norm_value)]]]


Animation = Annotated[Enter | Plot | Count | Keys | Blur, Field(discriminator="anim")]


class Repeat(_El):
    """Um molde de elementos e animações para cada item de um encaixe-lista (itens ou pares). No molde,
    `{{item}}` (itens) ou `{{item.rotulo}}`/`{{item.valor}}` (pares); nomes ganham " N"; posições andam `passo`
    por item e os tempos atrasam `intervalo` s por item."""
    tipo: Literal["repetir"]
    encaixe: str | None = Field(None, description="encaixe-lista; sem ele, repete `quantidade` vezes ({{item}} = 1, 2…)")
    quantidade: int | None = Field(None, ge=1, le=100, description="só sem encaixe: grade fixa (ex.: 100 = 10 × 10)")
    maximo: int = Field(8, ge=1, le=100)
    passo: tuple[float, float] = (0.0, 0.0)
    colunas: int | None = Field(None, ge=1, le=20, description="grade: o item i vai à coluna i % colunas e à linha "
                                "i // colunas (passo = [entre colunas, entre linhas]); sem colunas, anda em linha")
    ativos: str | None = Field(None, description="encaixe com número (ou %): os primeiros N itens usam `cor_ativa`")
    cor_ativa: RoleColor = "destaque"
    intervalo: float = Field(0.0, ge=0)
    disposicao_item: Literal["coluna", "linha", "camadas"] = Field(
        "coluna", description="dentro de caixa: como os elementos de UM item se arrumam na célula do item")
    pesos_item: list[float] | None = Field(None, description="dentro de caixa: tamanho relativo de cada elemento do "
                                           "item na célula (sem: texto 1, forma 3)")
    elementos: list[Element]
    animacoes: list[Animation] = Field(default_factory=list)


class Box(_El):
    """Layout relacional: a caixa ocupa uma região da tela (no nível de cima) ou a célula da caixa-mãe e divide
    o espaço entre os filhos; o compilador calcula posição e tamanho (nada de x/y). No 9:16 as regiões e o
    `fluxo` se reorganizam sozinhos."""
    tipo: Literal["caixa"]
    regiao: Literal["tela", "topo", "centro", "base", "esquerda", "direita"] = Field(
        "tela", description="só no nível de cima: onde a caixa fica (área segura já descontada)")
    disposicao: Literal["coluna", "linha", "fluxo", "grade", "camadas"] = Field(
        "coluna", description="coluna (de cima para baixo), linha (lado a lado), fluxo (linha no 16:9, coluna no "
        "9:16), grade (colunas × linhas), camadas (todos na mesma célula, formas atrás e textos na frente)")
    colunas: int | None = Field(None, ge=1, le=20, description="grade: colunas (sem: raiz quadrada dos itens)")
    pesos: list[float] | None = Field(None, description="coluna/linha: tamanho relativo de cada filho (ex.: [1, 3])")
    espaco: float = Field(0.02, ge=0, le=0.2, description="vão entre filhos, fração do lado menor")
    alinhar: Literal["inicio", "centro", "fim"] = "centro"
    filhos: list["ElementOrRepeat"]


ElementOrRepeat = Annotated[Text | Rectangle | Ellipse | Repeat | Box, Field(discriminator="tipo")]
Box.model_rebuild()


class Piece(BaseModel):
    versao: Literal[1] = 1
    fundo: Literal["tela", "veu", "nenhum"] = "veu"
    fundo_tela_cheia: Literal["tela", "veu", "nenhum"] = "tela"
    opacidade_veu: float = 0.85
    batidas_padrao: dict[str, float] = Field(default_factory=dict)
    botao_velocidade: str | None = None
    elementos: list[ElementOrRepeat]
    animacoes: list[Animation] = Field(default_factory=list)


DOCUMENT = Piece
SPEED = {"lenta": 1.6, "normal": 1.0, "rapida": 0.6}
_PROP = {"escala": "Scale", "opacidade": "Opacity", "posicao": "Position", "rotacao": "Rotation"}


class ErrorN1(ValueError):
    pass


def _js(v) -> str:
    return json.dumps(v, ensure_ascii=False)


def _num(x: float) -> str:
    return repr(round(float(x), 3))


class Compiler:
    """N1 + DADOS do script (`estudio/ec.data`) → corpo da peça em script do EffectCraft."""

    def __init__(self, doc: Piece | dict, d: dict):
        self.doc = doc if isinstance(doc, Piece) else Piece.model_validate(doc)
        self.d = d
        self.W, self.H = d["w"], d["h"]
        self.vert = self.H > self.W
        self.U = min(self.W, self.H)
        self.t0 = d.get("t0") or 0
        enc, bot = d.get("encaixes") or {}, d.get("botoes") or {}
        self.enc, self.bot, self.bat = enc, bot, d.get("batidas") or {}
        self.vel = SPEED.get(bot.get(self.doc.botao_velocidade), 1.0) if self.doc.botao_velocidade else 1.0
        self.vars: dict[str, str] = {}
        self.x_px: dict[str, float] = {}
        self.numeros: set[str] = set()
        self.nomes: set[str] = set()
        self.texts: list[str] = []
        self.limites: dict[str, tuple[float, float, float, float]] = {}  # célula (px) de cada texto de caixa
        self.small: list[str] = []  # textos de caixa que a célula espremeu a menos de 60% do nível
        self.m = (d.get("area") or 0.03) * self.U * 1.15  # margem da área segura (a mesma do portão, com folga)

    def ativo(self, se: Condition) -> bool:
        for c in conditions(se):
            if c.botao is not None and str(self.bot.get(c.botao)) != str(c.igual):
                return False
            if c.encaixe is not None and not str(self.enc.get(c.encaixe) or "").strip():
                return False
        return True

    def tempo(self, t) -> float:
        if isinstance(t, (int, float)):
            return self.t0 + t
        m = re.fullmatch(r"(T0|@([a-z_]+))((?:[+-]\d+(?:\.\d+)?v?)*)", t)
        if not m:
            raise ErrorN1(f"tempo inválido: {t}")
        if m.group(1) == "T0":
            base = self.t0
        else:
            name = m.group(2)
            if name in self.bat:
                base = self.bat[name]
            elif name in self.doc.batidas_padrao:
                base = self.t0 + self.doc.batidas_padrao[name]
            else:  # batida que os dados não trazem e sem padrão declarado: logo depois da entrada
                base = self.t0 + 0.15
        delta = sum(float(n) * (self.vel if v else 1) for n, v in re.findall(r"([+-]\d+(?:\.\d+)?)(v?)", m.group(3)))
        return base + delta

    def dur(self, t) -> float:
        if isinstance(t, (int, float)):
            return float(t)
        m = re.fullmatch(r"(\d+(?:\.\d+)?)(v?)", str(t).lstrip("+"))
        if not m:
            raise ErrorN1(f"duração inválida: {t}")
        return float(m.group(1)) * (self.vel if m.group(2) else 1)

    def texto(self, s: str) -> str:
        def valor(m):
            v, field = self.enc.get(m.group(1)), m.group(2)
            if isinstance(v, list):  # lista fora do `repetir`: o primeiro item (ou o campo dele, nos pares)
                v = v[0] if v else ""
                if isinstance(v, dict):
                    v = v.get(field or "valor", "")
            elif isinstance(v, dict):
                v = v.get(field or "valor", "")
            return str(v or "")
        s = re.sub(r"\{\{(\w+)(?:\.(\w+))?\}\}", valor, s)
        if m := re.search(r"\{\{[^}]*\}\}", s):  # o que sobrar apareceria literal na tela
            raise ErrorN1(f"marcador sem valor no texto: {m.group(0)}")
        return s

    def _el(self, e):
        if not (self.vert and e.vertical):
            return e
        return type(e).model_validate({**e.model_dump(), **e.vertical, "vertical": {}})

    # ---------- layout relacional (caixas) ----------

    def _regiao(self, nome: str) -> tuple[float, float, float, float]:
        """Região nomeada → (x, y, w, h) em px, dentro da área segura; no 9:16 esquerda/direita viram cima/baixo."""
        r = (REGIONS_V if self.vert else REGIONS_H)[nome]
        return r[0] * self.W, r[1] * self.H, r[2] * self.W, r[3] * self.H

    def _celulas(self, disp, rect, n, cx: "Box"):
        x, y, w, h = rect
        g = cx.espaco * self.U
        if n <= 0:
            return []
        if disp == "camadas":
            return [rect] * n
        if disp == "grade":
            c = cx.colunas or max(1, round(n ** 0.5 + 0.49))
            lin = -(-n // c)
            cw, ch = (w - g * (c - 1)) / c, (h - g * (lin - 1)) / lin
            return [(x + (i % c) * (cw + g), y + (i // c) * (ch + g), cw, ch) for i in range(n)]
        weights = (cx.pesos or [])[:n]
        weights = weights + [1.0] * (n - len(weights))
        total = sum(max(p, 0.01) for p in weights)
        util = (h if disp == "coluna" else w) - g * (n - 1)
        cel, pos = [], (y if disp == "coluna" else x)
        for p in weights:
            t = util * max(p, 0.01) / total
            cel.append((x, pos, w, t) if disp == "coluna" else (pos, y, t, h))
            pos += t + g
        return cel

    def _encaixar(self, e, cel, cx: "Box", grade=False, bar=None):
        """Elemento → posição e tamanho absolutos dentro da célula (frações da tela, como o N1 solto)."""
        x, y, w, h = cel
        if isinstance(e, Text):
            size = (e.tam or LEVELS[e.nivel or "corpo"]) * self.U
            size = min(size, h * 0.9)
            # o bloco do EffectCraft fixa o topo e quebra para baixo: centrar como uma linha só fazia o texto de
            # várias linhas invadir a célula de baixo. Estima as linhas e encolhe até caber na célula.
            n = self._linhas(e, size, w)
            # a palavra mais longa também cabe na largura: o bloco não quebra no meio dela ("1.234,5" vazava do anel)
            while (n * size * 1.25 > h or self._palavra(e, size) > w * 0.95) and size > LEVELS["rotulo"] * self.U:
                size *= 0.92
                n = self._linhas(e, size, w)
            if size < 0.6 * (e.tam or LEVELS[e.nivel or "corpo"]) * self.U and size < 0.026 * self.U:  # < 28 px no 1080
                self.small.append(e.nome)
            ty = y + max(0.0, (h - n * size * 1.25) / 2)
            self.limites[e.nome] = (x, y, x + w, y + h)
            return e.model_copy(update={
                "x": x / self.W, "y": ty / self.H, "largura": w / self.W, "tam": size / self.U, "apos": None,
                "alinhar": {"inicio": "esquerda", "centro": "centro", "fim": "direita"}[cx.alinhar], "vertical": {}})
        if isinstance(e, Ellipse):
            d = min(e.d * self.U if e.d else 1e9, min(w, h) * 0.92)
            return e.model_copy(update={"x": (x + w / 2) / self.W, "y": (y + h / 2) / self.H, "d": d / self.U,
                                        "vertical": {}})
        if isinstance(e, Rectangle):
            if grade and not (e.w or e.h):
                side = min(w, h) * 0.86
                rw, rh = side, side
            else:
                rw = min(e.w * self.U, w) if e.w else w
                rh = min(e.h * self.U, h) if e.h else h
            if e.proporcional and e.escala_valor is not None:  # barra: cresce da base (alta) ou da esquerda (larga)
                f = max(e.escala_valor, 0.03)
                if bar == "alta" or (bar is None and h >= w):
                    rh = h * f
                    rw = rw if e.w else min(rw, w * 0.6)
                    return e.model_copy(update={"x": (x + (w - rw) / 2) / self.W, "y": (y + h - rh) / self.H,
                                                "w": rw / self.U, "h": rh / self.U, "vertical": {}})
                rw = w * f
                return e.model_copy(update={"x": x / self.W, "y": (y + (h - rh) / 2) / self.H, "w": rw / self.U,
                                            "h": rh / self.U, "vertical": {}})
            return e.model_copy(update={"x": (x + (w - rw) / 2) / self.W, "y": (y + (h - rh) / 2) / self.H,
                                        "w": rw / self.U, "h": rh / self.U, "centralizar": False, "vertical": {}})
        return e

    def _palavra(self, e: "Text", tam: float) -> float:
        """Largura estimada (px) da palavra mais longa do texto."""
        try:
            s = self.texto(e.conteudo)
        except ErrorN1:
            s = e.conteudo
        largest = max((len(p) for p in s.replace("*", "").split()), default=0)
        return largest * tam * (0.62 + e.tracking / 1000) * (1.12 if e.caps else 1)

    def _linhas(self, e: "Text", tam: float, w: float) -> int:
        """Linhas estimadas do texto na largura w (largura média do caractere ≈ 0,55 do corpo; caps e tracking a mais)."""
        try:
            s = self.texto(e.conteudo)
        except ErrorN1:
            s = e.conteudo
        car = tam * (0.55 + e.tracking / 1000) * (1.12 if e.caps else 1)
        return max(1, math.ceil(len(s.replace("*", "")) * car / max(w * 0.95, 1)))

    def _miolo(self, rect, shapes):
        """Área para texto por cima das formas da camada: dentro do furo do anel (elipse com contorno), dentro da
        elipse cheia ou do retângulo, com folga."""
        x, y, w, h = rect
        side = min(w, h)
        el = [f for f in shapes if isinstance(f, Ellipse)]
        if el:
            d = min(min(f.d * self.U if f.d else 1e9 for f in el), side * 0.92)
            edge = max((f.contorno or (0.2 * (f.d or 0) if (f.inicio > 0 or f.fim < 1 or f.fatia) else 0)) * self.U
                        for f in el)
            if any(f.fatia for f in el):
                edge = max(edge, d * 0.2)
            m = (d - 2 * edge) * 0.68
            return (x + (w - m) / 2, y + (h - m) / 2, m, m)
        if any(isinstance(f, Rectangle) for f in shapes):
            return (x + w * 0.08, y + h * 0.1, w * 0.84, h * 0.8)
        return rect

    def _resolver(self, cx: "Box", rect) -> tuple[list, list]:
        cx = self._el(cx)
        if not self.ativo(cx.se):
            return [], []
        items, anims = [], []
        for f in cx.filhos:
            if not self.ativo(self._el(f).se):
                continue
            if isinstance(f, Repeat):
                r = self._el(f)
                els, an = self._desdobrar(r)
                anims += an
                k = max(len(r.elementos), 1)
                for i in range(0, len(els), k):
                    items.append(("item", els[i:i + k], (r.disposicao_item, r.pesos_item)))
            elif isinstance(f, Box):
                items.append(("caixa", f, None))
            else:
                items.append(("el", self._el(f), None))
        disp = cx.disposicao
        if disp == "fluxo":
            disp = "coluna" if self.vert else "linha"
        output = []
        cells = self._celulas(disp, rect, len(items), cx)
        if disp == "camadas":  # texto sobre forma: no furo do anel ou dentro da forma, vários textos em coluna
            middle = self._miolo(rect, [c for t, c, _ in items if t == "el"] +
                                [e for t, c, _ in items if t == "item" for e in c])
            texts = [k for k, (t, c, _) in enumerate(items) if t == "el" and isinstance(c, Text)]
            stack = Box(tipo="caixa", nome="_miolo", espaco=cx.espaco / 2, filhos=[],
                          pesos=[2.0 if items[k][1].nivel in ("numero", "destaque", "titulo") else 1.0 for k in texts])
            cells = list(cells)
            for k, c in zip(texts, self._celulas("coluna", middle, len(texts), stack), strict=False):
                cells[k] = c
        for (kind, thing, sub), cel in zip(items, cells, strict=False):
            if kind == "el":
                output.append(self._encaixar(thing, cel, cx, disp == "grade"))
            elif kind == "caixa":
                els, an = self._resolver(thing, cel)
                output += els
                anims += an
            else:
                sub, weights_item = sub
                inner = Box(tipo="caixa", nome="_item", disposicao=sub, espaco=cx.espaco / 2, alinhar=cx.alinhar,
                                filhos=[], pesos=weights_item or [1.0 if isinstance(e, Text) else 3.0 for e in thing])
                bar = {"linha": "alta", "coluna": "larga"}.get(disp)
                for e, c in zip(thing, self._celulas(sub, cel, len(thing), inner), strict=False):
                    output.append(self._encaixar(e, c, inner, disp == "grade", bar))
        if disp == "camadas":  # formas atrás, textos na frente
            output.sort(key=lambda e: isinstance(e, Text))
        return output, anims

    def _desdobrar(self, r: Repeat) -> tuple[list, list]:
        r = self._el(r)  # `vertical` do repetir (passo, colunas, posição) vale no 9:16
        if r.encaixe:
            items = self.enc.get(r.encaixe) or []
            if not isinstance(items, list):
                items = [items]
            items = items[: r.maximo]
        else:
            items = [str(n + 1) for n in range(r.quantidade or r.maximo)]
        vals = [_number(x.get("valor") if isinstance(x, dict) else x) or 0 for x in items]
        total = sum(vals) or 1
        n_active = None
        if r.ativos:
            v = self.enc.get(r.ativos)
            v = v[0] if isinstance(v, list) and v else v
            v = v.get("valor") if isinstance(v, dict) else v
            n = _number(v)
            if n is not None:  # percentual sobre uma grade: 34% de 100 itens = 34 acesos
                n_active = round(n * len(items) / 100) if "%" in str(v) else round(n)
        els, anims = [], []
        for i, item in enumerate(items):
            def troca(txt, item=item):
                if isinstance(item, dict):
                    txt = re.sub(r"\{\{item\.(\w+)\}\}", lambda m: str(item.get(m.group(1), "")), txt)
                return txt.replace("{{item}}", str(item if not isinstance(item, dict) else item.get("rotulo", "")))
            names = {e.nome: f"{e.nome} {i + 1}" for e in r.elementos}
            col, lin = (i % r.colunas, i // r.colunas) if r.colunas else (i, i)
            for e in map(self._el, r.elementos):  # o `vertical` do molde antes do passo (senão empilha os itens)
                upd = {"nome": names[e.nome], "x": None if e.x is None else e.x + col * r.passo[0],
                       "y": None if e.y is None else e.y + lin * r.passo[1]}
                if n_active is not None and i < n_active and not isinstance(e, Text):
                    upd["cor"] = r.cor_ativa
                if isinstance(e, Rectangle) and e.proporcional and vals:
                    upd["escala_valor"] = max(vals[i], 0) / (max(vals) or 1)
                if isinstance(e, Ellipse) and e.fatia:
                    upd.update(inicio=sum(vals[:i]) / total, fim=sum(vals[: i + 1]) / total, fatia=False,
                               cor=COLORS_SLICES[i % len(COLORS_SLICES)])
                if isinstance(e, Text):
                    upd["conteudo"] = troca(e.conteudo)
                    if e.apos:
                        upd["apos"] = {"nome": names.get(e.apos.nome, e.apos.nome), "folga": e.apos.folga}
                    if e.unidade_de:
                        upd["unidade_de"] = names.get(e.unidade_de, e.unidade_de)
                els.append(type(e).model_validate({**e.model_dump(), **upd}))
            atraso = i * r.intervalo
            for a in r.animacoes:
                def mais(t, atraso=atraso):
                    if isinstance(t, (int, float)):
                        return t + atraso
                    return f"{t}+{atraso:g}" if atraso else t
                upd = {"alvo": names.get(a.alvo, a.alvo)}
                if hasattr(a, "t"):
                    upd["t"] = mais(a.t)
                if hasattr(a, "pares"):
                    upd["pares"] = [(mais(t), v) for t, v in a.pares]
                anims.append(type(a).model_validate({**a.model_dump(), **upd}))
        return els, anims

    def compilar(self) -> str:
        doc, lines = self.doc, []
        declared = {e.nome for e in walk(doc.elementos)}  # inclui os desligados por `se` dentro de caixas
        plans, extras = [], []
        for e in doc.elementos:
            if isinstance(e, Box):
                els, anims = self._resolver(e, self._regiao(self._el(e).regiao))
                plans += els
                extras += anims
            elif isinstance(e, Repeat):
                if self.ativo(e.se):
                    els, anims = self._desdobrar(e)
                    plans += els
                    extras += anims
            else:
                plans.append(e)
        for e in plans:
            if e.x is None or e.y is None:
                raise ErrorN1(f"{e.nome!r} sem posição: ponha o elemento dentro de uma caixa (ou dê x e y)")
        contados = {a.alvo for a in [*doc.animacoes, *extras] if a.anim == "contar"}
        plans = [e.model_copy(update={"numero": True}) if isinstance(e, Text) and e.nome in contados else e
                  for e in plans]  # `contar` num texto implica que ele é número
        plans = _sort(plans)
        doc = doc.model_copy(update={"elementos": plans, "animacoes": [*doc.animacoes, *extras]})
        self.nomes = {e.nome for e in plans}
        background = doc.fundo_tela_cheia if self.d.get("tela_cheia") else doc.fundo
        if background == "tela":
            lines.append("fundoTela();")
        elif background == "veu":
            lines.append(f"veuBaixo({_num(doc.opacidade_veu)});")
        for k, e in enumerate(doc.elementos):
            e = self._el(e)
            if not self.ativo(e.se):
                continue
            v = f"e{k}"
            self.vars[e.nome] = v
            lines += getattr(self, f"_{e.tipo}")(e, v)
        for a in doc.animacoes:
            if not self.ativo(a.se):
                continue
            if a.alvo not in self.vars:
                if any(x.nome == a.alvo for x in doc.elementos) or a.alvo in declared:
                    continue  # alvo desligado por `se`
                raise ErrorN1(f"animação de elemento inexistente: {a.alvo}")
            v = self.vars[a.alvo]
            lines += [f"if ({v}) {x}" for x in getattr(self, f"_{a.anim}")(a, v)]
        for name, (x0, y0, x1, y1) in self.limites.items():  # texto de caixa: não sai da própria célula
            if name in self.vars:
                lines.append(f"if ({self.vars[name]}) LIMITE[{self.vars[name]}.id] = "
                              f"[{_num(x0)}, {_num(y0)}, {_num(x1)}, {_num(y1)}];")
        if self.texts:  # texto máximo encolhe para caber na área segura (depois das animações, nos instantes medidos)
            lines.append(f"caber([{', '.join(self.texts)}]);")
        return "// peça gerada do N1 (esteira/n1/effectcraft.py)\n" + "\n".join(lines) + "\n"

    # ---------- elementos ----------

    def _texto(self, e: Text, v):
        s = self.texto(e.conteudo)
        if e.caps and e.largura is None:  # o bloco usa allCaps (o texto editável fica como foi escrito)
            s = s.upper()
        size = (e.tam or LEVELS[e.nivel or "corpo"]) * self.U
        x, m = e.x * self.W, self.m
        if e.largura is None:  # a âncora da linha fica dentro da área segura (o caber só encolhe em volta dela)
            x = min(max(x, m), self.W - m)  # (y não se move: empilharia textos; o portão acusa e a LLM corrige)
        else:  # o parágrafo cabe na largura útil
            x = min(max(x, m), self.W - m - 4 * size)
            width = min(e.largura * self.W, self.W - m - x)
            e = e.model_copy(update={"largura": width / self.W})
        self.texts.append(v)
        out = []
        if e.apos and e.apos.nome == e.nome:  # autorreferência: sem `apos`
            e = e.model_copy(update={"apos": None})
        exists = e.apos and e.apos.nome in self.nomes
        if e.apos and not exists:  # referência a texto que não existe: fica no próprio x
            e = e.model_copy(update={"apos": None})
        if e.apos and e.apos.nome not in self.vars:  # a referência está desligada por `se`: fica no próprio x
            e = e.model_copy(update={"apos": None})
        if e.apos:
            ref = self.vars[e.apos.nome]
            out.append(f"var r_{v} = {ref}.sourceRectAtTime(DUR, false);")
            x_js = (f"Math.min({_num(self.x_px[e.apos.nome])} + r_{v}.left + r_{v}.width + {_num(e.apos.folga * self.U)}, "
                    f"{_num(self.W - self.m - 3 * size)})")  # no fim da tela, a âncora fica onde o caber() ainda age
            s = re.sub(r"^\s+", "", s)
        else:
            x_js = _num(x)
        self.x_px[e.nome] = x
        style = {"papel": e.fonte, "peso": e.peso, "tam": round(size, 3), "cor": e.cor}
        if e.tracking:
            style["tracking"] = e.tracking
        if e.italico:
            style["italico"] = True
        if e.unidade_de and e.unidade_de not in self.numeros:  # não é texto-número: vira texto comum
            e = e.model_copy(update={"unidade_de": None})
        if e.unidade_de:  # só existe se o número tiver unidade (decidido no script, pelo valor dito)
            ref = self.vars.get(e.unidade_de)
            s_js = f"n_{ref}.depois.replace(/^\\s+/, \"\")"
            body = [l.replace(f"var r_{v}", f"  var r_{v}") for l in out]
            style["justify"] = "left"
            return [f"var {v} = null;", f"if (n_{ref} && n_{ref}.depois) {{", *body,
                    f"  {v} = linha({_js(e.nome)}, {s_js}, {x_js}, {_num(e.y * self.H)}, {_js(style)});", "}"]
        if e.numero:  # número dito → formato pt-BR; `contar` anima de 0 até ele
            self.numeros.add(e.nome)
            out += [f"var n_{v} = numero({_js(s)});",
                    f"var s_{v} = n_{v} ? n_{v}.antes + String(n_{v}.n.toFixed(n_{v}.casas)).replace(\".\", \",\")"
                    f".replace(/\\B(?=(\\d{{3}})+(?!\\d))/g, \".\") : {_js(s)};"]
            s_js = f"s_{v}"
        else:
            s_js = _js(s)
        if e.largura is None:
            style["justify"] = {"esquerda": "left", "centro": "center", "direita": "right"}[e.alinhar]
            out.append(f"var {v} = linha({_js(e.nome)}, {s_js}, {x_js}, {_num(e.y * self.H)}, {_js(style)});")
        else:
            style["alinhar"] = e.alinhar
            if e.caps:
                style["caps"] = True
            if e.entrelinha:
                style["entrelinha"] = e.entrelinha
            out.append(f"var {v} = bloco({_js(e.nome)}, {s_js}, {x_js}, {_num(e.y * self.H)}, "
                       f"{_num(e.largura * self.W)}, {_js(style)});")
        return out

    def _retangulo(self, e: Rectangle, v):
        w, h = e.w * self.U, e.h * self.U
        x = e.x * self.W - (w / 2 if e.centralizar else 0)
        self.x_px[e.nome] = x
        return [f"var {v} = retangulo({_js(e.nome)}, {_num(x)}, {_num(e.y * self.H)}, {_num(w)}, {_num(h)}, "
                f"{_js(e.cor)}, {_num(e.opacidade)}, {_num(e.raio * self.U)}, {_js(e.ancora_esq)});"]

    def _elipse(self, e: Ellipse, v):
        self.x_px[e.nome] = e.x * self.W - e.d * self.U / 2
        arc = e.inicio > 0 or e.fim < 1
        espessura = e.contorno or (0.2 * e.d if arc else 0)  # arco cheio não existe: vira anel
        contorno = _num(espessura * self.U) if espessura else "undefined"
        extra = f", {_num(round(e.inicio, 4))}, {_num(round(e.fim, 4))}" if arc else ""
        return [f"var {v} = elipse({_js(e.nome)}, {_num(e.x * self.W)}, {_num(e.y * self.H)}, {_num(e.d * self.U)}, "
                f"{_js(e.cor)}, {contorno}{extra});"]

    # ---------- animações ----------

    def _entrar(self, a: Enter, v):
        return [f"entrar({v}, {_js(a.de)}, {_num(self.tempo(a.t))}, {_num(self.dur(a.dur))});"]

    def _tracar(self, a: Plot, v):
        return [f"traco({v}, {_num(self.tempo(a.t))}, {_num(self.dur(a.dur))}{', true' if a.vertical else ''});"]

    def _contar(self, a: Count, v):
        if a.alvo not in self.numeros:
            raise ErrorN1(f"`contar` só em texto com numero=true: {a.alvo}")
        return [f"if (n_{v}) contagem({v}, n_{v}.n, n_{v}.casas, {_num(self.tempo(a.t))}, {_num(self.dur(a.dur))}, "
                f"n_{v}.antes, \"\");"]

    def _valor(self, prop, val, everything):
        """Normaliza o que modelos escrevem de jeitos diferentes: escala como fator ou número, opacidade 0–1,
        posição em frações da tela."""
        if prop == "escala":
            vs = val if isinstance(val, list) else [val, val]
            return [round(x * 100 if x <= 10 else x, 2) for x in vs[:2]]
        if prop == "opacidade":
            x = val[0] if isinstance(val, list) else val
            return round(x * 100, 2) if max(abs(y if not isinstance(y, list) else y[0]) for y in everything) <= 1 else x
        if prop == "posicao":
            vs = val if isinstance(val, list) else [val, val]
            if all(abs(x) <= 1.5 for x in vs[:2]):
                return [round(vs[0] * self.W, 1), round(vs[1] * self.H, 1)]
            return vs[:2]
        return val[0] if isinstance(val, list) else val

    def _chaves(self, a: Keys, v):
        everything = [val for _, val in a.pares]
        pairs = [[round(self.tempo(t), 3), self._valor(a.prop, val, everything)] for t, val in a.pares]
        return [f"chaves(tr({v}, {_js(_PROP[a.prop])}), {_js(pairs)});"]

    def _desfocar(self, a: Blur, v):
        return [f"desfoque({v}, {_js([[round(self.tempo(t), 3), val] for t, val in a.pares])});"]


COLORS_SLICES = ("destaque", "acento", "apoio", "texto", "fundo2")
LEVELS = {"titulo": 0.065, "destaque": 0.09, "numero": 0.15, "corpo": 0.045, "rotulo": 0.034}  # fração do lado menor
# regiões (x, y, w, h) em frações da tela, já dentro da área segura
REGIONS_H = {"tela": (0.06, 0.08, 0.88, 0.84), "topo": (0.06, 0.07, 0.88, 0.17), "centro": (0.06, 0.27, 0.88, 0.5),
             "base": (0.06, 0.79, 0.88, 0.14), "esquerda": (0.06, 0.27, 0.42, 0.66),
             "direita": (0.52, 0.27, 0.42, 0.66)}
REGIONS_V = {"tela": (0.07, 0.06, 0.86, 0.88), "topo": (0.07, 0.06, 0.86, 0.13), "centro": (0.07, 0.23, 0.86, 0.52),
             "base": (0.07, 0.80, 0.86, 0.12), "esquerda": (0.07, 0.22, 0.86, 0.34),
             "direita": (0.07, 0.58, 0.86, 0.34)}


def walk(els):
    """Todos os nós do documento (caixas, repetir e o que está dentro deles), em profundidade."""
    for e in els:
        yield e
        if isinstance(e, Box):
            yield from walk(e.filhos)
        elif isinstance(e, Repeat):
            yield from e.elementos


def loose(doc: "Piece") -> list[str]:
    """Elementos fora de caixa (a LLM local só monta peça por caixas: coordenada absoluta era a causa dos erros)."""
    return [e.nome for e in doc.elementos if not isinstance(e, Box)]


def _number(v) -> float | None:
    """ "34%", "R$ 1.200", "1,5" → número (pt-BR)."""
    if isinstance(v, (int, float)):
        return float(v)
    m = re.search(r"-?\d[\d.]*(?:,\d+)?", str(v or ""))
    return float(m.group(0).replace(".", "").replace(",", ".")) if m else None


def _sort(els: list) -> list:
    """Elementos referenciados por `apos`/`unidade_de` vêm antes de quem os usa (ordem estável no resto)."""
    done, output, pending = set(), [], list(els)
    for _ in range(len(els) + 1):
        rest = []
        for e in pending:
            deps = {x for x in (getattr(e, "apos", None) and e.apos.nome, getattr(e, "unidade_de", None)) if x}
            deps &= {x.nome for x in els} - {e.nome}
            (output.append(e) or done.add(e.nome)) if deps <= done else rest.append(e)
        if not rest or len(rest) == len(pending):
            return output + rest  # ciclo: mantém a ordem (o compilador acusa a referência)
        pending = rest
    return output


def build(doc: Piece | dict, d: dict) -> str:
    return Compiler(doc, d).compilar()
