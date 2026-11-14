// Pergunta em planos de profundidade: cartão chega do fundo, palavras entram uma a uma, "?" ou anéis ficam atrás.
ESTUDIO.peca("pergunta_planos_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");

  const dur = Math.max(1.5, c.ate - c.t);
  const cena = k.$("div", "pq-cena", box);
  const palco = k.$("div", "pq-palco", cena);
  const tp = c.batidas.pergunta != null ? c.batidas.pergunta : c.t + 0.35;

  // planos de trás
  let marca = null;
  const aneis = [];
  if (b.fundo === "aneis") {
    for (let i = 0; i < 3; i++) {
      const wrap = k.$("div", "pq-fio", palco);
      const an = k.$("div", "pq-anel", wrap);
      an.style.width = an.style.height = `calc(${34 + i * 18} * var(--U))`;
      aneis.push({ wrap, an, z: -(12 + i * 14) * U });
    }
    aneis.forEach((a, i) => {
      k.tl.set(a.wrap, { z: a.z }, c.t);
      k.tl.fromTo(a.an, { scale: 0.5, opacity: 0 }, { scale: 1, opacity: 1, duration: 0.8, ease: k.SUAVE }, c.t + 0.1 + i * 0.12);
    });
  } else {
    const fio = k.$("div", "pq-fio", palco);
    marca = k.$("div", "pq-marca", fio, "?");
    k.tl.set(fio, { z: -20 * U }, c.t);
    k.tl.fromTo(marca, { scale: 0.6, opacity: 0, rotation: -8 }, { scale: 1, opacity: 1, rotation: 0, duration: 0.9, ease: k.SUAVE }, c.t + 0.1);
  }

  // cartão com a pergunta
  const fioC = k.$("div", "pq-fio", palco);
  const card = k.$("div", "pq-card", fioC);
  if (e.apoio) k.kicker(card, e.apoio, c.t + 0.2);
  const q = k.$("div", "pq-q", card);
  k.tl.fromTo(card, { z: -40 * U, rotationY: 26, rotationX: 8, opacity: 0 },
    { z: 0, rotationY: 0, rotationX: 0, opacity: 1, duration: 0.85, ease: k.SUAVE }, c.t);
  k.palavras(q, e.pergunta, tp, 0.09);

  // a interrogação pulsa quando a pergunta fecha
  const nPal = String(e.pergunta || "").split(/\s+/).length;
  const tf = tp + 0.09 * nPal + 0.3;
  const alvo = marca || (aneis[0] && aneis[0].an);
  if (alvo) k.tl.fromTo(alvo, { scale: 1 }, { scale: 1.05, duration: 0.5, yoyo: true, repeat: 1, ease: "sine.inOut" }, tf);

  // câmera respira até o fim
  if (b.camera === "aproxima") {
    k.tl.fromTo(palco, { z: -6 * U, rotationY: -5, rotationX: 2 }, { z: 6 * U, rotationY: 3, rotationX: -1, duration: dur, ease: "none" }, c.t);
  } else {
    k.tl.fromTo(palco, { rotationY: -8, rotationX: 3 }, { rotationY: 8, rotationX: -3, duration: dur, ease: "none" }, c.t);
  }
});
