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

FORMATO = "agent-wireframe"
VERSAO = 1
ESTADOS = ("existe", "proposto", "divergencia")
CORES = ("azul", "ambar", "vermelho", "verde", "roxo", "ciano", "cinza")
CORES_TEXTO = ("tinta", "suave", "branco", *CORES)
LEGENDA = {
    "existe": "azul: já existe no sistema",
    "proposto": "âmbar tracejado: proposto (ainda não existe)",
    "divergencia": "vermelho tracejado: divergência entre o que existe e o esperado",
}
_STR = {"type": "string"}
_BOOL = {"type": "boolean"}
_NUM = {"type": "number"}
_ITEM_ESTADO = {
    "type": "object",
    "required": ["texto"],
    "properties": {"texto": _STR, "estado": {"enum": [*ESTADOS, "desabilitado"]}},
}

# Catálogo: tipo → (descrição, props). É a fonte do schema, do AGENTS.md e da validação.
COMPONENTES: dict[str, tuple[str, dict[str, Any]]] = {
    "texto": (
        "Texto solto (títulos, legendas).",
        {
            "texto": _STR,
            "tamanho": {**_NUM, "default": 13},
            "negrito": _BOOL,
            "mono": _BOOL,
            "cor": {"enum": list(CORES_TEXTO), "default": "tinta"},
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
    "selo": ("Etiqueta colorida (status).", {"texto": _STR, "cor": {"enum": list(CORES)}}),
    "abas": (
        "Barra de abas.",
        {"itens": {"type": "array", "items": _ITEM_ESTADO}, "ativa": {"type": "integer"}},
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
                        "estado": {"enum": list(ESTADOS)},
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
                                "properties": {"texto": _STR, "selo": {"enum": list(CORES)}},
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
    "menu": ("Menu suspenso.", {"itens": {"type": "array", "items": _ITEM_ESTADO}}),
    "modal": (
        "Janela modal: escurece a tela; os componentes seguintes ficam por cima.",
        {"titulo": _STR},
    ),
    "painel": (
        "Retângulo de agrupamento, com título opcional.",
        {"titulo": _STR, "fundo": {"enum": ["branco", "cinza", *CORES]}},
    ),
    "seta": (
        "Seta por pontos relativos a (x, y); a ponta fica no último.",
        {
            "pontos": {
                "type": "array",
                "minItems": 2,
                "items": {"type": "array", "items": _NUM, "minItems": 2, "maxItems": 2},
            },
            "cor": {"enum": list(CORES_TEXTO)},
        },
    ),
}
TIPOS = tuple(COMPONENTES)
_BASE = ("id", "tipo", "x", "y", "largura", "altura", "estado")


class FormatoInvalido(Exception):
    pass


def _novo_id() -> str:
    return uuid.uuid4().hex[:12]


def tela_padrao(n: int = 1) -> dict[str, Any]:
    return {
        "id": _novo_id(),
        "nome": f"Tela {n}",
        "codigo": f"WF-{n:02d}",
        "subtitulo": "",
        "caminho": [],
        "largura": 1280,
        "altura": 1080,
        "notas": [],
    }


def schema() -> dict[str, Any]:
    componentes = [
        {
            "if": {"properties": {"tipo": {"const": t}}},
            "then": {"properties": props, "description": desc},
        }
        for t, (desc, props) in COMPONENTES.items()
    ]
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "agent-wireframe/1",
        "title": "Wireframe (agent-wireframe v1)",
        "type": "object",
        "required": ["formato", "versao", "titulo", "telas"],
        "properties": {
            "formato": {"const": FORMATO},
            "versao": {"const": VERSAO},
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
                    "tipo": {"enum": list(TIPOS)},
                    "x": _NUM,
                    "y": _NUM,
                    "largura": _NUM,
                    "altura": _NUM,
                    "estado": {"enum": list(ESTADOS), "default": "existe"},
                    "nota": {"type": "integer", "description": "Número da nota ligada (marcador)"},
                },
                "allOf": componentes,
            },
            "nota": {
                "type": "object",
                "required": ["n", "titulo"],
                "properties": {
                    "n": {"type": "integer"},
                    "estado": {"enum": list(ESTADOS)},
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
    catalogo = "\n".join(
        f"| `{t}` | {desc} | {', '.join(f'`{p}`' for p in props) or '—'} |"
        for t, (desc, props) in COMPONENTES.items()
    )
    estados = "\n".join(f"- `{k}`: {v}" for k, v in LEGENDA.items())
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
{estados}
5. `notas` formam o painel lateral (componente, clique, endpoint). Ligue componente e nota com
   `"nota": <n>`; o número aparece num marcador sobre o componente.
6. Use só os tipos e propriedades do catálogo abaixo; nada de HTML ou CSS.
7. `telas/<id>.png` (campo `imagem` da tela) mostra como a tela está desenhada hoje: use para
   entender o layout, mas edite só o JSON; as imagens são refeitas a cada exportação.

## Catálogo de componentes

| tipo | o que é | propriedades |
|---|---|---|
{catalogo}

## Exemplo de componente

```json
{{"id": "btn-gerar", "tipo": "botao", "x": 1020, "y": 48, "largura": 118, "altura": 32,
 "estado": "existe", "texto": "Gerar ND", "variante": "primario", "icone": "+", "nota": 2}}
```
"""


def para_ia(doc: dict[str, Any]) -> dict[str, Any]:
    """Documento interno → `wireframe.json`."""
    paginas = doc.get("paginas") or [tela_padrao()]
    primeira = paginas[0]["id"]
    telas = []
    for p in paginas:
        componentes = []
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
            componentes.append(c)
        telas.append(
            {
                "id": p["id"],
                "codigo": p.get("codigo", ""),
                "titulo": p.get("nome", ""),
                "subtitulo": p.get("subtitulo", ""),
                "caminho": p.get("caminho", []),
                "largura": p.get("largura", 1280),
                "altura": p.get("altura", 1080),
                "componentes": componentes,
                "notas": p.get("notas", []),
            }
        )
    return {
        "$schema": "./wireframe.schema.json",
        "formato": FORMATO,
        "versao": VERSAO,
        "titulo": doc.get("titulo", ""),
        "legenda": LEGENDA,
        "telas": telas,
    }


def _num(v: Any, onde: str) -> float:
    if isinstance(v, bool) or not isinstance(v, int | float):
        raise FormatoInvalido(f"{onde}: número esperado")
    return v


def de_ia(dados: dict[str, Any]) -> dict[str, Any]:
    """`wireframe.json` → `{titulo, paginas, elementos}` internos; o erro diz onde falhou."""
    if not isinstance(dados, dict) or dados.get("formato") != FORMATO:
        raise FormatoInvalido(f'"formato" deve ser "{FORMATO}"')
    if dados.get("versao") != VERSAO:
        raise FormatoInvalido(f"Versão {dados.get('versao')!r} não suportada (esperado {VERSAO})")
    telas = dados.get("telas")
    if not isinstance(telas, list) or not telas:
        raise FormatoInvalido('"telas" precisa de ao menos uma tela')
    paginas, elementos, ids = [], [], set()
    for i, t in enumerate(telas, 1):
        if not isinstance(t, dict):
            raise FormatoInvalido(f"telas[{i - 1}]: objeto esperado")
        # O id vira nome do PNG da tela no pacote: só letras, números, _ e -.
        tid = re.sub(r"[^\w-]", "-", str(t.get("id") or _novo_id()))[:64]
        notas = t.get("notas") or []
        for nota in notas:
            if not isinstance(nota, dict) or not isinstance(nota.get("n"), int):
                raise FormatoInvalido(f"Tela {tid}: nota sem número inteiro em n")
            if nota.get("estado", "existe") not in ESTADOS:
                raise FormatoInvalido(f"Tela {tid}, nota {nota['n']}: estado inválido")
        paginas.append(
            {
                "id": tid,
                "nome": str(t.get("titulo") or f"Tela {i}"),
                "codigo": str(t.get("codigo", "")),
                "subtitulo": str(t.get("subtitulo", "")),
                "caminho": [str(c) for c in t.get("caminho") or []],
                "largura": _num(t.get("largura", 1280), f"Tela {tid}.largura"),
                "altura": _num(t.get("altura", 1080), f"Tela {tid}.altura"),
                "notas": notas,
            }
        )
        for c in t.get("componentes") or []:
            onde = f"Tela {tid}, componente {c.get('id', '?') if isinstance(c, dict) else '?'}"
            if not isinstance(c, dict) or c.get("tipo") not in TIPOS:
                raise FormatoInvalido(f"{onde}: tipo desconhecido (use {', '.join(TIPOS)})")
            if c.get("estado", "existe") not in ESTADOS:
                raise FormatoInvalido(f"{onde}: estado inválido")
            cid = str(c.get("id") or _novo_id())
            if cid in ids:
                cid = f"{cid}-{_novo_id()[:4]}"
            ids.add(cid)
            elementos.append(
                {
                    "id": cid,
                    "tipo": c["tipo"],
                    "pagina": tid,
                    "x": _num(c.get("x", 0), f"{onde}.x"),
                    "y": _num(c.get("y", 0), f"{onde}.y"),
                    "w": _num(c.get("largura", 0), f"{onde}.largura"),
                    "h": _num(c.get("altura", 0), f"{onde}.altura"),
                    "estado": c.get("estado", "existe"),
                    "props": {k: v for k, v in c.items() if k not in _BASE and k != "pagina"},
                }
            )
    titulo = str(dados.get("titulo") or "Wireframe")[:200]
    return {"titulo": titulo, "paginas": paginas, "elementos": elementos}


def pacote(doc: dict[str, Any], imagens: dict[str, bytes] | None = None) -> bytes:
    """ZIP para mandar a outra IA: `AGENTS.md`, `wireframe.schema.json`, `wireframe.json` e, com
    [imagens] ({id da tela: PNG}), `telas/<id>.png`, apontado no campo `imagem` de cada tela."""
    imagens = imagens or {}
    troca = para_ia(doc)
    for t in troca["telas"]:
        if t["id"] in imagens:
            t["imagem"] = f"telas/{t['id']}.png"
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("AGENTS.md", agents_md(doc.get("titulo", "")))
        z.writestr("wireframe.schema.json", json.dumps(schema(), ensure_ascii=False, indent=2))
        z.writestr("wireframe.json", json.dumps(troca, ensure_ascii=False, indent=2))
        for t in troca["telas"]:
            if t["id"] in imagens:
                z.writestr(t["imagem"], imagens[t["id"]], zipfile.ZIP_STORED)
    return buf.getvalue()


def ler(bruto: bytes) -> dict[str, Any]:
    """ZIP (acha o `wireframe.json`), JSON puro ou texto com bloco ```json → formato interno."""
    if bruto.startswith(b"PK"):
        try:
            with zipfile.ZipFile(io.BytesIO(bruto)) as z:
                nomes = [n for n in z.namelist() if n.endswith(".json") and "schema" not in n]
                nome = next((n for n in nomes if n.endswith("wireframe.json")), None)
                if nome is None and not nomes:
                    raise FormatoInvalido("ZIP sem wireframe.json")
                texto = z.read(nome or nomes[0]).decode("utf-8")
        except zipfile.BadZipFile as e:
            raise FormatoInvalido("ZIP corrompido") from e
    else:
        texto = bruto.decode("utf-8", "ignore")
        bloco = re.search(r"```(?:json)?\s*(\{.*\})\s*```", texto, re.S)
        if bloco:
            texto = bloco.group(1)
    try:
        dados = json.loads(texto)
    except json.JSONDecodeError as e:
        raise FormatoInvalido(f"JSON inválido (linha {e.lineno}, coluna {e.colno})") from e
    return de_ia(dados)
