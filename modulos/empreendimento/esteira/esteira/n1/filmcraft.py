"""N1 do FilmCraft (montagem de uma sequência, lista de operações) e o executor N1 → comandos do MCP.

Trilhas por papel: base V1 · apoio V2 · texto V3 · grafismo V4 · narracao A1 · musica A2 · sfx A3. Mídia por
referência (`narracao`, `cam`, `cena:12`, `grafico:3`, `musica`, `legendas`), resolvida pelo dicionário `midias`
que quem chama passa ao executor. Clipes são nomeados no `colocar` (`id`); as operações seguintes usam o nome. Os
IDs reais do FilmCraft vêm das respostas e nunca aparecem no N1.
"""
from typing import Annotated, Literal

from pydantic import BaseModel, Field

from esteira.filmcraft import ticks

APP = "filmcraft"
VERSION = 1

TRACKS = {"base": "V1", "apoio": "V2", "texto": "V3", "grafismo": "V4", "narracao": "A1", "musica": "A2",
           "sfx": "A3"}
Track = Literal["base", "apoio", "texto", "grafismo", "narracao", "musica", "sfx"]
Transition = Literal["cross_dissolve", "film_dissolve", "dip_to_black", "dip_to_white", "flash", "glitch", "push",
                    "slide", "zoom_blur", "light_leak", "light_sweep", "burn_chroma", "cross_zoom", "luma_fade",
                    "blur_dissolve", "morph_cut"]
Motion = Literal["zoom_in", "zoom_out", "pan_dir", "pan_esq"]
Role = Literal["texto", "destaque", "acento"]
FORMATS = {"16:9": (1920, 1080), "9:16": (1080, 1920)}

# Ken Burns: socos de zoom nos instantes ditos (mesmos valores do montar antigo)
PUNCH, PUNCH_DURATION, PUNCHES_MAX = 6, 0.12, 2  # % de zoom de impacto, s que ele leva, máximo por cena


class _Op(BaseModel):
    model_config = {"extra": "forbid"}


class Sequence(_Op):
    op: Literal["sequencia"]
    nome: str
    formato: Literal["16:9", "9:16"] = "16:9"
    fps: int = 30
    largura: int | None = None  # só quando o perfil foge do padrão do formato
    altura: int | None = None


class Place(_Op):
    op: Literal["colocar"]
    id: str = Field(description="nome do clipe para as operações seguintes")
    midia: str
    trilha: Track
    em: float = Field(ge=0, description="segundos na linha do tempo")
    dur: float | None = Field(None, gt=0, description="padrão: a mídia inteira")
    origem: float | None = Field(None, ge=0, description="ponto de entrada na mídia (s)")
    com_audio: bool = False


class Frame(_Op):
    op: Literal["enquadrar"]
    alvo: str
    zoom: float = Field(gt=0, description="escala em % (100 = original)")


class KenBurns(_Op):
    op: Literal["ken_burns"]
    alvo: str
    movimento: Motion
    zoom: float = Field(ge=0, le=40, description="% de zoom extra no movimento")
    socos: list[float] = Field(default_factory=list, description="instantes (s) de punch-in")


class TransitionOp(_Op):
    op: Literal["transicao"]
    alvo: str
    tipo: Transition
    borda: Literal["entrada", "saida"] = "entrada"
    quadros: int = Field(12, ge=1, le=120)


class Adjustments(_Op):
    exposicao: float = 0
    contraste: float = 0
    saturacao: float = 100
    temperatura: float = 0
    filme: float = 0
    vinheta: float = 0


class Color(_Op):
    op: Literal["cor"]
    acima_de: Literal["base", "apoio"] = "base"
    em: float = 0
    dur: float = Field(gt=0)
    ajustes: Adjustments


class Text(_Op):
    op: Literal["texto"]
    id: str
    conteudo: str
    em: float = Field(ge=0)
    dur: float = Field(gt=0)
    tamanho: float = Field(gt=0, le=0.5, description="fração da altura")
    pos: tuple[float, float] = Field(description="centro em frações (x, y)")
    cor: Role = "texto"
    estilo: Literal["surgir", "pop"] = "surgir"


class Music(_Op):
    op: Literal["musica"]
    midia: str = "musica"
    de: float = 0
    ate: float = Field(gt=0)
    ganho_db: float = Field(-20, ge=-60, le=6)
    ducking: bool = True


class KindAudio(_Op):
    op: Literal["tipo_audio"]
    alvo: str
    tipo: Literal["dialogo", "musica", "sfx"]


class Captions(_Op):
    op: Literal["legendas"]
    arquivo: str = "legendas"
    tamanho: float = Field(0.05, gt=0, le=0.2, description="fração da altura")
    margem: float = Field(0.06, ge=0, le=0.5, description="distância da borda de baixo (fração da altura)")
    fundo: bool = True


# Correções (edição de uma montagem já feita)
class Cut(_Op):
    op: Literal["cortar"]
    em: float = Field(ge=0)
    trilha: Track | None = None


class Remove(_Op):
    op: Literal["remover"]
    alvo: str
    fechar: bool = True


class Trim(_Op):
    op: Literal["aparar"]
    alvo: str
    borda: Literal["entrada", "saida"]
    delta: float = Field(description="segundos (+ estica, − encurta)")
    fechar: bool = False


class Move(_Op):
    op: Literal["mover"]
    alvo: str
    para: float = Field(ge=0)
    trilha: Track | None = None


class Speed(_Op):
    op: Literal["velocidade"]
    alvo: str
    fator: float = Field(gt=0.05, le=20)


class Gain(_Op):
    op: Literal["ganho"]
    alvo: str
    db: float = Field(ge=-60, le=20)


class Fade(_Op):
    op: Literal["fade"]
    alvo: str
    entrada: float = Field(0, ge=0)
    saida: float = Field(0, ge=0)


class Mark(_Op):
    op: Literal["marcar"]
    em: float = Field(ge=0)
    nome: str
    cor: Literal["vermelho", "amarelo", "verde", "azul"] = "amarelo"


Operation = Annotated[
    Sequence | Place | Frame | KenBurns | TransitionOp | Color | Text | Music | KindAudio | Captions
    | Cut | Remove | Trim | Move | Speed | Gain | Fade | Mark, Field(discriminator="op")]


class Assembly(BaseModel):
    versao: Literal[1] = 1
    ops: list[Operation]


DOCUMENT = Assembly

_COLORS_MARK = {"vermelho": "Red", "amarelo": "Yellow", "verde": "Green", "azul": "Blue"}
_KIND_AUDIO = {"dialogo": "dialogue", "musica": "music", "sfx": "sfx"}
_LUMETRI = {"exposicao": "exposure", "contraste": "contrast", "saturacao": "saturation", "temperatura": "temperature",
            "filme": "faded_film", "vinheta": "vignette_amount"}


class ErrorN1(ValueError):
    pass


class Executor:
    """Aplica uma `Montagem` numa sessão do FilmCraft. `midias`: ref → {"caminho", "dur"?}. `estilo`: fonte,
    fonte_estilo e cores por papel. `rastro` guarda os comandos N0 enviados (o dataset grava)."""

    def __init__(self, fc, midias: dict, estilo: dict):
        self.fc, self.midias, self.estilo = fc, midias, estilo
        self.itens: dict[str, str] = {}   # ref → item importado
        self.clipes: dict[str, list] = {}  # nome → ids de clipe
        self.inicio: dict[str, tuple[float, float]] = {}  # nome → (em, dur), para animações relativas
        self.w, self.h = 1920, 1080
        self.rastro: list[dict] = []

    def run(self, cmd, **params):
        self.rastro.append({"command": cmd, "params": params})
        return self.fc.run(cmd, **params)

    def _clipes(self, nome):
        if nome not in self.clipes:
            raise ErrorN1(f"clipe desconhecido: {nome}")
        return self.clipes[nome]

    def importar(self, doc: Assembly):
        refs = []
        for o in doc.ops:
            ref = getattr(o, "midia", None)
            if ref and ref not in refs and ref not in self.itens:
                refs.append(ref)
        faltam = [r for r in refs if r not in self.midias]
        if faltam:
            raise ErrorN1(f"mídia sem caminho: {faltam}")
        if refs:
            imp = self.run("file.import", paths=[str(self.midias[r]["caminho"]) for r in refs])
            if imp.get("errors"):
                raise ErrorN1(f"erro ao importar: {imp['errors']}")
            self.itens.update(zip(refs, imp["items"]))

    def executar(self, doc: Assembly | dict) -> list[dict]:
        doc = doc if isinstance(doc, Assembly) else Assembly.model_validate(doc)
        self._usa_sfx = any(getattr(o, "trilha", None) == "sfx" for o in doc.ops)
        self.importar(doc)
        for o in doc.ops:
            getattr(self, f"_{o.op}")(o)
        return self.rastro

    # ---------- operações ----------

    def _sequencia(self, o: Sequence):
        self.w, self.h = (o.largura, o.altura) if o.largura and o.altura else FORMATS[o.formato]
        self.run("file.newSequence", name=o.nome, width=self.w, height=self.h, fps=o.fps, video=4,
                 audio=3 if self._usa_sfx else 2)

    _usa_sfx = False

    def _colocar(self, o: Place):
        trilha = TRACKS[o.trilha]
        p = {"item": self.itens[o.midia], "track": trilha, "seconds": o.em, "insert": False}
        if o.origem is not None:
            p["sourceIn"] = ticks(o.origem)
        if o.dur is not None:
            p["duration"] = ticks(o.dur)
        if trilha.startswith("V") and not o.com_audio:
            p["audio"] = False
        if trilha.startswith("A") and o.trilha != "narracao":
            p["video"] = False
        self.clipes[o.id] = self.run("timeline.place", **p)["clips"]
        self.inicio[o.id] = (o.em, o.dur or float(self.midias[o.midia].get("dur") or 0))

    def _enquadrar(self, o: Frame):
        for c in self._clipes(o.alvo):
            self.run("effects.setParam", clip=c, effect="motion", param="scale", value=o.zoom)

    def _ken_burns(self, o: KenBurns):
        clip = self._clipes(o.alvo)[0]
        ini, dur = self.inicio[o.alvo]
        fim = ini + dur
        z = o.zoom
        cx, cy = self.w / 2, self.h / 2
        dx = self.w * z / 200 * 0.9  # deslocamento que o zoom extra permite sem mostrar borda
        a, b = {"zoom_in": (100, 100 + z), "zoom_out": (100 + z, 100)}.get(o.movimento, (100 + z, 100 + z))

        def base(t):
            return a + (b - a) * (t - ini) / max(fim - ini, 0.01)
        chaves, extra = [(ini, a)], 0
        for tp in sorted(t for t in o.socos if ini + 0.3 < t < fim - 0.6)[:PUNCHES_MAX]:
            if tp - chaves[-1][0] < 0.5:
                continue
            chaves.append((tp, base(tp) + extra))
            extra += PUNCH
            chaves.append((tp + PUNCH_DURATION, base(tp + PUNCH_DURATION) + extra))
        chaves.append((fim, b + extra))
        for t, v in chaves:
            self.run("effects.setParam", clip=clip, effect="motion", param="scale", value=round(v, 2), time=ticks(t),
                     keyframe=True)
        if o.movimento in ("pan_dir", "pan_esq"):
            sinal = 1 if o.movimento == "pan_dir" else -1
            self.run("effects.setParam", clip=clip, effect="motion", param="position", value=[cx + sinal * dx, cy],
                     time=ticks(ini), keyframe=True)
            self.run("effects.setParam", clip=clip, effect="motion", param="position", value=[cx - sinal * dx, cy],
                     time=ticks(fim), keyframe=True)

    def _transicao(self, o: TransitionOp):
        self.run("sequence.applyVideoTransition", clip=self._clipes(o.alvo)[0], effect=o.tipo,
                 edge="in" if o.borda == "entrada" else "out", frames=o.quadros)

    def _cor(self, o: Color):
        item = self.run("file.newAdjustmentLayer", seconds=o.dur)
        item = item["item"] if isinstance(item, dict) else item
        trilha = "V2" if o.acima_de == "base" else "V3"
        aj = self.run("timeline.place", item=item, track=trilha, seconds=o.em, duration=ticks(o.dur),
                      insert=False)["clips"][0]
        self.run("effects.apply", clips=[aj], effect="lumetri")
        for campo, param in _LUMETRI.items():
            self.run("effects.setParam", clip=aj, effect="lumetri", param=param, value=getattr(o.ajustes, campo))

    def _texto(self, o: Text):
        e = self.estilo
        tam = round(o.tamanho * self.h, 1)
        tam = int(tam) if tam == int(tam) else tam
        x, y = o.pos[0] * self.w, o.pos[1] * self.h
        cor = e["cores"][o.cor]
        clip = self.run("graphics.newText", text=o.conteudo, size=tam, seconds=o.dur, time=ticks(o.em),
                        track=3)["clip"]
        self.clipes[o.id] = [clip]
        self.inicio[o.id] = (o.em, o.dur)
        pop = o.estilo == "pop"
        self.run("graphics.set", clip=clip, layer=0, props={
            "font": e["fonte"], "font_style": e["fonte_estilo"], "size": tam, "align": "center", "fill_color": cor,
            "stroke": True, "stroke_width": 6 if pop else 4, "shadow": True, "position": [x, y]})
        ini, dur = o.em, o.dur
        if pop:  # nasce pequena, passa de 100% e assenta; sobe 30 px ao entrar; some encolhendo
            for t, v in ((0, 40), (0.12, 112), (0.22, 100), (dur - 0.15, 100), (dur, 85)):
                self.run("effects.setParam", clip=clip, effect="motion", param="scale", value=v, time=ticks(ini + t),
                         keyframe=True)
            for t, v in ((0, [x, y + 30]), (0.2, [x, y])):
                self.run("effects.setParam", clip=clip, effect="motion", param="position", value=v,
                         time=ticks(ini + t), keyframe=True)
            for t, v in ((0, 0), (0.08, 100), (dur - 0.15, 100), (dur, 0)):
                self.run("effects.setParam", clip=clip, effect="opacity", param="opacity", value=v,
                         time=ticks(ini + t), keyframe=True)
            return
        # surgir: cresce de 85% e aparece em 0,3 s; some nos últimos 0,3 s
        t0, t1, tin, tout = ticks(ini), ticks(ini + dur), ticks(ini + 0.3), ticks(ini + dur - 0.3)
        for t, v in ((t0, 85), (tin, 100)):
            self.run("effects.setParam", clip=clip, effect="motion", param="scale", value=v, time=t, keyframe=True)
        for t, v in ((t0, 0), (tin, 100), (tout, 100), (t1, 0)):
            self.run("effects.setParam", clip=clip, effect="opacity", param="opacity", value=v, time=t, keyframe=True)

    def _musica(self, o: Music):
        dur_m = float(self.midias[o.midia].get("dur") or 0)
        if dur_m <= 0:
            raise ErrorN1("música sem duração conhecida")
        t, trilha = o.de, []
        while t < o.ate:
            d = min(dur_m, o.ate - t)
            trilha += self.run("timeline.place", item=self.itens[o.midia], track="A2", seconds=t, duration=ticks(d),
                               insert=False, video=False)["clips"]
            t += d
        self.clipes[o.midia] = trilha
        self.run("clip.audioGain", clips=trilha, mode="set", db=o.ganho_db)
        self.run("essentialSound.setType", clips=trilha, type="music")
        if o.ducking:
            self.run("essentialSound.generateDucking", clips=trilha)

    def _tipo_audio(self, o: KindAudio):
        self.run("essentialSound.setType", clips=self._clipes(o.alvo), type=_KIND_AUDIO[o.tipo])

    def _legendas(self, o: Captions):
        e = self.estilo
        self.run("captions.import", path=str(self.midias[o.arquivo]["caminho"]))
        tam = round(o.tamanho * self.h)
        self.run("captions.setStyle", track="C1", font=e["fonte"], size=tam, color=e["cores"]["texto"],
                 background=o.fundo, backgroundColor="#000000aa", anchor="bottom", margin=o.margem)

    def _cortar(self, o: Cut):
        p = {"time": ticks(o.em)}
        if o.trilha:
            p["track"] = TRACKS[o.trilha]
        self.run("timeline.razor", **p)

    def _remover(self, o: Remove):
        self.run("timeline.delete", clips=self._clipes(o.alvo), ripple=o.fechar)

    def _aparar(self, o: Trim):
        for c in self._clipes(o.alvo):
            self.run("timeline.trim", clip=c, edge="in" if o.borda == "entrada" else "out",
                     mode="ripple" if o.fechar else "regular", delta=ticks(o.delta))

    def _mover(self, o: Move):
        movs = [{"clip": c, "time": {"seconds": o.para}, **({"track": TRACKS[o.trilha]} if o.trilha else {})}
                for c in self._clipes(o.alvo)]
        self.run("timeline.move", moves=movs, insert=False)

    def _velocidade(self, o: Speed):
        self.run("clip.speedDuration", clips=self._clipes(o.alvo), speed=round(o.fator * 100, 2), reverse=False,
                 ripple=False)

    def _ganho(self, o: Gain):
        self.run("clip.audioGain", clips=self._clipes(o.alvo), mode="set", db=o.db)

    def _fade(self, o: Fade):
        fps = 30
        for borda, s in (("in", o.entrada), ("out", o.saida)):
            if s > 0:
                for c in self._clipes(o.alvo):
                    self.run("sequence.applyAudioTransition", clip=c, effect="constant_power", edge=borda,
                             frames=max(1, round(s * fps)))

    def _marcar(self, o: Mark):
        self.run("markers.add", target="program", time=ticks(o.em), name=o.nome, color=_COLORS_MARK[o.cor])

