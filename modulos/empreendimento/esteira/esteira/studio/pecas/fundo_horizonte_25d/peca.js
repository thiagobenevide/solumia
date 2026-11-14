// Fundo horizonte: piso em perspectiva que corre até o horizonte, pulsos de luz e partículas em profundidade. Sem texto.
ESTUDIO.peca("fundo_horizonte_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const dur = Math.max(1, c.ate - c.t);
  const vel = b.ritmo === "normal" ? 1.6 : 0.8;
  const pista = b.forma === "pista";
  // o assunto não aparece na tela: só muda a semente do aleatório determinístico
  const txt = String(e.assunto || "");
  let sem = 0;
  for (let i = 0; i < txt.length; i++) sem = (sem + txt.charCodeAt(i) * (i + 1)) % 97;
  if (pista) box.classList.add("fg-pista");
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");

  const cena = k.$("div", "fg-cena", box);
  const palco = k.$("div", "fg-palco", cena);
  k.$("div", "fg-brilho", palco);
  const chao = k.$("div", "fg-chao", palco);
  const g = (pista ? 14 : 10) * U;
  const alt = 120 * U;

  window.gsap.set(chao, { rotationX: 78, transformOrigin: "50% 0%", xPercent: -50 });

  // piso correndo na direção do espectador
  k.tl.fromTo(chao, { backgroundPosition: "0px 0px" },
    { backgroundPosition: "0px " + (vel * 10 * U * dur) + "px", duration: dur, ease: "none" }, c.t);

  // pulsos de luz que viajam pelas linhas do piso
  const cols = Math.floor(400 * U / g);
  for (let i = 0; i < 6; i++) {
    const col = 4 + Math.floor(k.rnd(i + 3 + sem) * (cols - 8));
    const p = k.$("div", "fg-pulso", chao);
    p.style.left = (col * g) + "px";
    const per = (3.6 + k.rnd(i + 11 + sem) * 1.8) / vel;
    let t0 = c.t + k.rnd(i + 21 + sem) * per;
    for (let n = 0; n < 8 && t0 + per <= c.ate; n++, t0 += per + k.rnd(i * 7 + n + sem) * 1.2) {
      k.tl.fromTo(p, { y: 0, opacity: 0 },
        { y: alt, opacity: 1, duration: per, ease: "sine.in" }, t0);
      k.tl.set(p, { opacity: 0 }, t0 + per);
    }
  }

  // partículas em profundidade
  for (let i = 0; i < 16; i++) {
    const d = k.$("div", "fg-ponto", palco);
    const x = (k.rnd(i + 40 + sem) - 0.5) * 150 * U;
    const y = (k.rnd(i + 60 + sem) - 0.55) * 80 * U;
    const z = (k.rnd(i + 80 + sem) - 0.6) * 100 * U;
    const s = 0.7 + k.rnd(i + 100 + sem) * 0.9;
    window.gsap.set(d, { x, y, z, scale: s });
    k.tl.fromTo(d, { y }, { y: y - 10 * U * vel, duration: dur, ease: "none" }, c.t);
    k.tl.fromTo(d, { opacity: 0 },
      { opacity: 0.35 + k.rnd(i + 120 + sem) * 0.45, duration: 1.2, ease: k.SUAVE }, c.t + k.rnd(i + 140 + sem) * 1.5);
  }

  // a câmera respira: o palco gira alguns graus até o fim
  k.tl.fromTo(palco, { rotationY: -4, rotationX: 1.5 },
    { rotationY: 4, rotationX: -1.5, duration: dur, ease: "sine.inOut" }, c.t);
  k.tl.fromTo(cena, { opacity: 0 }, { opacity: 1, duration: 0.9, ease: k.SUAVE }, c.t);
});
