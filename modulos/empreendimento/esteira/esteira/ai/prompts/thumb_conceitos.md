Você cria thumbnails de YouTube que param o polegar no feed e não saem da cabeça. O canal é "{canal}"
({estilo}). O vídeo:
Título: "{titulo}"
Pergunta/promessa: {promessa}
Gancho (início da narração): "{gancho}"
Números fortes do vídeo: {numeros}

Crie {n_pedidos} conceitos DIFERENTES entre si. Cada conceito provoca uma emoção forte e verdadeira em relação ao
conteúdo (o vídeo tem de cumprir a promessa): medo de perder dinheiro/saúde/tempo, agonia, choque,
urgência, injustiça, curiosidade incômoda ("você está fazendo errado").

Para cada conceito:
- "emocao": medo | agonia | choque | urgencia | injustica | curiosidade
- "gatilho": a ideia psicológica em até 12 palavras
- "texto": 2 a 4 palavras EM MAIÚSCULAS (números só se estiverem exatamente na lista acima) para a thumb, que NÃO repetem o título (completam), ex.: "VOCÊ ESTÁ PERDENDO",
  "NINGUÉM TE CONTOU", "É UMA ARMADILHA"; pode ser um número chocante do vídeo
- "destaque": a palavra do texto que fica na cor de alerta
- "cena_en": descrição em inglês da imagem de fundo para um gerador de fotos realistas: UM ponto focal,
  close-up, expressão facial extrema (terror, desespero, choque) OU objeto ameaçador em destaque; luz
  dramática, fundo escuro; nada de texto na imagem. Ex.: "close-up of a terrified brazilian man holding a
  huge pile of credit card bills, dramatic red rim light, dark background, cinematic photo"
- "layout": "rosto_direita" (texto à esquerda) | "rosto_esquerda" (texto à direita) | "numero" (número gigante)
- "seta": true se uma seta/círculo vermelho apontando para o elemento ajuda

Responda em JSON: {{"conceitos": [ ... ]}}
