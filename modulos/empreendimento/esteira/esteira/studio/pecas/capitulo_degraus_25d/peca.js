// Capítulo em degraus: número espesso (camadas em Z) gira até a câmera, título ao lado e trilha de etapas com a atual acesa.
ESTUDIO.peca("capitulo_degraus_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const g = b.giro === "esquerda" ? -1 : 1;
  const forte = b.profundidade === "forte";
  const camadas = forte ? 9 : 6;
  const passo = (forte ? 1.4 : 1.0) * U;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");

  const cena = k.$("div", "cd-cena", box);
  const palco = k.$("div", "cd-palco", cena);
  const linha = k.$("div", "cd-linha", palco);

  // Número em camadas
  const numWrap = k.$("div", "cd-num", linha);
  const txt = k.esc(e.numero);
  for (let i = camadas - 1; i >= 0; i--) {
    const ly = k.$("div", "cd-ly" + (i === 0 ? " cd-fr" : ""), numWrap, txt);
    if (i > 0) {
      const mix = Math.round(30 + 50 * (i / camadas));
      ly.style.color = `color-mix(in srgb, var(--destaque) ${100 - mix}%, var(--fundo))`;
    }
    k.tl.fromTo(ly, { z: -i * passo * 6 }, { z: -i * passo, duration: 1.1, ease: k.SUAVE }, c.t);
  }

  // Texto
  const col = k.$("div", "cd-col", linha);
  k.kicker(col, "Capítulo " + e.numero, c.t + 0.1);
  const tt = c.batidas.titulo != null ? c.batidas.titulo : c.t + 0.5;
  const tit = k.$("div", "cd-titulo", col);
  k.palavras(tit, e.titulo, tt, 0.07);
  k.traco(k.$("div", "traco", col), tt + 0.4, 0.7);
  if (e.subtitulo) {
    const sub = k.$("div", "cd-sub", col);
    k.entra(sub, tt + 0.5, { de: { y: 2 * U } });
    sub.innerHTML = k.rico(k.esc(e.subtitulo));
  }

  // Trilha de etapas
  const et = Array.isArray(e.etapas) ? e.etapas : [];
  if (et.length) {
    const trilha = k.$("div", "cd-trilha", palco);
    const atual = parseInt(e.numero, 10) - 1;
    et.forEach((t, i) => {
      const p = k.$("div", "cd-et" + (i === atual ? " cd-on" : ""), trilha, k.esc(t));
      k.tl.fromTo(p, { y: 5 * U, z: -20 * U, opacity: 0 }, { y: 0, z: 0, opacity: 1, duration: 0.6, ease: k.SUAVE }, tt + 0.6 + i * 0.12);
    });
  }

  // Câmera: palco gira até a frente e depois "respira"
  const dur = Math.max(1.2, c.ate - c.t);
  k.tl.fromTo(palco, { rotationY: -g * 26, rotationX: 9, z: -50 * U, opacity: 0 },
    { rotationY: g * 2, rotationX: 0, z: 0, opacity: 1, duration: 1.2, ease: k.SUAVE }, c.t);
  k.tl.to(palco, { rotationY: g * 7, rotationX: -2, duration: Math.max(0.5, dur - 1.2), ease: "none" }, c.t + 1.2);
});
