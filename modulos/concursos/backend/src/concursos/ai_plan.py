"""Pedido ao Claude Code (tarefa `claude_json` do worker) que lê o edital e devolve a estrutura do
estudo: prazos, disciplinas do cargo com os tópicos na ordem de aprendizado (o fluxo do
conhecimento), horas estimadas e estratégia. O calendário de tarefas sai dessa estrutura por regra
(`cronograma.py`), não do LLM: assim dá para replanejar atrasos sem chamar o Claude de novo."""

from typing import Any

LIMIT_NOTICE = 250_000
"""Caracteres do edital mandados ao Claude (editais da FGV/Cebraspe ficam bem abaixo)."""

KINDS_DEADLINE = (
    "inscricao",
    "pagamento",
    "isencao",
    "documentos",
    "atendimento",
    "local_prova",
    "prova",
    "gabarito",
    "recurso",
    "resultado",
    "outro",
)
MODULES = ("gerais", "especificos", "discursiva")
PRIORITIES = ("alta", "media", "baixa")

SYSTEM = """Você é um planejador de estudos para concursos públicos brasileiros, com experiência \
nas bancas (FGV, Cebraspe, FCC, Vunesp) e no que elas mais cobram.

Leia o edital e monte a estrutura do estudo SÓ para o cargo/especialidade informado:
- `prazos`: todas as datas do edital que exigem ação ou atenção do candidato (inscrição, \
pagamento da taxa, isenção, envio de laudo/documentos, atendimento especial, divulgação de \
local de prova, a prova, gabarito, prazos de recurso, resultados), com data ISO (AAAA-MM-DD), \
hora "HH:MM" quando houver (senão ""), tipo e o que fazer em `detalhe`. Nunca invente datas: \
datas que o edital não fixa ficam de fora.
- `disciplinas`: as do cargo, com o número de questões do quadro de provas e o módulo (gerais, \
especificos, discursiva). Quando o edital agrupa "Conhecimentos Específicos" num bloco só, separe \
em disciplinas coerentes do conteúdo programático (ex.: Engenharia de Software, Banco de Dados, \
Desenvolvimento, Segurança) e reparta as questões do bloco entre elas pela extensão do conteúdo. \
`prioridade` 1–5 = peso na nota × chance de cobrança.
- `topicos` de cada disciplina na ORDEM em que devem ser estudados (pré-requisitos primeiro: é o \
fluxo do conhecimento). Agrupe itens pequenos do edital num tópico de estudo de 2–8 h; em \
`conteudo`, os itens do edital que o tópico cobre, com a numeração do edital. `horas` = horas \
para um candidato de nível médio estudar teoria e resolver questões da banca. `prioridade` pela \
incidência histórica da banca.
- `discursiva`: formato da prova discursiva do cargo e temas prováveis.
- `estrategia`: até 8 orientações práticas para este edital e esta banca.
Responda em português do Brasil."""

_DEADLINE = {
    "type": "object",
    "properties": {
        "titulo": {"type": "string"},
        "data": {"type": "string"},
        "hora": {"type": "string"},
        "tipo": {"type": "string", "enum": list(KINDS_DEADLINE)},
        "detalhe": {"type": "string"},
    },
    "required": ["titulo", "data", "hora", "tipo", "detalhe"],
    "additionalProperties": False,
}

_TOPIC = {
    "type": "object",
    "properties": {
        "titulo": {"type": "string"},
        "conteudo": {"type": "string"},
        "horas": {"type": "number"},
        "prioridade": {"type": "string", "enum": list(PRIORITIES)},
    },
    "required": ["titulo", "conteudo", "horas", "prioridade"],
    "additionalProperties": False,
}

_SUBJECT = {
    "type": "object",
    "properties": {
        "nome": {"type": "string"},
        "modulo": {"type": "string", "enum": list(MODULES)},
        "questoes": {"type": "integer"},
        "prioridade": {"type": "integer"},
        "topicos": {"type": "array", "items": _TOPIC},
    },
    "required": ["nome", "modulo", "questoes", "prioridade", "topicos"],
    "additionalProperties": False,
}

SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "resumo": {"type": "string"},
        "data_prova": {"type": "string"},
        "horario_prova": {"type": "string"},
        "formato_prova": {"type": "string"},
        "prazos": {"type": "array", "items": _DEADLINE},
        "disciplinas": {"type": "array", "items": _SUBJECT},
        "discursiva": {
            "type": "object",
            "properties": {
                "descricao": {"type": "string"},
                "temas_provaveis": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["descricao", "temas_provaveis"],
            "additionalProperties": False,
        },
        "estrategia": {"type": "array", "items": {"type": "string"}},
    },
    "required": [
        "resumo",
        "data_prova",
        "horario_prova",
        "formato_prova",
        "prazos",
        "disciplinas",
        "discursiva",
        "estrategia",
    ],
    "additionalProperties": False,
}


def assemble_prompt(exam: dict[str, Any], notice: str, hoje: str) -> str:
    parts = [
        f"Hoje: {hoje}.",
        f"Concurso: {exam['nome']}"
        + (f" (banca {exam['banca']})" if exam.get("banca") else ""),
        f"Cargo/especialidade do candidato: {exam['cargo']}",
        f"Disponibilidade: {exam['minutos_util']} min por dia útil e "
        f"{exam['minutos_fds']} min por dia de fim de semana; o estudo de conteúdo vai até "
        "7 dias antes da prova.",
    ]
    if exam.get("observacoes"):
        parts.append("Sobre o candidato: " + exam["observacoes"])
    parts.append("<edital>\n" + notice[:LIMIT_NOTICE] + "\n</edital>")
    return "\n\n".join(parts)


# ---------- simulados ----------

SYSTEM_MOCK_EXAM = """Você é elaborador de questões de concursos públicos brasileiros e imita \
o estilo da banca informada (FGV: enunciados contextualizados, casos práticos, alternativas \
longas e plausíveis; Cebraspe: certo/errado vira 5 alternativas). Crie questões INÉDITAS de \
múltipla escolha com 5 alternativas e só uma correta, no nível da prova do cargo, cobrindo o \
conteúdo do edital.
- `correta` = índice 0–4 da alternativa certa; varie a posição entre as questões.
- `comentario`: por que a certa está certa e o erro de cada distratora, com a base (lei, norma, \
conceito); curto e didático.
- Respeite exatamente a quantidade de questões por disciplina pedida.
Responda em português do Brasil."""

SCHEMA_MOCK_EXAM: dict[str, Any] = {
    "type": "object",
    "properties": {
        "questoes": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "disciplina": {"type": "string"},
                    "topico": {"type": "string"},
                    "enunciado": {"type": "string"},
                    "alternativas": {"type": "array", "items": {"type": "string"}},
                    "correta": {"type": "integer"},
                    "comentario": {"type": "string"},
                },
                "required": [
                    "disciplina",
                    "topico",
                    "enunciado",
                    "alternativas",
                    "correta",
                    "comentario",
                ],
                "additionalProperties": False,
            },
        }
    },
    "required": ["questoes"],
    "additionalProperties": False,
}


def distribute(weights: dict[str, int], n: int) -> dict[str, int]:
    """Reparte [n] questões pelos pesos (maiores restos), sem disciplina com 0 se couber."""
    total = sum(weights.values()) or 1
    cotas = {k: n * v / total for k, v in weights.items()}
    output = {k: int(c) for k, c in cotas.items()}
    for k in sorted(cotas, key=lambda k: cotas[k] - output[k], reverse=True)[
        : n - sum(output.values())
    ]:
        output[k] += 1
    return {k: v for k, v in output.items() if v}


def prompt_mock_exam(exam: dict[str, Any], cotas: dict[str, int], estudados: list[str]) -> str:
    discs = {d["nome"]: d for d in exam["estrutura"]["disciplinas"]}
    lines = [
        f"Concurso: {exam['nome']} — banca {exam.get('banca') or 'não informada'}",
        f"Cargo: {exam['cargo']}",
        "Questões por disciplina (exatamente):",
    ]
    for name, q in cotas.items():
        topicos = "; ".join(t["titulo"] for t in discs[name]["topicos"])
        lines.append(f"- {name}: {q} questão(ões). Tópicos do edital: {topicos}")
    if estudados:
        lines.append(
            "Tópicos que o candidato já estudou (dê preferência a eles): " + "; ".join(estudados)
        )
    return "\n".join(lines)
