"""Note types: fields and relations the app turns into a form and buttons.

Any module can use these types; the Nagger (Panel module) reads `status`, `prazo` and the `cobra`
relations of goals/tasks to write the nagging messages.
"""


from typing import Any

from youtube.schema import KINDS_NOTE

_STATUS = ["aberta", "em andamento", "concluida", "cancelada"]


def _field(nome: str, label: str, tipo: str = "texto", options: list[str] | None = None) -> dict:
    return {"nome": nome, "rotulo": label, "tipo": tipo, "opcoes": options or []}


KINDS: list[dict[str, Any]] = [
    {
        "id": "nota",
        "nome": "Nota",
        "campos": [],
        "relacoes": ["relacionada", "fonte"],
        "modelo": "",
    },
    {
        "id": "tarefa",
        "nome": "Tarefa",
        "campos": [
            _field("status", "Status", "opcoes", _STATUS),
            _field("prazo", "Prazo", "data"),
            _field("prioridade", "Prioridade", "opcoes", ["alta", "media", "baixa"]),
            _field("responsavel", "Responsável", "link"),
        ],
        "relacoes": ["parte_de", "depende_de", "bloqueia"],
        "modelo": "## Objetivo\n\n## Checklist\n- [ ] \n",
    },
    {
        "id": "meta",
        "nome": "Meta",
        "campos": [
            _field("status", "Status", "opcoes", _STATUS),
            _field("prazo", "Prazo", "data"),
            _field("indicador", "Indicador"),
            _field("alvo", "Alvo", "numero"),
            _field("atual", "Atual", "numero"),
        ],
        "relacoes": ["parte_de", "projeto"],
        "modelo": "## Por quê\n\n## Como medir\n",
    },
    {
        "id": "cobranca",
        "nome": "Cobrança",
        "campos": [
            _field("status", "Status", "opcoes", ["aberta", "enviada", "respondida", "resolvida"]),
            _field("prazo", "Responder até", "data"),
            _field("canal", "Canal", "opcoes", ["app", "push", "email"]),
            _field("cobra", "Cobra", "link"),
        ],
        "relacoes": ["cobra"],
        "modelo": "## Desvio\n\n## Ação pedida\n",
    },
    {
        "id": "projeto",
        "nome": "Projeto",
        "campos": [_field("status", "Status", "opcoes", _STATUS), _field("prazo", "Prazo", "data")],
        "relacoes": ["parte_de", "relacionada"],
        "modelo": "## Escopo\n\n## Marcos\n",
    },
    {
        "id": "pessoa",
        "nome": "Pessoa",
        "campos": [_field("contato", "Contato")],
        "relacoes": ["relacionada"],
        "modelo": "",
    },
    *KINDS_NOTE,
]
