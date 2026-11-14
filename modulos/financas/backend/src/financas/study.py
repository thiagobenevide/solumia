"""Estudos de finanças: a trilha (níveis → etapas), o guia de cada livro (que capítulos ler, em que
ordem e por quê), artigos científicos e relatórios de mercado para praticar. O conteúdo-base fica
aqui; o progresso (`estudo_progresso`), os livros que a pessoa acrescenta e os guias feitos pelo
Claude (`estudo_livros`) ficam no armazém. As leituras e grifos vão para o módulo Estudos (área
Finanças, projeto "Trilha de Finanças"), como os outros projetos de leitura.

Capítulos com número só onde o sumário é estável entre edições; nos demais o guia cita a seção
pelo assunto (procure no sumário da sua edição)."""

from typing import Any
from urllib.parse import quote_plus

from financas.warehouse import Armazem, Invalido

PROJETO = "Trilha de Finanças"

OBJETIVOS = [
    {
        "id": "investidor",
        "nome": "Investidor de longo prazo",
        "descricao": "Montar e manter sozinho uma carteira de ações, FIIs e Tesouro, sabendo por "
        "que cada ativo está lá e quando ele deixa de fazer sentido.",
        "niveis": [1, 2, 3, 4, 5, 6, 7, 8],
    },
    {
        "id": "analista",
        "nome": "Analista de empresas",
        "descricao": "Ler DFP, ITR e release como um analista: qualidade do lucro, vantagem "
        "competitiva, valuation e tese escrita.",
        "niveis": [1, 2, 3, 4, 7, 8],
    },
    {
        "id": "renda",
        "nome": "Viver de renda",
        "descricao": "Carteira de dividendos, FIIs e renda fixa que pague as contas com "
        "segurança, protegida da inflação.",
        "niveis": [1, 2, 3, 5, 6, 8],
    },
    {
        "id": "imobiliario",
        "nome": "Mercado imobiliário",
        "descricao": "FIIs de tijolo e de papel, ciclo imobiliário e a comparação com ter o "
        "imóvel direto (juntar × financiar já está em Cenários).",
        "niveis": [1, 2, 5, 6, 7, 8],
    },
]

NIVEIS = {
    1: ("Fundamentos", "Investir × especular, juros compostos, risco e inflação."),
    2: ("Contabilidade para investidor", "Ler DRE, balanço e fluxo de caixa sem se perder."),
    3: ("Análise de empresas", "Indicadores, qualidade do lucro e vantagem competitiva."),
    4: ("Valuation e margem de segurança", "Quanto vale, quanto custa e a folga entre os dois."),
    5: ("Renda fixa e Tesouro", "Selic, IPCA, prefixado, marcação a mercado e crédito privado."),
    6: ("Fundos imobiliários", "Tijolo (vacância, contratos) e papel (CRI, indexador, risco)."),
    7: ("Ciclos, psicologia e macro", "Pêndulo do mercado, ciclo de crédito e a ordem mundial."),
    8: ("Carteira e processo próprio", "Alocação, rebalanceamento, diário de decisões e tese."),
}

# ---------- livros ----------


def _caps(*itens: tuple[str, str, str, str]) -> list[dict[str, str]]:
    return [{"n": n, "titulo": t, "prioridade": p, "porque": q} for n, t, p, q in itens]


ESS, IMP, OPC = "essencial", "importante", "opcional"

LIVROS: dict[str, dict[str, Any]] = {
    "investidor_inteligente": {
        "titulo": "O Investidor Inteligente",
        "autor": "Benjamin Graham (comentários de Jason Zweig)",
        "ano": "1949 / ed. revisada 2003",
        "tenho": True,
        "niveis": [1, 3, 4, 7],
        "sobre": "A base do value investing: diferença entre investir e especular, o Sr. Mercado "
        "e a margem de segurança. Não é um manual de cálculo, é um manual de comportamento.",
        "como_ler": "Não leia de ponta a ponta. Comece pelo 1, 8 e 20 (a filosofia inteira está "
        "neles); depois 4 e 5 (o investidor defensivo) e 14 (os critérios de seleção). Leia "
        "sempre o comentário do Zweig logo após o capítulo: ele traz os exemplos para hoje. Os "
        "números de 1970 servem de exemplo, não de regra; troque 'títulos' por Tesouro.",
        "ordem": [
            "1",
            "8",
            "20",
            "4",
            "5",
            "14",
            "11",
            "12",
            "15",
            "19",
            "3",
            "2",
            "6",
            "7",
            "Apêndice",
        ],
        "capitulos": _caps(
            (
                "1",
                "Investimento versus especulação",
                ESS,
                "Define o que é investir: análise, segurança do principal e retorno adequado.",
            ),
            (
                "2",
                "O investidor e a inflação",
                IMP,
                "Por que ações protegem (em parte) da inflação; ligue com o Tesouro IPCA+.",
            ),
            (
                "3",
                "Um século de história do mercado",
                IMP,
                "Como preços e lucros andam no longo prazo; leia junto do ciclo do Howard Marks.",
            ),
            (
                "4",
                "Política geral de carteira: o investidor defensivo",
                ESS,
                "A divisão ações × renda fixa (25% a 75%) e o rebalanceamento.",
            ),
            (
                "5",
                "O investidor defensivo e as ações",
                ESS,
                "Diversificação, empresas grandes e conservadoras, histórico de dividendos.",
            ),
            (
                "6",
                "Investidor empreendedor: o que evitar",
                IMP,
                "Day trade, IPOs da moda e ações 'de crescimento' caras.",
            ),
            (
                "7",
                "Investidor empreendedor: o que fazer",
                IMP,
                "Onde o investidor ativo pode ganhar: empresas esquecidas e situações especiais.",
            ),
            (
                "8",
                "O investidor e as flutuações do mercado",
                ESS,
                "O Sr. Mercado: o preço é uma oferta, não uma ordem. O capítulo mais famoso.",
            ),
            (
                "9",
                "Investindo em fundos",
                OPC,
                "Fundos de ações e taxas; no Brasil, leia pensando em fundos e ETFs.",
            ),
            (
                "10",
                "O investidor e seus consultores",
                OPC,
                "Como avaliar quem dá recomendação (e conflitos de interesse).",
            ),
            (
                "11",
                "Análise de títulos para o leigo: abordagem geral",
                ESS,
                "Os fatores que um analista olha: estabilidade, crescimento, dividendos, balanço.",
            ),
            (
                "12",
                "O que considerar sobre o lucro por ação",
                ESS,
                "Lucro 'ajustado', itens não recorrentes e a média de vários anos.",
            ),
            (
                "13",
                "Comparação de quatro empresas listadas",
                OPC,
                "Exercício de comparação; refaça com 4 empresas do mesmo setor na B3.",
            ),
            (
                "14",
                "Seleção de ações para o investidor defensivo",
                ESS,
                "Os 7 critérios: porte, solidez, estabilidade, dividendos, crescimento, P/L, P/VP.",
            ),
            (
                "15",
                "Seleção de ações para o investidor empreendedor",
                IMP,
                "Filtros mais agressivos (net-nets, P/L baixo) e como aplicar com dados da CVM.",
            ),
            ("16", "Conversíveis e warrants", OPC, "Pouco usado na B3; pode pular."),
            (
                "17",
                "Quatro casos extremamente instrutivos",
                OPC,
                "Casos de fraude e euforia; ótimo para treinar o olhar crítico.",
            ),
            (
                "18",
                "Comparação de oito pares de empresas",
                OPC,
                "Pares parecidos com preços muito diferentes; treino de valuation relativo.",
            ),
            (
                "19",
                "Acionistas, administração e dividendos",
                IMP,
                "Política de dividendos e o acionista como dono; ligue com payout e JCP.",
            ),
            (
                "20",
                "Margem de segurança, o conceito central",
                ESS,
                "A ideia que resume o livro; releia depois de cada nível da trilha.",
            ),
            (
                "Apêndice",
                "Os superinvestidores de Graham-e-Doddsville (Buffett)",
                IMP,
                "Prova histórica de que o método funciona; também está na lista de artigos.",
            ),
        ),
    },
    "interpretacao_demonstracoes": {
        "titulo": "Interpretação das Demonstrações Financeiras",
        "autor": "Benjamin Graham e Spencer B. Meredith",
        "ano": "1937",
        "tenho": True,
        "niveis": [2, 3],
        "sobre": "Livro curto, de capítulos de 2–3 páginas, que explica cada linha do balanço e da "
        "DRE do ponto de vista do investidor. É o melhor primeiro livro de contabilidade.",
        "como_ler": "Leia em blocos e, a cada bloco, abra uma DFP real (Mercado › ficha › "
        "Demonstrações completas) e ache as linhas que o livro explicou. Os capítulos são "
        "curtos e com nome do assunto: guie-se pelos títulos abaixo no sumário.",
        "ordem": [
            "Balanço",
            "Capital de giro",
            "Ativos fixos e depreciação",
            "Valor patrimonial",
            "DRE",
            "Lucro por ação",
            "Índices",
            "Glossário",
        ],
        "capitulos": _caps(
            (
                "Balanço",
                "O balanço patrimonial: ativo, passivo e patrimônio",
                ESS,
                "A foto da empresa num dia; base para VPA, P/VP e endividamento.",
            ),
            (
                "Capital de giro",
                "Ativo e passivo circulante, capital de giro, liquidez corrente",
                ESS,
                "Se a empresa paga o curto prazo; é a liquidez corrente da ficha.",
            ),
            (
                "Ativos fixos e depreciação",
                "Imobilizado, depreciação e intangíveis",
                ESS,
                "Por que lucro não é caixa e como o EBITDA soma a depreciação de volta.",
            ),
            (
                "Valor patrimonial",
                "Valor contábil por ação e valor de liquidação",
                IMP,
                "VPA e a ideia de comprar abaixo do patrimônio (net-net).",
            ),
            (
                "DRE",
                "A demonstração de resultado: vendas, lucro operacional, margens",
                ESS,
                "Leitura da DRE de cima a baixo; liga com margem bruta, EBIT e líquida.",
            ),
            (
                "Lucro por ação",
                "Lucro por ação, P/L e dividendos",
                ESS,
                "LPA, P/L e dividend yield com as ressalvas do autor.",
            ),
            (
                "Índices",
                "Análise por índices (o 'método das razões')",
                IMP,
                "Como juntar os índices numa análise; compare com a aba Indicadores.",
            ),
            ("Glossário", "Glossário de termos", OPC, "Consulta quando travar num termo."),
        ),
    },
    "ciclo_mercado": {
        "titulo": "Dominando o Ciclo de Mercado",
        "autor": "Howard Marks",
        "ano": "2018",
        "tenho": True,
        "niveis": [6, 7],
        "sobre": "Não dá para prever, mas dá para saber onde estamos. Ciclos da economia, dos "
        "lucros, da psicologia, do risco, do crédito e do mercado imobiliário.",
        "como_ler": "Leia I, II e VII para entender a ideia; depois o ciclo de crédito (IX) e "
        "o de risco (VIII), que mais movem preços. O XI (imobiliário) é obrigatório para FIIs. "
        "Feche com XII a XIV, que dizem o que fazer. Os capítulos de governo e dívida "
        "estressada podem ficar para depois.",
        "ordem": [
            "I",
            "II",
            "VII",
            "VIII",
            "IX",
            "XII",
            "XIII",
            "XIV",
            "XI",
            "III",
            "IV",
            "VI",
            "XV",
            "XVIII",
        ],
        "capitulos": _caps(
            ("I", "Por que estudar ciclos?", ESS, "A tese do livro: posicionar-se, não prever."),
            ("II", "A natureza dos ciclos", ESS, "Excessos e correções; a média é rara."),
            ("III", "A regularidade dos ciclos", IMP, "Rimam, não se repetem."),
            ("IV", "O ciclo econômico", IMP, "PIB, emprego e por que ele oscila pouco."),
            ("V", "Governo e o ciclo econômico", OPC, "Juros e gasto público; ligue com o Copom."),
            ("VI", "O ciclo dos lucros", IMP, "Alavancagem operacional e financeira dos lucros."),
            (
                "VII",
                "O pêndulo da psicologia do investidor",
                ESS,
                "Ganância × medo; o motor dos excessos.",
            ),
            (
                "VIII",
                "O ciclo das atitudes em relação ao risco",
                ESS,
                "Quando o risco parece baixo é quando ele é mais alto.",
            ),
            ("IX", "O ciclo do crédito", ESS, "A janela de crédito abre e fecha; o mais poderoso."),
            ("X", "O ciclo da dívida estressada", OPC, "Especialidade da Oaktree."),
            (
                "XI",
                "O ciclo do mercado imobiliário",
                ESS,
                "Defasagem entre demanda e obra pronta; essencial para FIIs de tijolo.",
            ),
            ("XII", "Juntando tudo: o ciclo do mercado", ESS, "Os ciclos somados no preço."),
            ("XIII", "Lidando com os ciclos", ESS, "Como medir a 'temperatura' do mercado."),
            (
                "XIV",
                "Posicionamento no ciclo",
                ESS,
                "Agressivo × defensivo conforme a temperatura.",
            ),
            ("XV", "Limites para lidar com os ciclos", IMP, "Humildade: o tempo é incerto."),
            ("XVI", "O ciclo do sucesso", OPC, "Sucesso traz complacência."),
            ("XVII", "O futuro dos ciclos", OPC, "Por que nunca vão acabar."),
            ("XVIII", "A essência dos ciclos", IMP, "Resumo para reler."),
        ),
    },
    "ordem_mundial": {
        "titulo": "Princípios para a Ordem Mundial em Transformação: por que as nações prosperam "
        "e fracassam",
        "autor": "Ray Dalio",
        "ano": "2021",
        "tenho": True,
        "niveis": [7],
        "sobre": "O grande ciclo de longo prazo: dívida, moeda, ordem interna e externa. Dá o "
        "pano de fundo macro para juros, dólar, ouro e títulos públicos.",
        "como_ler": "Leia a Parte I (como o mundo funciona) e o capítulo de investimentos; a "
        "Parte II é história dos impérios: escolha um (Estados Unidos) e leia como exemplo. "
        "Não é preciso ler os outros impérios para tirar o essencial.",
        "ordem": ["1", "2", "3", "4", "7", "11", "5", "6", "12", "14"],
        "capitulos": _caps(
            ("1", "O grande ciclo em resumo", ESS, "A ideia toda em poucas páginas."),
            ("2", "Os determinantes", ESS, "Os 18 fatores que fazem um país subir ou cair."),
            (
                "3",
                "O valor da moeda em transformação",
                ESS,
                "Moeda forte × fraca; por que guardar dinheiro parado perde valor.",
            ),
            (
                "4",
                "O grande ciclo de dinheiro, crédito e dívida",
                ESS,
                "O ciclo de dívida de longo prazo; ligue com o ciclo de crédito do Marks.",
            ),
            ("5", "O grande ciclo da ordem e desordem interna", IMP, "Desigualdade e polarização."),
            ("6", "O grande ciclo da ordem e desordem externa", IMP, "Conflitos entre potências."),
            (
                "7",
                "Investindo à luz do grande ciclo",
                ESS,
                "O que muda na alocação (diversificar países, moedas e classes).",
            ),
            (
                "11",
                "Ascensão e declínio dos Estados Unidos e do dólar",
                IMP,
                "O caso mais útil para quem investe hoje.",
            ),
            ("12", "A ascensão da China e do renminbi", OPC, "Para entender commodities e Vale."),
            ("14", "O futuro", OPC, "As projeções do autor; leia com espírito crítico."),
        ),
    },
    "bazin": {
        "titulo": "Faça Fortuna com Ações Antes que Seja Tarde",
        "autor": "Décio Bazin",
        "ano": "1992",
        "tenho": True,
        "niveis": [3, 4, 8],
        "sobre": "Clássico brasileiro de dividendos: comprar empresas que pagam bem, pouco "
        "endividadas, e a regra do preço teto (dividendo / 6%).",
        "como_ler": "Livro curto: leia inteiro em duas ou três sessões, anotando as regras. "
        "Depois aplique o preço teto na ficha (Preço Bazin) e compare com o Graham.",
        "ordem": ["Dividendos", "Endividamento", "Preço teto", "Quando vender"],
        "capitulos": _caps(
            (
                "Dividendos",
                "Dividendo como critério (rendimento mínimo de 6%)",
                ESS,
                "A regra central; veja o DY 12m na ficha.",
            ),
            (
                "Endividamento",
                "Empresas pouco endividadas e com lucro constante",
                ESS,
                "O filtro de segurança; ligue com dívida líquida/EBITDA.",
            ),
            (
                "Preço teto",
                "Preço teto = dividendo por ação / 6%",
                ESS,
                "É o 'Preço Bazin' calculado na ficha e na análise da empresa.",
            ),
            (
                "Quando vender",
                "Sinais de alerta e quando vender",
                IMP,
                "Corte de dividendos, dívida crescendo, preço acima do teto.",
            ),
        ),
    },
    # ----- recomendados -----
    "assaf_balancos": {
        "titulo": "Estrutura e Análise de Balanços: um enfoque econômico-financeiro",
        "autor": "Alexandre Assaf Neto",
        "tenho": False,
        "niveis": [2, 3],
        "sobre": "O manual brasileiro de análise de balanços, com o plano de contas daqui (o "
        "mesmo da CVM). Liquidez, endividamento, rentabilidade, ROE × ROIC, capital de giro.",
        "como_ler": "Use como livro-texto do nível 2: os capítulos de análise vertical e "
        "horizontal, indicadores de liquidez, endividamento e rentabilidade são os principais.",
    },
    "manual_societaria": {
        "titulo": "Manual de Contabilidade Societária",
        "autor": "FIPECAFI (Gelbcke, Santos, Iudícibus, Martins)",
        "tenho": False,
        "niveis": [2],
        "sobre": "Referência das normas brasileiras (CPC/IFRS). Não é para ler inteiro.",
        "como_ler": "Consulta: quando uma nota explicativa citar uma norma (arrendamento IFRS 16, "
        "impairment, receita), procure o capítulo do tema.",
    },
    "mais_importante": {
        "titulo": "O Mais Importante para o Investidor",
        "autor": "Howard Marks",
        "tenho": False,
        "niveis": [1, 7],
        "sobre": "Vinte lições curtas: pensamento de segunda ordem, risco, ciclo, preço × valor. "
        "Ótima ponte entre Graham e o livro de ciclos.",
        "como_ler": "Capítulos curtos e independentes; leia os de risco (são três) primeiro.",
    },
    "fisher": {
        "titulo": "Ações Comuns, Lucros Extraordinários",
        "autor": "Philip A. Fisher",
        "tenho": False,
        "niveis": [3],
        "sobre": "O lado qualitativo: os 15 pontos para achar empresas excepcionais e o método "
        "do 'scuttlebutt' (conversar com clientes, fornecedores e concorrentes).",
        "como_ler": "Os 15 pontos (capítulo 3) viram perguntas do seu Questionário de empresas.",
    },
    "ensaios_buffett": {
        "titulo": "Os Ensaios de Warren Buffett",
        "autor": "Warren Buffett (org. Lawrence Cunningham)",
        "tenho": False,
        "niveis": [3, 4, 8],
        "sobre": "As cartas aos acionistas da Berkshire organizadas por tema: governança, "
        "alocação de capital, valuation, contabilidade.",
        "como_ler": "Leia por tema conforme o nível: 'contabilidade' no nível 2, 'avaliação' no "
        "4, 'alocação de capital' no 8.",
    },
    "pequeno_valuation": {
        "titulo": "O Pequeno Livro de Valuation",
        "autor": "Aswath Damodaran",
        "tenho": False,
        "niveis": [4],
        "sobre": "Fluxo de caixa descontado e valuation relativo sem matemática pesada, com "
        "casos por tipo de empresa (jovem, madura, cíclica, banco).",
        "como_ler": "Leia a parte de fundamentos e depois só os casos dos tipos de empresa que "
        "você analisa (há capítulo para bancos e para cíclicas).",
    },
    "valuation_mckinsey": {
        "titulo": "Valuation: Measuring and Managing the Value of Companies",
        "autor": "Koller, Goedhart e Wessels (McKinsey)",
        "tenho": False,
        "niveis": [4],
        "sobre": "A referência técnica de valuation: ROIC, crescimento e criação de valor.",
        "como_ler": "Avançado: leia os capítulos de fundamentos (ROIC × crescimento) e consulte "
        "o resto quando montar um fluxo de caixa.",
    },
    "fosso": {
        "titulo": "The Little Book That Builds Wealth",
        "autor": "Pat Dorsey",
        "tenho": False,
        "niveis": [3],
        "sobre": "Vantagens competitivas (fossos): marca, custo de troca, efeito rede, custo.",
        "como_ler": "Curto; leia inteiro e escreva o fosso de cada empresa na sua tese.",
    },
    "shenanigans": {
        "titulo": "Financial Shenanigans",
        "autor": "Howard Schilit",
        "tenho": False,
        "niveis": [2, 3],
        "sobre": "Como empresas maquiam lucro e caixa; o melhor treino de leitura cética.",
        "como_ler": "Leia as partes de manipulação de lucro e de fluxo de caixa; depois confira "
        "a 'conversão de caixa' (FCO/lucro) das suas empresas.",
    },
    "rapido_devagar": {
        "titulo": "Rápido e Devagar",
        "autor": "Daniel Kahneman",
        "tenho": False,
        "niveis": [7],
        "sobre": "Vieses de decisão: ancoragem, aversão à perda, excesso de confiança.",
        "como_ler": "Partes sobre heurísticas, excesso de confiança e escolhas (teoria da "
        "perspectiva); o resto é opcional.",
    },
    "psicologia_financeira": {
        "titulo": "A Psicologia Financeira",
        "autor": "Morgan Housel",
        "tenho": False,
        "niveis": [1],
        "sobre": "Comportamento com dinheiro, juros compostos e margem de erro na vida real.",
        "como_ler": "Leitura leve, capítulos independentes; bom para começar.",
    },
    "passeio_aleatorio": {
        "titulo": "Um Passeio Aleatório por Wall Street",
        "autor": "Burton Malkiel",
        "tenho": False,
        "niveis": [1, 8],
        "sobre": "O contraponto: mercado eficiente, bolhas e o caso dos índices.",
        "como_ler": "Leia a parte de bolhas e a de alocação por idade.",
    },
    "siegel": {
        "titulo": "Investindo em Ações no Longo Prazo",
        "autor": "Jeremy Siegel",
        "tenho": False,
        "niveis": [1, 5],
        "sobre": "Dois séculos de retorno de ações, títulos e ouro; a base do 'ações no longo "
        "prazo'.",
        "como_ler": "Primeira parte (retornos históricos) e a de inflação.",
    },
    "crises_divida": {
        "titulo": "Princípios para Navegar Grandes Crises de Dívida",
        "autor": "Ray Dalio",
        "tenho": False,
        "niveis": [7],
        "sobre": "O modelo de ciclo de dívida (deflacionário e inflacionário) com casos.",
        "como_ler": "Parte 1 (o modelo); os casos são consulta. Complementa os cap. 3–4 do "
        "Ordem Mundial.",
    },
    "assaf_mercado": {
        "titulo": "Mercado Financeiro",
        "autor": "Alexandre Assaf Neto",
        "tenho": False,
        "niveis": [5],
        "sobre": "Sistema financeiro brasileiro, juros, títulos públicos e privados, derivativos.",
        "como_ler": "Capítulos de taxas de juros, títulos públicos e renda fixa privada.",
    },
    "livro_top_cvm": {
        "titulo": "Mercado de Valores Mobiliários Brasileiro (Livro TOP)",
        "autor": "CVM (gratuito, Portal do Investidor)",
        "tenho": False,
        "niveis": [1, 5, 6],
        "sobre": "Material oficial e gratuito da CVM: ações, fundos, FIIs, renda fixa, regras.",
        "como_ler": "Consulta de regras (FII, fundos, tributação); baixe o PDF no Portal do "
        "Investidor e leia no app com grifos.",
    },
}

# ---------- artigos científicos ----------

# autores, título, revista, nível da trilha, por que ler
ARTIGOS: dict[str, tuple[str, str, str, int, str]] = {
    "markowitz1952": (
        "Markowitz (1952)",
        "Portfolio Selection",
        "Journal of Finance",
        8,
        "Diversificação como redução de risco: a base da alocação de carteira.",
    ),
    "sharpe1964": (
        "Sharpe (1964)",
        "Capital Asset Prices: A Theory of Market Equilibrium under Conditions of Risk",
        "Journal of Finance",
        4,
        "CAPM e beta: de onde vem o custo de capital usado no valuation.",
    ),
    "fama1970": (
        "Fama (1970)",
        "Efficient Capital Markets: A Review of Theory and Empirical Work",
        "Journal of Finance",
        1,
        "Mercado eficiente: o argumento que você precisa vencer.",
    ),
    "basu1977": (
        "Basu (1977)",
        "Investment Performance of Common Stocks in Relation to Their Price-Earnings Ratios",
        "Journal of Finance",
        3,
        "P/L baixo rendeu mais: evidência empírica para Graham.",
    ),
    "kahneman1979": (
        "Kahneman e Tversky (1979)",
        "Prospect Theory: An Analysis of Decision under Risk",
        "Econometrica",
        7,
        "Aversão à perda; por que vendemos cedo e seguramos perdedoras.",
    ),
    "shiller1981": (
        "Shiller (1981)",
        "Do Stock Prices Move Too Much to be Justified by Subsequent Changes in Dividends?",
        "American Economic Review",
        7,
        "Preços oscilam mais que os fundamentos: o Sr. Mercado medido.",
    ),
    "debondt1985": (
        "De Bondt e Thaler (1985)",
        "Does the Stock Market Overreact?",
        "Journal of Finance",
        7,
        "Exagero do mercado e reversão: base do contrarian.",
    ),
    "buffett1984": (
        "Buffett (1984)",
        "The Superinvestors of Graham-and-Doddsville",
        "Hermes (Columbia Business School)",
        1,
        "Resposta de Buffett ao mercado eficiente (apêndice do Investidor Inteligente).",
    ),
    "altman1968": (
        "Altman (1968)",
        "Financial Ratios, Discriminant Analysis and the Prediction of Corporate Bankruptcy",
        "Journal of Finance",
        3,
        "Z-score: índices de balanço que antecipam falência.",
    ),
    "fama1992": (
        "Fama e French (1992)",
        "The Cross-Section of Expected Stock Returns",
        "Journal of Finance",
        4,
        "Tamanho e P/VP explicam retorno: o fator valor.",
    ),
    "jegadeesh1993": (
        "Jegadeesh e Titman (1993)",
        "Returns to Buying Winners and Selling Losers",
        "Journal of Finance",
        8,
        "Momento: o fator que contradiz o valor no curto prazo.",
    ),
    "lsv1994": (
        "Lakonishok, Shleifer e Vishny (1994)",
        "Contrarian Investment, Extrapolation, and Risk",
        "Journal of Finance",
        4,
        "Por que ações baratas rendem mais: extrapolação.",
    ),
    "sloan1996": (
        "Sloan (1996)",
        "Do Stock Prices Fully Reflect Information in Accruals and Cash "
        "Flows about Future Earnings?",
        "The Accounting Review",
        2,
        "Lucro sem caixa (accruals) piora depois: a 'conversão de caixa' da ficha.",
    ),
    "beneish1999": (
        "Beneish (1999)",
        "The Detection of Earnings Manipulation",
        "Financial Analysts Journal",
        2,
        "M-score: sinais de lucro manipulado.",
    ),
    "piotroski2000": (
        "Piotroski (2000)",
        "Value Investing: The Use of Historical Financial "
        "Statement Information to Separate Winners from Losers",
        "Journal of Accounting Research",
        3,
        "F-score: 9 testes de balanço que separam as baratas boas das ruins.",
    ),
    "novymarx2013": (
        "Novy-Marx (2013)",
        "The Other Side of Value: The Gross Profitability Premium",
        "Journal of Financial Economics",
        3,
        "Lucro bruto / ativo prevê retorno: qualidade junto do preço.",
    ),
    "asness2019": (
        "Asness, Frazzini e Pedersen (2019)",
        "Quality Minus Junk",
        "Review of Accounting Studies",
        3,
        "O que é 'qualidade' medida em dados.",
    ),
    "case1989": (
        "Case e Shiller (1989)",
        "The Efficiency of the Market for Single-Family Homes",
        "American Economic Review",
        6,
        "Preço de imóvel tem inércia: o ciclo imobiliário em dados.",
    ),
    "fama1987": (
        "Fama e Bliss (1987)",
        "The Information in Long-Maturity Forward Rates",
        "American Economic Review",
        5,
        "Curva de juros prevê retorno de títulos longos.",
    ),
    "damodaran_erp": (
        "Damodaran (anual)",
        "Equity Risk Premiums (ERP): Determinants, Estimation, and Implications",
        "SSRN (atualizado todo ano)",
        4,
        "Prêmio de risco de ações e de países (inclui o Brasil): use no valuation.",
    ),
}

# ---------- relatórios para praticar ----------

RELATORIOS: dict[str, dict[str, Any]] = {
    "dfp": {
        "nome": "DFP: demonstrações financeiras anuais",
        "emissor": "Empresa → CVM",
        "nivel": 2,
        "url": "https://www.rad.cvm.gov.br/ENET/frmConsultaExternaCVM.aspx",
        "como_ler": [
            "Relatório da administração (o que a empresa diz que fez)",
            "Parecer do auditor: procure 'ressalva' e 'principais assuntos de auditoria'",
            "DRE, balanço e fluxo de caixa: compare com a tabela da ficha",
            "Notas explicativas de dívida (prazos, indexadores) e de partes relacionadas",
        ],
        "no_app": "Mercado › ficha › Demonstrações completas (abre no leitor para grifar).",
    },
    "itr_release": {
        "nome": "ITR e release de resultados trimestral",
        "emissor": "Empresa → CVM / RI",
        "nivel": 3,
        "url": "https://www.rad.cvm.gov.br/ENET/frmConsultaExternaCVM.aspx",
        "como_ler": [
            "Release: os números que a empresa destaca (e os 'ajustados')",
            "Compare o EBITDA ajustado do release com o calculado da DRE",
            "Guidance e comentários sobre o trimestre seguinte",
            "Teleconferência: perguntas dos analistas mostram os riscos",
        ],
        "no_app": "Mercado › ficha › Releases e comunicados.",
    },
    "formulario_referencia": {
        "nome": "Formulário de Referência",
        "emissor": "Empresa → CVM",
        "nivel": 3,
        "url": "https://www.rad.cvm.gov.br/ENET/frmConsultaExternaCVM.aspx",
        "como_ler": [
            "Fatores de risco (seção 4)",
            "Controle e grupo econômico",
            "Remuneração da administração",
            "Transações com partes relacionadas",
        ],
        "no_app": "Página 'Todos os documentos na CVM' da ficha.",
    },
    "relatorio_gerencial_fii": {
        "nome": "Relatório gerencial mensal de FII",
        "emissor": "Gestor do fundo → FNET (B3)",
        "nivel": 6,
        "url": "https://fnet.bmfbovespa.com.br/fnet/publico/abrirGerenciadorDocumentosCVM",
        "como_ler": [
            "Tijolo: vacância física e financeira, inadimplência, contratos típicos × "
            "atípicos, prazo médio (WALT) e reajustes",
            "Papel: carteira de CRIs por indexador (IPCA/CDI), taxa média, LTV, "
            "garantias e devedores concentrados",
            "Resultado por cota × dividendo distribuído (está pagando acima do que ganha?)",
            "Reserva de lucros acumulada",
        ],
        "no_app": "Mercado › ficha do FII › Relatórios gerenciais (FNET).",
    },
    "informe_mensal_fii": {
        "nome": "Informe mensal do FII",
        "emissor": "Administrador → CVM",
        "nivel": 6,
        "url": "https://fnet.bmfbovespa.com.br/fnet/publico/abrirGerenciadorDocumentosCVM",
        "como_ler": [
            "Patrimônio e valor patrimonial da cota (P/VP)",
            "Composição do ativo (imóveis × CRI × caixa)",
            "Número de cotistas",
        ],
        "no_app": "Já vem lido na ficha do FII (P/VP, DY mensal, composição).",
    },
    "focus": {
        "nome": "Boletim Focus (semanal)",
        "emissor": "Banco Central",
        "nivel": 5,
        "url": "https://www.bcb.gov.br/publicacoes/focus",
        "como_ler": [
            "Expectativas de IPCA, Selic, PIB e câmbio para este ano e os próximos",
            "Compare a Selic esperada com a taxa do Tesouro Prefixado",
        ],
        "no_app": "Selic/CDI/IPCA de hoje aparecem em Cenários.",
    },
    "ata_copom": {
        "nome": "Ata do Copom e Relatório de Política Monetária",
        "emissor": "Banco Central",
        "nivel": 5,
        "url": "https://www.bcb.gov.br/publicacoes/atascopom",
        "como_ler": [
            "Balanço de riscos para a inflação",
            "Sinalização dos próximos passos",
            "O que isso faz com prefixados e IPCA+ (marcação a mercado)",
        ],
        "no_app": "",
    },
    "tesouro_direto": {
        "nome": "Títulos do Tesouro Direto e Relatório Mensal da Dívida",
        "emissor": "Tesouro Nacional",
        "nivel": 5,
        "url": "https://www.tesourodireto.com.br/",
        "como_ler": [
            "Taxas de Selic, Prefixado e IPCA+ por vencimento (curva de juros)",
            "Relatório da Dívida: prazo médio e custo da dívida pública",
        ],
        "no_app": "",
    },
    "cartas_berkshire": {
        "nome": "Cartas anuais da Berkshire Hathaway",
        "emissor": "Warren Buffett",
        "nivel": 3,
        "url": "https://www.berkshirehathaway.com/letters/letters.html",
        "como_ler": [
            "Uma carta por semana, das antigas (1977+) para as novas",
            "Grife as frases sobre alocação de capital e contabilidade",
        ],
        "no_app": "Baixe o PDF para Arquivos e leia com o projeto Trilha de Finanças ativo.",
    },
    "memos_oaktree": {
        "nome": "Memorandos da Oaktree",
        "emissor": "Howard Marks",
        "nivel": 7,
        "url": "https://www.oaktreecapital.com/insights/memos",
        "como_ler": [
            "Leia o memo mais recente e um antigo de crise (2007–2009)",
            "Relacione com o capítulo do ciclo de crédito",
        ],
        "no_app": "",
    },
    "damodaran_dados": {
        "nome": "Dados de Damodaran (prêmio de risco, múltiplos por setor)",
        "emissor": "NYU Stern",
        "nivel": 4,
        "url": "https://pages.stern.nyu.edu/~adamodar/",
        "como_ler": [
            "Prêmio de risco do Brasil (Country Risk Premium)",
            "Múltiplos médios do setor para comparar com a sua empresa",
        ],
        "no_app": "",
    },
    "portal_investidor": {
        "nome": "Portal do Investidor (CVM) e ANBIMA",
        "emissor": "CVM / ANBIMA",
        "nivel": 1,
        "url": "https://www.gov.br/investidor/",
        "como_ler": ["Cadernos sobre ações, fundos e FIIs", "Regras de tributação e de fundos"],
        "no_app": "",
    },
}

# ---------- trilha ----------

ETAPAS: list[dict[str, Any]] = [
    {
        "id": "n1_investir",
        "nivel": 1,
        "titulo": "Investir não é especular",
        "meta": "Explicar com suas palavras o que é investir e por que o preço de hoje não é o "
        "valor.",
        "leituras": [
            ("investidor_inteligente", ["1", "8"]),
            ("mais_importante", []),
            ("psicologia_financeira", []),
        ],
        "artigos": ["buffett1984", "fama1970"],
        "relatorios": ["portal_investidor"],
        "pratica": "Em Mercado, abra 3 ações que mais caíram hoje e escreva se algo mudou no "
        "negócio ou só no preço.",
    },
    {
        "id": "n1_juros",
        "nivel": 1,
        "titulo": "Juros compostos, inflação e risco",
        "meta": "Saber o retorno real (descontada a inflação) de cada classe de ativo.",
        "leituras": [("investidor_inteligente", ["2", "3"]), ("siegel", [])],
        "artigos": ["markowitz1952"],
        "relatorios": [],
        "pratica": "Em Cenários, simule juntar × financiar e veja o efeito dos juros.",
    },
    {
        "id": "n2_balanco",
        "nivel": 2,
        "titulo": "Balanço patrimonial",
        "meta": "Achar no balanço: caixa, dívida, patrimônio líquido e capital de giro.",
        "leituras": [
            ("interpretacao_demonstracoes", ["Balanço", "Capital de giro", "Valor patrimonial"]),
            ("assaf_balancos", []),
        ],
        "artigos": ["altman1968"],
        "relatorios": ["dfp"],
        "pratica": "Abra a DFP de uma empresa (Mercado › ficha) e confira o PL e a dívida "
        "bruta com a tabela da ficha.",
    },
    {
        "id": "n2_dre",
        "nivel": 2,
        "titulo": "DRE e fluxo de caixa",
        "meta": "Ler a DRE de cima a baixo e dizer se o lucro virou caixa.",
        "leituras": [
            (
                "interpretacao_demonstracoes",
                ["DRE", "Ativos fixos e depreciação", "Lucro por ação"],
            ),
            ("shenanigans", []),
        ],
        "artigos": ["sloan1996", "beneish1999"],
        "relatorios": ["dfp", "itr_release"],
        "pratica": "Compare lucro líquido × caixa operacional de 5 anos na ficha "
        "(linha 'Conversão de caixa').",
    },
    {
        "id": "n3_indicadores",
        "nivel": 3,
        "titulo": "Indicadores e qualidade",
        "meta": "Montar o painel de uma empresa: margens, ROE, ROIC, endividamento, crescimento.",
        "leituras": [
            ("investidor_inteligente", ["11", "12"]),
            ("interpretacao_demonstracoes", ["Índices"]),
            ("assaf_balancos", []),
        ],
        "artigos": ["piotroski2000", "novymarx2013", "asness2019"],
        "relatorios": ["itr_release", "formulario_referencia"],
        "pratica": "Acompanhe uma empresa (Mercado › Acompanhar) e responda o Questionário.",
    },
    {
        "id": "n3_negocio",
        "nivel": 3,
        "titulo": "O negócio: fosso e gestão",
        "meta": "Escrever a tese: por que essa empresa ganha dinheiro e o que pode dar errado.",
        "leituras": [
            ("fisher", []),
            ("fosso", []),
            ("ensaios_buffett", []),
            ("investidor_inteligente", ["19"]),
        ],
        "artigos": [],
        "relatorios": ["cartas_berkshire", "formulario_referencia"],
        "pratica": "Preencha Tese e Riscos na empresa acompanhada.",
    },
    {
        "id": "n3_dividendos",
        "nivel": 3,
        "titulo": "Dividendos (método Bazin)",
        "meta": "Filtrar pagadoras consistentes e calcular o preço teto.",
        "leituras": [("bazin", ["Dividendos", "Endividamento", "Preço teto", "Quando vender"])],
        "artigos": [],
        "relatorios": ["itr_release"],
        "pratica": "Compare o Preço Bazin com a cotação de 5 pagadoras na ficha.",
    },
    {
        "id": "n4_valuation",
        "nivel": 4,
        "titulo": "Valuation e margem de segurança",
        "meta": "Estimar um preço justo por múltiplos e por fluxo de caixa, com folga.",
        "leituras": [
            ("investidor_inteligente", ["14", "15", "20"]),
            ("pequeno_valuation", []),
            ("valuation_mckinsey", []),
        ],
        "artigos": ["basu1977", "fama1992", "lsv1994", "sharpe1964", "damodaran_erp"],
        "relatorios": ["damodaran_dados"],
        "pratica": "Defina o preço teto de uma empresa e veja a margem de segurança na análise.",
    },
    {
        "id": "n5_tesouro",
        "nivel": 5,
        "titulo": "Tesouro Direto e juros",
        "meta": "Escolher entre Selic, Prefixado e IPCA+ e entender a marcação a mercado.",
        "leituras": [("assaf_mercado", []), ("livro_top_cvm", []), ("siegel", [])],
        "artigos": ["fama1987"],
        "relatorios": ["focus", "ata_copom", "tesouro_direto"],
        "pratica": "Anote a taxa do IPCA+ longo hoje e compare com o IPCA esperado no Focus.",
    },
    {
        "id": "n6_tijolo",
        "nivel": 6,
        "titulo": "FIIs de tijolo",
        "meta": "Avaliar vacância, contratos, localização e P/VP de um fundo de imóveis.",
        "leituras": [("ciclo_mercado", ["XI"]), ("livro_top_cvm", [])],
        "artigos": ["case1989"],
        "relatorios": ["relatorio_gerencial_fii", "informe_mensal_fii"],
        "pratica": "Abra HGLG11 (ou outro de logística) em Mercado e leia o relatório gerencial.",
    },
    {
        "id": "n6_papel",
        "nivel": 6,
        "titulo": "FIIs de papel (CRI)",
        "meta": "Ler a carteira de CRIs: indexador, taxa, garantias e concentração.",
        "leituras": [("livro_top_cvm", []), ("assaf_mercado", [])],
        "artigos": [],
        "relatorios": ["relatorio_gerencial_fii", "informe_mensal_fii", "focus"],
        "pratica": "Compare o DY de MXRF11 e KNCR11 com o CDI e o IPCA de hoje.",
    },
    {
        "id": "n7_ciclos",
        "nivel": 7,
        "titulo": "Ciclos e psicologia do mercado",
        "meta": "Dizer em que ponto do ciclo estamos e o que isso muda na sua carteira.",
        "leituras": [
            ("ciclo_mercado", ["I", "II", "VII", "VIII", "IX", "XII", "XIII", "XIV"]),
            ("rapido_devagar", []),
        ],
        "artigos": ["shiller1981", "debondt1985", "kahneman1979", "jegadeesh1993"],
        "relatorios": ["memos_oaktree"],
        "pratica": "Escreva a 'temperatura' do mercado hoje (frio, morno, quente) com 3 sinais.",
    },
    {
        "id": "n7_macro",
        "nivel": 7,
        "titulo": "A ordem mundial e o ciclo da dívida",
        "meta": "Entender o pano de fundo de juros, moedas e dívida dos países.",
        "leituras": [("ordem_mundial", ["1", "2", "3", "4", "7", "11"]), ("crises_divida", [])],
        "artigos": [],
        "relatorios": ["ata_copom", "tesouro_direto"],
        "pratica": "Relacione o capítulo 4 do Dalio com a Selic e a dívida pública de hoje.",
    },
    {
        "id": "n8_carteira",
        "nivel": 8,
        "titulo": "Sua carteira e seu processo",
        "meta": "Ter alocação-alvo, regra de rebalanceamento e um diário de decisões.",
        "leituras": [
            ("investidor_inteligente", ["4", "5", "20"]),
            ("passeio_aleatorio", []),
            ("ensaios_buffett", []),
        ],
        "artigos": ["markowitz1952", "fama1992"],
        "relatorios": [],
        "pratica": "Em Investimentos › Carteira, confira a alocação por setor e defina o alvo.",
    },
]

ESQUEMA_GUIA = {
    "type": "object",
    "properties": {
        "sobre": {"type": "string"},
        "como_ler": {"type": "string"},
        "niveis": {"type": "array", "items": {"type": "integer"}},
        "ordem": {"type": "array", "items": {"type": "string"}},
        "capitulos": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "n": {"type": "string"},
                    "titulo": {"type": "string"},
                    "prioridade": {"type": "string", "enum": [ESS, IMP, OPC]},
                    "porque": {"type": "string"},
                },
                "required": ["n", "titulo", "prioridade", "porque"],
            },
        },
        "relacionados": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["sobre", "como_ler", "niveis", "ordem", "capitulos"],
}

SISTEMA_GUIA = """Você monta guias de leitura não linear de livros de finanças e investimentos para
um investidor brasileiro pessoa física que estuda sozinho. Português do Brasil, frases curtas.
Diga quais capítulos ler, em que ordem e por quê; marque cada um como essencial, importante ou
opcional. Numere capítulos só se tiver certeza do sumário; senão use o assunto do capítulo como
'n' e diga em 'como_ler' para conferir no sumário da edição. Não invente capítulos. Ligue cada
capítulo aos níveis da trilha: 1 fundamentos, 2 contabilidade, 3 análise de empresas, 4 valuation,
5 renda fixa e Tesouro, 6 fundos imobiliários, 7 ciclos/psicologia/macro, 8 carteira. Em
'relacionados', cite outros livros do catálogo que complementam."""


def _busca_artigo(titulo: str) -> str:
    return "https://scholar.google.com/scholar?q=" + quote_plus(titulo)


def _livro(id_: str, dados: dict[str, Any], extra: dict[str, Any] | None) -> dict[str, Any]:
    """Livro do catálogo (ou acrescentado) com o que a pessoa marcou e o guia do Claude, se houver:
    o guia do Claude completa, mas não troca, o guia escrito aqui."""
    guia = (extra or {}).get("guia") or {}
    livro = {
        "id": id_,
        "titulo": dados["titulo"],
        "autor": dados.get("autor", ""),
        "ano": dados.get("ano", ""),
        "tenho": dados.get("tenho", False),
        "niveis": dados.get("niveis") or guia.get("niveis") or [],
        "sobre": dados.get("sobre") or guia.get("sobre", ""),
        "como_ler": dados.get("como_ler") or guia.get("como_ler", ""),
        "ordem": dados.get("ordem") or guia.get("ordem") or [],
        "capitulos": [dict(c) for c in dados.get("capitulos") or guia.get("capitulos") or []],
        "relacionados": guia.get("relacionados", []),
        "guia_claude": bool(guia),
        "registro_id": (extra or {}).get("id"),
        "catalogo": id_ in LIVROS,
    }
    if (extra or {}).get("tenho") in ("sim", "nao"):
        livro["tenho"] = extra["tenho"] == "sim"  # type: ignore[index]
    return livro


def livros(arm: Armazem) -> dict[str, dict[str, Any]]:
    registros = arm.todos("estudo_livros")
    por_catalogo = {r["catalogo"]: r for r in registros if r["catalogo"]}
    saida = {k: _livro(k, v, por_catalogo.get(k)) for k, v in LIVROS.items()}
    for r in registros:
        if not r["catalogo"]:
            saida[r["id"]] = _livro(r["id"], r, r)
    return saida


def montar(arm: Armazem, objetivo: str = "") -> dict[str, Any]:
    """A trilha inteira com o progresso: objetivo, níveis com etapas (cada leitura com os
    capítulos certos do livro), livros, artigos e relatórios."""
    progresso = {p["item"]: p for p in arm.todos("estudo_progresso")}
    objetivo = objetivo or (progresso.get("objetivo") or {}).get("nota") or "investidor"
    obj = next((o for o in OBJETIVOS if o["id"] == objetivo), OBJETIVOS[0])
    biblioteca = livros(arm)

    def estado(item: str) -> dict[str, Any]:
        p = progresso.get(item) or {}
        return {
            "status": p.get("status") or "pendente",
            "nota": p.get("nota", ""),
            "leitura_id": p.get("leitura_id", ""),
        }

    artigos = {
        k: {
            "id": k,
            "autores": a,
            "titulo": t,
            "revista": r,
            "nivel": n,
            "porque": q,
            "url": _busca_artigo(t),
            **estado(f"artigo:{k}"),
        }
        for k, (a, t, r, n, q) in ARTIGOS.items()
    }
    relatorios = {k: {"id": k, **v, **estado(f"relatorio:{k}")} for k, v in RELATORIOS.items()}
    for k, livro in biblioteca.items():
        livro.update(estado(f"livro:{k}"))
        for c in livro["capitulos"]:
            c["status"] = estado(f"cap:{k}:{c['n']}")["status"]

    niveis = []
    feitas = total = 0
    for n in obj["niveis"]:
        titulo, resumo = NIVEIS[n]
        etapas = []
        for e in (x for x in ETAPAS if x["nivel"] == n):
            leituras = []
            for livro_id, caps in e["leituras"]:
                livro = biblioteca[livro_id]
                escolhidos = [c for c in livro["capitulos"] if c["n"] in caps] if caps else []
                lidos = sum(c["status"] == "feito" for c in escolhidos)
                leituras.append(
                    {
                        "livro": livro_id,
                        "titulo": livro["titulo"],
                        "autor": livro["autor"],
                        "tenho": livro["tenho"],
                        "capitulos": escolhidos,
                        "inteiro": not caps,
                        "lidos": lidos,
                    }
                )
            st = estado(f"etapa:{e['id']}")
            total += 1
            feitas += st["status"] == "feito"
            etapas.append(
                {
                    **{
                        k: v for k, v in e.items() if k not in ("leituras", "artigos", "relatorios")
                    },
                    **st,
                    "leituras": leituras,
                    "artigos": [artigos[a] for a in e["artigos"]],
                    "relatorios": [relatorios[r] for r in e["relatorios"]],
                }
            )
        niveis.append({"nivel": n, "titulo": titulo, "resumo": resumo, "etapas": etapas})
    return {
        "objetivo": obj,
        "objetivos": [{k: o[k] for k in ("id", "nome", "descricao")} for o in OBJETIVOS],
        "progresso": {"feitas": feitas, "total": total},
        "niveis": niveis,
        "livros": sorted(biblioteca.values(), key=lambda x: (not x["tenho"], x["titulo"])),
        "artigos": sorted(artigos.values(), key=lambda x: (x["nivel"], x["autores"])),
        "relatorios": sorted(relatorios.values(), key=lambda x: x["nivel"]),
        "projeto": PROJETO,
    }


def marcar(arm: Armazem, item: str, dados: dict[str, Any]) -> dict[str, Any]:
    """Grava o status (pendente, lendo, feito), a nota ou a leitura ligada de um item da trilha:
    `etapa:<id>`, `livro:<id>`, `cap:<livro>:<n>`, `artigo:<id>`, `relatorio:<id>` ou
    `objetivo` (a nota guarda o id do objetivo)."""
    if not item or len(item) > 200:
        raise Invalido("Item inválido.")
    campos = {k: dados[k] for k in ("status", "nota", "leitura_id") if k in dados}
    atual = next((p for p in arm.todos("estudo_progresso") if p["item"] == item), None)
    if atual:
        return arm.editar("estudo_progresso", atual["id"], campos)
    return arm.criar("estudo_progresso", {"item": item, **campos})


def tenho(arm: Armazem, livro_id: str, valor: bool) -> dict[str, Any]:
    """Marca se a pessoa tem o livro (do catálogo ou acrescentado)."""
    registro = next(
        (r for r in arm.todos("estudo_livros") if livro_id in (r["id"], r["catalogo"])), None
    )
    if registro:
        return arm.editar("estudo_livros", registro["id"], {"tenho": "sim" if valor else "nao"})
    if livro_id not in LIVROS:
        raise Invalido("Livro não encontrado.")
    return arm.criar(
        "estudo_livros",
        {
            "titulo": LIVROS[livro_id]["titulo"],
            "catalogo": livro_id,
            "tenho": "sim" if valor else "nao",
        },
    )


def prompt_guia(livro: dict[str, Any]) -> str:
    catalogo = "\n".join(f"- {v['titulo']} ({v.get('autor', '')})" for v in LIVROS.values())
    return (
        f"Livro: {livro['titulo']}\nAutor: {livro.get('autor') or 'não informado'}\n\n"
        "Monte o guia de leitura não linear deste livro para a trilha de finanças. Livros do "
        f"catálogo para 'relacionados':\n{catalogo}"
    )
