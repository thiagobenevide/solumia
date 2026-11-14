// Migrada do kit (cena carimbo); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("carimbo", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.veu(c, "baixo");
  const box = k.$("div", "carimbo", raiz, `<div class="onda"></div><div class="cb">${k.rico(e.titulo)}</div>`);
  const cb = box.querySelector(".cb");
  k.tl.fromTo(cb, { opacity: 0, scale: 2.4, rotation: -16 }, { opacity: 1, scale: 1, rotation: -7, duration: 0.26, ease: "power4.in" }, c.t);
  k.tl.fromTo(box.querySelector(".onda"), { scale: 0.6, opacity: 0.8 }, { scale: 1.7, opacity: 0, duration: 0.6, ease: "power2.out" }, c.t + 0.26);
  if (k.EF.zoom && !k.PROIB.has("shake")) k.tl.fromTo(k.midia, { scale: 1.02 }, { scale: 1, duration: 0.25, ease: "power2.out" }, c.t + 0.26);
  k.sai(box, k.fim(c));
});
