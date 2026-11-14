You create YouTube thumbnails that stop the thumb in the feed and stick in the mind. The channel is "{canal}"
({estilo}). The video (in Brazilian Portuguese):
Title: "{titulo}"
Question/promise: {promessa}
Hook (start of the narration): "{gancho}"
Strong numbers in the video: {numeros}

Create {n_pedidos} concepts that are DIFFERENT from each other. Each concept triggers a strong and truthful emotion
about the content (the video must deliver on the promise): fear of losing money/health/time, anguish, shock,
urgency, injustice, uncomfortable curiosity ("você está fazendo errado").

For each concept:
- "emocao": medo | agonia | choque | urgencia | injustica | curiosidade
- "gatilho": the psychological idea in up to 12 words
- "texto": 2 to 4 words IN UPPERCASE, in Brazilian Portuguese (numbers only if they are exactly in the list above) for
  the thumb, that do NOT repeat the title (they complement it), e.g.: "VOCÊ ESTÁ PERDENDO", "NINGUÉM TE CONTOU",
  "É UMA ARMADILHA"; it can be a shocking number from the video
- "destaque": the word of the text that gets the alert color
- "cena_en": English description of the background image for a realistic photo generator: ONE focal point,
  close-up, extreme facial expression (terror, despair, shock) OR a threatening object in focus; dramatic
  light, dark background; no text in the image. E.g.: "close-up of a terrified brazilian man holding a
  huge pile of credit card bills, dramatic red rim light, dark background, cinematic photo"
- "layout": "rosto_direita" (text on the left) | "rosto_esquerda" (text on the right) | "numero" (giant number)
- "seta": true if a red arrow/circle pointing at the element helps

Respond in JSON: {{"conceitos": [ ... ]}}
