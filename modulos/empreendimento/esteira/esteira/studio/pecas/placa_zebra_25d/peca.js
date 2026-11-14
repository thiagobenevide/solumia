// Placa de aviso em 2,5D: cai em perspectiva, quica; faixas zebradas deslizam em camadas; o título treme uma vez.
ESTUDIO.peca("placa_zebra_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");
  const perigo = b.nivel !== "atencao";
  box.classList.add(perigo ? "pz-perigo" : "pz-atencao");
  const rotulo = perigo ? "PERIGO" : "ATENÇÃO";
  const total = Math.max(2, c.ate - c.t);
  const t0 = c.batidas.titulo != null ? c.batidas.titulo : c.t + 0.1;

  const cena = k.$("div", "pz-cena", box);
  const palco = k.$("div", "pz-palco", cena);

  // faixas zebradas em camadas: [classe, rotação, z, sentido, opacidade]
  const faixas = [
    ["pz-f1", -7, -30 * U, -1, 0.5],
    ["pz-f3", 5, -12 * U, 1, 0.7],
    ["pz-f2", 8, 18 * U, -1, 1],
  ];
  const per = 8.485 * U * 5;
  faixas.forEach(([cl, rot, z, dir, op], i) => {
    const f = k.$("div", "pz-faixa " + cl, palco, '<div class="pz-fx"></div>');
    k.tl.set(f, { rotation: rot, z });
    k.tl.fromTo(f, { opacity: 0, y: (i % 2 ? 1 : -1) * 10 * U }, { opacity: op, y: 0, duration: 0.6, ease: k.SUAVE }, c.t + 0.05 * i);
    k.tl.fromTo(f.firstChild, { x: -dir * per }, { x: dir * per, duration: total, ease: "none" }, c.t);
  });

  const placa = k.$("div", "pz-placa", palco);
  k.$("div", "pz-topo", placa, `<span class="pz-ex">!</span><span class="pz-nv">${rotulo}</span>`);
  const tit = k.$("div", "pz-tit", placa, k.esc(e.titulo));
  const dur = 0.95;
  k.tl.set(placa, { transformOrigin: "50% 0%" });
  k.tl.fromTo(placa, { y: -70 * U, rotationX: -65, z: 30 * U, opacity: 0 },
    { y: 0, rotationX: 0, z: 0, opacity: 1, duration: dur, ease: "bounce.out" }, t0);
  k.tl.to(placa, { opacity: 1, duration: 0.01 }, t0);

  // tremor único no primeiro impacto
  const ts = t0 + dur * 0.36;
  [-1.2, 1.2, -0.9, 0.9, -0.4, 0].forEach((v, i) => {
    k.tl.to(tit, { x: v * U, duration: 0.05, ease: "none" }, ts + i * 0.05);
  });

  if (e.texto) {
    const tx = k.$("div", "pz-tx", placa);
    k.palavras(tx, e.texto, t0 + 0.75, 0.05);
  }

  // câmera respira até o fim
  k.tl.fromTo(palco, { rotationY: -5, rotationX: 2 }, { rotationY: 5, rotationX: -2, duration: total, ease: "sine.inOut" }, c.t);
});
