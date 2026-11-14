"""Wireframes: formato de troca com outras IAs e a conversão de/para o formato interno.

Interno (guardado por [Quadros] em `wireframes/`, igual aos quadros): `paginas` = telas
(`{id, nome, codigo, subtitulo, caminho, largura, altura, notas}`) e `elementos` = componentes
(`{id, tipo, pagina, x, y, w, h, estado, props}`), em px relativos à área útil da janela.

Troca (`wireframe.json`, formato `agent-wireframe` v1): telas aninhadas com os componentes de cada
uma, props achatadas no próprio componente e `largura`/`altura` por extenso. Vai num ZIP com o JSON
Schema (`wireframe.schema.json`, draft 2020-12) e as instruções (`AGENTS.md`), o padrão que os
agentes de código (Codex, Claude Code, Cursor…) leem. A IA devolve o `wireframe.json` (sozinho, em
ZIP ou até dentro de bloco ```json) e [de_ia] valida e converte de volta."""

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

# Catálogo: tipo → (descrição, props). É a fonte do schema, do AGENTS.md e da validação.
COMPONENTS: dict[str, tuple[str, dict[str, Any]]] = {
    "texto": (
        "Texto solto (títulos, legendas).",
        {
            "texto": _STR,
            "tamanho": {**_NUM, "default": 13},
            "negrito": _BOOL,
            "mono": _BOOL,
            "cor": {"enum": list(COLORS_TEXT), "default": "tinta"},
        },
    ),
    "botao": (
        "Botão com texto.",
        {
            "texto": _STR,
            "variante": {
                "enum": ["primario", "secundario", "perigo", "sucesso", "fantasma"],
                "default": "primario",
            },
            "icone": {**_STR, "description": "Caractere antes do texto, ex.: +"},
        },
    ),
    "botao_icone": ("Botão quadrado só com ícone.", {"icone": _STR}),
    "campo": (
        "Campo de formulário com rótulo em cima (altura > 46 vira área de texto).",
        {
            "rotulo": _STR,
            "valor": _STR,
            "somente_leitura": _BOOL,
            "busca": {**_BOOL, "description": "Lookup: lupa e ✕ à direita"},
            "combo": {**_BOOL, "description": "Lista suspensa: ▾ à direita"},
            "obrigatorio": _BOOL,
        },
    ),
    "caixa": ("Caixa de marcação.", {"marcado": _BOOL, "texto": _STR}),
    "selo": ("Etiqueta colorida (status).", {"texto": _STR, "cor": {"enum": list(COLORS)}}),
    "abas": (
        "Barra de abas.",
        {"itens": {"type": "array", "items": _ITEM_STATE}, "ativa": {"type": "integer"}},
    ),
    "cartoes": (
        "Linha de cartões de resumo (rótulo + valor).",
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
        "Tabela; célula é texto ou {texto, selo} para status colorido.",
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
    "paginador": ("Rodapé de paginação.", {"info": _STR}),
    "menu": ("Menu suspenso.", {"itens": {"type": "array", "items": _ITEM_STATE}}),
    "modal": (
        "Janela modal: escurece a tela; os componentes seguintes ficam por cima.",
        {"titulo": _STR},
    ),
    "painel": (
        "Retângulo de agrupamento, com título opcional.",
        {"titulo": _STR, "fundo": {"enum": ["branco", "cinza", *COLORS]}},
    ),
    "seta": (
        "Seta por pontos relativos a (x, y); a ponta fica no último.",
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

Pacote `agent-wireframe` v1. Você vai editar **`wireframe.json`**; ele segue `wireframe.schema.json`
(JSON Schema 2020-12). Devolva o `wireframe.json` completo e válido, só ele, sem comentários.

## Regras

1. Não mude `formato` nem `versao`. Mantenha o `id` de tudo o que já existe; para itens novos, crie
   ids curtos e únicos (ex.: `btn-gerar-nd`).
2. Coordenadas em px, relativas ao canto superior esquerdo da área útil da janela de cada tela
   (`largura` × `altura`, padrão 1280 × 1080). `x`, `y`, `largura`, `altura` em todo componente.
3. A ordem de `componentes` é a ordem de desenho: o que vem depois fica por cima. Um `modal`
   escurece tudo o que veio antes; ponha o conteúdo do modal logo depois dele.
4. `estado` de cada componente, aba, item de menu e coluna:
{states}
5. `notas` formam o painel lateral (componente, clique, endpoint). Ligue componente e nota com
   `"nota": <n>`; o número aparece num marcador sobre o componente.
6. Use só os tipos e propriedades do catálogo abaixo; nada de HTML ou CSS.
7. `telas/<id>.png` (campo `imagem` da tela) mostra como a tela está desenhada hoje: use para
   entender o layout, mas edite só o JSON; as imagens são refeitas a cada exportação.

## Catálogo de componentes

| tipo | o que é | propriedades |
|---|---|---|
{catalog}

## Exemplo de componente

```json
{{"id": "btn-gerar", "tipo": "botao", "x": 1020, "y": 48, "largura": 118, "altura": 32,
 "estado": "existe", "texto": "Gerar ND", "variante": "primario", "icone": "+", "nota": 2}}
```
"""


def for_ai(doc: dict[str, Any]) -> dict[str, Any]:
    """Documento interno → `wireframe.json`."""
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
    """`wireframe.json` → `{titulo, paginas, elementos}` internos; o erro diz onde falhou."""
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
        # O id vira nome do PNG da tela no pacote: só letras, números, _ e -.
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
    """ZIP para mandar a outra IA: `AGENTS.md`, `wireframe.schema.json`, `wireframe.json` e, com
    [imagens] ({id da tela: PNG}), `telas/<id>.png`, apontado no campo `imagem` de cada tela."""
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
    """ZIP (acha o `wireframe.json`), JSON puro ou texto com bloco ```json → formato interno."""
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
