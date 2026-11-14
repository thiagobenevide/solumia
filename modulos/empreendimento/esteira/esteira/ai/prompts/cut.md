You edit the narration of a YouTube video (in Brazilian Portuguese). The narrator recorded it reading a script, but
sometimes improves the text on the spot, adds a comment, makes a mistake, repeats (retake) or talks to the crew. The
final edit must sound like one continuous, natural speech, with no repetitions or behind-the-scenes talk, keeping the
additions that improve the video.

Context (what comes before and after in the edit):
BEFORE: "{antes}"
AFTER: "{depois}"
Script sentences in this region: {roteiro}

Segment in doubt (automatic transcription, may have recognition errors): "{trecho}"
Provisional classification: {tipo} ({motivo}).

Decide whether the segment STAYS or GOES:
- STAYS: it completes the sentence in BEFORE or AFTER; it is an addition/comment that makes sense to the viewer;
  it is the narrator's version of a script sentence that was not read as written.
- GOES: behind-the-scenes talk ("vamos de novo", "droga", "eita"); an abandoned sentence start; a loose word
  with no meaning; it repeats what is already in BEFORE or AFTER; speech that would leave the sentence broken.
- A complete sentence that continues the subject of BEFORE is an addition: it STAYS, even outside the script. When the
  classification is "reformulada", the segment is the narrator's reading of that sentence: it only GOES if the same
  idea is already said in BEFORE or AFTER, never because it looks incomplete or badly transcribed (the transcription
  makes mistakes, the audio does not).
- The narrator often repeats the sentence (whole or just its final part) to fix a word or the intonation:
  the EARLIER version goes and the last one stays, even if the earlier one looks complete. If the segment starts with
  the same words as AFTER, or ends in "...", it is an abandoned attempt: it GOES.

Real examples (from this narrator):
- BEFORE "...a renda vai embora." · segment "Resumindo, 81..." · AFTER "Resumindo. 81% de pessoas endividadas..."
  → GOES (abandoned attempt: ends in "..." and is restarted in AFTER).
- segment "Ou seja, os dados não surgiram com a..." · AFTER "Ou seja, os dados não sugeriram que..." → GOES.
- segment "Mais um número." between two takes → GOES (behind-the-scenes self-talk).
- segment "Tradução para o Brasil." after citing a foreign study → STAYS (a comment useful to the viewer).
- BEFORE "...o parcelado do cartão perto dos 200%." · segment "O consignado estava em uma fração disso." → STAYS.
- BEFORE "e quase ninguém" · segment "segue. Entretanto, tem um estudo que diz..." → STAYS (completes the sentence
  and brings the turn).
- segment "tá?" or "né?" stuck to the end of a read sentence → GOES, unless the BEFORE sentence would be cut off
  without it.

Respond in JSON: {{"manter": true|false, "motivo": "up to 12 words", "confianca": 0.0-1.0}}
