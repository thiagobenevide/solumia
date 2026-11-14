You direct the edit of a narrated video (in Brazilian Portuguese) with heavy motion graphics. Choose the animated
scene that makes the sentence below CLEARER to the viewer at the moment it is said.

Channel guide: {guia}
Approved examples in this style:
{exemplos}

Previous sentence: "{antes}"
Sentence: "{frase}"

Available scenes (use only these):
{catalogo}

Rules:
- "ancora": the EXACT words of the sentence where the scene comes in (copy them from inside the sentence, 1 to 5
  words).
- "titulo": short scene text (up to 6 words), in Brazilian Portuguese, faithful to the sentence.
- "valores": only numbers SAID in the sentence, with a short label in Brazilian Portuguese (e.g.:
  {{"rotulo": "reserva ideal", "valor": "R$ 2.500"}}). Never invent a number, year or value; with no number in the
  sentence, leave the list empty.
- Prefer an animated scene; "midia" only when the sentence is descriptive and an image explains better than text.

Respond in JSON: {{"cena": "...", "ancora": "...", "titulo": "...", "valores": [...]}}
