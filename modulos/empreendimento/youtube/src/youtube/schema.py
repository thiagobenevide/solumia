"""Collections of each channel: note type, vault subfolder, form fields and body template.

Follows the vault structure:
`Notas/Empreendimento/YouTube/<canal>/{Temas,História,Roteiros,Método}/`, with the video plans
in `Temas/Plano de 500 vídeos/`. `link` fields are written as `[[Title]]` and become relations
in the notes graph.
"""

from typing import Any

ROOT = "Notas/Empreendimento/YouTube"
MAP = "[[MOC — Rede de Canais no YouTube]]"

STATUS = [
    "rascunho",
    "rascunho-llm",
    "em-andamento",
    "revisado",
    "gravado",
    "publicado",
    "arquivada",
]
STATUS_CHANNEL = ["ideia", "em-andamento", "ativo", "pausado", "arquivada"]


def _field(name: str, label: str, kind: str = "texto", options: list[str] | None = None) -> dict:
    return {"nome": name, "rotulo": label, "tipo": kind, "opcoes": options or []}


_STATUS = _field("status", "Status", "opcoes", STATUS)

COLLECTIONS: dict[str, dict[str, Any]] = {
    "temas": {
        "tipo": "tema",
        "nome": "Temas",
        "item": "Tema",
        "pasta": "Temas",
        "tag": "empreendimento/youtube/temas",
        "campos": [
            _STATUS,
            _field("numero", "Número", "numero"),
            _field("fio", "Fio"),
            _field("plano", "Plano", "link"),
            _field("roteiro", "Roteiro", "link"),
            _field("historia", "História", "link"),
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
        "campos": [_STATUS, _field("tema", "Tema", "link"), _field("roteiro", "Roteiro", "link")],
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
            _field("video", "Vídeo nº", "numero"),
            _field("fio", "Fio"),
            _field("formato", "Formato", "opcoes", ["L", "M", "D"]),
            _field("evidencia", "Evidência", "opcoes", ["Consenso", "Moderada", "Debate"]),
            _field("modo", "Modo", "opcoes", ["dark", "apresentador"]),
            _field("tema", "Tema", "link"),
            _field("plano", "Plano", "link"),
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

MODEL_CHANNEL = (
    "> [!abstract] Posicionamento\n> \n\n## Público\n\n## Pilares de conteúdo\n\n"
    "## Formatos\n\n## Metas\n"
)

# So the notes app (`/api/notas/tipos`) shows the same forms.
KINDS_NOTE: list[dict[str, Any]] = [
    {
        "id": "canal",
        "nome": "Canal do YouTube",
        "campos": [_field("status", "Status", "opcoes", STATUS_CHANNEL)],
        "relacoes": ["mapa", "relacionados"],
        "modelo": MODEL_CHANNEL,
    },
    *(
        {
            "id": c["tipo"],
            "nome": c["item"],
            "campos": [_field("canal", "Canal", "link"), *c["campos"]],
            "relacoes": ["canal", *(x["nome"] for x in c["campos"] if x["tipo"] == "link")],
            "modelo": c["modelo"],
        }
        for c in COLLECTIONS.values()
    ),
]


def schema() -> dict[str, Any]:
    return {
        "status_canal": STATUS_CHANNEL,
        "colecoes": [
            {"id": k, "nome": c["nome"], "item": c["item"], "campos": c["campos"]}
            for k, c in COLLECTIONS.items()
        ],
    }
