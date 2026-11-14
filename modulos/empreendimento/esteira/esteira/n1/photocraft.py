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
VERSAO = 1

Cor = Annotated[str, Field(pattern=r"^(texto|destaque|alerta|preto|#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?)$")]
FONTES = {"corpo": "InterVar", "serifa": "Playfair Display", "mono": "JetBrains Mono"}
PESOS = {100: "Thin", 200: "ExtraLight", 300: "Light", 400: "Regular", 500: "Medium", 600: "SemiBold",
         700: "Bold", 800: "ExtraBold", 900: "Black"}
LUTS = Literal["warm", "cool", "tealOrange", "bleachBypass", "fadedFilm", "dayForNight", "monoContrast",
               "crossProcess"]


class _El(BaseModel):
    model_config = {"extra": "forbid"}


class Documento(_El):
    uso: Literal["thumb", "vertical", "foto"] = "thumb"
    largura: int = 1280
    altura: int = 720


class Imagem(_El):
    tipo: Literal["imagem"]
    nome: str = "Fundo"
    midia: str
    ajuste: Literal["cobrir", "conter"] = "cobrir"


class Ajuste(_El):
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


class Seta(_El):
    tipo: Literal["seta"]
    lado: Literal["esquerda", "direita"] = Field(description="lado do texto; a seta aponta para o centro")
    cor: Cor = "alerta"


class Titulo(_El):
    tipo: Literal["titulo"]
    conteudo: str = Field(description="palavras em *destaque* entre asteriscos")
    tamanho: float = Field(gt=0, le=0.5, description="fração da altura")
    largura: float = Field(0.5, gt=0, le=1, description="fração da largura")
    lado: Literal["esquerda", "direita"] = "esquerda"
    cor: Cor = "texto"
    destaque: Cor = "destaque"


class Selo(_El):
    tipo: Literal["selo"]
    conteudo: str = Field(max_length=24)
    fundo: Cor = "alerta"


class Caixa(_El):
    tipo: Literal["caixa"]
    conteudo: str
    pos: tuple[float, float] = Field(description="canto superior esquerdo em frações")
    largura: float = Field(gt=0, le=1)
    tamanho: float = Field(gt=0, le=0.5, description="fração da altura")
    fonte: Literal["corpo", "serifa", "mono"] = "corpo"
    peso: int = Field(800, ge=100, le=900)
    cor: Cor = "#f4f1ea"
    destaque: Cor | None = None
    maiusculas: bool = False
    alinhar: Literal["esquerda", "centro", "direita"] = "esquerda"
    fundo: Literal["nenhum", "contorno", "solido", "vidro", "tarja"] = "nenhum"
    cor_fundo: Cor = "#0a1122"


# Tratamento de foto (receita do canal)
class RecortarSujeito(_El):
    tipo: Literal["recortar_sujeito"]


class Reenquadrar(_El):
    tipo: Literal["reenquadrar"]
    formato: Literal["16:9", "9:16", "1:1"]
    foco: tuple[float, float] = (0.5, 0.5)


class Nitidez(_El):
    tipo: Literal["nitidez"]
    intensidade: float = Field(0.3, ge=0, le=1)


class Grao(_El):
    tipo: Literal["grao"]
    intensidade: float = Field(0.15, ge=0, le=1)


class DesfocarFundo(_El):
    tipo: Literal["desfocar_fundo"]
    intensidade: float = Field(0.3, ge=0, le=1)


Elemento = Annotated[Imagem | Ajuste | Vinheta | Seta | Titulo | Selo | Caixa | RecortarSujeito | Reenquadrar
                     | Nitidez | Grao | DesfocarFundo, Field(discriminator="tipo")]


class Variante(_El):
    nome: str
    titulo: str | None = None
    selo: str | None = None


class Composicao(BaseModel):
    versao: Literal[1] = 1
    documento: Documento = Documento()
    elementos: list[Elemento]
    variantes: list[Variante] = Field(default_factory=list)


DOCUMENTO = Composicao


class FotoDecisao(BaseModel):
    """N2 da tarefa `foto_tratar`: o que o modelo decide; o resto é a receita do canal."""
    foco: tuple[float, float] = (0.5, 0.5)
    recortar: bool = False
    separar_planos: bool = False


class ErroN1(ValueError):
    pass


def _destaques(s, cor):
    """*destaque* → (texto sem marcas, runs com a cor)."""
    out, runs, ini = "", [], None
    for ch in s:
        if ch == "*":
            if ini is None:
                ini = len(out)
            else:
                runs.append({"start": ini, "end": len(out), "color": cor})
                ini = None
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

    def __init__(self, rodar, midias: dict, cores: dict, tamanho_imagem):
        self.rodar, self.midias, self.cores, self.tamanho_imagem = rodar, midias, cores, tamanho_imagem
        self.rastro: list[list] = []

    def cor(self, c):
        return c if c.startswith("#") else self.cores[c]

    def executar(self, doc: Composicao | dict, destino: Path) -> Path:
        doc = doc if isinstance(doc, Composicao) else Composicao.model_validate(doc)
        w, h = doc.documento.largura, doc.documento.altura
        els = doc.elementos
        tit = next((e for e in els if isinstance(e, Titulo)), None)
        selo = next((e for e in els if isinstance(e, Selo)), None)
        passos, camadas, x_tit = [], {}, 56
        for e in els:
            if isinstance(e, Imagem):
                caminho = str(self.midias[e.midia]).replace("file://", "")
                iw, ih = self.tamanho_imagem(caminho)
                f = max(w / iw, h / ih) if e.ajuste == "cobrir" else min(w / iw, h / ih)
                passos += [("file.placeEmbedded", {"path": caminho, "fit": False, "scale": round(f * 100, 3),
                                                   "center": [w / 2, h / 2]}),
                           ("layer.renameLayer", {"name": e.nome})]
            elif isinstance(e, Ajuste):
                if e.ajuste == "brilho_contraste":
                    passos += [("layer.newAdjustmentLayer.brightnessContrast",
                                {"brightness": e.brilho, "contrast": e.contraste}),
                               ("layer.renameLayer", {"name": "Ajuste: contraste"})]
                elif e.ajuste == "saturacao":
                    passos += [("layer.newAdjustmentLayer.hueSaturation", {"saturation": e.saturacao}),
                               ("layer.renameLayer", {"name": "Ajuste: saturação"})]
                else:
                    passos += [("layer.newAdjustmentLayer.colorLookup", {"lut": e.lut or "none"}),
                               ("layer.renameLayer", {"name": "Ajuste: look"})]
            elif isinstance(e, Vinheta):
                if e.lado:  # escurece o lado do texto (degradê linear)
                    passos += [("shape.create", {"kind": "rect", "rect": [0, 0, w, h], "name": "Vinheta lateral",
                                                 "stroke": None, "fill": {"gradient": {
                                                     "stops": [[0, "#000000e0"], [0.38, "#0000008c"], [0.62, "#00000000"]],
                                                     "angle": 180 if e.lado == "direita" else 0, "style": "linear"}}})]
                if e.bordas:
                    passos += [("shape.create", {"kind": "rect", "rect": [0, 0, w, h], "name": "Vinheta das bordas",
                                                 "stroke": None, "fill": {"gradient": {
                                                     "stops": [[0.3, "#00000000"], [1, "#000000c7"]], "scale": 150,
                                                     "style": "radial"}}})]
            elif isinstance(e, Seta):
                esq = e.lado == "direita"  # texto à direita: rosto à esquerda, seta espelhada
                x0 = w - 660 - 220 if esq else 660
                sx = -1.1 if esq else 1.1

                def pt(x, y, x0=x0, sx=sx, esq=esq):
                    return [round(x0 + (220 if esq else 0) + x * sx, 1), round(150 + y * 1.1, 1)]
                passos += [("shape.create", {"kind": "path", "name": "Seta", "fill": None,
                                             "stroke": {"width": 16, "color": self.cor(e.cor), "cap": "round",
                                                        "join": "round"},
                                             "path": {"subpaths": [
                                                 {"closed": False, "knots": [
                                                     {"anchor": pt(20, 30), "out": pt(90, 40), "in": pt(20, 30)},
                                                     {"anchor": pt(150, 150), "in": pt(130, 80), "out": pt(150, 150)}]},
                                                 {"closed": False, "knots": [pt(118, 140), pt(152, 160), pt(166, 118)]}]}})]
            elif isinstance(e, Titulo):
                tam = round(e.tamanho * h)
                larg = round(e.largura * w)
                x_tit = w - 56 - larg if e.lado == "direita" else 56
                texto, runs = _destaques(e.conteudo, self.cor(e.destaque))
                if not texto:
                    continue
                passos += [("type.create", {"box": [x_tit, 0, larg, h], "text": texto, "name": "Título",
                                            "font": "InterVar", "fontStyle": "Black", "size": tam,
                                            "color": self.cor(e.cor), "leading": round(tam * 0.92), "tracking": -35,
                                            "align": "right" if e.lado == "direita" else "left"})]
                if runs:
                    passos += [("type.edit", {"runs": runs})]
                passos += [("layer.layerStyle.stroke", {"size": max(2, round(tam * 0.06)), "position": "outside",
                                                        "color": "#000000"}),
                           ("layer.layerStyle.dropShadow", {"color": "#000000", "opacity": 55, "distance": 10, "size": 0,
                                                            "angle": 90, "useGlobalLight": False, "add": True}),
                           ("layer.layerStyle.outerGlow", {"color": "#000000", "opacity": 80, "blend": "multiply",
                                                           "size": 60, "add": True}),
                           ("type.info", {})]
                camadas["titulo"] = len(passos) - 1
            elif isinstance(e, Selo):
                x_selo = (w - 56 - round(tit.largura * w) if tit.lado == "direita" else 56) if tit else 56
                passos += [("type.create", {"x": x_selo + 18, "y": 100, "text": e.conteudo, "name": "Selo (texto)",
                                            "font": "InterVar", "fontStyle": "Black", "size": 44, "color": "#000000",
                                            "tracking": -20}),
                           ("type.info", {})]
                camadas["selo"] = len(passos) - 1
            elif isinstance(e, Caixa):
                k = sum(1 for c in camadas if c.startswith("caixa"))
                t, rs = _destaques(e.conteudo, self.cor(e.destaque or "destaque"))
                if e.maiusculas:
                    t = t.upper()
                tam = round(e.tamanho * h)
                cx, cy, cw = w * e.pos[0], h * e.pos[1], w * e.largura
                passos += [("type.create", {"box": [round(cx), round(cy), round(cw), h], "text": t or " ",
                                            "name": f"Caixa {k + 1}", "font": FONTES[e.fonte],
                                            "fontStyle": PESOS.get(e.peso, "ExtraBold"), "size": tam,
                                            "color": self.cor(e.cor), "leading": round(tam * 1.12),
                                            "align": {"centro": "center", "direita": "right"}.get(e.alinhar, "left")})]
                if rs:
                    passos += [("type.edit", {"runs": rs})]
                if e.fundo == "contorno":
                    passos += [("layer.layerStyle.stroke", {"size": max(2, round(tam * 0.07)), "position": "outside",
                                                            "color": "#000000"})]
                elif e.fundo == "nenhum":
                    passos += [("layer.layerStyle.dropShadow", {"color": "#000000", "opacity": 75, "distance": 3,
                                                                "size": 18})]
                passos += [("type.info", {})]
                camadas[f"caixa{k}"] = (len(passos) - 1, e)
            else:
                passos += self._tratamento(e, w, h)
        if doc.variantes:
            passos += [("layerComp.new", {"name": "A"})]
        self.rastro.append(passos)
        res = self.rodar({"width": w, "height": h, "name": Path(destino).stem}, passos, destino)

        # segunda passagem: centraliza o título, põe o selo acima dele e os fundos atrás das caixas
        ajuste = []
        if "titulo" in camadas:
            info = res[camadas["titulo"]]
            bx, by, bw, bh = _bounds(info)
            alto_selo = 80 if selo else 0
            dy = round(h / 2 - (by + bh / 2) - h * 0.02 + alto_selo / 2)
            ajuste += [("type.edit", {"layer": info["layer"], "move": [0, dy]})]
            if "selo" in camadas:
                si = res[camadas["selo"]]
                sx, sy, sw, sh = _bounds(si)
                topo = by + dy - 18 - (sh + 22)
                ajuste += [("type.edit", {"layer": si["layer"], "move": [0, round(topo + 10 - sy)]}),
                           ("shape.create", {"kind": "rect", "rect": [x_tit, round(topo), round(sw + 36), round(sh + 22)],
                                             "fill": self.cor(selo.fundo), "stroke": None, "name": "Selo (fundo)"}),
                           ("layer.moveTo", {"target": si["layer"], "position": "below"}),
                           ("layer.select", {"layer": si["layer"], "mode": "add"}),
                           ("edit.transform", {"rotate": -3})]
        for chave, v in camadas.items():
            if not chave.startswith("caixa") or v[1].fundo not in ("solido", "vidro", "tarja"):
                continue
            info, c = res[v[0]], v[1]
            bx, by, bw, bh = _bounds(info)
            tam = round(c.tamanho * h)
            m = round(tam * 0.3)
            cor = "#080c189e" if c.fundo == "vidro" else self.cor(c.cor_fundo)  # vidro: 62% de opacidade
            ajuste += [("shape.create", {"kind": "roundedRect" if c.fundo == "vidro" else "rect", "radii": 8,
                                         "rect": [bx - m, by - m // 2, bw + 2 * m, bh + m], "fill": cor, "stroke": None,
                                         "name": f"Fundo da {info.get('name', 'caixa')}"}),
                       ("layer.moveTo", {"target": info["layer"], "position": "below"})]
            if c.fundo == "tarja":
                ajuste += [("shape.create", {"kind": "rect", "rect": [bx - m, by - m // 2, round(tam * 0.14), bh + m],
                                             "fill": self.cor("destaque"), "stroke": None, "name": "Tarja"})]
        ajuste += self._variantes(doc, res, camadas)
        if ajuste:
            self.rastro.append(ajuste)
            self.rodar(destino, ajuste, destino)
        return Path(destino)

    def _variantes(self, doc, res, camadas):
        """Cada variante troca textos e vira um layer comp (o A/B fica no mesmo `.pcraft`); volta ao A no fim."""
        if not doc.variantes:
            return []
        passos = []
        for v in doc.variantes:
            if v.titulo is not None and "titulo" in camadas:
                t, runs = _destaques(v.titulo, self.cor("destaque"))
                passos += [("type.edit", {"layer": res[camadas["titulo"]]["layer"], "text": t, "runs": runs})]
            if v.selo is not None and "selo" in camadas:
                passos += [("type.edit", {"layer": res[camadas["selo"]]["layer"], "text": v.selo})]
            passos += [("layerComp.new", {"name": v.nome})]
        return passos + [("layerComp.apply", {"comp": "A"})]

    def _tratamento(self, e, w, h):
        if isinstance(e, RecortarSujeito):
            return [("layer.removeBackground", {"refine": True})]
        if isinstance(e, Reenquadrar):
            rw, rh = {"16:9": (16, 9), "9:16": (9, 16), "1:1": (1, 1)}[e.formato]
            cw, ch = (w, round(w * rh / rw)) if w * rh / rw <= h else (round(h * rw / rh), h)
            x = min(max(round(e.foco[0] * w - cw / 2), 0), w - cw)
            y = min(max(round(e.foco[1] * h - ch / 2), 0), h - ch)
            return [("image.crop", {"x": x, "y": y, "width": cw, "height": ch})]
        if isinstance(e, Nitidez):
            return [("filter.sharpen.smartSharpen", {"amount": round(40 + 160 * e.intensidade), "radius": 1,
                                                     "reduceNoise": 10})]
        if isinstance(e, Grao):
            return [("filter.gallery.grain", {"intensity": round(100 * e.intensidade), "contrast": 50,
                                              "grainType": "soft"})]
        if isinstance(e, DesfocarFundo):
            return [("select.subject", {}), ("select.inverse", {}),
                    ("filter.blur.smartBlur", {"radius": round(2 + 30 * e.intensidade, 1), "threshold": 25,
                                               "quality": "high", "mode": "normal"})]
        raise ErroN1(f"elemento sem executor: {e.tipo}")


def de_dados_thumb(d: dict, w: int, h: int) -> Composicao:
    """Dados do modelo `thumb` (`thumbs.dados_thumb`) → N1. Ponte do formato antigo do editor/etapa."""
    esq = d["layout"] == "rosto_esquerda"
    lado = "direita" if esq else "esquerda"
    els: list[dict] = [
        {"tipo": "imagem", "midia": "fundo"},
        {"tipo": "ajuste", "ajuste": "brilho_contraste", "brilho": -8, "contraste": 18},
        {"tipo": "ajuste", "ajuste": "saturacao", "saturacao": 15},
        {"tipo": "vinheta", "lado": lado, "bordas": True},
    ]
    if d.get("seta"):
        els.append({"tipo": "seta", "lado": lado})
    titulo = " ".join(f"*{p['t']}*" if p["d"] else p["t"] for p in d.get("palavras") or [])
    if titulo:
        els.append({"tipo": "titulo", "conteudo": titulo, "tamanho": d["tamanho"] / h,
                    "largura": (1160 if d["layout"] == "numero" else 640) / w, "lado": lado})
    if d.get("selo"):
        els.append({"tipo": "selo", "conteudo": d["selo"]})
    for c in d.get("caixas") or []:
        fonte = {"Inter": "corpo", "Playfair": "serifa", "Mono": "mono"}.get(c.get("fonte", "Inter"), "corpo")
        els.append({"tipo": "caixa", "conteudo": c.get("texto", ""), "pos": (c["x"] / 100, c["y"] / 100),
                    "largura": c["w"] / 100, "tamanho": c.get("tam", 64) / h, "fonte": fonte,
                    "peso": c.get("peso", 800), "cor": c.get("cor", "#f4f1ea"), "destaque": c.get("cor_d"),
                    "maiusculas": bool(c.get("maiusculas")),
                    "alinhar": {"center": "centro", "right": "direita"}.get(c.get("alinhar"), "esquerda"),
                    "fundo": c.get("fundo", "nenhum"), "cor_fundo": c.get("cor_fundo", "#0a1122")})
    return Composicao.model_validate({"documento": {"uso": "thumb", "largura": w, "altura": h}, "elementos": els})


def tratamento(receita: dict, decisao: FotoDecisao, formato: str, w: int, h: int) -> Composicao:
    """Receita fixa do canal (`[foto]` do perfil) + decisão N2 → composição de tratamento da foto."""
    els: list[dict] = [{"tipo": "imagem", "nome": "Foto", "midia": "foto", "ajuste": "conter"}]
    if receita.get("reenquadrar", True):
        els.append({"tipo": "reenquadrar", "formato": formato, "foco": decisao.foco})
    if receita.get("lut"):
        els.append({"tipo": "ajuste", "ajuste": "lut", "lut": receita["lut"]})
    if receita.get("contraste") or receita.get("brilho"):
        els.append({"tipo": "ajuste", "ajuste": "brilho_contraste", "brilho": receita.get("brilho", 0),
                    "contraste": receita.get("contraste", 0)})
    if receita.get("saturacao"):
        els.append({"tipo": "ajuste", "ajuste": "saturacao", "saturacao": receita["saturacao"]})
    if receita.get("nitidez"):
        els.append({"tipo": "nitidez", "intensidade": receita["nitidez"]})
    if receita.get("grao"):
        els.append({"tipo": "grao", "intensidade": receita["grao"]})
    if decisao.separar_planos and receita.get("desfoque_fundo"):
        els.append({"tipo": "desfocar_fundo", "intensidade": receita["desfoque_fundo"]})
    if decisao.recortar:
        els.append({"tipo": "recortar_sujeito"})
    return Composicao.model_validate({"documento": {"uso": "foto", "largura": w, "altura": h}, "elementos": els})
