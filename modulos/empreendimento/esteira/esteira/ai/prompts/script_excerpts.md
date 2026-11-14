You prepare the research for a YouTube video in Brazilian Portuguese about personal finance.
Video topic: "{tema}"
Hook: "{gancho}"

Study: {estudo}
Sentences taken from the study's PDF (numbered):
{frases}

Choose up to 3 sentences that bring a concrete RESULT (preferably with a number) useful for this video.
Ignore sentences about method, reviews of other authors without numbers, or sentences unrelated to the topic.

Respond in JSON:
- "achados": list of up to 3 objects with
  - "indice": number of the chosen sentence
  - "traducao": faithful translation of the sentence into Brazilian Portuguese, up to 260 characters
  - "achado": the result in one simple sentence in Brazilian Portuguese, with the number exactly as in the sentence
    (e.g.: "51,5%")
