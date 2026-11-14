"""N1 do PhotoCraft: documento declarativo (thumb e tratamento de foto) e o executor N1 → `photocraft-cli run`.

Layout relacional: o título se centraliza na vertical e o selo fica acima dele; o executor mede o texto
(`type.info`) e faz a segunda passagem, o modelo nunca calcula pixels. Tamanhos e posições em frações da tela.
Cores por papel (`texto`, `destaque`, `alerta`, `preto`); nas caixas livres do editor também se aceita hex.

O tratamento das fotos dos vídeos segue a **receita fixa do canal** (`[foto]` do perfil); o modelo só decide
`FotoDecisao` (N2: foco, recortar, separar planos) e `tratamento()` monta as operações.
"""
from pathlib import Path
from typing import Annotated, Literal

from pydantic import BaseModel, Field

APP = "photocraft"
VERSION = 1

Color = Annotated[str, Field(pattern=r"^(texto|destaque|alerta|preto|#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?)$")]
SOURCES = {"corpo": "InterVar", "serifa": "Playfair Display", "mono": "JetBrains Mono"}
WEIGHTS = {100: "Thin", 200: "ExtraLight", 300: "Light", 400: "Regular", 500: "Medium", 600: "SemiBold",
         700: "Bold", 800: "ExtraBold", 900: "Black"}
LUTS = Literal["warm", "cool", "tealOrange", "bleachBypass", "fadedFilm", "dayForNight", "monoContrast",
               "crossProcess"]


class _El(BaseModel):
    model_config = {"extra": "forbid"}


class Document(_El):
    uso: Literal["thumb", "vertical", "foto"] = "thumb"
    largura: int = 1280
    altura: int = 720


class Image(_El):
    tipo: Literal["imagem"]
    nome: str = "Fundo"
    midia: str
    ajuste: Literal["cobrir", "conter"] = "cobrir"


class Adjustment(_El):
    tipo: Literal["ajuste"]
    ajuste: Literal["brilho_contraste", "saturacao", "lut"]
    brilho: float = 0
    contraste: float = 0
    saturacao: float = 0
    lut: LUTS | None = None


class Vinheta(_El):
    tipo: Literal["vinheta"]
    lado: Literal["esquerda", "direita"] | None = Field(None, description="lado escurecido (o do texto)")
    bordas: bool = True


class Arrow(_El):
    tipo: Literal["seta"]
    lado: Literal["esquerda", "direita"] = Field(description="lado do texto; a seta aponta para o centro")
    cor: Color = "alerta"


class Title(_El):
    tipo: Literal["titulo"]
    conteudo: str = Field(description="palavras em *destaque* entre asteriscos")
    tamanho: float = Field(gt=0, le=0.5, description="fração da altura")
    largura: float = Field(0.5, gt=0, le=1, description="fração da largura")
    lado: Literal["esquerda", "direita"] = "esquerda"
    cor: Color = "texto"
    destaque: Color = "destaque"


class Badge(_El):
    tipo: Literal["selo"]
    conteudo: str = Field(max_length=24)
    fundo: Color = "alerta"


class Box(_El):
    tipo: Literal["caixa"]
    conteudo: str
    pos: tuple[float, float] = Field(description="canto superior esquerdo em frações")
    largura: float = Field(gt=0, le=1)
    tamanho: float = Field(gt=0, le=0.5, description="fração da altura")
    fonte: Literal["corpo", "serifa", "mono"] = "corpo"
    peso: int = Field(800, ge=100, le=900)
    cor: Color = "#f4f1ea"
    destaque: Color | None = None
    maiusculas: bool = False
    alinhar: Literal["esquerda", "centro", "direita"] = "esquerda"
    fundo: Literal["nenhum", "contorno", "solido", "vidro", "tarja"] = "nenhum"
    cor_fundo: Color = "#0a1122"


# Tratamento de foto (receita do canal)
class CropSubject(_El):
    tipo: Literal["recortar_sujeito"]


class Reframe(_El):
    tipo: Literal["reenquadrar"]
    formato: Literal["16:9", "9:16", "1:1"]
    foco: tuple[float, float] = (0.5, 0.5)


class Sharpness(_El):
    tipo: Literal["nitidez"]
    intensidade: float = Field(0.3, ge=0, le=1)


class Grain(_El):
    tipo: Literal["grao"]
    intensidade: float = Field(0.15, ge=0, le=1)


class BlurBackground(_El):
    tipo: Literal["desfocar_fundo"]
    intensidade: float = Field(0.3, ge=0, le=1)


Element = Annotated[Image | Adjustment | Vinheta | Arrow | Title | Badge | Box | CropSubject | Reframe
                     | Sharpness | Grain | BlurBackground, Field(discriminator="tipo")]


class Variant(_El):
    nome: str
    titulo: str | None = None
    selo: str | None = None


class Composition(BaseModel):
    versao: Literal[1] = 1
    documento: Document = Document()
    elementos: list[Element]
    variantes: list[Variant] = Field(default_factory=list)


DOCUMENT = Composition


class PhotoDecision(BaseModel):
    """N2 da tarefa `foto_tratar`: o que o modelo decide; o resto é a receita do canal."""
    foco: tuple[float, float] = (0.5, 0.5)
    recortar: bool = False
    separar_planos: bool = False


class ErrorN1(ValueError):
    pass


def _highlights(s, cor):
    """*destaque* → (texto sem marcas, runs com a cor)."""
    out, runs, start = "", [], None
    for ch in s:
        if ch == "*":
            if start is None:
                start = len(out)
            else:
                runs.append({"start": start, "end": len(out), "color": cor})
                start = None
            continue
        out += ch
    return out, runs


def _bounds(info):
    """bounds [x0, y0, x1, y1] das respostas do PhotoCraft → (x, y, largura, altura)."""
    x0, y0, x1, y1 = info.get("bounds") or [0, 0, 0, 0]
    return x0, y0, x1 - x0, y1 - y0


class Executor:
    """Aplica uma `Composicao` com `rodar(origem, passos, destino)` (o `photocraft._run`). `midias`: ref → caminho;
    `cores`: papel → hex; `tamanho_imagem(caminho)` → (w, h). `rastro` guarda as duas passagens."""

    def __init__(self, run, medias: dict, colors: dict, size_image):
        self.rodar, self.midias, self.cores, self.tamanho_imagem = run, medias, colors, size_image
        self.rastro: list[list] = []

    def cor(self, c):
        return c if c.startswith("#") else self.cores[c]

    def executar(self, doc: Composition | dict, destino: Path) -> Path:
        doc = doc if isinstance(doc, Composition) else Composition.model_validate(doc)
        w, h = doc.documento.largura, doc.documento.altura
        els = doc.elementos
        tit = next((e for e in els if isinstance(e, Title)), None)
        badge = next((e for e in els if isinstance(e, Badge)), None)
        steps, layers, x_tit = [], {}, 56
        for e in els:
            if isinstance(e, Image):
                path = str(self.midias[e.midia]).replace("file://", "")
                iw, ih = self.tamanho_imagem(path)
                f = max(w / iw, h / ih) if e.ajuste == "cobrir" else min(w / iw, h / ih)
                steps += [("file.placeEmbedded", {"path": path, "fit": False, "scale": round(f * 100, 3),
                                                   "center": [w / 2, h / 2]}),
                           ("layer.renameLayer", {"name": e.nome})]
            elif isinstance(e, Adjustment):
                if e.ajuste == "brilho_contraste":
                    steps += [("layer.newAdjustmentLayer.brightnessContrast",
                                {"brightness": e.brilho, "contrast": e.contraste}),
                               ("layer.renameLayer", {"name": "Ajuste: contraste"})]
                elif e.ajuste == "saturacao":
                    steps += [("layer.newAdjustmentLayer.hueSaturation", {"saturation": e.saturacao}),
                               ("layer.renameLayer", {"name": "Ajuste: saturação"})]
                else:
                    steps += [("layer.newAdjustmentLayer.colorLookup", {"lut": e.lut or "none"}),
                               ("layer.renameLayer", {"name": "Ajuste: look"})]
            elif isinstance(e, Vinheta):
                if e.lado:  # escurece o lado do texto (degradê linear)
                    steps += [("shape.create", {"kind": "rect", "rect": [0, 0, w, h], "name": "Vinheta lateral",
                                                 "stroke": None, "fill": {"gradient": {
                                                     "stops": [[0, "#000000e0"], [0.38, "#0000008c"], [0.62, "#00000000"]],
                                                     "angle": 180 if e.lado == "direita" else 0, "style": "linear"}}})]
                if e.bordas:
                    steps += [("shape.create", {"kind": "rect", "rect": [0, 0, w, h], "name": "Vinheta das bordas",
                                                 "stroke": None, "fill": {"gradient": {
                                                     "stops": [[0.3, "#00000000"], [1, "#000000c7"]], "scale": 150,
                                                     "style": "radial"}}})]
            elif isinstance(e, Arrow):
                esq = e.lado == "direita"  # texto à direita: rosto à esquerda, seta espelhada
                x0 = w - 660 - 220 if esq else 660
                sx = -1.1 if esq else 1.1

                def pt(x, y, x0=x0, sx=sx, esq=esq):
                    return [round(x0 + (220 if esq else 0) + x * sx, 1), round(150 + y * 1.1, 1)]
                steps += [("shape.create", {"kind": "path", "name": "Seta", "fill": None,
                                             "stroke": {"width": 16, "color": self.cor(e.cor), "cap": "round",
                                                        "join": "round"},
                                             "path": {"subpaths": [
                                                 {"closed": False, "knots": [
                                                     {"anchor": pt(20, 30), "out": pt(90, 40), "in": pt(20, 30)},
                                                     {"anchor": pt(150, 150), "in": pt(130, 80), "out": pt(150, 150)}]},
                                                 {"closed": False, "knots": [pt(118, 140), pt(152, 160), pt(166, 118)]}]}})]
            elif isinstance(e, Title):
                size = round(e.tamanho * h)
                width = round(e.largura * w)
                x_tit = w - 56 - width if e.lado == "direita" else 56
                text, runs = _highlights(e.conteudo, self.cor(e.destaque))
                if not text:
                    continue
                steps += [("type.create", {"box": [x_tit, 0, width, h], "text": text, "name": "Título",
                                            "font": "InterVar", "fontStyle": "Black", "size": size,
                                            "color": self.cor(e.cor), "leading": round(size * 0.92), "tracking": -35,
                                            "align": "right" if e.lado == "direita" else "left"})]
                if runs:
                    steps += [("type.edit", {"runs": runs})]
                steps += [("layer.layerStyle.stroke", {"size": max(2, round(size * 0.06)), "position": "outside",
                                                        "color": "#000000"}),
                           ("layer.layerStyle.dropShadow", {"color": "#000000", "opacity": 55, "distance": 10, "size": 0,
                                                            "angle": 90, "useGlobalLight": False, "add": True}),
                           ("layer.layerStyle.outerGlow", {"color": "#000000", "opacity": 80, "blend": "multiply",
                                                           "size": 60, "add": True}),
                           ("type.info", {})]
                layers["titulo"] = len(steps) - 1
            elif isinstance(e, Badge):
                x_badge = (w - 56 - round(tit.largura * w) if tit.lado == "direita" else 56) if tit else 56
                steps += [("type.create", {"x": x_badge + 18, "y": 100, "text": e.conteudo, "name": "Selo (texto)",
                                            "font": "InterVar", "fontStyle": "Black", "size": 44, "color": "#000000",
                                            "tracking": -20}),
                           ("type.info", {})]
                layers["selo"] = len(steps) - 1
            elif isinstance(e, Box):
                k = sum(1 for c in layers if c.startswith("caixa"))
                t, rs = _highlights(e.conteudo, self.cor(e.destaque or "destaque"))
                if e.maiusculas:
                    t = t.upper()
                size = round(e.tamanho * h)
                cx, cy, cw = w * e.pos[0], h * e.pos[1], w * e.largura
                steps += [("type.create", {"box": [round(cx), round(cy), round(cw), h], "text": t or " ",
                                            "name": f"Caixa {k + 1}", "font": SOURCES[e.fonte],
                                            "fontStyle": WEIGHTS.get(e.peso, "ExtraBold"), "size": size,
                                            "color": self.cor(e.cor), "leading": round(size * 1.12),
                                            "align": {"centro": "center", "direita": "right"}.get(e.alinhar, "left")})]
                if rs:
                    steps += [("type.edit", {"runs": rs})]
                if e.fundo == "contorno":
                    steps += [("layer.layerStyle.stroke", {"size": max(2, round(size * 0.07)), "position": "outside",
                                                            "color": "#000000"})]
                elif e.fundo == "nenhum":
                    steps += [("layer.layerStyle.dropShadow", {"color": "#000000", "opacity": 75, "distance": 3,
                                                                "size": 18})]
                steps += [("type.info", {})]
                layers[f"caixa{k}"] = (len(steps) - 1, e)
            else:
                steps += self._tratamento(e, w, h)
        if doc.variantes:
            steps += [("layerComp.new", {"name": "A"})]
        self.rastro.append(steps)
        res = self.rodar({"width": w, "height": h, "name": Path(destino).stem}, steps, destino)

        # segunda passagem: centraliza o título, põe o selo acima dele e os fundos atrás das caixas
        adjustment = []
        if "titulo" in layers:
            info = res[layers["titulo"]]
            bx, by, bw, bh = _bounds(info)
            alto_badge = 80 if badge else 0
            dy = round(h / 2 - (by + bh / 2) - h * 0.02 + alto_badge / 2)
            adjustment += [("type.edit", {"layer": info["layer"], "move": [0, dy]})]
            if "selo" in layers:
                si = res[layers["selo"]]
                sx, sy, sw, sh = _bounds(si)
                top = by + dy - 18 - (sh + 22)
                adjustment += [("type.edit", {"layer": si["layer"], "move": [0, round(top + 10 - sy)]}),
                           ("shape.create", {"kind": "rect", "rect": [x_tit, round(top), round(sw + 36), round(sh + 22)],
                                             "fill": self.cor(badge.fundo), "stroke": None, "name": "Selo (fundo)"}),
                           ("layer.moveTo", {"target": si["layer"], "position": "below"}),
                           ("layer.select", {"layer": si["layer"], "mode": "add"}),
                           ("edit.transform", {"rotate": -3})]
        for key, v in layers.items():
            if not key.startswith("caixa") or v[1].fundo not in ("solido", "vidro", "tarja"):
                continue
            info, c = res[v[0]], v[1]
            bx, by, bw, bh = _bounds(info)
            size = round(c.tamanho * h)
            m = round(size * 0.3)
            color = "#080c189e" if c.fundo == "vidro" else self.cor(c.cor_fundo)  # vidro: 62% de opacidade
            adjustment += [("shape.create", {"kind": "roundedRect" if c.fundo == "vidro" else "rect", "radii": 8,
                                         "rect": [bx - m, by - m // 2, bw + 2 * m, bh + m], "fill": color, "stroke": None,
                                         "name": f"Fundo da {info.get('name', 'caixa')}"}),
                       ("layer.moveTo", {"target": info["layer"], "position": "below"})]
            if c.fundo == "tarja":
                adjustment += [("shape.create", {"kind": "rect", "rect": [bx - m, by - m // 2, round(size * 0.14), bh + m],
                                             "fill": self.cor("destaque"), "stroke": None, "name": "Tarja"})]
        adjustment += self._variantes(doc, res, layers)
        if adjustment:
            self.rastro.append(adjustment)
            self.rodar(destino, adjustment, destino)
        return Path(destino)

    def _variantes(self, doc, res, layers):
        """Cada variante troca textos e vira um layer comp (o A/B fica no mesmo `.pcraft`); volta ao A no fim."""
        if not doc.variantes:
            return []
        steps = []
        for v in doc.variantes:
            if v.titulo is not None and "titulo" in layers:
                t, runs = _highlights(v.titulo, self.cor("destaque"))
                steps += [("type.edit", {"layer": res[layers["titulo"]]["layer"], "text": t, "runs": runs})]
            if v.selo is not None and "selo" in layers:
                steps += [("type.edit", {"layer": res[layers["selo"]]["layer"], "text": v.selo})]
            steps += [("layerComp.new", {"name": v.nome})]
        return steps + [("layerComp.apply", {"comp": "A"})]

    def _tratamento(self, e, w, h):
        if isinstance(e, CropSubject):
            return [("layer.removeBackground", {"refine": True})]
        if isinstance(e, Reframe):
            rw, rh = {"16:9": (16, 9), "9:16": (9, 16), "1:1": (1, 1)}[e.formato]
            cw, ch = (w, round(w * rh / rw)) if w * rh / rw <= h else (round(h * rw / rh), h)
            x = min(max(round(e.foco[0] * w - cw / 2), 0), w - cw)
            y = min(max(round(e.foco[1] * h - ch / 2), 0), h - ch)
            return [("image.crop", {"x": x, "y": y, "width": cw, "height": ch})]
        if isinstance(e, Sharpness):
            return [("filter.sharpen.smartSharpen", {"amount": round(40 + 160 * e.intensidade), "radius": 1,
                                                     "reduceNoise": 10})]
        if isinstance(e, Grain):
            return [("filter.gallery.grain", {"intensity": round(100 * e.intensidade), "contrast": 50,
                                              "grainType": "soft"})]
        if isinstance(e, BlurBackground):
            return [("select.subject", {}), ("select.inverse", {}),
                    ("filter.blur.smartBlur", {"radius": round(2 + 30 * e.intensidade, 1), "threshold": 25,
                                               "quality": "high", "mode": "normal"})]
        raise ErrorN1(f"elemento sem executor: {e.tipo}")


def of_data_thumb(d: dict, w: int, h: int) -> Composition:
    """Dados do modelo `thumb` (`thumbs.data_thumb`) → N1. Ponte do formato antigo do editor/etapa."""
    esq = d["layout"] == "rosto_esquerda"
    side = "direita" if esq else "esquerda"
    els: list[dict] = [
        {"tipo": "imagem", "midia": "fundo"},
        {"tipo": "ajuste", "ajuste": "brilho_contraste", "brilho": -8, "contraste": 18},
        {"tipo": "ajuste", "ajuste": "saturacao", "saturacao": 15},
        {"tipo": "vinheta", "lado": side, "bordas": True},
    ]
    if d.get("seta"):
        els.append({"tipo": "seta", "lado": side})
    title = " ".join(f"*{p['t']}*" if p["d"] else p["t"] for p in d.get("palavras") or [])
    if title:
        els.append({"tipo": "titulo", "conteudo": title, "tamanho": d["tamanho"] / h,
                    "largura": (1160 if d["layout"] == "numero" else 640) / w, "lado": side})
    if d.get("selo"):
        els.append({"tipo": "selo", "conteudo": d["selo"]})
    for c in d.get("caixas") or []:
        source = {"Inter": "corpo", "Playfair": "serifa", "Mono": "mono"}.get(c.get("fonte", "Inter"), "corpo")
        els.append({"tipo": "caixa", "conteudo": c.get("texto", ""), "pos": (c["x"] / 100, c["y"] / 100),
                    "largura": c["w"] / 100, "tamanho": c.get("tam", 64) / h, "fonte": source,
                    "peso": c.get("peso", 800), "cor": c.get("cor", "#f4f1ea"), "destaque": c.get("cor_d"),
                    "maiusculas": bool(c.get("maiusculas")),
                    "alinhar": {"center": "centro", "right": "direita"}.get(c.get("alinhar"), "esquerda"),
                    "fundo": c.get("fundo", "nenhum"), "cor_fundo": c.get("cor_fundo", "#0a1122")})
    return Composition.model_validate({"documento": {"uso": "thumb", "largura": w, "altura": h}, "elementos": els})


def treatment(recipe: dict, decision: PhotoDecision, fmt: str, w: int, h: int) -> Composition:
    """Receita fixa do canal (`[foto]` do perfil) + decisão N2 → composição de tratamento da foto."""
    els: list[dict] = [{"tipo": "imagem", "nome": "Foto", "midia": "foto", "ajuste": "conter"}]
    if recipe.get("reenquadrar", True):
        els.append({"tipo": "reenquadrar", "formato": fmt, "foco": decision.foco})
    if recipe.get("lut"):
        els.append({"tipo": "ajuste", "ajuste": "lut", "lut": recipe["lut"]})
    if recipe.get("contraste") or recipe.get("brilho"):
        els.append({"tipo": "ajuste", "ajuste": "brilho_contraste", "brilho": recipe.get("brilho", 0),
                    "contraste": recipe.get("contraste", 0)})
    if recipe.get("saturacao"):
        els.append({"tipo": "ajuste", "ajuste": "saturacao", "saturacao": recipe["saturacao"]})
    if recipe.get("nitidez"):
        els.append({"tipo": "nitidez", "intensidade": recipe["nitidez"]})
    if recipe.get("grao"):
        els.append({"tipo": "grao", "intensidade": recipe["grao"]})
    if decision.separar_planos and recipe.get("desfoque_fundo"):
        els.append({"tipo": "desfocar_fundo", "intensidade": recipe["desfoque_fundo"]})
    if decision.recortar:
        els.append({"tipo": "recortar_sujeito"})
    return Composition.model_validate({"documento": {"uso": "foto", "largura": w, "altura": h}, "elementos": els})
