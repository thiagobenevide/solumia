"""Coleções de cada canal: tipo da nota, subpasta no cofre, campos do formulário e modelo do corpo.

Segue a estrutura do vault:
`Notas/Empreendimento/YouTube/<canal>/{Temas,História,Roteiros,Método}/`, com os planos de vídeos
em `Temas/Plano de 500 vídeos/`. Campos `link` são gravados como `[[Título]]` e viram relações
no grafo das notas.
"""

from typing import Any

RAIZ = "Notas/Empreendimento/YouTube"
MAPA = "[[MOC — Rede de Canais no YouTube]]"

STATUS = [
    "rascunho",
    "rascunho-llm",
    "em-andamento",
    "revisado",
    "gravado",
    "publicado",
    "arquivada",
]
STATUS_CANAL = ["ideia", "em-andamento", "ativo", "pausado", "arquivada"]


def _campo(nome: str, rotulo: str, tipo: str = "texto", opcoes: list[str] | None = None) -> dict:
    return {"nome": nome, "rotulo": rotulo, "tipo": tipo, "opcoes": opcoes or []}


_STATUS = _campo("status", "Status", "opcoes", STATUS)

COLECOES: dict[str, dict[str, Any]] = {
    "temas": {
        "tipo": "tema",
        "nome": "Temas",
        "item": "Tema",
        "pasta": "Temas",
        "tag": "empreendimento/youtube/temas",
        "campos": [
            _STATUS,
            _campo("numero", "Número", "numero"),
            _campo("fio", "Fio"),
            _campo("plano", "Plano", "link"),
            _campo("roteiro", "Roteiro", "link"),
            _campo("historia", "História", "link"),
        ],
        "modelo": (
            "## Títulos\n\n## Miniaturas (Testar e comparar)\n\n## Descrição do vídeo\n\n"
            "## Tags\n\n## Fontes de estudo\n\n## Força da evidência\n\n"
            "## Checklist\n- [ ] História\n- [ ] Roteiro\n"
        ),
    },
    "historias": {
        "tipo": "historia",
        "nome": "Histórias",
        "item": "História",
        "pasta": "História",
        "tag": "empreendimento/youtube/historia",
        "campos": [_STATUS, _campo("tema", "Tema", "link"), _campo("roteiro", "Roteiro", "link")],
        "modelo": (
            "## A história do vídeo\n\n## Arco narrativo\n\n| # | Parte | Início |\n|---|---|---|\n"
        ),
    },
    "roteiros": {
        "tipo": "roteiro",
        "nome": "Roteiros",
        "item": "Roteiro",
        "pasta": "Roteiros",
        "tag": "empreendimento/youtube/roteiros",
        "campos": [
            _STATUS,
            _campo("video", "Vídeo nº", "numero"),
            _campo("fio", "Fio"),
            _campo("formato", "Formato", "opcoes", ["L", "M", "D"]),
            _campo("evidencia", "Evidência", "opcoes", ["Consenso", "Moderada", "Debate"]),
            _campo("modo", "Modo", "opcoes", ["dark", "apresentador"]),
            _campo("tema", "Tema", "link"),
            _campo("plano", "Plano", "link"),
        ],
        "modelo": "## Leitura antes de gravar\n\n## Parte 1\n\n## Parte 2\n\n## Fechamento\n",
    },
    "planos": {
        "tipo": "plano-de-videos",
        "nome": "Planos",
        "item": "Plano",
        "pasta": "Temas/Plano de 500 vídeos",
        "tag": "empreendimento/youtube/canais",
        "campos": [_STATUS],
        "modelo": (
            "| # | Fio | Título | Gancho | Artigos-base | Evidência | Fmt |\n"
            "|---|---|---|---|---|---|---|\n"
        ),
    },
    "metodos": {
        "tipo": "metodo",
        "nome": "Método",
        "item": "Método",
        "pasta": "Método",
        "tag": "empreendimento/youtube/metodo",
        "campos": [_STATUS],
        "modelo": "## Formato\n\n## Estilo\n\n## Ritmo de publicação\n",
    },
}

MODELO_CANAL = (
    "> [!abstract] Posicionamento\n> \n\n## Público\n\n## Pilares de conteúdo\n\n"
    "## Formatos\n\n## Metas\n"
)

# Para o app de notas (`/api/notas/tipos`) mostrar os mesmos formulários.
TIPOS_NOTA: list[dict[str, Any]] = [
    {
        "id": "canal",
        "nome": "Canal do YouTube",
        "campos": [_campo("status", "Status", "opcoes", STATUS_CANAL)],
        "relacoes": ["mapa", "relacionados"],
        "modelo": MODELO_CANAL,
    },
    *(
        {
            "id": c["tipo"],
            "nome": c["item"],
            "campos": [_campo("canal", "Canal", "link"), *c["campos"]],
            "relacoes": ["canal", *(x["nome"] for x in c["campos"] if x["tipo"] == "link")],
            "modelo": c["modelo"],
        }
        for c in COLECOES.values()
    ),
]


def esquema() -> dict[str, Any]:
    return {
        "status_canal": STATUS_CANAL,
        "colecoes": [
            {"id": k, "nome": c["nome"], "item": c["item"], "campos": c["campos"]}
            for k, c in COLECOES.items()
        ],
    }
