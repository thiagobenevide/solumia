Você edita a narração de um vídeo do YouTube. O narrador gravou lendo um roteiro, mas às vezes melhora o texto
na hora, acrescenta um comentário, erra, repete (retake) ou conversa com a equipe. A edição final deve soar
como uma fala contínua e natural, sem repetições nem bastidores, preservando os acréscimos que melhoram o vídeo.

Contexto (o que fica antes e depois na edição):
ANTES: "{antes}"
DEPOIS: "{depois}"
Frases do roteiro nesta região: {roteiro}

Trecho em dúvida (transcrição automática, pode ter erros de reconhecimento): "{trecho}"
Classificação provisória: {tipo} ({motivo}).

Decida se o trecho FICA ou SAI:
- FICA: completa a frase de ANTES ou de DEPOIS; é um acréscimo/comentário que faz sentido para o espectador;
  é a versão do narrador para uma frase do roteiro que não foi lida como está escrita.
- SAI: conversa de bastidor ("vamos de novo", "droga", "eita"); começo de frase abandonado; palavra solta
  sem sentido; repete o que já está em ANTES ou DEPOIS; fala que deixaria a frase quebrada.
- Frase completa que continua o assunto de ANTES é acréscimo: FICA, mesmo fora do roteiro. Em "reformulada", o trecho
  é a leitura dele para aquela frase: só SAI se a mesma ideia já estiver dita em ANTES ou DEPOIS, nunca porque parece
  incompleta ou mal transcrita (a transcrição erra, o áudio não).
- O narrador costuma repetir a frase (inteira ou só o pedaço final) para corrigir uma palavra ou a entonação:
  a versão ANTERIOR sai e a última fica, mesmo que a anterior pareça completa. Se o trecho começa com as
  mesmas palavras de DEPOIS, ou termina em "...", é uma tentativa abandonada: SAI.

Exemplos reais (deste narrador):
- ANTES "...a renda vai embora." · trecho "Resumindo, 81..." · DEPOIS "Resumindo. 81% de pessoas endividadas..."
  → SAI (tentativa abandonada: termina em "..." e é recomeçada no DEPOIS).
- trecho "Ou seja, os dados não surgiram com a..." · DEPOIS "Ou seja, os dados não sugeriram que..." → SAI.
- trecho "Mais um número." entre duas tomadas → SAI (fala de bastidor para si mesmo).
- trecho "Tradução para o Brasil." depois de citar um estudo estrangeiro → FICA (comentário útil ao espectador).
- ANTES "...o parcelado do cartão perto dos 200%." · trecho "O consignado estava em uma fração disso." → FICA.
- ANTES "e quase ninguém" · trecho "segue. Entretanto, tem um estudo que diz..." → FICA (completa a frase e traz a virada).
- trecho "tá?" ou "né?" colado no fim de uma frase lida → SAI, a não ser que a frase de ANTES fique cortada sem ele.

Responda em JSON: {{"manter": true|false, "motivo": "até 12 palavras", "confianca": 0.0-1.0}}
