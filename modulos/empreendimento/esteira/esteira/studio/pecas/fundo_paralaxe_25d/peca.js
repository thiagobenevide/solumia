// Fundo em paralaxe: três camadas a profundidades diferentes, movimento lento em vai-e-vem (sem emenda). Sem texto.
ESTUDIO.peca("fundo_paralaxe_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const textura = b.textura || "particulas";
  const vel = { lento: 1.5, normal: 1.0 }[b.movimento] || 1.5;
  // o tema não aparece na tela: só muda a semente da disposição das manchas e pontos
  const sem = [...String(e.tema || "")].reduce((a, ch) => a + ch.charCodeAt(0), 0) % 50;
  if (c.takeover) k.fundo(c);
  const dur = Math.max(1, c.ate - c.t);
  // repete em vai-e-vem; número par de trechos para fechar o ciclo
  const reps = (d) => { let n = Math.ceil(dur / d); if ((n + 1) % 2) n++; return Math.max(1, n); };
  const bob = (el, vars, d, t0) =>
    k.tl.to(el, { ...vars, duration: d, ease: "sine.inOut", repeat: reps(d), yoyo: true }, t0);

  const cena = k.$("div", "fp-cena", box);
  const palco = k.$("div", "fp-palco", cena);
  k.tl.fromTo(cena, { opacity: 0 }, { opacity: 1, duration: 0.8, ease: k.SUAVE }, c.t);

  const prof = [
    { z: -26, esc: 1.0, mov: 2.2, n: 1 },
    { z: -12, esc: 0.8, mov: 1.6, n: 2 },
    { z: 0, esc: 0.6, mov: 1.0, n: 3 },
  ];
  const nPorCamada = { particulas: 16, grao: 55, gradiente: 0 }[textura] ?? 16;
  const tam = { particulas: [0.5, 1.5], grao: [0.18, 0.4], gradiente: [0, 0] }[textura] || [0.5, 1.5];

  prof.forEach((p, li) => {
    const cam = k.$("div", "fp-camada fp-c" + p.n, palco);
    k.tl.set(cam, { z: p.z * U }, 0);
    // manchas de gradiente que respiram
    const nb = li === 2 ? 1 : 2;
    for (let j = 0; j < nb; j++) {
      const s = li * 7 + j * 3 + sem;
      const bl = k.$("div", "fp-mancha fp-m" + ((li + j) % 3), cam);
      const tb = (28 + 22 * k.rnd(s + 1)) * (textura === "gradiente" ? 1.3 : 1);
      bl.style.width = bl.style.height = tb * U + "px";
      bl.style.left = 10 + 60 * k.rnd(s + 2) + "%";
      bl.style.top = 10 + 60 * k.rnd(s + 3) + "%";
      bob(bl, { scale: 1.18, x: (k.rnd(s + 4) - 0.5) * 10 * U * p.mov, y: (k.rnd(s + 5) - 0.5) * 8 * U * p.mov, opacity: 0.55 }, (7 + 4 * k.rnd(s + 6)) * vel, c.t);
    }
    // partículas ou grão
    for (let i = 0; i < nPorCamada; i++) {
      const s = 100 + li * 200 + i + sem;
      const d = k.$("div", "fp-ponto fp-p" + (i % 3), cam);
      const t = (tam[0] + (tam[1] - tam[0]) * k.rnd(s + 1)) * p.esc * (li === 2 ? 1.3 : 1);
      d.style.width = d.style.height = t * U + "px";
      d.style.left = k.rnd(s + 2) * 100 + "%";
      d.style.top = k.rnd(s + 3) * 100 + "%";
      d.style.opacity = 0.25 + 0.35 * k.rnd(s + 4);
      const dd = (6 + 6 * k.rnd(s + 5)) * vel;
      bob(d, { y: -(3 + 6 * k.rnd(s + 6)) * U * p.mov, x: (k.rnd(s + 7) - 0.5) * 4 * U * p.mov, opacity: 0.08 }, dd, c.t);
    }
    // deriva lateral da camada: paralaxe
    bob(cam, { x: (li % 2 ? -1 : 1) * (1.5 + li) * U }, 10 * vel, c.t);
  });

  // a câmera respira
  bob(palco, { rotationY: 2.5, rotationX: -1.5 }, 9 * vel, c.t);
  k.$("div", "fp-veu", box);
});
