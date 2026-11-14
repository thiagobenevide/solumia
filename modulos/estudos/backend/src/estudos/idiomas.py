"""Gerador do cronograma de idiomas (A1 a C2). Sem LLM: regras fixas a partir do nível, dos minutos
por dia e dos dias da semana da trilha. As horas por nível seguem as "horas guiadas" do Quadro
Europeu (Cambridge), arredondadas para cima: são estimativas para marcar o ritmo, não promessa."""

from datetime import date, timedelta
from typing import Any

NIVEIS = ["A1", "A2", "B1", "B2", "C1", "C2"]

# horas acumuladas para concluir cada nível (partindo do zero)
HORAS = {"A1": 100, "A2": 200, "B1": 400, "B2": 600, "C1": 800, "C2": 1100}

IDIOMAS = {"en": "Inglês", "fr": "Francês", "es": "Espanhol", "pt": "Português"}

# habilidade do bloco principal em cada dia da semana (0 = segunda)
FOCO_DO_DIA = ["gramatica", "escuta", "leitura", "fala", "escrita", "imersao", "revisao"]

ROTULOS = {
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

# temas de vocabulário/gramática por nível; um por semana, em ciclo
TEMAS = {
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

ATIVIDADES = {
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


def nivel_de_horas(horas: float) -> str:
    """Nível em curso para as horas acumuladas (o primeiro ainda não concluído)."""
    for n in NIVEIS:
        if horas < HORAS[n]:
            return n
    return "C2"


def _faixa(nivel: str) -> str:
    return nivel[0]


def _blocos(minutos: int, foco: str, nivel: str, tema: str, idioma: str) -> list[dict[str, Any]]:
    """Divide o dia: flashcards (~15%), bloco principal (~50%), vocabulário do tema (resto)."""
    faixa = _faixa(nivel)
    cartoes = max(5, round(minutos * 0.15))
    principal = max(10, round(minutos * 0.5))
    vocab = max(0, minutos - cartoes - principal)
    blocos = [
        {
            "habilidade": "flashcards",
            "titulo": ROTULOS["flashcards"],
            "minutos": cartoes,
            "descricao": f"Revise o baralho de {idioma} (Anki) e inclua as palavras novas.",
        },
        {
            "habilidade": foco,
            "titulo": ROTULOS[foco],
            "minutos": principal,
            "descricao": f"{ATIVIDADES[foco][faixa]} Tema: {tema}.",
        },
    ]
    if vocab:
        blocos.append(
            {
                "habilidade": "vocabulario",
                "titulo": ROTULOS["vocabulario"],
                "minutos": vocab,
                "descricao": f'Liste 10 palavras/expressões de "{tema}" com frases de exemplo.',
            }
        )
    return blocos


def horas_estudadas(trilha: dict[str, Any]) -> float:
    base = (
        HORAS[NIVEIS[NIVEIS.index(trilha["nivel_inicial"]) - 1]]
        if trilha["nivel_inicial"] != "A1"
        else 0
    )
    return base + sum(trilha.get("sessoes", {}).values()) / 60


def cronograma(trilha: dict[str, Any], de: date, ate: date) -> list[dict[str, Any]]:
    """Dias de estudo no período, com os blocos de cada um e se a sessão foi registrada."""
    inicio = date.fromisoformat(trilha["inicio"])
    sessoes: dict[str, int] = trilha.get("sessoes", {})
    nivel = nivel_de_horas(horas_estudadas(trilha))
    temas = TEMAS[nivel]
    nome = IDIOMAS.get(trilha["idioma"], trilha["idioma"])
    dias = []
    d = max(de, inicio)
    while d <= ate:
        if d.isoweekday() in trilha["dias_semana"]:
            semana = (d - inicio).days // 7
            tema = temas[semana % len(temas)]
            dias.append(
                {
                    "data": d.isoformat(),
                    "nivel": nivel,
                    "tema": tema,
                    "minutos": trilha["minutos_por_dia"],
                    "blocos": _blocos(
                        trilha["minutos_por_dia"], FOCO_DO_DIA[d.weekday()], nivel, tema, nome
                    ),
                    "feito_minutos": sessoes.get(d.isoformat(), 0),
                }
            )
        d += timedelta(days=1)
    return dias


def marcos(trilha: dict[str, Any], hoje: date) -> list[dict[str, Any]]:
    """Para cada nível até o alvo: horas que faltam e a data estimada no ritmo da trilha."""
    horas = horas_estudadas(trilha)
    por_semana = trilha["minutos_por_dia"] * len(trilha["dias_semana"]) / 60
    alvo = NIVEIS.index(trilha["nivel_alvo"])
    lista = []
    for n in NIVEIS[: alvo + 1]:
        faltam = max(0.0, HORAS[n] - horas)
        semanas = faltam / por_semana if por_semana else None
        lista.append(
            {
                "nivel": n,
                "horas_total": HORAS[n],
                "horas_faltando": round(faltam, 1),
                "concluido": faltam == 0,
                "previsao": (hoje + timedelta(weeks=semanas)).isoformat()
                if semanas is not None
                else None,
            }
        )
    return lista
