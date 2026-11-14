// Placa de alerta 2,5D: cai em perspectiva, quica, faixas zebradas em camadas e texto que treme uma vez.
ESTUDIO.peca("placa_perigo_zebra_25d", (k, c, box) => {
  const { U, tl } = k;
  const e = c.encaixes, b = c.botoes;
  const perigo = b.nivel !== "atencao";
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");
  box.classList.add(perigo ? "pz-perigo" : "pz-atencao");
  const dur = Math.max(1, c.ate - c.t);

  const cena = k.$("div", "pz-cena", box);
  const palco = k.$("div", "pz-palco", cena);

  // faixas zebradas em quatro camadas (duas ao fundo, duas à frente), sentidos opostos
  const faixas = [
    { cls: "pz-f3", z: -30, dir: 1, vel: 7, op: 0.35, rz: -3 },
    { cls: "pz-f4", z: -30, dir: -1, vel: 7, op: 0.35, rz: 3 },
    { cls: "pz-f1", z: 8, dir: -1, vel: 16, op: 0.95, rz: 0 },
    { cls: "pz-f2", z: 8, dir: 1, vel: 16, op: 0.95, rz: 0 },
  ];
  faixas.forEach((f, i) => {
    const el = k.$("div", "pz-faixa " + f.cls, palco);
    tl.set(el, { z: f.z * U, rotationZ: f.rz });
    tl.fromTo(el, { opacity: 0, x: -f.dir * 30 * U }, { opacity: f.op, x: 0, duration: 0.6, ease: k.SUAVE }, c.t + 0.05 * i);
    tl.fromTo(el, { backgroundPositionX: "0px" },
      { backgroundPositionX: (f.dir * f.vel * U * dur) + "px", duration: dur, ease: "none" }, c.t);
  });

  // placa
  const placa = k.$("div", "pz-placa", palco);
  const cab = k.$("div", "pz-cab", placa);
  k.$("div", "pz-sinal", cab, "!");
  k.$("div", "pz-nivel", cab, perigo ? "PERIGO" : "ATENÇÃO");
  const corpo = k.$("div", "pz-corpo", placa);
  k.$("div", "pz-titulo", corpo, k.esc(e.titulo));
  if (e.texto) k.$("div", "pz-texto", corpo, k.rico(e.texto));

  // queda, impacto e quique
  const ti = c.batidas.titulo != null ? Math.max(c.batidas.titulo, c.t + 0.55) : c.t + 0.6;
  const q = ti - 0.5;
  tl.fromTo(placa, { opacity: 0 }, { opacity: 1, duration: 0.12, ease: "none" }, q);
  tl.fromTo(placa, { y: -80 * U, rotationX: -55, z: -40 * U },
    { y: 0, rotationX: 0, z: 0, duration: 0.5, ease: "power2.in" }, q);
  tl.to(placa, { y: -8 * U, rotationX: 7, duration: 0.2, ease: "power2.out" }, ti);
  tl.to(placa, { y: 0, rotationX: 0, duration: 0.2, ease: "power2.in" }, ti + 0.2);
  tl.to(placa, { y: -2.5 * U, duration: 0.1, ease: "power2.out" }, ti + 0.4);
  tl.to(placa, { y: 0, duration: 0.1, ease: "power2.in" }, ti + 0.5);

  // o texto treme uma vez no impacto
  const a = (perigo ? 1.4 : 0.8) * U;
  [-a, a, -a * 0.6, a * 0.35, 0].forEach((x, i) => {
    tl.to(corpo, { x, duration: 0.05, ease: "none" }, ti + 0.02 + i * 0.05);
  });
  if (perigo && !k.PROIB.has("flash")) k.flash(ti);

  // a câmera respira até o fim
  tl.fromTo(palco, { rotationY: -10, rotationX: 5 },
    { rotationY: 7, rotationX: -2, duration: dur, ease: "none" }, c.t);
});
