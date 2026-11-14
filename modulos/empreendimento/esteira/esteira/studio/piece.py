"""Peças do acervo de motion (`docs/PLANO-ACERVO.md`): uma pasta por peça em `estudio/pecas/<id>/`.

- `peca.js`: a animação. Registra-se no kit com `ESTUDIO.peca("<id>", (k, c) => {...})`; `k` traz os utilitários do
  kit (tl, U, V, W, H, $, esc, svg, entra, sai, traco, palavras, letras, contar, numero, fmt, icone, veu, kicker,
  flash, fim, camada) e `c` a cena do mapa com `c.encaixes` (conteúdo), `c.botoes` (estrutura) e `c.batidas`
  ({encaixe: instante}). Contrato completo em `estudio/pecas/GUIA.md`.
- `peca.css` (opcional): estilos da peça, sempre dentro de `.p-<id>` e só com as variáveis de pele do kit.
- `ficha.json`: os metadados (`Ficha`), o que a IA local lê para escolher e preencher.
- `prova/`: quadros nas duas peles de prova × formatos da ficha, gerados pelo portão de entrada.

Pele por código: nenhuma cor nem fonte fixa na peça (`--fundo`, `--fundo2`, `--texto`, `--destaque`, `--apoio`,
`--acento`, `--fD`, `--fT`, `--fM`, `--fL`, `--fE`, `--U`), então trocar de canal é só aplicar a identidade dele.
"""
import html as html_lib
import json
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field, ValidationError, model_validator

from esteira.studio.style import SOUNDS, Skin

FOLDER = Path(__file__).parent / "pecas"
ID = r"^[a-z][a-z0-9_]{2,40}$"
NAME = r"^[a-z][a-z0-9_]{0,30}$"
INTENTS = ("numero", "comparacao", "processo", "lista", "narrativa_passado", "conceito", "citacao", "chamada",
             "pergunta", "capitulo", "destaque", "transicao", "fundo", "dado_temporal", "alerta")
WEIGHTS = ("texto", "2d", "2_5d", "3d", "midia")
STATES = ("rascunho", "revisao", "aprovada", "reprovada")
VARS_SKIN = ("--fundo", "--fundo2", "--texto", "--destaque", "--apoio", "--acento", "--fD", "--fT", "--fM", "--fL",
             "--fE", "--U", "--esc", "--inativo", "--R", "--brilhoF", "--gradeF")


class Fit(BaseModel):
    """Conteúdo que a IA local preenche, com limites que o código confere."""
    nome: str = Field(pattern=NAME)
    # pares: lista de {"rotulo", "valor"} (o formato do diretor: valores de barras, marcos, termos de conta)
    # pagina: página de documento com grifos {"src", "w", "h", "grifos": [[x0, y0, x1, y1], ...]} (px da imagem;
    # `graficos/pdf.image_of_page`); imagem: caminho/URL de uma imagem
    tipo: Literal["texto", "numero", "itens", "pares", "icone", "imagem", "tematico", "pagina"]
    descricao: str = ""
    obrigatorio: bool = True
    max_car: int = Field(40, ge=1, le=400)          # texto, número, cada item, rótulo de cada par
    max_valor: int = Field(16, ge=1, le=60)         # pares: valor de cada par
    min_itens: int = Field(1, ge=0, le=20)          # itens, pares, grifos
    max_itens: int = Field(6, ge=1, le=20)
    unidade: bool = False                           # número precisa de unidade ("%", "R$", "anos")
    opcoes: list[str] = Field(default_factory=list)  # ícone/temático: valores possíveis (vazio = livre)
    exemplo: str | list[str] | list[dict[str, str]] = ""  # valor típico (prova e prompt)


class Button(BaseModel):
    """Parâmetro de estrutura com valores permitidos (as "pequenas modificações" da IA)."""
    nome: str = Field(pattern=NAME)
    valores: list[str | int | float] = Field(min_length=2)
    padrao: str | int | float
    descricao: str = ""

    @model_validator(mode="after")
    def _default_valid(self):
        if self.padrao not in self.valores:
            raise ValueError(f"botão {self.nome}: padrão {self.padrao!r} fora dos valores")
        return self


class Card(BaseModel):
    id: str = Field(pattern=ID)
    versao: int = Field(1, ge=1)
    origem: str = ""                                 # canal onde nasceu
    motor: Literal["html", "effectcraft"] = "html"
    estado: Literal[STATES] = "rascunho"
    comunica: str = Field(min_length=10, max_length=200)
    intencoes: list[Literal[INTENTS]] = Field(min_length=1)
    exemplos_sim: list[str] = Field(min_length=5, max_length=10)
    exemplos_nao: list[str] = Field(min_length=3, max_length=5)
    temas: list[str] = Field(default_factory=list)
    neutra: bool = True                              # serve a qualquer canal; temática exige trocar o encaixe temático
    tom: list[Literal["calma", "dramatica", "didatica", "leve", "urgente"]] = Field(min_length=1)
    energia: Literal["baixa", "media", "alta"] = "media"
    peso: Literal[WEIGHTS] = "2d"
    formatos: list[Literal["16:9", "9:16"]] = Field(min_length=1)
    duracao_min: float = Field(1.0, ge=0.3, le=120)
    duracao_max: float = Field(8.0, ge=0.5, le=120)
    tela_cheia: bool = True                          # ocupa a tela (takeover) ou fica por cima da mídia/câmera
    rosto: Literal["nao_usa", "precisa_area_livre", "sobre_camera"] = "nao_usa"
    encaixes: list[Fit] = Field(min_length=1)
    botoes: list[Button] = Field(default_factory=list)
    batidas: list[str] = Field(default_factory=list)  # encaixes que entram sincronizados a palavras do bloco
    sfx: dict[str, Literal[SOUNDS]] = Field(default_factory=dict)  # evento → categoria do pacote de SFX
    notas: str = ""

    @model_validator(mode="after")
    def _coherent(self):
        names = [e.nome for e in self.encaixes]
        if len(set(names)) != len(names):
            raise ValueError("encaixes com nome repetido")
        if len({b.nome for b in self.botoes}) != len(self.botoes):
            raise ValueError("botões com nome repetido")
        if outside := [b for b in self.batidas if b not in names]:
            raise ValueError(f"batidas sem encaixe: {outside}")
        if self.duracao_min >= self.duracao_max:
            raise ValueError("duracao_min tem de ser menor que duracao_max")
        if not self.neutra and not any(e.tipo == "tematico" for e in self.encaixes):
            raise ValueError("peça temática precisa de um encaixe 'tematico' (o elemento que muda de canal)")
        for e in self.encaixes:
            if e.min_itens > e.max_itens:
                raise ValueError(f"encaixe {e.nome}: min_itens > max_itens")
        return self


# ---------------------------------------------------------------- acervo

def folder(id_):
    return FOLDER / id_


def load(id_):
    file = folder(id_) / "ficha.json"
    if not file.exists():
        raise KeyError(f"peça inexistente: {id_}")
    return Card.model_validate_json(file.read_text())


def list_all(state=None):
    """Fichas válidas do acervo (as inválidas ficam de fora; o portão diz o porquê)."""
    output = []
    for file in sorted(FOLDER.glob("*/ficha.json")):
        try:
            f = Card.model_validate_json(file.read_text())
        except ValidationError:
            continue
        if state is None or f.estado == state:
            output.append(f)
    return output


def save(card: Card):
    folder(card.id).mkdir(parents=True, exist_ok=True)
    (folder(card.id) / "ficha.json").write_text(card.model_dump_json(indent=1, exclude_defaults=False))


def in_channel(cards, style):
    """Peças que o canal pode usar: aprovadas, no formato e fora do filtro (id, intenção ou tema filtrado)."""
    criteria = set(style.regras.filtro)
    return [f for f in cards if f.estado == "aprovada" and f.id not in criteria
            and not criteria & set(f.intencoes) and not criteria & set(f.temas)]


# ---------------------------------------------------------------- preenchimento

def defaults(card: Card):
    return {b.nome: b.padrao for b in card.botoes}


def validate_data(card: Card, slots: dict, buttons: dict | None = None):
    """Confere o preenchimento da IA local contra os limites da ficha → lista de erros (vazia = ok). O erro volta
    ao modelo como está, então tem de dizer o que corrigir."""
    errors = []
    for e in card.encaixes:
        v = slots.get(e.nome)
        if v in (None, "", []):
            if e.obrigatorio:
                errors.append(f"{e.nome}: obrigatório")
            continue
        if e.tipo == "pagina":
            errors += _errors_page(e, v)
            continue
        if e.tipo == "pares":
            if not isinstance(v, list) or not all(isinstance(x, dict) for x in v):
                errors.append(f'{e.nome}: lista de {{"rotulo", "valor"}}')
                continue
            if not e.min_itens <= len(v) <= e.max_itens:
                errors.append(f"{e.nome}: {e.min_itens}–{e.max_itens} pares (veio {len(v)})")
            for i, x in enumerate(v):
                if len(str(x.get("rotulo", ""))) > e.max_car:
                    errors.append(f"{e.nome}[{i}].rotulo: até {e.max_car} caracteres")
                if len(str(x.get("valor", ""))) > e.max_valor:
                    errors.append(f"{e.nome}[{i}].valor: até {e.max_valor} caracteres")
            continue
        if e.tipo == "itens":
            if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
                errors.append(f"{e.nome}: lista de textos")
                continue
            if not e.min_itens <= len(v) <= e.max_itens:
                errors.append(f"{e.nome}: {e.min_itens}–{e.max_itens} itens (veio {len(v)})")
            errors += [f"{e.nome}[{i}]: até {e.max_car} caracteres" for i, x in enumerate(v) if len(x) > e.max_car]
            continue
        if not isinstance(v, str):
            errors.append(f"{e.nome}: texto")
            continue
        if len(v) > e.max_car and e.tipo != "imagem":  # imagem é caminho/descrição: limite de texto não se aplica
            errors.append(f"{e.nome}: até {e.max_car} caracteres (veio {len(v)})")
        if e.tipo == "numero":
            if not re.search(r"\d", v):
                errors.append(f"{e.nome}: precisa de um número")
            elif e.unidade and not re.search(r"[^\d\s.,]", v):
                errors.append(f"{e.nome}: número com unidade (%, R$, anos…)")
        if e.opcoes and e.tipo in ("icone", "tematico") and v not in e.opcoes:
            errors.append(f"{e.nome}: um de {e.opcoes}")
    if extras := set(slots) - {e.nome for e in card.encaixes}:
        errors.append(f"encaixes que a peça não tem: {sorted(extras)}")
    for name, v in (buttons or {}).items():
        b = next((b for b in card.botoes if b.nome == name), None)
        if not b:
            errors.append(f"botão que a peça não tem: {name}")
        elif v not in b.valores:
            errors.append(f"{name}: um de {b.valores}")
    return errors


def _errors_page(e, v):
    if not isinstance(v, dict) or not isinstance(v.get("src"), str):
        return [f'{e.nome}: {{"src", "w", "h", "grifos"}}']
    w, h, gs = v.get("w"), v.get("h"), v.get("grifos")
    if not (isinstance(w, int) and isinstance(h, int) and w > 0 and h > 0):
        return [f"{e.nome}: w e h em pixels"]
    if not isinstance(gs, list) or not e.min_itens <= len(gs) <= e.max_itens:
        return [f"{e.nome}: {e.min_itens}–{e.max_itens} grifos"]
    if any(not (isinstance(g, list) and len(g) == 4 and 0 <= g[0] < g[2] <= w and 0 <= g[1] < g[3] <= h) for g in gs):
        return [f"{e.nome}: cada grifo [x0, y0, x1, y1] dentro da página"]
    return []


SAMPLE_TEXT = (
    "Household debt and financial stress",
    "Abstract. We study how revolving credit affects the financial well-being of low-income households over a decade. "
    "Using panel data from 12,000 families, we find that households relying on revolving credit for more than six "
    "months report significantly higher stress and lower savings rates. The effect persists after controlling for "
    "income, education and regional prices. Families who refinanced into fixed-installment loans reduced their total "
    "interest payments by almost half within two years. These results suggest that the structure of credit, and not "
    "only its cost, shapes long-term financial outcomes. We discuss implications for consumer protection policy and "
    "for financial education programs aimed at young adults entering the credit market for the first time.")
SAMPLE_MARKER = "households relying on revolving credit for more than six months report significantly higher stress"


def sample_photo():
    """Foto sintética sem texto (céu em degradê, sol e silhuetas; PNG em cache): o encaixe `imagem` da prova. Com a
    página de artigo no lugar, a visão lia o texto da página recortado pela moldura como texto cortado."""
    import pymupdf

    from esteira.project import CACHE
    file = CACHE / "estudio" / "amostra_foto.png"
    if file.exists():
        return str(file)
    doc = pymupdf.open()
    pg = doc.new_page(width=600, height=400)
    for i in range(40):  # céu: azul escuro → laranja
        k = i / 39
        color = (0.16 + 0.8 * k, 0.24 + 0.4 * k, 0.45 - 0.2 * k)
        pg.draw_rect(pymupdf.Rect(0, i * 7, 600, i * 7 + 8), color=None, fill=color)
    pg.draw_circle(pymupdf.Point(420, 230), 46, color=None, fill=(1, 0.86, 0.55))
    for x, w, h in ((20, 70, 150), (100, 50, 110), (160, 90, 190), (270, 60, 130), (480, 80, 170), (540, 60, 120)):
        pg.draw_rect(pymupdf.Rect(x, 280 - h, x + w, 280), color=None, fill=(0.12, 0.1, 0.12))
    pg.draw_rect(pymupdf.Rect(0, 280, 600, 400), color=None, fill=(0.2, 0.17, 0.15))
    file.parent.mkdir(parents=True, exist_ok=True)
    pg.get_pixmap(dpi=150).save(file)
    return str(file)


def sample_page():
    """Página de artigo sintética (PNG em cache) com o grifo de um trecho: o encaixe `pagina` da prova."""
    import pymupdf

    from esteira.project import CACHE
    file = CACHE / "estudio" / "amostra_pagina.png"
    meta = file.with_suffix(".json")
    if file.exists() and meta.exists():
        return {**json.loads(meta.read_text()), "arquivo": str(file)}
    doc = pymupdf.open()
    pg = doc.new_page(width=612, height=792)
    pg.insert_textbox(pymupdf.Rect(72, 80, 540, 130), SAMPLE_TEXT[0], fontsize=20, fontname="tibo")
    pg.insert_textbox(pymupdf.Rect(72, 150, 540, 720), SAMPLE_TEXT[1], fontsize=11.5, fontname="tiro")
    k = 150 / 72
    grifos = [[round(r.x0 * k), round(r.y0 * k), round(r.x1 * k), round(r.y1 * k)] for r in pg.search_for(SAMPLE_MARKER)]
    pix = pg.get_pixmap(dpi=150)
    file.parent.mkdir(parents=True, exist_ok=True)
    pix.save(file)
    d = {"w": pix.width, "h": pix.height, "grifos": grifos}
    meta.write_text(json.dumps(d))
    return {**d, "arquivo": str(file)}


def maximums(card: Card):
    """Preenchimento no pior caso (texto no limite, itens no máximo): o portão prova que cabe."""
    output = {}
    for e in card.encaixes:
        base = e.exemplo if isinstance(e.exemplo, str) and e.exemplo else "Palavra"
        if e.tipo == "pares":
            ex = e.exemplo if isinstance(e.exemplo, list) and e.exemplo and isinstance(e.exemplo[0], dict) \
                else [{"rotulo": "Rótulo", "valor": "12%"}]
            output[e.nome] = [{"rotulo": _fill(ex[i % len(ex)].get("rotulo", ""), e.max_car),
                              "valor": str(ex[i % len(ex)].get("valor", ""))[:e.max_valor]} for i in range(e.max_itens)]
        elif e.tipo == "itens":
            ex = e.exemplo if isinstance(e.exemplo, list) and e.exemplo else ["Item de exemplo"]
            # item pode ser objeto (ex.: {"ano": .., "texto": ..}): cada campo de texto vai ao limite
            output[e.nome] = [{k: _fill(str(v), e.max_car) for k, v in it.items()} if isinstance(it, dict)
                             else _fill(str(it), e.max_car) for it in (ex[i % len(ex)] for i in range(e.max_itens))]
        elif e.tipo == "numero":
            output[e.nome] = (e.exemplo or "1.234,5%")[:e.max_car]
        elif e.tipo == "pagina":
            a = sample_page()
            output[e.nome] = {"src": "assets/amostra_pagina.png", "w": a["w"], "h": a["h"],
                             "grifos": a["grifos"][:e.max_itens]}
        elif e.tipo == "imagem":
            output[e.nome] = "assets/amostra_foto.png"
        elif e.opcoes:
            output[e.nome] = max(e.opcoes, key=len)
        else:
            output[e.nome] = _fill(base, e.max_car)
    return output


def _fill(txt, n):
    """Texto de exatamente até n caracteres, repetindo palavras do exemplo (largura realista, não "MMMM")."""
    words = (txt or "Palavra").split() or ["Palavra"]
    output, i = "", 0
    while len(output) < n:
        w = words[i % len(words)]
        output = f"{output} {w}".strip()
        i += 1
    if len(output) > n:  # corta na última palavra inteira: palavra pela metade a visão lê como texto cortado
        output = output[:n + 1].rsplit(" ", 1)[0] if " " in output[:n + 1] else output[:n]
        while " " in output and not any(c.isalnum() for c in output.rsplit(" ", 1)[1]):
            output = output.rsplit(" ", 1)[0]  # nem símbolo solto no fim ("% ao ano %")
    if output.count("*") % 2:  # a marca de destaque cortada no meio não pode sobrar solta
        i = output.rfind("*")
        output = output[:i] + output[i + 1:]
    return output


# ---------------------------------------------------------------- portão de entrada

RE_COLOR = re.compile(r"#[0-9a-fA-F]{3,8}\b|\b(?:rgb|rgba|hsl|hsla)\(\s*(?!0\s*,\s*0\s*,\s*0\s*,)")
RE_COLOR_NAME = re.compile(r"(?<![\w-])(?:white|black|red|blue|green|yellow|orange|purple|gray|grey|gold)(?![\w-])", re.I)
RE_SOURCE = re.compile(r"font-family\s*:\s*(?!\s*var\()|fontFamily\s*[:=]\s*[\"'](?!var\()")
SKINS_PROOF = {  # duas peles bem diferentes: a peça tem de funcionar nas duas só pelas variáveis
    "escura": Skin(),
    "clara": Skin(fundo="#f4f1ea", fundo2="#e6e0d2", texto="#1d1b18", destaque="#0f6e5c", apoio="#c2410c",
                  acento="#6b6457", fonte_destaque="Playfair Display", fonte_texto="Inter",
                  fonte_editorial="Playfair Display", fonte_legenda="Inter"),
}
DIM = {"16:9": (1920, 1080), "9:16": (1080, 1920)}
AREA_SAFE = 0.03  # fração do lado menor que o texto deixa livre em cada borda
INSTANTS = (0.35, 0.6, 0.9)  # frações da duração em que o portão mede e fotografa


def _code(text):
    """Sem comentários (a regra vale para o que roda, não para o que explica)."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"(?m)(^|[^:\"'])//.*$", r"\1", text)


def check_code(id_, card: Card):
    """Checagens estáticas: arquivos, sintaxe, registro do id, pele só por variáveis, encaixes/botões declarados."""
    errors, warnings = [], []
    p = folder(id_)
    js_file, css_file = p / "peca.js", p / "peca.css"
    if not js_file.exists():
        return [f"falta {js_file.name}"], warnings
    js = js_file.read_text()
    css = css_file.read_text() if css_file.exists() else ""
    node = _node()
    if node:
        r = subprocess.run([node, "--check", str(js_file)], capture_output=True, text=True)
        if r.returncode:
            errors.append("sintaxe do peca.js: " + (r.stderr.strip().splitlines() or ["?"])[-1])
    else:
        warnings.append("node não encontrado: sintaxe não conferida")
    if not re.search(rf"ESTUDIO\.peca\(\s*[\"']{re.escape(id_)}[\"']", js):
        errors.append(f'peca.js não registra a peça: ESTUDIO.peca("{id_}", (k, c) => ...)')
    for name, text in (("peca.js", _code(js)), ("peca.css", _code(css))):
        if m := RE_COLOR.search(text):
            errors.append(f"{name}: cor fixa ({m.group(0)}); use var(--destaque), var(--texto)… ou color-mix com elas")
        if m := RE_COLOR_NAME.search(text):
            errors.append(f"{name}: cor fixa pelo nome ({m.group(0)})")
        if RE_SOURCE.search(text):
            errors.append(f"{name}: fonte fixa; use var(--fD), var(--fT), var(--fM) ou var(--fE)")
    if css:
        for sel in re.findall(r"(?:^|[{}])\s*([^{}@;]+)\{", _code(css)):
            parts = [s.strip() for s in sel.split(",") if s.strip()]
            if all(re.fullmatch(r"from|to|[\d.]+%", s) for s in parts):  # quadros de @keyframes
                continue
            if any(f".p-{id_}" not in s for s in parts):
                errors.append(f"peca.css: seletor fora de .p-{id_} ({sel.strip()[:40]})")
                break
    if colide := _classes(js) & _classes_kit() - REUSE:
        errors.append(f"peca.js usa classes do kit ({sorted(colide)[:5]}): o estilo global do kit vaza para a peça; "
                     f"use o prefixo da peça (ex.: {id_[:2]}-titulo)")
    used_and, used_b = _used(js, "encaixes"), _used(js, "botoes")
    names_and, names_b = {e.nome for e in card.encaixes}, {b.nome for b in card.botoes}
    if outside := used_and - names_and - {"*"}:
        errors.append(f"peca.js usa encaixes que a ficha não declara: {sorted(outside)}")
    if outside := used_b - names_b:
        errors.append(f"peca.js usa botões que a ficha não declara: {sorted(outside)}")
    if "*" in used_and:
        used_and = (used_and - {"*"}) | names_and
    if stopped := names_and - used_and:
        warnings.append(f"encaixes declarados e não usados: {sorted(stopped)}")
    if stopped := names_b - used_b:
        warnings.append(f"botões declarados e não usados: {sorted(stopped)}")
    return errors, warnings


# classes do núcleo do kit que as peças reusam de propósito (estilo comum: título, rótulo, etiqueta, número grande)
REUSE = {"kicker", "traco", "veu", "pw", "pl", "l", "d", "baixo", "cheio", "centro", "titulo", "tag", "tx", "tk", "ngr",
         "nn", "ctx", "kick2"}


def _classes_kit():
    from esteira.studio import compiler
    return set(re.findall(r"\.([a-zA-Z][\w-]*)", _code((compiler.KIT / "estudio.css").read_text())))


def _classes(js):
    """Classes que a peça cria: k.$("div", "a b", ...), classList.add("x"), class="y" em HTML."""
    js = _code(js)
    names = set()
    for group in re.findall(r"\$\(\s*[\"'][a-z0-9]+[\"']\s*,\s*[\"']([^\"']+)[\"']", js):
        names |= set(group.split())
    for group in re.findall(r"classList\.add\(([^)]*)\)", js):
        names |= set(re.findall(r"[\"']([\w-]+)[\"']", group))
    for group in re.findall(r"class=\\?[\"']([^\"'\\]+)", js):
        names |= set(group.split())
    for group in re.findall(r"\bclass\s*:\s*[\"']([^\"']+)[\"']", js):  # svg("circle", {class: "arco"})
        names |= set(group.split())
    return names


def _used(js, field):
    """Nomes lidos de c.<campo> no código: direto (c.encaixes.x, c.encaixes["x"]), por apelido
    (const e = c.encaixes; e.x) ou por desestruturação (const { x, y } = c.encaixes)."""
    js = _code(js)
    names = {a or b for a, b in re.findall(rf"\bc\.{field}\s*(?:\.\s*(\w+)|\[\s*[\"'](\w+)[\"']\s*\])", js)}
    for apelido in re.findall(rf"\b(\w+)\s*=\s*c\.{field}\b(?!\s*[.\[])", js):
        names |= {a or b for a, b in re.findall(rf"\b{apelido}\s*(?:\.\s*(\w+)|\[\s*[\"'](\w+)[\"']\s*\])", js)}
    for apelido in re.findall(rf"\b(\w+)\s*=\s*\{{[^{{}}]*\.\.\.c\.{field}\s*\}}", js):  # const e = { a: 1, ...c.encaixes }
        names |= {a or b for a, b in re.findall(rf"\b{apelido}\s*(?:\.\s*(\w+)|\[\s*[\"'](\w+)[\"']\s*\])", js)}
        if re.search(rf"\.\.\.{apelido}\b", js):  # passa tudo adiante (k.proporcao({{ ...c, ...e }}))
            names.add("*")
    for group in re.findall(rf"\b(?:const|let|var)\s*\{{([^{{}}]*)\}}\s*=\s*c\.{field}\b", js):
        names |= {x.split(":")[0].split("=")[0].strip() for x in group.split(",") if x.strip()}
    return names


def _node():
    from esteira.studio import engine
    n = engine.NODE / "bin" / "node"
    return str(n) if n.exists() else shutil.which("node")


def _scene(card: Card, duration, buttons=None, slots=None):
    enc = slots or maximums(card)
    t = 0.3
    beats = {b: round(t + 0.4 + 0.5 * k, 2) for k, b in enumerate(card.batidas)}
    return {"cena": card.id, "t": t, "ate": round(t + duration, 2), "takeover": card.tela_cheia, "titulo": "",
            "valores": [], "frase": "", "encaixes": enc, "botoes": {**defaults(card), **(buttons or {})},
            "batidas": beats}


def assemble(destination, scenes, skin: Skin, fmt, ids=None, duration=None, measure=False):
    """Composição mínima (kit + peças + pele + uma ou mais cenas, sem mídia) em `destino`: usada na prova do portão
    e na prévia das peças. `medir`: ao abrir com ?t=S, posiciona a timeline em S e grava o que estoura a tela."""
    from esteira.studio import compiler, style, fonts
    a = destination / "assets"
    a.mkdir(parents=True, exist_ok=True)
    for name in ("estudio.js", "estudio.css", "gsap.min.js"):
        shutil.copy(compiler.KIT / name, a / name)
    three = join(a, ids)
    if "assets/amostra_pagina.png" in json.dumps(scenes):
        shutil.copy(sample_page()["arquivo"], a / "amostra_pagina.png")
    if "assets/amostra_foto.png" in json.dumps(scenes):
        shutil.copy(sample_photo(), a / "amostra_foto.png")
    roles = ("fonte_destaque", "fonte_texto", "fonte_tecnica", "fonte_legenda", "fonte_editorial")
    (a / "fontes.css").write_text(fonts.css([getattr(skin, k) for k in roles], a))
    skin = skin.model_copy(update={k: fonts.resolve(getattr(skin, k)) for k in roles})
    base = style.Style(id="prova", nome="prova", canal="prova", pele=skin)
    rg = base.regras
    W, H = DIM[fmt]
    duration = duration or max(c["ate"] for c in scenes) + 0.5
    cfg = {"W": W, "H": H, "pele": skin.model_dump(), "efeitos": rg.efeitos, "visual": rg.visual.model_dump(),
           "legenda": {"ativa": False, **rg.legenda_visual.model_dump(), "chaves": []},
           "movimento": base.movimento.model_dump(), "layouts": base.layouts.model_dump(),
           "regras_cor": base.regras_cor.model_dump(), "pecas": {}}
    html = (compiler.KIT / "index.template.html").read_text()
    for k, v in {"__W__": W, "__H__": H, "__DUR__": round(duration, 3), "__CFG__": json.dumps(cfg, ensure_ascii=False),
                 "__MIDIA__": "[]", "__CENAS__": json.dumps(scenes, ensure_ascii=False), "__WORDS__": "[]",
                 "__SFX__": "[]"}.items():
        html = html.replace(k, str(v))
    html = html.replace("__EC__", videos_ec(scenes)).replace("__DE__", "0").replace("__THREE__", TAG_THREE if three else "")
    html = re.sub(r'\s*<audio id="voz"[^>]*></audio>', "", html)  # sem narração na prova/prévia
    if measure:
        html = html.replace("</body>", MEASURE.replace("__AREA__", str(AREA_SAFE)) + "</body>")
    (destination / "index.html").write_text(html)
    return destination / "index.html"


# posiciona a timeline no instante pedido e anota no DOM os elementos visíveis que saem da tela
MEASURE = """<script>
(() => {
  const t = parseFloat(new URLSearchParams(location.search).get("t") || "0");
  const AREA_SEGURA = __AREA__;
  tl.seek(t, false);
  const raiz = document.getElementById("root").getBoundingClientRect();
  const fora = [];
  // só o que tem texto dentro das peças: fundos e brilhos do kit passam da borda de propósito
  const comTexto = (el) => [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim());
  document.querySelectorAll(".peca *").forEach((el) => {
    if (!comTexto(el)) return;
    // área do texto em si (não a caixa: um bloco de borda a borda com texto centralizado não estoura)
    const rg = document.createRange();
    rg.selectNodeContents(el);
    const r = rg.getBoundingClientRect(), s = getComputedStyle(el);
    if (!r.width || !r.height || s.visibility === "hidden" || parseFloat(s.opacity) < 0.05) return;
    let o = el, vis = 1;
    while (o && o.id !== "root") { vis *= parseFloat(getComputedStyle(o).opacity); o = o.parentElement; }
    if (vis < 0.05) return;
    const m = AREA_SEGURA * Math.min(raiz.width, raiz.height);  // texto fica dentro da área segura
    if (r.left < raiz.left + m || r.top < raiz.top + m || r.right > raiz.right - m || r.bottom > raiz.bottom - m
        || (el.scrollWidth > el.clientWidth + 2 && s.overflow === "hidden"))
      fora.push((el.className && String(el.className)) || el.tagName.toLowerCase());
  });
  document.body.setAttribute("data-estouro", JSON.stringify([...new Set(fora)].slice(0, 8)));
  document.body.setAttribute("data-erros", JSON.stringify(window.__errosPecas || []));
})();
</script>
"""


def legacy(scene, card: Card):
    """Cena do mapa do diretor atual (titulo/valores no topo) → encaixes da peça migrada."""
    if scene.get("encaixes"):
        return scene["encaixes"]
    names = {e.nome for e in card.encaixes}
    return {k: scene[k] for k in ("titulo", "valores") if k in names and k in scene}


def videos_ec(scenes):
    """<video> das cenas com peça EffectCraft já renderizada (`ec_src`), para a camada #ec do template."""
    return "".join(
        f'<video id="ec{n}" class="clip peca-ec" src="{c["ec_src"]}" muted playsinline data-start="{c["t"]:.3f}" '
        f'data-duration="{max(0.1, c["ate"] - c["t"]):.3f}" data-track-index="{30 + n % 2}"></video>'
        for n, c in enumerate(scenes) if c.get("ec_src"))


TAG_THREE = '<script src="assets/three.min.js"></script>\n'


_SYNTAX = {}


def _syntax_ok(file):
    """`node --check` do peca.js (em memória por data de modificação); sem node ou sem arquivo, passa."""
    node = _node()
    if not node or not file.exists():
        return True
    k = (str(file), file.stat().st_mtime_ns)
    if k not in _SYNTAX:
        _SYNTAX[k] = subprocess.run([node, "--check", str(file)], capture_output=True).returncode == 0
    return _SYNTAX[k]


def join(destination_assets, ids=None):
    """`pecas.js` e `pecas.css` com as peças do acervo (todas as válidas, ou só `ids`) para a composição; com alguma
    peça 3D, copia o Three.js para os assets. → True se a composição precisa do Three.js."""
    chosen = ids if ids is not None else [f.id for f in list_all()]
    three = False
    for i in chosen:
        try:
            three = three or load(i).peso == "3d"
        except (KeyError, ValidationError):
            continue
    if three:
        from esteira.studio import compiler
        shutil.copy(compiler.KIT / "three.min.js", destination_assets / "three.min.js")
    js, css = [], []
    for i in chosen:
        p = folder(i)
        if not _syntax_ok(p / "peca.js"):
            print(f"  peça {i} fora da composição: erro de sintaxe no peca.js", flush=True)
            continue  # um script quebrado no pecas.js derrubaria todas as peças do vídeo
        if (p / "peca.js").exists():
            js.append(f"// ── peça {i}\n" + (p / "peca.js").read_text())
        if (p / "peca.css").exists():
            css.append(f"/* ── peça {i} */\n" + (p / "peca.css").read_text())
    (destination_assets / "pecas.js").write_text("\n".join(js))
    (destination_assets / "pecas.css").write_text("\n".join(css))
    return three


def _chromium(url, W, H, output=None, budget=2500):
    from esteira.studio import engine
    exe = engine._chromium()
    if not exe:
        raise RuntimeError("Chromium não instalado (aba Estúdio → Dependências)")
    args = [exe, "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
            f"--window-size={W},{H}", f"--virtual-time-budget={budget}"]
    args += [f"--screenshot={output}", url] if output else ["--dump-dom", url]
    r = subprocess.run(args, capture_output=True, text=True, timeout=90)
    if r.returncode and not output:
        raise RuntimeError(r.stderr.strip()[-200:])
    return r.stdout


def prove(id_, card: Card):
    """Monta a peça com o preenchimento máximo nas duas peles × formatos da ficha; mede estouro de tela em
    INSTANTES e fotografa o meio. → (erros, quadros)."""
    errors, frames = [], []
    proof = folder(id_) / "prova"
    shutil.rmtree(proof, ignore_errors=True)
    proof.mkdir(parents=True)
    duration = min(card.duracao_max, max(card.duracao_min, 4.0))
    scene = _scene(card, duration)
    with tempfile.TemporaryDirectory() as tmp:
        for name_skin, skin in SKINS_PROOF.items():
            for fmt in card.formatos:
                d = Path(tmp) / f"{name_skin}_{fmt.replace(':', 'x')}"
                idx = assemble(d, [scene], skin, fmt, ids=[id_], duration=scene["ate"] + 0.5, measure=True)
                W, H = DIM[fmt]
                for frac in INSTANTS:
                    t = round(scene["t"] + frac * duration, 2)
                    dom = _chromium(f"file://{idx}?t={t}", W, H)
                    m = re.search(r'data-estouro="([^"]*)"', dom)
                    if not m:
                        errors.append(f"{name_skin} {fmt}: a composição não rodou (erro de JavaScript na peça?)")
                        break
                    outside = json.loads(html_lib.unescape(m.group(1)))
                    if (e := re.search(r'data-erros="([^"]*)"', dom)) and (lst := json.loads(html_lib.unescape(e.group(1)))):
                        errors.append(f"{name_skin} {fmt}: erro de JavaScript na peça: {lst[0]}")
                        break
                    if outside:
                        errors.append(f"{name_skin} {fmt} em {t:.1f} s: sai da tela com o texto máximo: {outside[:4]}")
                png = Path(tmp) / f"{name_skin}_{fmt.replace(':', 'x')}.png"
                _chromium(f"file://{idx}?t={round(scene['t'] + 0.6 * duration, 2)}", W, H, output=png)
                file = proof / png.with_suffix(".jpg").name  # metade do tamanho, JPG: a prova é para olhar
                if png.exists():
                    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(png), "-vf", "scale=iw/2:-2",
                                    "-q:v", "4", str(file)], check=True)
                    frames.append(file.name)
    return errors, frames


def gate(id_, render=True):
    """Portão de entrada da peça no acervo: ficha válida + código + prova nas duas peles × formatos. Passou e era
    rascunho → vai para a revisão da pessoa (a aprovação é dela). Grava `prova/portao.json`."""
    p = folder(id_)
    try:
        card = Card.model_validate_json((p / "ficha.json").read_text())
    except FileNotFoundError:
        return {"ok": False, "erros": ["falta ficha.json"], "avisos": [], "quadros": []}
    except ValidationError as e:
        return {"ok": False, "erros": [f"ficha: {x['loc']}: {x['msg']}" for x in e.errors()], "avisos": [],
                "quadros": []}
    from esteira.studio import ec
    errors, warnings = (ec.check_code if card.motor == "effectcraft" else check_code)(id_, card)
    if card.id != id_:
        errors.append(f"ficha.id ({card.id}) diferente da pasta ({id_})")
    if card.motor == "effectcraft" and not ec.available():
        warnings.append("effectcraft-cli não encontrado: prova não feita")
        render = False
    if errors := errors + validate_data(card, maximums(card)):
        render = False
    frames, render_s = [], None
    if render:
        if card.motor == "effectcraft":
            e2, frames, render_s = ec.prove(id_, card)
        else:
            t0 = time.monotonic()
            e2, frames = prove(id_, card)
            render_s = round(time.monotonic() - t0, 2)
        errors += e2
    r = {"ok": not errors, "erros": errors, "avisos": warnings, "quadros": frames, "versao": card.versao,
         "motor": card.motor, "render_s": render_s}
    (p / "prova").mkdir(exist_ok=True)
    (p / "prova" / "portao.json").write_text(json.dumps(r, ensure_ascii=False, indent=1))
    if r["ok"] and card.estado == "rascunho":
        save(card.model_copy(update={"estado": "revisao"}))
    return r


# ---------------------------------------------------------------- prévia animada (revisão)

def previews_dir(id_):
    from esteira.project import DATA
    return DATA / "estudio" / "fabrica" / "previas" / id_


def preview(id_, style_ref, video_format=None):
    """MP4 curto da peça (preenchimento de exemplo) na pele do estilo de um canal, pelo HyperFrames (GPU) ou, no
    motor EffectCraft, pela engine dele."""
    from esteira.studio import compiler, ec, style
    card = load(id_)
    est = style.load(style_ref)
    fmt = video_format or card.formatos[0]
    if card.motor == "effectcraft":
        return ec.preview(id_, est, fmt)
    duration = min(card.duracao_max, max(card.duracao_min, 5.0))
    enc = {e.nome: e.exemplo for e in card.encaixes if e.exemplo and e.tipo not in ("pagina", "imagem")}
    enc = {**maximums(card), **enc}
    destination = previews_dir(id_) / f"_{est.id}"
    shutil.rmtree(destination, ignore_errors=True)
    assemble(destination, [_scene(card, duration, slots=enc)], est.pele, fmt, ids=[id_], duration=duration + 1.0)
    raw = compiler.render(None, fmt, qualidade="draft", p=destination)
    output = previews_dir(id_) / f"{est.id}_{fmt.replace(':', 'x')}.mp4"
    shutil.move(str(raw), output)
    shutil.rmtree(destination, ignore_errors=True)
    return output


# ---------------------------------------------------------------- prova de troca de pele entre canais

def examples(card: Card):
    """Preenchimento típico (os `exemplo` da ficha; o máximo só onde não há exemplo)."""
    m = maximums(card)
    return {e.nome: (e.exemplo if e.exemplo and e.tipo not in ("pagina", "imagem") else m[e.nome]) for e in card.encaixes}


def proof_channels(styles, formats=("16:9", "9:16"), ids=None):
    """Cada peça aprovada (ou `ids`) com o conteúdo de exemplo na pele de cada estilo: mede erro de JavaScript e
    estouro da área segura e monta uma folha por estilo × formato. A mesma peça tem de funcionar em todos os canais
    só pela pele. → {"folhas": [...], "problemas": [{peca, estilo, formato, erro}]}."""
    from esteira.studio import style as E
    folder_output = previews_dir("_canais").parent / "_prova_canais"
    folder_output.mkdir(parents=True, exist_ok=True)
    cards = [load(i) for i in ids] if ids else list_all("aprovada")
    problems, folhas = [], []
    with tempfile.TemporaryDirectory() as tmp:
        for ref in styles:
            est = E.load(ref)
            for fmt in formats:
                W, H = DIM[fmt]
                frames = []
                for f in cards:
                    if fmt not in f.formatos:
                        continue
                    duration = min(f.duracao_max, max(f.duracao_min, 4.0))
                    scene = _scene(f, duration, slots=examples(f))
                    d = Path(tmp) / f"{est.id}_{fmt.replace(':', 'x')}_{f.id}"
                    if f.motor == "effectcraft":
                        q = _proof_channel_ec(f, scene, duration, est, fmt, d, problems)
                        if q:
                            frames.append(q)
                        continue
                    idx = assemble(d, [scene], est.pele, fmt, ids=[f.id] + _drops(f), duration=scene["ate"] + 0.5, measure=True)
                    t = round(scene["t"] + 0.6 * duration, 2)
                    dom = _chromium(f"file://{idx}?t={t}", W, H)
                    er = re.search(r'data-erros="([^"]*)"', dom)
                    es = re.search(r'data-estouro="([^"]*)"', dom)
                    lst_and = json.loads(html_lib.unescape(er.group(1))) if er else ["a composição não rodou"]
                    lst_s = json.loads(html_lib.unescape(es.group(1))) if es else []
                    for x in lst_and:
                        problems.append({"peca": f.id, "estilo": est.id, "formato": fmt, "erro": f"JavaScript: {x}"})
                    if lst_s:
                        problems.append({"peca": f.id, "estilo": est.id, "formato": fmt, "erro": f"sai da área segura: {lst_s[:3]}"})
                    png = d / "quadro.png"
                    _chromium(f"file://{idx}?t={t}", W, H, output=png)
                    if png.exists():
                        frames.append(png)
                if frames:
                    sheet = folder_output / f"{est.id}_{fmt.replace(':', 'x')}.jpg"
                    _sheet(frames, sheet, 6 if W > H else 8)
                    folhas.append(sheet.name)
    r = {"estilos": list(styles), "pecas": [f.id for f in cards], "folhas": folhas, "problemas": problems}
    (folder_output / "resultado.json").write_text(json.dumps(r, ensure_ascii=False, indent=1))
    return r


def _proof_channel_ec(f, scene, duration, est, fmt, folder_tmp, problems):
    """Peça EffectCraft na pele do estilo: estouro da área segura e o quadro do meio (ou o erro do script)."""
    from esteira.studio import ec
    folder_tmp.mkdir(parents=True, exist_ok=True)
    t = round(scene["t"] + 0.6 * duration, 2)
    d = ec.data(f, scene["encaixes"], scene["botoes"], scene["batidas"], est.pele, fmt, duration, scene["t"], [t], AREA_SAFE)
    try:
        overflows, _ = ec.assemble(f.id, d, folder_tmp / "p.ecproj", est.pele)
    except (RuntimeError, subprocess.TimeoutExpired) as e:
        problems.append({"peca": f.id, "estilo": est.id, "formato": fmt, "erro": f"EffectCraft: {str(e)[:200]}"})
        return None
    if overflows:
        problems.append({"peca": f.id, "estilo": est.id, "formato": fmt, "erro": f"sai da área segura: {overflows[:3]}"})
    return ec.frame(folder_tmp / "p.ecproj", t, folder_tmp / "quadro.jpg", est.pele.fundo, scale=1.0)


def _drops(card: Card):
    """Peças em que esta cai quando o conteúdo não serve (`k.outra`), para a composição ter as duas."""
    js = (folder(card.id) / "peca.js").read_text() if (folder(card.id) / "peca.js").exists() else ""
    return sorted(set(re.findall(r'k\.outra\("(\w+)"', js)))


def _sheet(frames, destination, columns):
    """Folha de contato (ffmpeg xstack) com os quadros em miniatura, na ordem."""
    n = len(frames)
    width = 320
    inputs = sum((["-i", str(q)] for q in frames), [])
    scale = "".join(f"[{i}]scale={width}:-2[a{i}];" for i in range(n))
    if n == 1:
        criteria = f"[0]scale={width}:-2"
    else:
        # posições: colunas de `larg` px; linhas pela altura da primeira miniatura (h0)
        pos = "|".join(("0" if i % columns == 0 else "+".join(f"w{j}" for j in range(i - i % columns, i)))
                       + "_" + ("0" if i < columns else "+".join("h0" for _ in range(i // columns))) for i in range(n))
        criteria = scale + "".join(f"[a{i}]" for i in range(n)) + f"xstack=inputs={n}:layout={pos}:fill=black"
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", *inputs, "-filter_complex", criteria, "-frames:v", "1",
                    "-q:v", "4", str(destination)], check=True)
