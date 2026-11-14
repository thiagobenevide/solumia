"""Request to Claude Code (worker task `claude_json`) that reads the exam notice and returns the
study
structure: deadlines, the position's subjects with topics in learning order (the knowledge flow),
estimated hours and strategy. The task calendar comes out of that structure by rule
(`schedule.py`), not from the LLM: so delays can be replanned without calling Claude again."""

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

SYSTEM = """You are a study planner for Brazilian public service exams (concursos públicos),
experienced with the exam boards (FGV, Cebraspe, FCC, Vunesp) and what they test most.

Read the exam notice (edital) and build the study structure ONLY for the position/specialty given:
- `prazos`: every date in the notice that requires action or attention from the candidate
(registration, fee payment, fee waiver, sending reports/documents, special accommodation, exam venue
announcement, the exam, answer key, appeal deadlines, results), with an ISO date (YYYY-MM-DD), time
"HH:MM" when there is one (otherwise ""), type, and what to do in `detalhe`. Never invent dates:
dates the notice does not set are left out.
- `disciplinas`: the subjects of the position, with the number of questions from the exam table and
the module (gerais, especificos, discursiva). When the notice groups "Conhecimentos Específicos"
into a single block, split it into coherent subjects from the syllabus (e.g.: Engenharia de
Software, Banco de Dados, Desenvolvimento, Segurança) and distribute the block's questions among
them by the size of their content. `prioridade` 1–5 = weight in the score × chance of being tested.
- `topicos` of each subject in the ORDER they should be studied (prerequisites first: it is the flow
of knowledge). Group small items of the notice into a study topic of 2–8 h; in `conteudo`, the
notice items the topic covers, with the notice's numbering. `horas` = hours for an average candidate
to study the theory and solve the board's questions. `prioridade` by the board's historical
incidence.
- `discursiva`: format of the position's essay exam and likely themes.
- `estrategia`: up to 8 practical guidelines for this notice and this board.
Write every text in Brazilian Portuguese."""

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


# ---------- mock exams ----------

SYSTEM_MOCK_EXAM = """You write questions for Brazilian public service exams and imitate the style
of the given board (FGV: contextualized statements, practical cases, long and plausible options;
Cebraspe: true/false becomes 5 options). Create ORIGINAL multiple-choice questions with 5 options
and only one correct, at the level of the position's exam, covering the notice's syllabus.
- `correta` = index 0–4 of the right option; vary its position across questions.
- `comentario`: why the right one is right and the mistake of each distractor, with the basis (law,
standard, concept); short and didactic.
- Respect exactly the number of questions per subject requested.
Write every text in Brazilian Portuguese."""

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
    """Splits [n] questions by the weights (largest remainders), leaving no subject at 0 if it
    fits."""
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
