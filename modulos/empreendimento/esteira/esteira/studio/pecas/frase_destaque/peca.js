// Migrada do kit (cena frase_destaque); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("frase_destaque", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.veu(c, "baixo");
  const box = k.$("div", "frase", raiz, '<span class="barra"></span>');
  k.traco(box.querySelector(".barra"), c.t, 0.6);
  k.palavras(box, e.titulo, c.t + 0.1, Math.min(0.12, (c.ate - c.t) / Math.max(String(e.titulo).split(/\s+/).length * 3, 1)));
  k.sai(box, k.fim(c));
});
