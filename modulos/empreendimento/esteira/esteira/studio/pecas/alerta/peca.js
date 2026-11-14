// Migrada do kit (cena alerta); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("alerta", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.veu(c, "baixo");
  const dica = /dica|truque|segredo|macete/i.test(c.frase + " " + e.titulo);
  const box = k.$("div", "alerta" + (dica ? " dica" : ""), raiz,
    `<div class="ai"><i class="pulso"></i>${k.icone(dica ? "lampada" : "cuidado")}</div><div class="at"><div class="ak">${dica ? "Dica" : "Atenção"}</div><div class="ap"></div></div>`);
  k.entra(box, c.t, { de: { x: -5 * k.U, y: 0 } });
  k.tl.fromTo(box.querySelectorAll(".ai path, .ai circle, .ai rect"), { strokeDashoffset: 1 }, { strokeDashoffset: 0, duration: 0.7, stagger: 0.08, ease: "power2.inOut" }, c.t + 0.1);
  if (!k.PROIB.has("flash")) k.tl.fromTo(box.querySelector(".pulso"), { scale: 1, opacity: 0.7 }, { scale: 1.9, opacity: 0, duration: 0.8, repeat: 2, ease: "power2.out" }, c.t + 0.3);
  k.palavras(box.querySelector(".ap"), e.titulo, c.t + 0.2, 0.06);
  k.sai(box, k.fim(c));
});
