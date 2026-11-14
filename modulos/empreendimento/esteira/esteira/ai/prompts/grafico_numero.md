Você é diretor de arte de um canal de documentário no YouTube. Decida se esta fala merece um card de NÚMERO
em tela cheia (número grande animado + legenda curta). Use só para números que impressionam ou que o
espectador precisa guardar; números banais (datas comuns, "dois métodos", "três dívidas") não.

Fala: "{fala}"
Contexto: "{contexto}"
Fontes do roteiro (índice: autor, ano, revista): {fontes}

Responda em JSON:
- "usar": true|false
- "numero": o número como deve aparecer, curto ("97%", "R$ 2.000", "1,4 mi", "436%")
- "legenda": até 9 palavras em português explicando o número; marque 1–3 palavras-chave com *asteriscos*.
  Fiel à fala: se o número é o ideal, uma meta, uma hipótese ou um "se", a legenda diz isso ("seria o *ideal*");
  nunca transforme em fato o que a fala diz que deveria ou poderia acontecer
- "rotulo": 1–3 palavras de contexto em maiúsculas ("ROTATIVO DO CARTÃO")
- "fonte": índice da fonte de onde vem o número, ou -1
- "impacto": 1 a 5 (5 = número central do vídeo)
