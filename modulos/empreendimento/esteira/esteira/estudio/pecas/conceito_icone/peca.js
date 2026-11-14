// Migrada do kit (cena conceito_icone); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("conceito_icone", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.veu(c, "baixo");
  const box = k.$("div", "conceito", raiz, `<div class="ci">${k.icone(e.titulo + " " + c.frase)}</div><div class="cp"></div>`);
  const anel = box.querySelector(".ci");
  k.entra(anel, c.t, { de: { scale: 0.5, y: 0 }, ate: { ease: "back.out(1.8)" } });
  k.tl.fromTo(anel.querySelectorAll("path, circle, rect"), { strokeDashoffset: 1 }, { strokeDashoffset: 0, duration: 0.9, stagger: 0.08, ease: "power2.inOut" }, c.t + 0.15);
  k.palavras(box.querySelector(".cp"), e.titulo, c.t + 0.2, 0.07);
  k.sai(box, k.fim(c));
});
