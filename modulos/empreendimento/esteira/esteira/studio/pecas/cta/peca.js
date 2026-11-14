// Migrada do kit (cena cta); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("cta", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.veu(c, "baixo");
  const box = k.$("div", "cta", raiz, `<div class="anel"></div><div class="botao"><span>${k.rico(e.titulo)}</span><span class="seta">→</span></div>`);
  k.entra(box, c.t, { de: { scale: 0.7, y: 0 }, ate: { ease: "back.out(2)" } });
  k.tl.fromTo(box.querySelector(".anel"), { scale: 0.9, opacity: 0.8 }, { scale: 1.35, opacity: 0, duration: 0.9, repeat: 2, ease: "power2.out" }, c.t + 0.5);
  k.tl.to(box.querySelector(".seta"), { x: 1.2 * k.U, duration: 0.35, yoyo: true, repeat: 3, ease: "sine.inOut" }, c.t + 0.6);
  k.sai(box, k.fim(c));
});
