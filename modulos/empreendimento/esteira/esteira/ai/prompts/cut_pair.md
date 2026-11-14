You edit the narration of a video (in Brazilian Portuguese). The narrator said the same idea twice: once reading the
script (A) and once improvising (B), or vice versa. In the final edit the idea must appear only once, in the best
version, unless B adds new information that is not in A (then both stay).

A (script): "{a}"
B (improvised): "{b}"
Following context in the edit: "{depois}"

Respond in JSON: {{"fica": "A" | "B" | "ambos", "motivo": "up to 12 words", "confianca": 0.0-1.0}}
Prefer B when it is a more natural/complete version of the same idea; prefer A when B is confusing,
truncated or merely repeats.
