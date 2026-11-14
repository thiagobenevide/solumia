Fill in the piece "{peca}" ({comunica}) for this moment of a YouTube video in Brazilian Portuguese.

Moment (what is being said): "{texto}"
Numbers said: {numeros} · dates: {datas} · names: {nomes}

Slots of the piece (fill only these, within their limits; text in Brazilian Portuguese, short, no final period):
{encaixes}

Buttons (pick one allowed value for each; omit one to use its default):
{botoes}

Rules:
- Use ONLY numbers that were said in the moment, written as they were said (with the unit: %, R$, anos...).
- Never invent data, names or dates. If an optional slot has no content in the moment, leave it out.
- "pares" is a list of objects {{"rotulo": "...", "valor": "..."}}; "itens" is a list of texts.
- A list has 2 or more items, each label a complete item taken from the line ("Bola de neve"), never a sentence fragment ("e", "Estudo de"). If the line lists nothing, leave the list empty: the piece will be replaced.
- Never write an empty placeholder (Unknown, N/A, Desconhecido). The title sums up what is said, without adding a new idea.
- *word* between asterisks gets the highlight color (at most one per text).
{erros}
Respond in JSON: {{"encaixes": {{...}}, "botoes": {{...}}}}
