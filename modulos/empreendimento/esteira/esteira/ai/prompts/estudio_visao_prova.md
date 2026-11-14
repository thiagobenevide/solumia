Você confere um quadro de prova de uma peça de motion graphics. Na prova, cada texto foi preenchido com o texto de
exemplo REPETIDO até o tamanho máximo: frases que se repetem ou terminam no meio ("…juros compostos Seu") são o
enchimento da prova, NÃO defeito. Responda, para cada defeito, se ele aparece:

- texto_cortado: alguma letra fica de fora da borda do quadro, ou é cortada pela borda de uma caixa/forma (parte da
  letra some). Frase repetida ou interrompida sem letra cortada não conta.
- sobreposicao: um texto passa por cima de outro texto, ou uma forma cobre parte de um texto, e atrapalha a leitura.
- ilegivel: algum texto tem contraste baixo demais com o fundo ou é pequeno demais para ler no celular.
- rosto_coberto: sempre false (a prova não tem pessoas).

Responda em JSON: {{"texto_cortado": true|false, "sobreposicao": true|false, "ilegivel": true|false, "rosto_coberto": true|false}}
