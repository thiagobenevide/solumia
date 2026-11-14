// Chamada em portal 2,5D: cartão chega do fundo por anéis que pulsam; botão e setas chamam a ação.
ESTUDIO.peca("chamada_portal_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");
  const t0 = c.batidas.acao != null ? c.batidas.acao : c.t + 0.2;
  const resto = Math.max(1, c.ate - t0 - 1.0);
  const cena = k.$("div", "cp-cena", box);
  const palco = k.$("div", "cp-palco", cena);

  if (b.fundo === "aneis") {
    for (let i = 0; i < 4; i++) {
      const r = k.$("div", "cp-anel", palco);
      k.tl.set(r, { z: -(10 + i * 14) * U }, 0);
      k.tl.fromTo(r, { scale: 0.5, opacity: 0 }, { scale: 1, opacity: 0.55 - i * 0.1, duration: 0.7, ease: k.SUAVE }, t0 + i * 0.08);
      k.tl.fromTo(r, { scale: 1 }, { scale: 1.35, opacity: 0, duration: 1.5, ease: "none", repeat: 2 }, t0 + 0.9 + i * 0.35);
    }
  } else if (b.fundo === "grade") {
    const g = k.$("div", "cp-grade", palco);
    k.tl.set(g, { z: -30 * U, rotationX: 55 }, 0);
    k.tl.fromTo(g, { opacity: 0 }, { opacity: 0.7, duration: 0.8, ease: k.SUAVE }, t0);
    k.tl.fromTo(g, { backgroundPositionY: 0 }, { backgroundPositionY: 12 * U, duration: resto + 1, ease: "none" }, t0);
  }

  const card = k.$("div", "cp-cartao", palco);
  if (e.destino) k.$("div", "cp-destino", card, k.esc(e.destino));
  const acao = k.$("div", "cp-acao", card);
  k.palavras(acao, e.acao, t0 + 0.5, 0.08);
  let tf = t0 + 0.5 + 0.08 * String(e.acao).split(/\s+/).length + 0.3;
  if (e.detalhe) {
    k.palavras(k.$("div", "cp-detalhe", card), e.detalhe, tf, 0.05);
    tf += 0.5;
  }
  let btn = null;
  if (e.botao) {
    btn = k.$("div", "cp-botao", card, `<span>${k.esc(e.botao)}</span><i class="cp-seta">›</i><i class="cp-seta cp-s2">›</i>`);
    k.tl.fromTo(btn, { opacity: 0, y: 3 * U, scale: 0.9 }, { opacity: 1, y: 0, scale: 1, duration: 0.5, ease: k.SUAVE }, tf);
    k.tl.fromTo(btn, { scale: 1 }, { scale: 1.06, duration: 0.45, ease: "sine.inOut", yoyo: true, repeat: 5 }, tf + 0.6);
    k.tl.fromTo(btn.querySelectorAll(".cp-seta"), { x: -1.2 * U, opacity: 0.3 }, { x: 1.2 * U, opacity: 1, duration: 0.5, ease: "none", stagger: 0.12, repeat: 5, yoyo: true }, tf + 0.3);
  }

  const giro = b.giro === "virada" ? -65 : -22;
  k.tl.fromTo(palco, { z: -70 * U, rotationY: giro, rotationX: 14, opacity: 0 },
    { z: 0, rotationY: -9, rotationX: 4, opacity: 1, duration: 1.0, ease: k.SUAVE }, t0);
  k.tl.to(palco, { rotationY: 8, rotationX: 1, duration: resto, ease: "sine.inOut" }, t0 + 1.0);
});
