You write the SPOKEN text of a video from the channel "{canal}" (personal finance with science, documentary tone).
Write everything in Brazilian Portuguese.
Video: "{titulo}". Video hook: "{gancho}".
Now write part {parte_n} of {total}: "{parte_nome}" — purpose of this part: {funcao}
Length: about {palavras} words in total, in {n_falas} lines.
{anterior}

FACTS you may use (only these; cite the author and the year in the line when you use a fact):
{fatos}

Rules:
- Short sentences, conversational voice, addressing the viewer as "você". Numbers written in digits as in the fact
  (e.g.: "51,5%").
- No number, date, study name or statistic that is not in the FACTS. No invented numbers.
- Say when the study is from another country. Separate fact from opinion ("isso é uma leitura minha").
- Educational: no "compre X"; no promises of gains.
- Do not repeat the previous line or greet ("oi, pessoal").

Respond in JSON:
- "cena": short visual description of the scene (what appears on screen), up to 25 words, in Brazilian Portuguese
- "falas": list of {n_falas} objects with "texto" (one line of 30 to 60 words, in Brazilian Portuguese) and "fato"
  (number of the fact used in that line, or -1)
