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

from esteira.estudio.estilo import SONS, Pele

PASTA = Path(__file__).parent / "pecas"
ID = r"^[a-z][a-z0-9_]{2,40}$"
NOME = r"^[a-z][a-z0-9_]{0,30}$"
INTENCOES = ("numero", "comparacao", "processo", "lista", "narrativa_passado", "conceito", "citacao", "chamada",
             "pergunta", "capitulo", "destaque", "transicao", "fundo", "dado_temporal", "alerta")
PESOS = ("texto", "2d", "2_5d", "3d", "midia")
ESTADOS = ("rascunho", "revisao", "aprovada", "reprovada")
VARS_PELE = ("--fundo", "--fundo2", "--texto", "--destaque", "--apoio", "--acento", "--fD", "--fT", "--fM", "--fL",
             "--fE", "--U", "--esc", "--inativo", "--R", "--brilhoF", "--gradeF")


class Encaixe(BaseModel):
    """Conteúdo que a IA local preenche, com limites que o código confere."""
    nome: str = Field(pattern=NOME)
    # pares: lista de {"rotulo", "valor"} (o formato do diretor: valores de barras, marcos, termos de conta)
    # pagina: página de documento com grifos {"src", "w", "h", "grifos": [[x0, y0, x1, y1], ...]} (px da imagem;
    # `graficos/pdf.imagem_da_pagina`); imagem: caminho/URL de uma imagem
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


class Botao(BaseModel):
    """Parâmetro de estrutura com valores permitidos (as "pequenas modificações" da IA)."""
    nome: str = Field(pattern=NOME)
    valores: list[str | int | float] = Field(min_length=2)
    padrao: str | int | float
    descricao: str = ""

    @model_validator(mode="after")
    def _padrao_valido(self):
        if self.padrao not in self.valores:
            raise ValueError(f"botão {self.nome}: padrão {self.padrao!r} fora dos valores")
        return self


class Ficha(BaseModel):
    id: str = Field(pattern=ID)
    versao: int = Field(1, ge=1)
    origem: str = ""                                 # canal onde nasceu
    motor: Literal["html", "effectcraft"] = "html"
    estado: Literal[ESTADOS] = "rascunho"
    comunica: str = Field(min_length=10, max_length=200)
    intencoes: list[Literal[INTENCOES]] = Field(min_length=1)
    exemplos_sim: list[str] = Field(min_length=5, max_length=10)
    exemplos_nao: list[str] = Field(min_length=3, max_length=5)
    temas: list[str] = Field(default_factory=list)
    neutra: bool = True                              # serve a qualquer canal; temática exige trocar o encaixe temático
    tom: list[Literal["calma", "dramatica", "didatica", "leve", "urgente"]] = Field(min_length=1)
    energia: Literal["baixa", "media", "alta"] = "media"
    peso: Literal[PESOS] = "2d"
    formatos: list[Literal["16:9", "9:16"]] = Field(min_length=1)
    duracao_min: float = Field(1.0, ge=0.3, le=120)
    duracao_max: float = Field(8.0, ge=0.5, le=120)
    tela_cheia: bool = True                          # ocupa a tela (takeover) ou fica por cima da mídia/câmera
    rosto: Literal["nao_usa", "precisa_area_livre", "sobre_camera"] = "nao_usa"
    encaixes: list[Encaixe] = Field(min_length=1)
    botoes: list[Botao] = Field(default_factory=list)
    batidas: list[str] = Field(default_factory=list)  # encaixes que entram sincronizados a palavras do bloco
    sfx: dict[str, Literal[SONS]] = Field(default_factory=dict)  # evento → categoria do pacote de SFX
    notas: str = ""

    @model_validator(mode="after")
    def _coerente(self):
        nomes = [e.nome for e in self.encaixes]
        if len(set(nomes)) != len(nomes):
            raise ValueError("encaixes com nome repetido")
        if len({b.nome for b in self.botoes}) != len(self.botoes):
            raise ValueError("botões com nome repetido")
        if fora := [b for b in self.batidas if b not in nomes]:
            raise ValueError(f"batidas sem encaixe: {fora}")
        if self.duracao_min >= self.duracao_max:
            raise ValueError("duracao_min tem de ser menor que duracao_max")
        if not self.neutra and not any(e.tipo == "tematico" for e in self.encaixes):
            raise ValueError("peça temática precisa de um encaixe 'tematico' (o elemento que muda de canal)")
        for e in self.encaixes:
            if e.min_itens > e.max_itens:
                raise ValueError(f"encaixe {e.nome}: min_itens > max_itens")
        return self


# ---------------------------------------------------------------- acervo

def pasta(id_):
    return PASTA / id_


def carregar(id_):
    arq = pasta(id_) / "ficha.json"
    if not arq.exists():
        raise KeyError(f"peça inexistente: {id_}")
    return Ficha.model_validate_json(arq.read_text())


def listar(estado=None):
    """Fichas válidas do acervo (as inválidas ficam de fora; o portão diz o porquê)."""
    saida = []
    for arq in sorted(PASTA.glob("*/ficha.json")):
        try:
            f = Ficha.model_validate_json(arq.read_text())
        except ValidationError:
            continue
        if estado is None or f.estado == estado:
            saida.append(f)
    return saida


def salvar(ficha: Ficha):
    pasta(ficha.id).mkdir(parents=True, exist_ok=True)
    (pasta(ficha.id) / "ficha.json").write_text(ficha.model_dump_json(indent=1, exclude_defaults=False))


def no_canal(fichas, estilo):
    """Peças que o canal pode usar: aprovadas, no formato e fora do filtro (id, intenção ou tema filtrado)."""
    filtro = set(estilo.regras.filtro)
    return [f for f in fichas if f.estado == "aprovada" and f.id not in filtro
            and not filtro & set(f.intencoes) and not filtro & set(f.temas)]


# ---------------------------------------------------------------- preenchimento

def padroes(ficha: Ficha):
    return {b.nome: b.padrao for b in ficha.botoes}


def validar_dados(ficha: Ficha, encaixes: dict, botoes: dict | None = None):
    """Confere o preenchimento da IA local contra os limites da ficha → lista de erros (vazia = ok). O erro volta
    ao modelo como está, então tem de dizer o que corrigir."""
    erros = []
    for e in ficha.encaixes:
        v = encaixes.get(e.nome)
        if v in (None, "", []):
            if e.obrigatorio:
                erros.append(f"{e.nome}: obrigatório")
            continue
        if e.tipo == "pagina":
            erros += _erros_pagina(e, v)
            continue
        if e.tipo == "pares":
            if not isinstance(v, list) or not all(isinstance(x, dict) for x in v):
                erros.append(f'{e.nome}: lista de {{"rotulo", "valor"}}')
                continue
            if not e.min_itens <= len(v) <= e.max_itens:
                erros.append(f"{e.nome}: {e.min_itens}–{e.max_itens} pares (veio {len(v)})")
            for i, x in enumerate(v):
                if len(str(x.get("rotulo", ""))) > e.max_car:
                    erros.append(f"{e.nome}[{i}].rotulo: até {e.max_car} caracteres")
                if len(str(x.get("valor", ""))) > e.max_valor:
                    erros.append(f"{e.nome}[{i}].valor: até {e.max_valor} caracteres")
            continue
        if e.tipo == "itens":
            if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
                erros.append(f"{e.nome}: lista de textos")
                continue
            if not e.min_itens <= len(v) <= e.max_itens:
                erros.append(f"{e.nome}: {e.min_itens}–{e.max_itens} itens (veio {len(v)})")
            erros += [f"{e.nome}[{i}]: até {e.max_car} caracteres" for i, x in enumerate(v) if len(x) > e.max_car]
            continue
        if not isinstance(v, str):
            erros.append(f"{e.nome}: texto")
            continue
        if len(v) > e.max_car and e.tipo != "imagem":  # imagem é caminho/descrição: limite de texto não se aplica
            erros.append(f"{e.nome}: até {e.max_car} caracteres (veio {len(v)})")
        if e.tipo == "numero":
            if not re.search(r"\d", v):
                erros.append(f"{e.nome}: precisa de um número")
            elif e.unidade and not re.search(r"[^\d\s.,]", v):
                erros.append(f"{e.nome}: número com unidade (%, R$, anos…)")
        if e.opcoes and e.tipo in ("icone", "tematico") and v not in e.opcoes:
            erros.append(f"{e.nome}: um de {e.opcoes}")
    if extras := set(encaixes) - {e.nome for e in ficha.encaixes}:
        erros.append(f"encaixes que a peça não tem: {sorted(extras)}")
    for nome, v in (botoes or {}).items():
        b = next((b for b in ficha.botoes if b.nome == nome), None)
        if not b:
            erros.append(f"botão que a peça não tem: {nome}")
        elif v not in b.valores:
            erros.append(f"{nome}: um de {b.valores}")
    return erros


def _erros_pagina(e, v):
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


AMOSTRA_TEXTO = (
    "Household debt and financial stress",
    "Abstract. We study how revolving credit affects the financial well-being of low-income households over a decade. "
    "Using panel data from 12,000 families, we find that households relying on revolving credit for more than six "
    "months report significantly higher stress and lower savings rates. The effect persists after controlling for "
    "income, education and regional prices. Families who refinanced into fixed-installment loans reduced their total "
    "interest payments by almost half within two years. These results suggest that the structure of credit, and not "
    "only its cost, shapes long-term financial outcomes. We discuss implications for consumer protection policy and "
    "for financial education programs aimed at young adults entering the credit market for the first time.")
AMOSTRA_GRIFO = "households relying on revolving credit for more than six months report significantly higher stress"


def amostra_foto():
    """Foto sintética sem texto (céu em degradê, sol e silhuetas; PNG em cache): o encaixe `imagem` da prova. Com a
    página de artigo no lugar, a visão lia o texto da página recortado pela moldura como texto cortado."""
    import pymupdf

    from esteira.projeto import CACHE
    arq = CACHE / "estudio" / "amostra_foto.png"
    if arq.exists():
        return str(arq)
    doc = pymupdf.open()
    pg = doc.new_page(width=600, height=400)
    for i in range(40):  # céu: azul escuro → laranja
        k = i / 39
        cor = (0.16 + 0.8 * k, 0.24 + 0.4 * k, 0.45 - 0.2 * k)
        pg.draw_rect(pymupdf.Rect(0, i * 7, 600, i * 7 + 8), color=None, fill=cor)
    pg.draw_circle(pymupdf.Point(420, 230), 46, color=None, fill=(1, 0.86, 0.55))
    for x, w, h in ((20, 70, 150), (100, 50, 110), (160, 90, 190), (270, 60, 130), (480, 80, 170), (540, 60, 120)):
        pg.draw_rect(pymupdf.Rect(x, 280 - h, x + w, 280), color=None, fill=(0.12, 0.1, 0.12))
    pg.draw_rect(pymupdf.Rect(0, 280, 600, 400), color=None, fill=(0.2, 0.17, 0.15))
    arq.parent.mkdir(parents=True, exist_ok=True)
    pg.get_pixmap(dpi=150).save(arq)
    return str(arq)


def amostra_pagina():
    """Página de artigo sintética (PNG em cache) com o grifo de um trecho: o encaixe `pagina` da prova."""
    import pymupdf

    from esteira.projeto import CACHE
    arq = CACHE / "estudio" / "amostra_pagina.png"
    meta = arq.with_suffix(".json")
    if arq.exists() and meta.exists():
        return {**json.loads(meta.read_text()), "arquivo": str(arq)}
    doc = pymupdf.open()
    pg = doc.new_page(width=612, height=792)
    pg.insert_textbox(pymupdf.Rect(72, 80, 540, 130), AMOSTRA_TEXTO[0], fontsize=20, fontname="tibo")
    pg.insert_textbox(pymupdf.Rect(72, 150, 540, 720), AMOSTRA_TEXTO[1], fontsize=11.5, fontname="tiro")
    k = 150 / 72
    grifos = [[round(r.x0 * k), round(r.y0 * k), round(r.x1 * k), round(r.y1 * k)] for r in pg.search_for(AMOSTRA_GRIFO)]
    pix = pg.get_pixmap(dpi=150)
    arq.parent.mkdir(parents=True, exist_ok=True)
    pix.save(arq)
    d = {"w": pix.width, "h": pix.height, "grifos": grifos}
    meta.write_text(json.dumps(d))
    return {**d, "arquivo": str(arq)}


def maximos(ficha: Ficha):
    """Preenchimento no pior caso (texto no limite, itens no máximo): o portão prova que cabe."""
    saida = {}
    for e in ficha.encaixes:
        base = e.exemplo if isinstance(e.exemplo, str) and e.exemplo else "Palavra"
        if e.tipo == "pares":
            ex = e.exemplo if isinstance(e.exemplo, list) and e.exemplo and isinstance(e.exemplo[0], dict) \
                else [{"rotulo": "Rótulo", "valor": "12%"}]
            saida[e.nome] = [{"rotulo": _encher(ex[i % len(ex)].get("rotulo", ""), e.max_car),
                              "valor": str(ex[i % len(ex)].get("valor", ""))[:e.max_valor]} for i in range(e.max_itens)]
        elif e.tipo == "itens":
            ex = e.exemplo if isinstance(e.exemplo, list) and e.exemplo else ["Item de exemplo"]
            # item pode ser objeto (ex.: {"ano": .., "texto": ..}): cada campo de texto vai ao limite
            saida[e.nome] = [{k: _encher(str(v), e.max_car) for k, v in it.items()} if isinstance(it, dict)
                             else _encher(str(it), e.max_car) for it in (ex[i % len(ex)] for i in range(e.max_itens))]
        elif e.tipo == "numero":
            saida[e.nome] = (e.exemplo or "1.234,5%")[:e.max_car]
        elif e.tipo == "pagina":
            a = amostra_pagina()
            saida[e.nome] = {"src": "assets/amostra_pagina.png", "w": a["w"], "h": a["h"],
                             "grifos": a["grifos"][:e.max_itens]}
        elif e.tipo == "imagem":
            saida[e.nome] = "assets/amostra_foto.png"
        elif e.opcoes:
            saida[e.nome] = max(e.opcoes, key=len)
        else:
            saida[e.nome] = _encher(base, e.max_car)
    return saida


def _encher(txt, n):
    """Texto de exatamente até n caracteres, repetindo palavras do exemplo (largura realista, não "MMMM")."""
    palavras = (txt or "Palavra").split() or ["Palavra"]
    saida, i = "", 0
    while len(saida) < n:
        w = palavras[i % len(palavras)]
        saida = f"{saida} {w}".strip()
        i += 1
    if len(saida) > n:  # corta na última palavra inteira: palavra pela metade a visão lê como texto cortado
        saida = saida[:n + 1].rsplit(" ", 1)[0] if " " in saida[:n + 1] else saida[:n]
        while " " in saida and not any(c.isalnum() for c in saida.rsplit(" ", 1)[1]):
            saida = saida.rsplit(" ", 1)[0]  # nem símbolo solto no fim ("% ao ano %")
    if saida.count("*") % 2:  # a marca de destaque cortada no meio não pode sobrar solta
        i = saida.rfind("*")
        saida = saida[:i] + saida[i + 1:]
    return saida


# ---------------------------------------------------------------- portão de entrada

RE_COR = re.compile(r"#[0-9a-fA-F]{3,8}\b|\b(?:rgb|rgba|hsl|hsla)\(\s*(?!0\s*,\s*0\s*,\s*0\s*,)")
RE_COR_NOME = re.compile(r"(?<![\w-])(?:white|black|red|blue|green|yellow|orange|purple|gray|grey|gold)(?![\w-])", re.I)
RE_FONTE = re.compile(r"font-family\s*:\s*(?!\s*var\()|fontFamily\s*[:=]\s*[\"'](?!var\()")
PELES_PROVA = {  # duas peles bem diferentes: a peça tem de funcionar nas duas só pelas variáveis
    "escura": Pele(),
    "clara": Pele(fundo="#f4f1ea", fundo2="#e6e0d2", texto="#1d1b18", destaque="#0f6e5c", apoio="#c2410c",
                  acento="#6b6457", fonte_destaque="Playfair Display", fonte_texto="Inter",
                  fonte_editorial="Playfair Display", fonte_legenda="Inter"),
}
DIM = {"16:9": (1920, 1080), "9:16": (1080, 1920)}
AREA_SEGURA = 0.03  # fração do lado menor que o texto deixa livre em cada borda
INSTANTES = (0.35, 0.6, 0.9)  # frações da duração em que o portão mede e fotografa


def _codigo(texto):
    """Sem comentários (a regra vale para o que roda, não para o que explica)."""
    texto = re.sub(r"/\*.*?\*/", "", texto, flags=re.S)
    return re.sub(r"(?m)(^|[^:\"'])//.*$", r"\1", texto)


def checar_codigo(id_, ficha: Ficha):
    """Checagens estáticas: arquivos, sintaxe, registro do id, pele só por variáveis, encaixes/botões declarados."""
    erros, avisos = [], []
    p = pasta(id_)
    js_arq, css_arq = p / "peca.js", p / "peca.css"
    if not js_arq.exists():
        return [f"falta {js_arq.name}"], avisos
    js = js_arq.read_text()
    css = css_arq.read_text() if css_arq.exists() else ""
    node = _node()
    if node:
        r = subprocess.run([node, "--check", str(js_arq)], capture_output=True, text=True)
        if r.returncode:
            erros.append("sintaxe do peca.js: " + (r.stderr.strip().splitlines() or ["?"])[-1])
    else:
        avisos.append("node não encontrado: sintaxe não conferida")
    if not re.search(rf"ESTUDIO\.peca\(\s*[\"']{re.escape(id_)}[\"']", js):
        erros.append(f'peca.js não registra a peça: ESTUDIO.peca("{id_}", (k, c) => ...)')
    for nome, texto in (("peca.js", _codigo(js)), ("peca.css", _codigo(css))):
        if m := RE_COR.search(texto):
            erros.append(f"{nome}: cor fixa ({m.group(0)}); use var(--destaque), var(--texto)… ou color-mix com elas")
        if m := RE_COR_NOME.search(texto):
            erros.append(f"{nome}: cor fixa pelo nome ({m.group(0)})")
        if RE_FONTE.search(texto):
            erros.append(f"{nome}: fonte fixa; use var(--fD), var(--fT), var(--fM) ou var(--fE)")
    if css:
        for sel in re.findall(r"(?:^|[{}])\s*([^{}@;]+)\{", _codigo(css)):
            partes = [s.strip() for s in sel.split(",") if s.strip()]
            if all(re.fullmatch(r"from|to|[\d.]+%", s) for s in partes):  # quadros de @keyframes
                continue
            if any(f".p-{id_}" not in s for s in partes):
                erros.append(f"peca.css: seletor fora de .p-{id_} ({sel.strip()[:40]})")
                break
    if colide := _classes(js) & _classes_kit() - REUSO:
        erros.append(f"peca.js usa classes do kit ({sorted(colide)[:5]}): o estilo global do kit vaza para a peça; "
                     f"use o prefixo da peça (ex.: {id_[:2]}-titulo)")
    usados_e, usados_b = _usados(js, "encaixes"), _usados(js, "botoes")
    nomes_e, nomes_b = {e.nome for e in ficha.encaixes}, {b.nome for b in ficha.botoes}
    if fora := usados_e - nomes_e - {"*"}:
        erros.append(f"peca.js usa encaixes que a ficha não declara: {sorted(fora)}")
    if fora := usados_b - nomes_b:
        erros.append(f"peca.js usa botões que a ficha não declara: {sorted(fora)}")
    if "*" in usados_e:
        usados_e = (usados_e - {"*"}) | nomes_e
    if parados := nomes_e - usados_e:
        avisos.append(f"encaixes declarados e não usados: {sorted(parados)}")
    if parados := nomes_b - usados_b:
        avisos.append(f"botões declarados e não usados: {sorted(parados)}")
    return erros, avisos


# classes do núcleo do kit que as peças reusam de propósito (estilo comum: título, rótulo, etiqueta, número grande)
REUSO = {"kicker", "traco", "veu", "pw", "pl", "l", "d", "baixo", "cheio", "centro", "titulo", "tag", "tx", "tk", "ngr",
         "nn", "ctx", "kick2"}


def _classes_kit():
    from esteira.estudio import compilar
    return set(re.findall(r"\.([a-zA-Z][\w-]*)", _codigo((compilar.KIT / "estudio.css").read_text())))


def _classes(js):
    """Classes que a peça cria: k.$("div", "a b", ...), classList.add("x"), class="y" em HTML."""
    js = _codigo(js)
    nomes = set()
    for grupo in re.findall(r"\$\(\s*[\"'][a-z0-9]+[\"']\s*,\s*[\"']([^\"']+)[\"']", js):
        nomes |= set(grupo.split())
    for grupo in re.findall(r"classList\.add\(([^)]*)\)", js):
        nomes |= set(re.findall(r"[\"']([\w-]+)[\"']", grupo))
    for grupo in re.findall(r"class=\\?[\"']([^\"'\\]+)", js):
        nomes |= set(grupo.split())
    for grupo in re.findall(r"\bclass\s*:\s*[\"']([^\"']+)[\"']", js):  # svg("circle", {class: "arco"})
        nomes |= set(grupo.split())
    return nomes


def _usados(js, campo):
    """Nomes lidos de c.<campo> no código: direto (c.encaixes.x, c.encaixes["x"]), por apelido
    (const e = c.encaixes; e.x) ou por desestruturação (const { x, y } = c.encaixes)."""
    js = _codigo(js)
    nomes = {a or b for a, b in re.findall(rf"\bc\.{campo}\s*(?:\.\s*(\w+)|\[\s*[\"'](\w+)[\"']\s*\])", js)}
    for apelido in re.findall(rf"\b(\w+)\s*=\s*c\.{campo}\b(?!\s*[.\[])", js):
        nomes |= {a or b for a, b in re.findall(rf"\b{apelido}\s*(?:\.\s*(\w+)|\[\s*[\"'](\w+)[\"']\s*\])", js)}
    for apelido in re.findall(rf"\b(\w+)\s*=\s*\{{[^{{}}]*\.\.\.c\.{campo}\s*\}}", js):  # const e = { a: 1, ...c.encaixes }
        nomes |= {a or b for a, b in re.findall(rf"\b{apelido}\s*(?:\.\s*(\w+)|\[\s*[\"'](\w+)[\"']\s*\])", js)}
        if re.search(rf"\.\.\.{apelido}\b", js):  # passa tudo adiante (k.proporcao({{ ...c, ...e }}))
            nomes.add("*")
    for grupo in re.findall(rf"\b(?:const|let|var)\s*\{{([^{{}}]*)\}}\s*=\s*c\.{campo}\b", js):
        nomes |= {x.split(":")[0].split("=")[0].strip() for x in grupo.split(",") if x.strip()}
    return nomes


def _node():
    from esteira.estudio import motor
    n = motor.NODE / "bin" / "node"
    return str(n) if n.exists() else shutil.which("node")


def _cena(ficha: Ficha, dur, botoes=None, encaixes=None):
    enc = encaixes or maximos(ficha)
    t = 0.3
    batidas = {b: round(t + 0.4 + 0.5 * k, 2) for k, b in enumerate(ficha.batidas)}
    return {"cena": ficha.id, "t": t, "ate": round(t + dur, 2), "takeover": ficha.tela_cheia, "titulo": "",
            "valores": [], "frase": "", "encaixes": enc, "botoes": {**padroes(ficha), **(botoes or {})},
            "batidas": batidas}


def montar(destino, cenas, pele: Pele, formato, ids=None, dur=None, medir=False):
    """Composição mínima (kit + peças + pele + uma ou mais cenas, sem mídia) em `destino`: usada na prova do portão
    e na prévia das peças. `medir`: ao abrir com ?t=S, posiciona a timeline em S e grava o que estoura a tela."""
    from esteira.estudio import compilar, estilo, fontes
    a = destino / "assets"
    a.mkdir(parents=True, exist_ok=True)
    for nome in ("estudio.js", "estudio.css", "gsap.min.js"):
        shutil.copy(compilar.KIT / nome, a / nome)
    tres = juntar(a, ids)
    if "assets/amostra_pagina.png" in json.dumps(cenas):
        shutil.copy(amostra_pagina()["arquivo"], a / "amostra_pagina.png")
    if "assets/amostra_foto.png" in json.dumps(cenas):
        shutil.copy(amostra_foto(), a / "amostra_foto.png")
    papeis = ("fonte_destaque", "fonte_texto", "fonte_tecnica", "fonte_legenda", "fonte_editorial")
    (a / "fontes.css").write_text(fontes.css([getattr(pele, k) for k in papeis], a))
    pele = pele.model_copy(update={k: fontes.resolver(getattr(pele, k)) for k in papeis})
    base = estilo.Estilo(id="prova", nome="prova", canal="prova", pele=pele)
    rg = base.regras
    W, H = DIM[formato]
    dur = dur or max(c["ate"] for c in cenas) + 0.5
    cfg = {"W": W, "H": H, "pele": pele.model_dump(), "efeitos": rg.efeitos, "visual": rg.visual.model_dump(),
           "legenda": {"ativa": False, **rg.legenda_visual.model_dump(), "chaves": []},
           "movimento": base.movimento.model_dump(), "layouts": base.layouts.model_dump(),
           "regras_cor": base.regras_cor.model_dump(), "pecas": {}}
    html = (compilar.KIT / "index.template.html").read_text()
    for k, v in {"__W__": W, "__H__": H, "__DUR__": round(dur, 3), "__CFG__": json.dumps(cfg, ensure_ascii=False),
                 "__MIDIA__": "[]", "__CENAS__": json.dumps(cenas, ensure_ascii=False), "__WORDS__": "[]",
                 "__SFX__": "[]"}.items():
        html = html.replace(k, str(v))
    html = html.replace("__EC__", videos_ec(cenas)).replace("__DE__", "0").replace("__THREE__", TAG_THREE if tres else "")
    html = re.sub(r'\s*<audio id="voz"[^>]*></audio>', "", html)  # sem narração na prova/prévia
    if medir:
        html = html.replace("</body>", MEDIR.replace("__AREA__", str(AREA_SEGURA)) + "</body>")
    (destino / "index.html").write_text(html)
    return destino / "index.html"


# posiciona a timeline no instante pedido e anota no DOM os elementos visíveis que saem da tela
MEDIR = """<script>
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


def legado(cena, ficha: Ficha):
    """Cena do mapa do diretor atual (titulo/valores no topo) → encaixes da peça migrada."""
    if cena.get("encaixes"):
        return cena["encaixes"]
    nomes = {e.nome for e in ficha.encaixes}
    return {k: cena[k] for k in ("titulo", "valores") if k in nomes and k in cena}


def videos_ec(cenas):
    """<video> das cenas com peça EffectCraft já renderizada (`ec_src`), para a camada #ec do template."""
    return "".join(
        f'<video id="ec{n}" class="clip peca-ec" src="{c["ec_src"]}" muted playsinline data-start="{c["t"]:.3f}" '
        f'data-duration="{max(0.1, c["ate"] - c["t"]):.3f}" data-track-index="{30 + n % 2}"></video>'
        for n, c in enumerate(cenas) if c.get("ec_src"))


TAG_THREE = '<script src="assets/three.min.js"></script>\n'


_SINTAXE = {}


def _sintaxe_ok(arq):
    """`node --check` do peca.js (em memória por data de modificação); sem node ou sem arquivo, passa."""
    node = _node()
    if not node or not arq.exists():
        return True
    k = (str(arq), arq.stat().st_mtime_ns)
    if k not in _SINTAXE:
        _SINTAXE[k] = subprocess.run([node, "--check", str(arq)], capture_output=True).returncode == 0
    return _SINTAXE[k]


def juntar(destino_assets, ids=None):
    """`pecas.js` e `pecas.css` com as peças do acervo (todas as válidas, ou só `ids`) para a composição; com alguma
    peça 3D, copia o Three.js para os assets. → True se a composição precisa do Three.js."""
    escolhidas = ids if ids is not None else [f.id for f in listar()]
    tres = False
    for i in escolhidas:
        try:
            tres = tres or carregar(i).peso == "3d"
        except (KeyError, ValidationError):
            continue
    if tres:
        from esteira.estudio import compilar
        shutil.copy(compilar.KIT / "three.min.js", destino_assets / "three.min.js")
    js, css = [], []
    for i in escolhidas:
        p = pasta(i)
        if not _sintaxe_ok(p / "peca.js"):
            print(f"  peça {i} fora da composição: erro de sintaxe no peca.js", flush=True)
            continue  # um script quebrado no pecas.js derrubaria todas as peças do vídeo
        if (p / "peca.js").exists():
            js.append(f"// ── peça {i}\n" + (p / "peca.js").read_text())
        if (p / "peca.css").exists():
            css.append(f"/* ── peça {i} */\n" + (p / "peca.css").read_text())
    (destino_assets / "pecas.js").write_text("\n".join(js))
    (destino_assets / "pecas.css").write_text("\n".join(css))
    return tres


def _chromium(url, W, H, saida=None, budget=2500):
    from esteira.estudio import motor
    exe = motor._chromium()
    if not exe:
        raise RuntimeError("Chromium não instalado (aba Estúdio → Dependências)")
    args = [exe, "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
            f"--window-size={W},{H}", f"--virtual-time-budget={budget}"]
    args += [f"--screenshot={saida}", url] if saida else ["--dump-dom", url]
    r = subprocess.run(args, capture_output=True, text=True, timeout=90)
    if r.returncode and not saida:
        raise RuntimeError(r.stderr.strip()[-200:])
    return r.stdout


def provar(id_, ficha: Ficha):
    """Monta a peça com o preenchimento máximo nas duas peles × formatos da ficha; mede estouro de tela em
    INSTANTES e fotografa o meio. → (erros, quadros)."""
    erros, quadros = [], []
    prova = pasta(id_) / "prova"
    shutil.rmtree(prova, ignore_errors=True)
    prova.mkdir(parents=True)
    dur = min(ficha.duracao_max, max(ficha.duracao_min, 4.0))
    cena = _cena(ficha, dur)
    with tempfile.TemporaryDirectory() as tmp:
        for nome_pele, pele in PELES_PROVA.items():
            for fmt in ficha.formatos:
                d = Path(tmp) / f"{nome_pele}_{fmt.replace(':', 'x')}"
                idx = montar(d, [cena], pele, fmt, ids=[id_], dur=cena["ate"] + 0.5, medir=True)
                W, H = DIM[fmt]
                for frac in INSTANTES:
                    t = round(cena["t"] + frac * dur, 2)
                    dom = _chromium(f"file://{idx}?t={t}", W, H)
                    m = re.search(r'data-estouro="([^"]*)"', dom)
                    if not m:
                        erros.append(f"{nome_pele} {fmt}: a composição não rodou (erro de JavaScript na peça?)")
                        break
                    fora = json.loads(html_lib.unescape(m.group(1)))
                    if (e := re.search(r'data-erros="([^"]*)"', dom)) and (lst := json.loads(html_lib.unescape(e.group(1)))):
                        erros.append(f"{nome_pele} {fmt}: erro de JavaScript na peça: {lst[0]}")
                        break
                    if fora:
                        erros.append(f"{nome_pele} {fmt} em {t:.1f} s: sai da tela com o texto máximo: {fora[:4]}")
                png = Path(tmp) / f"{nome_pele}_{fmt.replace(':', 'x')}.png"
                _chromium(f"file://{idx}?t={round(cena['t'] + 0.6 * dur, 2)}", W, H, saida=png)
                arq = prova / png.with_suffix(".jpg").name  # metade do tamanho, JPG: a prova é para olhar
                if png.exists():
                    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(png), "-vf", "scale=iw/2:-2",
                                    "-q:v", "4", str(arq)], check=True)
                    quadros.append(arq.name)
    return erros, quadros


def portao(id_, render=True):
    """Portão de entrada da peça no acervo: ficha válida + código + prova nas duas peles × formatos. Passou e era
    rascunho → vai para a revisão da pessoa (a aprovação é dela). Grava `prova/portao.json`."""
    p = pasta(id_)
    try:
        ficha = Ficha.model_validate_json((p / "ficha.json").read_text())
    except FileNotFoundError:
        return {"ok": False, "erros": ["falta ficha.json"], "avisos": [], "quadros": []}
    except ValidationError as e:
        return {"ok": False, "erros": [f"ficha: {x['loc']}: {x['msg']}" for x in e.errors()], "avisos": [],
                "quadros": []}
    from esteira.estudio import ec
    erros, avisos = (ec.checar_codigo if ficha.motor == "effectcraft" else checar_codigo)(id_, ficha)
    if ficha.id != id_:
        erros.append(f"ficha.id ({ficha.id}) diferente da pasta ({id_})")
    if ficha.motor == "effectcraft" and not ec.disponivel():
        avisos.append("effectcraft-cli não encontrado: prova não feita")
        render = False
    if erros := erros + validar_dados(ficha, maximos(ficha)):
        render = False
    quadros, render_s = [], None
    if render:
        if ficha.motor == "effectcraft":
            e2, quadros, render_s = ec.provar(id_, ficha)
        else:
            t0 = time.monotonic()
            e2, quadros = provar(id_, ficha)
            render_s = round(time.monotonic() - t0, 2)
        erros += e2
    r = {"ok": not erros, "erros": erros, "avisos": avisos, "quadros": quadros, "versao": ficha.versao,
         "motor": ficha.motor, "render_s": render_s}
    (p / "prova").mkdir(exist_ok=True)
    (p / "prova" / "portao.json").write_text(json.dumps(r, ensure_ascii=False, indent=1))
    if r["ok"] and ficha.estado == "rascunho":
        salvar(ficha.model_copy(update={"estado": "revisao"}))
    return r


# ---------------------------------------------------------------- prévia animada (revisão)

def previas_dir(id_):
    from esteira.projeto import DADOS
    return DADOS / "estudio" / "fabrica" / "previas" / id_


def previa(id_, estilo_ref, formato=None):
    """MP4 curto da peça (preenchimento de exemplo) na pele do estilo de um canal, pelo HyperFrames (GPU) ou, no
    motor EffectCraft, pela engine dele."""
    from esteira.estudio import compilar, ec, estilo
    ficha = carregar(id_)
    est = estilo.carregar(estilo_ref)
    fmt = formato or ficha.formatos[0]
    if ficha.motor == "effectcraft":
        return ec.previa(id_, est, fmt)
    dur = min(ficha.duracao_max, max(ficha.duracao_min, 5.0))
    enc = {e.nome: e.exemplo for e in ficha.encaixes if e.exemplo and e.tipo not in ("pagina", "imagem")}
    enc = {**maximos(ficha), **enc}
    destino = previas_dir(id_) / f"_{est.id}"
    shutil.rmtree(destino, ignore_errors=True)
    montar(destino, [_cena(ficha, dur, encaixes=enc)], est.pele, fmt, ids=[id_], dur=dur + 1.0)
    bruto = compilar.render(None, fmt, qualidade="draft", p=destino)
    saida = previas_dir(id_) / f"{est.id}_{fmt.replace(':', 'x')}.mp4"
    shutil.move(str(bruto), saida)
    shutil.rmtree(destino, ignore_errors=True)
    return saida


# ---------------------------------------------------------------- prova de troca de pele entre canais

def exemplos(ficha: Ficha):
    """Preenchimento típico (os `exemplo` da ficha; o máximo só onde não há exemplo)."""
    m = maximos(ficha)
    return {e.nome: (e.exemplo if e.exemplo and e.tipo not in ("pagina", "imagem") else m[e.nome]) for e in ficha.encaixes}


def prova_canais(estilos, formatos=("16:9", "9:16"), ids=None):
    """Cada peça aprovada (ou `ids`) com o conteúdo de exemplo na pele de cada estilo: mede erro de JavaScript e
    estouro da área segura e monta uma folha por estilo × formato. A mesma peça tem de funcionar em todos os canais
    só pela pele. → {"folhas": [...], "problemas": [{peca, estilo, formato, erro}]}."""
    from esteira.estudio import estilo as E
    pasta_saida = previas_dir("_canais").parent / "_prova_canais"
    pasta_saida.mkdir(parents=True, exist_ok=True)
    fichas = [carregar(i) for i in ids] if ids else listar("aprovada")
    problemas, folhas = [], []
    with tempfile.TemporaryDirectory() as tmp:
        for ref in estilos:
            est = E.carregar(ref)
            for fmt in formatos:
                W, H = DIM[fmt]
                quadros = []
                for f in fichas:
                    if fmt not in f.formatos:
                        continue
                    dur = min(f.duracao_max, max(f.duracao_min, 4.0))
                    cena = _cena(f, dur, encaixes=exemplos(f))
                    d = Path(tmp) / f"{est.id}_{fmt.replace(':', 'x')}_{f.id}"
                    if f.motor == "effectcraft":
                        q = _prova_canal_ec(f, cena, dur, est, fmt, d, problemas)
                        if q:
                            quadros.append(q)
                        continue
                    idx = montar(d, [cena], est.pele, fmt, ids=[f.id] + _quedas(f), dur=cena["ate"] + 0.5, medir=True)
                    t = round(cena["t"] + 0.6 * dur, 2)
                    dom = _chromium(f"file://{idx}?t={t}", W, H)
                    er = re.search(r'data-erros="([^"]*)"', dom)
                    es = re.search(r'data-estouro="([^"]*)"', dom)
                    lst_e = json.loads(html_lib.unescape(er.group(1))) if er else ["a composição não rodou"]
                    lst_s = json.loads(html_lib.unescape(es.group(1))) if es else []
                    for x in lst_e:
                        problemas.append({"peca": f.id, "estilo": est.id, "formato": fmt, "erro": f"JavaScript: {x}"})
                    if lst_s:
                        problemas.append({"peca": f.id, "estilo": est.id, "formato": fmt, "erro": f"sai da área segura: {lst_s[:3]}"})
                    png = d / "quadro.png"
                    _chromium(f"file://{idx}?t={t}", W, H, saida=png)
                    if png.exists():
                        quadros.append(png)
                if quadros:
                    folha = pasta_saida / f"{est.id}_{fmt.replace(':', 'x')}.jpg"
                    _folha(quadros, folha, 6 if W > H else 8)
                    folhas.append(folha.name)
    r = {"estilos": list(estilos), "pecas": [f.id for f in fichas], "folhas": folhas, "problemas": problemas}
    (pasta_saida / "resultado.json").write_text(json.dumps(r, ensure_ascii=False, indent=1))
    return r


def _prova_canal_ec(f, cena, dur, est, fmt, pasta_tmp, problemas):
    """Peça EffectCraft na pele do estilo: estouro da área segura e o quadro do meio (ou o erro do script)."""
    from esteira.estudio import ec
    pasta_tmp.mkdir(parents=True, exist_ok=True)
    t = round(cena["t"] + 0.6 * dur, 2)
    d = ec.dados(f, cena["encaixes"], cena["botoes"], cena["batidas"], est.pele, fmt, dur, cena["t"], [t], AREA_SEGURA)
    try:
        estouros, _ = ec.montar(f.id, d, pasta_tmp / "p.ecproj", est.pele)
    except (RuntimeError, subprocess.TimeoutExpired) as e:
        problemas.append({"peca": f.id, "estilo": est.id, "formato": fmt, "erro": f"EffectCraft: {str(e)[:200]}"})
        return None
    if estouros:
        problemas.append({"peca": f.id, "estilo": est.id, "formato": fmt, "erro": f"sai da área segura: {estouros[:3]}"})
    return ec.quadro(pasta_tmp / "p.ecproj", t, pasta_tmp / "quadro.jpg", est.pele.fundo, escala=1.0)


def _quedas(ficha: Ficha):
    """Peças em que esta cai quando o conteúdo não serve (`k.outra`), para a composição ter as duas."""
    js = (pasta(ficha.id) / "peca.js").read_text() if (pasta(ficha.id) / "peca.js").exists() else ""
    return sorted(set(re.findall(r'k\.outra\("(\w+)"', js)))


def _folha(quadros, destino, colunas):
    """Folha de contato (ffmpeg xstack) com os quadros em miniatura, na ordem."""
    n = len(quadros)
    larg = 320
    entradas = sum((["-i", str(q)] for q in quadros), [])
    escala = "".join(f"[{i}]scale={larg}:-2[a{i}];" for i in range(n))
    if n == 1:
        filtro = f"[0]scale={larg}:-2"
    else:
        # posições: colunas de `larg` px; linhas pela altura da primeira miniatura (h0)
        pos = "|".join(("0" if i % colunas == 0 else "+".join(f"w{j}" for j in range(i - i % colunas, i)))
                       + "_" + ("0" if i < colunas else "+".join("h0" for _ in range(i // colunas))) for i in range(n))
        filtro = escala + "".join(f"[a{i}]" for i in range(n)) + f"xstack=inputs={n}:layout={pos}:fill=black"
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", *entradas, "-filter_complex", filtro, "-frames:v", "1",
                    "-q:v", "4", str(destino)], check=True)
