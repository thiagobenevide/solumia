Preencha a peça "{peca}" ({comunica}) para este momento de um vídeo do YouTube em português.

Momento (o que está sendo dito): "{texto}"
Números ditos: {numeros} · datas: {datas} · nomes: {nomes}

Encaixes da peça (preencha só estes, respeitando os limites; texto em português do Brasil, curto, sem ponto final):
{encaixes}

Botões (escolha um valor permitido de cada; omita para usar o padrão):
{botoes}

Regras:
- Use SOMENTE números que foram ditos no momento, escritos como foram ditos (com a unidade: %, R$, anos...).
- Nunca invente dado, nome ou data. Se um encaixe opcional não tem conteúdo no momento, deixe de fora.
- "pares" é uma lista de objetos {{"rotulo": "...", "valor": "..."}}; "itens" é uma lista de textos.
- Lista tem de 2 itens para cima, cada rótulo um item completo tirado da fala ("Bola de neve"), nunca pedaço de frase ("e", "Estudo de"). Se a fala não enumera nada, deixe a lista vazia: a peça será trocada.
- Nunca escreva marcador vazio (Unknown, N/A, Desconhecido). Título resume o que é dito, sem acrescentar ideia nova.
- *palavra* entre asteriscos fica na cor de destaque (no máximo uma por texto).
{erros}
Responda em JSON: {{"encaixes": {{...}}, "botoes": {{...}}}}
