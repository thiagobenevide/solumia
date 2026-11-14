"""Dados iniciais: categorias (com o grupo da regra 50/30/20) e o questionário de seleção de setores
e empresas para aporte. O usuário edita os dois pelo app."""

CATEGORIAS_BASE = [
    {"nome": "Salário", "tipo": "receita", "cor": "#2e7d32"},
    {"nome": "Renda extra", "tipo": "receita", "cor": "#43a047"},
    {"nome": "Rendimentos", "tipo": "receita", "cor": "#66bb6a"},
    {"nome": "Moradia", "tipo": "despesa", "grupo": "essencial", "cor": "#5c6bc0"},
    {"nome": "Mercado", "tipo": "despesa", "grupo": "essencial", "cor": "#26a69a"},
    {"nome": "Transporte", "tipo": "despesa", "grupo": "essencial", "cor": "#29b6f6"},
    {"nome": "Saúde", "tipo": "despesa", "grupo": "essencial", "cor": "#ef5350"},
    {"nome": "Educação", "tipo": "despesa", "grupo": "essencial", "cor": "#7e57c2"},
    {"nome": "Contas e serviços", "tipo": "despesa", "grupo": "essencial", "cor": "#8d6e63"},
    {"nome": "Restaurantes", "tipo": "despesa", "grupo": "estilo", "cor": "#ffa726"},
    {"nome": "Lazer", "tipo": "despesa", "grupo": "estilo", "cor": "#ffca28"},
    {"nome": "Compras", "tipo": "despesa", "grupo": "estilo", "cor": "#ec407a"},
    {"nome": "Assinaturas", "tipo": "despesa", "grupo": "estilo", "cor": "#ab47bc"},
    {"nome": "Impostos e taxas", "tipo": "despesa", "grupo": "essencial", "cor": "#78909c"},
    {"nome": "Investimentos", "tipo": "investimento", "grupo": "futuro", "cor": "#00897b"},
    {"nome": "Reserva de emergência", "tipo": "investimento", "grupo": "futuro", "cor": "#00acc1"},
    {"nome": "Transferência entre contas", "tipo": "transferencia", "cor": "#9e9e9e"},
    {"nome": "Pagamento de fatura", "tipo": "transferencia", "cor": "#bdbdbd"},
]

# nota de 0 a 5 em cada pergunta; o peso multiplica a nota
QUESTIONARIO_BASE = [
    # setor
    {
        "id": "s1",
        "alvo": "setor",
        "bloco": "Setor",
        "peso": 3,
        "texto": "O setor é perene (vai existir e ser necessário daqui a 20 anos)?",
        "ajuda": "Energia, saneamento, bancos, seguros e telecom costumam ser perenes.",
    },
    {
        "id": "s2",
        "alvo": "setor",
        "bloco": "Setor",
        "peso": 2,
        "texto": "A demanda é previsível e pouco sensível a ciclos econômicos?",
        "ajuda": "",
    },
    {
        "id": "s3",
        "alvo": "setor",
        "bloco": "Setor",
        "peso": 2,
        "texto": "Há barreiras de entrada altas (regulação, capital, escala, marca)?",
        "ajuda": "",
    },
    {
        "id": "s4",
        "alvo": "setor",
        "bloco": "Setor",
        "peso": 2,
        "texto": "O risco regulatório e de interferência política é baixo?",
        "ajuda": "",
    },
    {
        "id": "s5",
        "alvo": "setor",
        "bloco": "Setor",
        "peso": 1,
        "texto": "O setor está em crescimento ou consolidação favorável aos líderes?",
        "ajuda": "",
    },
    {
        "id": "s6",
        "alvo": "setor",
        "bloco": "Setor",
        "peso": 1,
        "texto": "O setor historicamente distribui bons dividendos?",
        "ajuda": "",
    },
    # negócio
    {
        "id": "n1",
        "alvo": "empresa",
        "bloco": "Negócio",
        "peso": 3,
        "texto": "Entendo como a empresa ganha dinheiro?",
        "ajuda": "Se não sabe explicar em 2 frases, nota baixa.",
    },
    {
        "id": "n2",
        "alvo": "empresa",
        "bloco": "Negócio",
        "peso": 3,
        "texto": "Tem vantagem competitiva durável (fosso)?",
        "ajuda": "Marca, custo baixo, rede, troca cara para o cliente, concessão.",
    },
    {
        "id": "n3",
        "alvo": "empresa",
        "bloco": "Negócio",
        "peso": 2,
        "texto": "É líder ou está entre as maiores do segmento?",
        "ajuda": "",
    },
    {
        "id": "n4",
        "alvo": "empresa",
        "bloco": "Negócio",
        "peso": 1,
        "texto": "A receita é diversificada (clientes, produtos, regiões)?",
        "ajuda": "",
    },
    # gestão
    {
        "id": "g1",
        "alvo": "empresa",
        "bloco": "Gestão e governança",
        "peso": 2,
        "texto": "A governança é boa (Novo Mercado, tag along 100%, conselho independente)?",
        "ajuda": "",
    },
    {
        "id": "g2",
        "alvo": "empresa",
        "bloco": "Gestão e governança",
        "peso": 2,
        "texto": "A gestão tem histórico de boa alocação de capital e cumpre o que promete?",
        "ajuda": "",
    },
    {
        "id": "g3",
        "alvo": "empresa",
        "bloco": "Gestão e governança",
        "peso": 1,
        "texto": "Os controladores e gestores têm os interesses alinhados aos minoritários?",
        "ajuda": "",
    },
    {
        "id": "g4",
        "alvo": "empresa",
        "bloco": "Gestão e governança",
        "peso": 2,
        "texto": "Está livre de escândalos, processos relevantes e risco estatal?",
        "ajuda": "",
    },
    # finanças (leitura dos relatórios)
    {
        "id": "f1",
        "alvo": "empresa",
        "bloco": "Relatórios",
        "peso": 2,
        "texto": "Os lucros são consistentes nos últimos 5 a 10 anos?",
        "ajuda": "Veja a aba Demonstrativos.",
    },
    {
        "id": "f2",
        "alvo": "empresa",
        "bloco": "Relatórios",
        "peso": 2,
        "texto": "O lucro vira caixa (FCO próximo ou acima do lucro líquido)?",
        "ajuda": "",
    },
    {
        "id": "f3",
        "alvo": "empresa",
        "bloco": "Relatórios",
        "peso": 2,
        "texto": "As notas explicativas e o release não mostram riscos escondidos?",
        "ajuda": "Contingências, partes relacionadas, mudanças contábeis.",
    },
    # valuation
    {
        "id": "v1",
        "alvo": "empresa",
        "bloco": "Valuation",
        "peso": 3,
        "texto": "O preço atual está abaixo do preço teto/valor justo que calculei?",
        "ajuda": "",
    },
    {
        "id": "v2",
        "alvo": "empresa",
        "bloco": "Valuation",
        "peso": 1,
        "texto": "A tese de investimento está escrita e faz sentido para os meus objetivos?",
        "ajuda": "",
    },
]

# corte das notas finais (0 a 100)
APTA = 70
OBSERVAR = 50
