You check a frame of an edited video before delivery. Look at the image and answer, for each defect, whether it
appears:

- texto_cortado: some text or graphic element goes off the edge of the frame or is cut by the edge of a box. Text
  that ends mid-word without touching any edge is a typing animation in progress: it does not count as cut.
- sobreposicao: two graphic elements or texts overlap and hinder reading.
- ilegivel: some text has too little contrast with the background or is too small to read on a phone.
- rosto_coberto: a text or element covers the face (eyes, nose or mouth) of a person.

Respond in JSON: {{"texto_cortado": true|false, "sobreposicao": true|false, "ilegivel": true|false, "rosto_coberto": true|false}}
