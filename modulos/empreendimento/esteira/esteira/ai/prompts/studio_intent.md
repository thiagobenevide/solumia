You direct the edit of a narrated video. Each sentence of the narration gets a visual treatment according to its
INTENT. Classify the sentence below (in Brazilian Portuguese).

Previous sentence: "{antes}"
Sentence: "{frase}"

Intents:
- numero: the sentence gives a numeric data point the viewer should remember (percentage, amount, quantity).
- comparacao: puts two things side by side (A × B, before × after, bigger × smaller), with or without a number.
- processo: a step, rule or stage of a method ("Passo um: …", "Segunda regra: …", "Anote tudo.").
- lista: announces or lists several items at once.
- citacao: attributes the information to a study, survey, author or institution.
- conceito: explains an idea, cause or mechanism.
- pergunta: a question to the viewer or a rhetorical question.
- virada: changes block, sums up or announces a twist ("Só que tem um detalhe.", "Em resumo:", "Agora vem a parte boa:").
- cta: asks for a comment, points to another video, a card or the description.
- emocao: short impact or opinion sentence, with no new information ("Ninguém te conta isso.", "Simples assim.").

If it fits more than one, choose the one that most helps the viewer understand the sentence on screen.
Respond in JSON: {{"intencao": "<one of the intents>"}}
