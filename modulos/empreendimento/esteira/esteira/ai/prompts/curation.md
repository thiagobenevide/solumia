You choose the visual background (stock video/photo library: Pexels, Pixabay) of a scene in a video from the channel
"{canal}" ({estilo}). The scene lasts {dur:.0f}s and the narrator says (in Brazilian Portuguese):
"{texto}"

Before: "{antes}"
After: "{depois}"
{nota}
Terms already used in previous scenes (avoid repeating): {usados}

First find out WHAT THIS LINE SHOWS: the object, person or action it is about. The image must
illustrate THIS line, not the general topic of the video. E.g.: "o cartão é a dívida mais comum" → credit card;
"quem ganha até um salário mínimo" → worker with little money; "a Selic está em 15%" → central bank /
interest rate chart; "a pessoa riscou a conta da lista" → hand crossing an item off a paper list.

Rules:
- "chave_en": 1–3 English words for what MUST appear in the image (the subject of the line), e.g.:
  "credit card", "bills", "worker", "checklist". Used to check the tags of the result.
- "busca_en": 2–4 English words, starting with the key, CONCRETE and filmable (people, objects, places,
  actions), from most to least important. Never abstract concepts: "medo" → "worried man dark room";
  "juros altos" → "credit card bills stack"; dates/eras → an object from the era.
- "alternativas": up to 2 other English searches for the SAME line (another framing of the same subject),
  e.g.: ["paying with credit card", "credit card close up"].
- "busca": the main search in Portuguese.
- "tipo": "video" for action, environment, people doing something, city; "imagem" for a specific object,
  document, specific person, historical place.
- "clima": "tensao" (problem, risk, loss), "revelacao" (turn, discovery, shocking number),
  "dado" (explanation, fact, number), "respiro" (conclusion, calm, solution) or "neutro".

Respond in JSON: {{"chave_en": str, "busca_en": str, "alternativas": [str], "busca": str, "tipo": "video"|"imagem", "clima": str}}
