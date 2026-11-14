"""Language schedule generator (A1 to C2). No LLM: fixed rules from the level, the minutes per day
and the track's weekdays. Hours per level follow the CEFR "guided learning hours" (Cambridge),
rounded up: they are estimates to set the pace, not a promise."""

from datetime import date, timedelta
from typing import Any

LEVELS = ["A1", "A2", "B1", "B2", "C1", "C2"]

# cumulative hours to finish each level (starting from zero)
HOURS = {"A1": 100, "A2": 200, "B1": 400, "B2": 600, "C1": 800, "C2": 1100}

LANGUAGES = {"en": "Inglês", "fr": "Francês", "es": "Espanhol", "pt": "Português"}

# main-block skill on each weekday (0 = Monday)
FOCUS_DO_DAY = ["gramatica", "escuta", "leitura", "fala", "escrita", "imersao", "revisao"]

LABELS = {
    "gramatica": "Gramática",
    "escuta": "Escuta",
    "leitura": "Leitura",
    "fala": "Fala",
    "escrita": "Escrita",
    "imersao": "Imersão",
    "revisao": "Revisão da semana",
    "vocabulario": "Vocabulário",
    "flashcards": "Flashcards (repetição espaçada)",
}

# vocabulary/grammar themes per level; one per week, cycling
THEMES = {
    "A1": [
        "apresentações e cumprimentos",
        "números, horas e datas",
        "família e descrições",
        "comida e restaurante",
        "rotina diária",
        "casa e cidade",
        "compras e preços",
        "verbos ser/estar/ter no presente",
        "perguntas básicas",
        "clima e estações",
    ],
    "A2": [
        "passado simples",
        "viagens e transporte",
        "saúde e corpo",
        "trabalho e profissões",
        "planos para o futuro próximo",
        "comparações",
        "tempo livre e hobbies",
        "direções e lugares",
        "pedidos e favores",
        "experiências pessoais",
    ],
    "B1": [
        "dar e defender opiniões",
        "condicionais",
        "notícias do dia",
        "tecnologia",
        "meio ambiente",
        "relatar o que alguém disse",
        "sentimentos e relações",
        "entrevista de emprego",
        "cultura e tradições",
        "resolver problemas",
    ],
    "B2": [
        "argumentação e contra-argumentação",
        "voz passiva e registro formal",
        "economia e finanças",
        "ciência e saúde",
        "subjuntivo e hipóteses",
        "conectores de texto",
        "debates atuais",
        "e-mails profissionais",
        "expressões idiomáticas comuns",
        "resumir textos longos",
    ],
    "C1": [
        "textos acadêmicos",
        "nuances de sentido e conotação",
        "apresentações orais",
        "ironia e humor",
        "relatórios técnicos",
        "negociação",
        "estilo e coesão",
        "variedades regionais",
        "política e sociedade",
        "filosofia e ética",
    ],
    "C2": [
        "literatura clássica",
        "retórica e persuasão",
        "tradução e interpretação",
        "gírias e registro coloquial",
        "redação crítica",
        "discursos e palestras",
        "linguagem jurídica",
        "poesia",
        "história da língua",
        "debate improvisado",
    ],
}

ACTIVITIES = {
    "gramatica": {
        "A": "Estude o tópico da semana com exemplos e faça 15 frases próprias.",
        "B": "Revise o tópico da semana e reescreva um parágrafo aplicando a estrutura.",
        "C": "Analise o uso da estrutura em textos reais e anote exceções e nuances.",
    },
    "escuta": {
        "A": "Áudio curto para iniciantes (podcast/diálogo) com transcrição; ouça 3 vezes.",
        "B": "Podcast ou vídeo nativo sobre o tema; anote 10 expressões novas.",
        "C": "Palestra ou debate sem legenda; resuma oralmente os argumentos.",
    },
    "leitura": {
        "A": "Texto graduado curto; sublinhe palavras novas e leia em voz alta.",
        "B": "Artigo de notícia ou blog sobre o tema; resuma em 5 frases.",
        "C": "Artigo longo, ensaio ou capítulo de livro; anote argumentos e vocabulário.",
    },
    "fala": {
        "A": "Shadowing de um diálogo e grave-se se apresentando sobre o tema.",
        "B": "Fale 5 minutos sobre o tema gravando-se; ouça e corrija.",
        "C": "Conversa com nativo/tutor ou monólogo de 10 min defendendo uma posição.",
    },
    "escrita": {
        "A": "Escreva 5 a 8 frases simples sobre o tema.",
        "B": "Escreva um texto de 150 a 200 palavras (e-mail, opinião ou relato).",
        "C": "Escreva um ensaio de 300+ palavras e revise coesão e registro.",
    },
    "imersao": {
        "A": "Episódio de série/desenho com legenda no idioma.",
        "B": "Filme ou episódio com legenda no idioma; anote falas úteis.",
        "C": "Filme, documentário ou livro sem apoio; discuta-o por escrito.",
    },
    "revisao": {
        "A": "Releia as anotações da semana e refaça os exercícios em que errou.",
        "B": "Revise o vocabulário da semana e faça um mini-teste de cada habilidade.",
        "C": "Autoavaliação da semana: o que travou na fala/escrita e plano de ajuste.",
    },
}


def level_of_hours(horas: float) -> str:
    """Current level for the cumulative hours (the first one not finished yet)."""
    for n in LEVELS:
        if horas < HOURS[n]:
            return n
    return "C2"


def _band(nivel: str) -> str:
    return nivel[0]


def _blocks(minutos: int, focus: str, nivel: str, tema: str, language: str) -> list[dict[str, Any]]:
    """Splits the day: flashcards (~15%), main block (~50%), theme vocabulary (the rest)."""
    band = _band(nivel)
    cartoes = max(5, round(minutos * 0.15))
    main = max(10, round(minutos * 0.5))
    vocab = max(0, minutos - cartoes - main)
    blocks = [
        {
            "habilidade": "flashcards",
            "titulo": LABELS["flashcards"],
            "minutos": cartoes,
            "descricao": f"Revise o baralho de {language} (Anki) e inclua as palavras novas.",
        },
        {
            "habilidade": focus,
            "titulo": LABELS[focus],
            "minutos": main,
            "descricao": f"{ACTIVITIES[focus][band]} Tema: {tema}.",
        },
    ]
    if vocab:
        blocks.append(
            {
                "habilidade": "vocabulario",
                "titulo": LABELS["vocabulario"],
                "minutos": vocab,
                "descricao": f'Liste 10 palavras/expressões de "{tema}" com frases de exemplo.',
            }
        )
    return blocks


def hours_studied(track: dict[str, Any]) -> float:
    base = (
        HOURS[LEVELS[LEVELS.index(track["nivel_inicial"]) - 1]]
        if track["nivel_inicial"] != "A1"
        else 0
    )
    return base + sum(track.get("sessoes", {}).values()) / 60


def schedule(track: dict[str, Any], de: date, ate: date) -> list[dict[str, Any]]:
    """Study days in the period, with each one's blocks and whether the session was logged."""
    start = date.fromisoformat(track["inicio"])
    sessions: dict[str, int] = track.get("sessoes", {})
    level = level_of_hours(hours_studied(track))
    themes = THEMES[level]
    name = LANGUAGES.get(track["idioma"], track["idioma"])
    days = []
    d = max(de, start)
    while d <= ate:
        if d.isoweekday() in track["dias_semana"]:
            week = (d - start).days // 7
            tema = themes[week % len(themes)]
            days.append(
                {
                    "data": d.isoformat(),
                    "nivel": level,
                    "tema": tema,
                    "minutos": track["minutos_por_dia"],
                    "blocos": _blocks(
                        track["minutos_por_dia"], FOCUS_DO_DAY[d.weekday()], level, tema, name
                    ),
                    "feito_minutos": sessions.get(d.isoformat(), 0),
                }
            )
        d += timedelta(days=1)
    return days


def milestones(track: dict[str, Any], hoje: date) -> list[dict[str, Any]]:
    """For each level up to the target: hours left and the estimated date at the track's pace."""
    hours = hours_studied(track)
    by_week = track["minutos_por_dia"] * len(track["dias_semana"]) / 60
    target = LEVELS.index(track["nivel_alvo"])
    items = []
    for n in LEVELS[: target + 1]:
        missing = max(0.0, HOURS[n] - hours)
        semanas = missing / by_week if by_week else None
        items.append(
            {
                "nivel": n,
                "horas_total": HOURS[n],
                "horas_faltando": round(missing, 1),
                "concluido": missing == 0,
                "previsao": (hoje + timedelta(weeks=semanas)).isoformat()
                if semanas is not None
                else None,
            }
        )
    return items
