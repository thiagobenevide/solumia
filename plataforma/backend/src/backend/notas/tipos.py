"""Tipos de nota: campos e relações que o app transforma em formulário e botões.

Qualquer módulo pode usar estes tipos; o Cobrador (módulo Painel) lê `status`, `prazo` e as
relações `cobra` das metas/tarefas para redigir as cobranças.
"""

from typing import Any

from youtube.esquema import TIPOS_NOTA

_STATUS = ["aberta", "em andamento", "concluida", "cancelada"]


def _campo(nome: str, rotulo: str, tipo: str = "texto", opcoes: list[str] | None = None) -> dict:
    return {"nome": nome, "rotulo": rotulo, "tipo": tipo, "opcoes": opcoes or []}


TIPOS: list[dict[str, Any]] = [
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
            _campo("status", "Status", "opcoes", _STATUS),
            _campo("prazo", "Prazo", "data"),
            _campo("prioridade", "Prioridade", "opcoes", ["alta", "media", "baixa"]),
            _campo("responsavel", "Responsável", "link"),
        ],
        "relacoes": ["parte_de", "depende_de", "bloqueia"],
        "modelo": "## Objetivo\n\n## Checklist\n- [ ] \n",
    },
    {
        "id": "meta",
        "nome": "Meta",
        "campos": [
            _campo("status", "Status", "opcoes", _STATUS),
            _campo("prazo", "Prazo", "data"),
            _campo("indicador", "Indicador"),
            _campo("alvo", "Alvo", "numero"),
            _campo("atual", "Atual", "numero"),
        ],
        "relacoes": ["parte_de", "projeto"],
        "modelo": "## Por quê\n\n## Como medir\n",
    },
    {
        "id": "cobranca",
        "nome": "Cobrança",
        "campos": [
            _campo("status", "Status", "opcoes", ["aberta", "enviada", "respondida", "resolvida"]),
            _campo("prazo", "Responder até", "data"),
            _campo("canal", "Canal", "opcoes", ["app", "push", "email"]),
            _campo("cobra", "Cobra", "link"),
        ],
        "relacoes": ["cobra"],
        "modelo": "## Desvio\n\n## Ação pedida\n",
    },
    {
        "id": "projeto",
        "nome": "Projeto",
        "campos": [_campo("status", "Status", "opcoes", _STATUS), _campo("prazo", "Prazo", "data")],
        "relacoes": ["parte_de", "relacionada"],
        "modelo": "## Escopo\n\n## Marcos\n",
    },
    {
        "id": "pessoa",
        "nome": "Pessoa",
        "campos": [_campo("contato", "Contato")],
        "relacoes": ["relacionada"],
        "modelo": "",
    },
    *TIPOS_NOTA,
]
