// Placa de alerta 2,5D: a placa cai em perspectiva e quica, faixas zebradas deslizam em camadas e o texto treme uma vez.
ESTUDIO.peca("placa_alerta_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const perigo = b.nivel === "perigo";
  box.classList.add(perigo ? "pa-perigo" : "pa-atencao");
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");

  const t0 = c.t;
  const dur = Math.max(1.5, c.ate - c.t);
  const cena = k.$("div", "pa-cena", box);
  const palco = k.$("div", "pa-palco", cena);

  // faixas zebradas em camadas: [posição vertical, profundidade, sentido, opacidade, classe]
  const faixas = [
    ["pa-f1", -34, 1, 0.5],
    ["pa-f2", -34, -1, 0.5],
    ["pa-f3", 14, -1, 1],
    ["pa-f4", 14, 1, 1],
  ];
  faixas.forEach(([cls, z, dir, op], i) => {
    const f = k.$("div", "pa-faixa " + cls, palco);
    const fx = k.$("div", "pa-fx", f);
    k.tl.set(f, { z: z * U });
    k.tl.fromTo(f, { xPercent: dir * -40, opacity: 0 }, { xPercent: 0, opacity: op, duration: 0.7, ease: k.SUAVE }, t0 + 0.05 * i);
    k.tl.fromTo(fx, { x: -dir * 12 * U }, { x: dir * 12 * U, duration: dur, ease: "none" }, t0);
  });

  // placa
  const placa = k.$("div", "pa-placa", palco);
  const topo = k.$("div", "pa-topo", placa);
  const ico = k.$("div", "pa-ico", topo, "<span>!</span>");
  const tit = k.$("div", "pa-titulo", topo, k.esc(e.titulo || ""));
  let tx = null;
  if (e.texto) tx = k.$("div", "pa-texto", placa, k.rico(e.texto));

  const tq = t0 + 0.1;
  const queda = 1.1;
  k.tl.fromTo(placa, { y: -60 * U, z: 60 * U, rotationX: -55, opacity: 0 },
    { y: 0, z: 0, rotationX: 0, opacity: 1, duration: queda, ease: "bounce.out" }, tq);
  k.tl.fromTo(placa, { opacity: 0 }, { opacity: 1, duration: 0.15, ease: "none" }, tq);
  k.tl.fromTo(ico, { scale: 0.6 }, { scale: 1, duration: 0.4, ease: "back.out(3)" }, tq + 0.4);
  if (tx) k.tl.fromTo(tx, { opacity: 0 }, { opacity: 1, duration: 0.25, ease: "none" }, tq + 0.35);

  // primeiro impacto da placa (~36% da queda): clarão curto
  const ti = tq + queda * 0.36;
  if (!k.PROIB.has("flash")) k.flash(ti);

  // o texto treme uma vez, logo depois de a placa assentar
  const alvo = tx || tit;
  const amp = (perigo ? 1.3 : 0.7) * U;
  const passos = perigo ? [-1, 1, -0.9, 0.8, -0.5, 0.3, 0] : [-1, 1, -0.6, 0.4, 0];
  let tt = tq + queda * 0.9;
  passos.forEach((p) => {
    k.tl.to(alvo, { x: p * amp, duration: 0.05, ease: "none" }, tt);
    tt += 0.05;
  });
  if (tx) {
    let t2 = tq + queda * 0.9;
    passos.forEach((p) => {
      k.tl.to(tit, { x: p * amp * 0.6, duration: 0.05, ease: "none" }, t2);
      t2 += 0.05;
    });
  }

  // a câmera respira até o fim
  k.tl.fromTo(palco, { rotationY: -5, rotationX: 2 }, { rotationY: 5, rotationX: -1, duration: dur, ease: "none" }, t0);
});
