// Migrada do kit (cena pergunta_destaque); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("pergunta_destaque", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.fundo(c);
  const box = k.$("div", "centro pergunta", raiz, '<div class="qm">?</div><div class="qt"></div>');
  k.tl.fromTo(box.querySelector(".qm"), { opacity: 0, scale: 1.3, rotation: -8 }, { opacity: 1, scale: 1, rotation: 0, duration: 1.2, ease: k.SUAVE }, c.t);
  k.palavras(box.querySelector(".qt"), e.titulo.replace(/\?*$/, "?"), c.t + 0.15, Math.min(0.1, (c.ate - c.t) / 20));
  k.sai(box, k.fim(c));
});
