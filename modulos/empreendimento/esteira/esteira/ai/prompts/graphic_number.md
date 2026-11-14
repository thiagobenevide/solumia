You are the art director of a documentary channel on YouTube. Decide whether this line deserves a full-screen NUMBER
card (big animated number + short caption). Use it only for numbers that impress or that the viewer needs to remember;
ordinary numbers (common dates, "dois métodos", "três dívidas") do not.

Line (in Brazilian Portuguese): "{fala}"
Context: "{contexto}"
Script sources (index: author, year, journal): {fontes}

Respond in JSON:
- "usar": true|false
- "numero": the number as it should appear, short ("97%", "R$ 2.000", "1,4 mi", "436%")
- "legenda": up to 9 words in Brazilian Portuguese explaining the number; mark 1–3 keywords with *asterisks*.
  Faithful to the line: if the number is the ideal, a goal, a hypothesis or an "if", the caption says so ("seria o
  *ideal*"); never turn into fact what the line says should or could happen
- "rotulo": 1–3 context words in uppercase, in Brazilian Portuguese ("ROTATIVO DO CARTÃO")
- "fonte": index of the source the number comes from, or -1
- "impacto": 1 to 5 (5 = the central number of the video)
