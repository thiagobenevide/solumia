"""Wireframes: the exchange format with other AIs and the conversion from/to the internal format.

Internal (stored by [Frames] in `wireframes/`, like the boards): `paginas` = screens
(`{id, nome, codigo, subtitulo, caminho, largura, altura, notas}`) and `elementos` = components
(`{id, tipo, pagina, x, y, w, h, estado, props}`), in px relative to the window's usable area.

Exchange (`wireframe.json`, format `agent-wireframe` v1): nested screens with the components of each
one, props flattened into the component itself and `largura`/`altura` spelled out. It goes in a ZIP
with the JSON Schema (`wireframe.schema.json`, draft 2020-12) and the instructions (`AGENTS.md`),
the
convention coding agents (Codex, Claude Code, Cursor…) read. The AI returns the `wireframe.json`
(alone, in a ZIP or even inside a ```json block) and [of_ai] validates and converts it back."""

import io
import json
import re
import uuid
import zipfile
from typing import Any

FORMAT = "agent-wireframe"
VERSION = 1
STATES = ("existe", "proposto", "divergencia")
COLORS = ("azul", "ambar", "vermelho", "verde", "roxo", "ciano", "cinza")
COLORS_TEXT = ("tinta", "suave", "branco", *COLORS)
CAPTION = {
    "existe": "azul: já existe no sistema",
    "proposto": "âmbar tracejado: proposto (ainda não existe)",
    "divergencia": "vermelho tracejado: divergência entre o que existe e o esperado",
}
_STR = {"type": "string"}
_BOOL = {"type": "boolean"}
_NUM = {"type": "number"}
_ITEM_STATE = {
    "type": "object",
    "required": ["texto"],
    "properties": {"texto": _STR, "estado": {"enum": [*STATES, "desabilitado"]}},
}

# Catalog: type → (description, props). It is the source of the schema, of AGENTS.md and of
# validation.
COMPONENTS: dict[str, tuple[str, dict[str, Any]]] = {
    "texto": (
        "Loose text (titles, captions).",
        {
            "texto": _STR,
            "tamanho": {**_NUM, "default": 13},
            "negrito": _BOOL,
            "mono": _BOOL,
            "cor": {"enum": list(COLORS_TEXT), "default": "tinta"},
        },
    ),
    "botao": (
        "Button with text.",
        {
            "texto": _STR,
            "variante": {
                "enum": ["primario", "secundario", "perigo", "sucesso", "fantasma"],
                "default": "primario",
            },
            "icone": {**_STR, "description": "Caractere antes do texto, ex.: +"},
        },
    ),
    "botao_icone": ("Square button with an icon only.", {"icone": _STR}),
    "campo": (
        "Form field with the label on top (height > 46 becomes a text area).",
        {
            "rotulo": _STR,
            "valor": _STR,
            "somente_leitura": _BOOL,
            "busca": {**_BOOL, "description": "Lookup: lupa e ✕ à direita"},
            "combo": {**_BOOL, "description": "Lista suspensa: ▾ à direita"},
            "obrigatorio": _BOOL,
        },
    ),
    "caixa": ("Checkbox.", {"marcado": _BOOL, "texto": _STR}),
    "selo": ("Colored tag (status).", {"texto": _STR, "cor": {"enum": list(COLORS)}}),
    "abas": (
        "Tab bar.",
        {"itens": {"type": "array", "items": _ITEM_STATE}, "ativa": {"type": "integer"}},
    ),
    "cartoes": (
        "Row of summary cards (label + value).",
        {
            "itens": {
                "type": "array",
                "items": {
                    "type": "object",
                    "required": ["rotulo", "valor"],
                    "properties": {"rotulo": _STR, "valor": _STR},
                },
            }
        },
    ),
    "tabela": (
        "Table; a cell is text or {texto, selo} for a colored status.",
        {
            "colunas": {
                "type": "array",
                "items": {
                    "type": "object",
                    "required": ["titulo", "largura"],
                    "properties": {
                        "titulo": _STR,
                        "largura": _NUM,
                        "estado": {"enum": list(STATES)},
                    },
                },
            },
            "linhas": {
                "type": "array",
                "items": {
                    "type": "array",
                    "items": {
                        "anyOf": [
                            _STR,
                            {
                                "type": "object",
                                "required": ["texto"],
                                "properties": {"texto": _STR, "selo": {"enum": list(COLORS)}},
                            },
                        ]
                    },
                },
            },
            "destaque": {"type": ["integer", "null"], "description": "Linha selecionada"},
            "altura_linha": {**_NUM, "default": 30},
        },
    ),
    "paginador": ("Pagination footer.", {"info": _STR}),
    "menu": ("Dropdown menu.", {"itens": {"type": "array", "items": _ITEM_STATE}}),
    "modal": (
        "Modal window: darkens the screen; the following components go on top.",
        {"titulo": _STR},
    ),
    "painel": (
        "Grouping rectangle, with an optional title.",
        {"titulo": _STR, "fundo": {"enum": ["branco", "cinza", *COLORS]}},
    ),
    "seta": (
        "Arrow through points relative to (x, y); the tip is on the last one.",
        {
            "pontos": {
                "type": "array",
                "minItems": 2,
                "items": {"type": "array", "items": _NUM, "minItems": 2, "maxItems": 2},
            },
            "cor": {"enum": list(COLORS_TEXT)},
        },
    ),
}
KINDS = tuple(COMPONENTS)
_BASE = ("id", "tipo", "x", "y", "largura", "altura", "estado")


class FormatInvalid(Exception):
    pass


def _new_id() -> str:
    return uuid.uuid4().hex[:12]


def screen_default(n: int = 1) -> dict[str, Any]:
    return {
        "id": _new_id(),
        "nome": f"Tela {n}",
        "codigo": f"WF-{n:02d}",
        "subtitulo": "",
        "caminho": [],
        "largura": 1280,
        "altura": 1080,
        "notas": [],
    }


def schema() -> dict[str, Any]:
    components = [
        {
            "if": {"properties": {"tipo": {"const": t}}},
            "then": {"properties": props, "description": desc},
        }
        for t, (desc, props) in COMPONENTS.items()
    ]
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "agent-wireframe/1",
        "title": "Wireframe (agent-wireframe v1)",
        "type": "object",
        "required": ["formato", "versao", "titulo", "telas"],
        "properties": {
            "formato": {"const": FORMAT},
            "versao": {"const": VERSION},
            "titulo": _STR,
            "legenda": {"type": "object", "additionalProperties": _STR},
            "telas": {"type": "array", "minItems": 1, "items": {"$ref": "#/$defs/tela"}},
        },
        "$defs": {
            "tela": {
                "type": "object",
                "required": ["id", "titulo", "componentes"],
                "properties": {
                    "id": _STR,
                    "codigo": {**_STR, "description": "Ex.: WF-ND-03"},
                    "titulo": _STR,
                    "subtitulo": _STR,
                    "caminho": {"type": "array", "items": _STR, "description": "Breadcrumb"},
                    "largura": {**_NUM, "default": 1280},
                    "altura": {**_NUM, "default": 1080},
                    "imagem": {
                        **_STR,
                        "description": "PNG de referência da tela no pacote (só leitura)",
                    },
                    "componentes": {"type": "array", "items": {"$ref": "#/$defs/componente"}},
                    "notas": {"type": "array", "items": {"$ref": "#/$defs/nota"}},
                },
            },
            "componente": {
                "type": "object",
                "required": ["id", "tipo", "x", "y", "largura", "altura"],
                "properties": {
                    "id": _STR,
                    "tipo": {"enum": list(KINDS)},
                    "x": _NUM,
                    "y": _NUM,
                    "largura": _NUM,
                    "altura": _NUM,
                    "estado": {"enum": list(STATES), "default": "existe"},
                    "nota": {"type": "integer", "description": "Número da nota ligada (marcador)"},
                },
                "allOf": components,
            },
            "nota": {
                "type": "object",
                "required": ["n", "titulo"],
                "properties": {
                    "n": {"type": "integer"},
                    "estado": {"enum": list(STATES)},
                    "titulo": _STR,
                    "linhas": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "required": ["texto"],
                            "properties": {
                                "rotulo": {**_STR, "description": "Ex.: Componente, Endpoint"},
                                "texto": _STR,
                            },
                        },
                    },
                },
            },
        },
    }


def agents_md(titulo: str) -> str:
    catalog = "\n".join(
        f"| `{t}` | {desc} | {', '.join(f'`{p}`' for p in props) or '—'} |"
        for t, (desc, props) in COMPONENTS.items()
    )
    states = "\n".join(f"- `{k}`: {v}" for k, v in CAPTION.items())
    return f"""# Wireframe: {titulo}

Package `agent-wireframe` v1. You are going to edit **`wireframe.json`**; it follows
`wireframe.schema.json` (JSON Schema 2020-12). Return the complete, valid `wireframe.json`, only it,
with no comments. The texts shown on screen are in Brazilian Portuguese; keep them that way.

## Rules

1. Do not change `formato` or `versao`. Keep the `id` of everything that already exists; for new
   items, create short, unique ids (e.g.: `btn-gerar-nd`).
2. Coordinates in px, relative to the top-left corner of the usable area of each screen's window
   (`largura` × `altura`, default 1280 × 1080). `x`, `y`, `largura`, `altura` on every component.
3. The order of `componentes` is the drawing order: what comes later goes on top. A `modal` darkens
   everything that came before it; put the modal's content right after it.
4. `estado` of each component, tab, menu item and column:
{states}
5. `notas` form the side panel (component, click, endpoint). Link a component and a note with
   `"nota": <n>`; the number appears in a marker over the component.
6. Use only the types and properties of the catalog below; no HTML or CSS.
7. `telas/<id>.png` (the screen's `imagem` field) shows how the screen is drawn today: use it to
   understand the layout, but edit only the JSON; the images are redone on every export.

## Component catalog

| tipo | what it is | properties |
|---|---|---|
{catalog}

## Component example

```json
{{"id": "btn-gerar", "tipo": "botao", "x": 1020, "y": 48, "largura": 118, "altura": 32,
 "estado": "existe", "texto": "Gerar ND", "variante": "primario", "icone": "+", "nota": 2}}
```
"""


def for_ai(doc: dict[str, Any]) -> dict[str, Any]:
    """Internal document → `wireframe.json`."""
    pages = doc.get("paginas") or [screen_default()]
    primeira = pages[0]["id"]
    telas = []
    for p in pages:
        components = []
        for e in doc.get("elementos", []):
            if (e.get("pagina") or primeira) != p["id"]:
                continue
            c = {
                "id": e["id"],
                "tipo": e["tipo"],
                "x": e.get("x", 0),
                "y": e.get("y", 0),
                "largura": e.get("w", 0),
                "altura": e.get("h", 0),
                "estado": e.get("estado", "existe"),
            }
            c.update({k: v for k, v in (e.get("props") or {}).items() if k not in _BASE})
            components.append(c)
        telas.append(
            {
                "id": p["id"],
                "codigo": p.get("codigo", ""),
                "titulo": p.get("nome", ""),
                "subtitulo": p.get("subtitulo", ""),
                "caminho": p.get("caminho", []),
                "largura": p.get("largura", 1280),
                "altura": p.get("altura", 1080),
                "componentes": components,
                "notas": p.get("notas", []),
            }
        )
    return {
        "$schema": "./wireframe.schema.json",
        "formato": FORMAT,
        "versao": VERSION,
        "titulo": doc.get("titulo", ""),
        "legenda": CAPTION,
        "telas": telas,
    }


def _num(v: Any, where: str) -> float:
    if isinstance(v, bool) or not isinstance(v, int | float):
        raise FormatInvalid(f"{where}: número esperado")
    return v


def of_ai(dados: dict[str, Any]) -> dict[str, Any]:
    """`wireframe.json` → internal `{titulo, paginas, elementos}`; the error says where it
    failed."""
    if not isinstance(dados, dict) or dados.get("formato") != FORMAT:
        raise FormatInvalid(f'"formato" deve ser "{FORMAT}"')
    if dados.get("versao") != VERSION:
        raise FormatInvalid(f"Versão {dados.get('versao')!r} não suportada (esperado {VERSION})")
    telas = dados.get("telas")
    if not isinstance(telas, list) or not telas:
        raise FormatInvalid('"telas" precisa de ao menos uma tela')
    pages, elements, ids = [], [], set()
    for i, t in enumerate(telas, 1):
        if not isinstance(t, dict):
            raise FormatInvalid(f"telas[{i - 1}]: objeto esperado")
        # The id becomes the name of the screen PNG in the package: only letters, digits, _ and -.
        tid = re.sub(r"[^\w-]", "-", str(t.get("id") or _new_id()))[:64]
        notes = t.get("notas") or []
        for note in notes:
            if not isinstance(note, dict) or not isinstance(note.get("n"), int):
                raise FormatInvalid(f"Tela {tid}: nota sem número inteiro em n")
            if note.get("estado", "existe") not in STATES:
                raise FormatInvalid(f"Tela {tid}, nota {note['n']}: estado inválido")
        pages.append(
            {
                "id": tid,
                "nome": str(t.get("titulo") or f"Tela {i}"),
                "codigo": str(t.get("codigo", "")),
                "subtitulo": str(t.get("subtitulo", "")),
                "caminho": [str(c) for c in t.get("caminho") or []],
                "largura": _num(t.get("largura", 1280), f"Tela {tid}.largura"),
                "altura": _num(t.get("altura", 1080), f"Tela {tid}.altura"),
                "notas": notes,
            }
        )
        for c in t.get("componentes") or []:
            where = f"Tela {tid}, componente {c.get('id', '?') if isinstance(c, dict) else '?'}"
            if not isinstance(c, dict) or c.get("tipo") not in KINDS:
                raise FormatInvalid(f"{where}: tipo desconhecido (use {', '.join(KINDS)})")
            if c.get("estado", "existe") not in STATES:
                raise FormatInvalid(f"{where}: estado inválido")
            cid = str(c.get("id") or _new_id())
            if cid in ids:
                cid = f"{cid}-{_new_id()[:4]}"
            ids.add(cid)
            elements.append(
                {
                    "id": cid,
                    "tipo": c["tipo"],
                    "pagina": tid,
                    "x": _num(c.get("x", 0), f"{where}.x"),
                    "y": _num(c.get("y", 0), f"{where}.y"),
                    "w": _num(c.get("largura", 0), f"{where}.largura"),
                    "h": _num(c.get("altura", 0), f"{where}.altura"),
                    "estado": c.get("estado", "existe"),
                    "props": {k: v for k, v in c.items() if k not in _BASE and k != "pagina"},
                }
            )
    title = str(dados.get("titulo") or "Wireframe")[:200]
    return {"titulo": title, "paginas": pages, "elementos": elements}


def package(doc: dict[str, Any], images: dict[str, bytes] | None = None) -> bytes:
    """ZIP to send to another AI: `AGENTS.md`, `wireframe.schema.json`, `wireframe.json` and, with
    images ({screen id: PNG}), `telas/<id>.png`, referenced in the `imagem` field of each screen."""
    images = images or {}
    swap = for_ai(doc)
    for t in swap["telas"]:
        if t["id"] in images:
            t["imagem"] = f"telas/{t['id']}.png"
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("AGENTS.md", agents_md(doc.get("titulo", "")))
        z.writestr("wireframe.schema.json", json.dumps(schema(), ensure_ascii=False, indent=2))
        z.writestr("wireframe.json", json.dumps(swap, ensure_ascii=False, indent=2))
        for t in swap["telas"]:
            if t["id"] in images:
                z.writestr(t["imagem"], images[t["id"]], zipfile.ZIP_STORED)
    return buf.getvalue()


def read(raw: bytes) -> dict[str, Any]:
    """ZIP (finds the `wireframe.json`), plain JSON or text with a ```json block → internal
    format."""
    if raw.startswith(b"PK"):
        try:
            with zipfile.ZipFile(io.BytesIO(raw)) as z:
                names = [n for n in z.namelist() if n.endswith(".json") and "schema" not in n]
                name = next((n for n in names if n.endswith("wireframe.json")), None)
                if name is None and not names:
                    raise FormatInvalid("ZIP sem wireframe.json")
                text = z.read(name or names[0]).decode("utf-8")
        except zipfile.BadZipFile as e:
            raise FormatInvalid("ZIP corrompido") from e
    else:
        text = raw.decode("utf-8", "ignore")
        block = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.S)
        if block:
            text = block.group(1)
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        raise FormatInvalid(f"JSON inválido (linha {e.lineno}, coluna {e.colno})") from e
    return of_ai(data)
