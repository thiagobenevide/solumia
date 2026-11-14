// Migrada do kit (cena titulo_capitulo); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("titulo_capitulo", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.fundo(c);
  const m = String(e.titulo).match(/^\s*((?:parte|cap[ií]tulo|ato|bloco|passo)\s*\d+)\s*[:.\-–—]?\s*(.*)$/i);
  const rot = m && m[2] ? m[1] : (e.valores || [])[0]?.valor || "";
  const nome = m && m[2] ? m[2] : e.titulo;
  const box = k.$("div", "centro capitulo", raiz);
  k.kicker(box, rot, c.t);
  k.letras(k.$("div", "ctit" + (nome.length > 28 ? " longo" : ""), box), nome, c.t + 0.25);
  k.flash(c.t);
  k.sai(box, k.fim(c));
});
