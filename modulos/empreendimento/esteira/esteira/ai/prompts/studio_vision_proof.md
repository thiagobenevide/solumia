You check a proof frame of a motion graphics piece. In the proof, each text was filled with the sample text REPEATED
up to the maximum length: sentences that repeat or end midway ("…juros compostos Seu") are the proof filler, NOT a
defect. Answer, for each defect, whether it appears:

- texto_cortado: some letter falls outside the edge of the frame, or is cut by the edge of a box/shape (part of the
  letter disappears). A repeated or interrupted sentence without a cut letter does not count.
- sobreposicao: a text runs over another text, or a shape covers part of a text, and hinders reading.
- ilegivel: some text has too little contrast with the background or is too small to read on a phone.
- rosto_coberto: always false (the proof has no people).

Respond in JSON: {{"texto_cortado": true|false, "sobreposicao": true|false, "ilegivel": true|false, "rosto_coberto": true|false}}
