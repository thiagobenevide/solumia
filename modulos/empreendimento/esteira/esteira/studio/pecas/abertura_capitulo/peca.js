// Abertura de capítulo: número desenhado a traço, título ao lado, linha que varre a tela e barra de progresso.
ESTUDIO.peca("abertura_capitulo", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const D = {
    0: "M30 5 C10 5 8 25 8 50 C8 75 10 95 30 95 C50 95 52 75 52 50 C52 25 50 5 30 5Z",
    1: "M18 25 L34 8 L34 95",
    2: "M10 28 C10 -2 52 -2 52 28 C52 55 10 75 8 95 L54 95",
    3: "M10 12 C30 0 52 10 48 30 C46 45 30 48 24 48 C42 48 54 55 52 74 C48 100 18 98 8 84",
    4: "M42 95 L42 5 L6 65 L56 65",
    5: "M50 6 L16 6 L12 48 C30 38 54 46 52 70 C50 98 20 98 8 84",
    6: "M48 12 C30 0 8 15 8 60 C8 100 52 100 52 68 C52 42 18 40 9 62",
    7: "M8 8 L54 8 L26 95",
    8: "M30 48 C8 44 8 6 30 6 C52 6 52 44 30 48 C6 54 6 96 30 96 C54 96 54 54 30 48Z",
    9: "M52 40 C44 58 10 58 8 32 C6 4 52 -2 52 40 C52 80 40 98 14 90",
  };
  const t0 = c.batidas.numero != null ? c.batidas.numero : c.t + 0.1;
  const tri = b.camera === "atravessa";
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");
  if (tri) box.classList.add("ac-3d");
  if (b.progresso === "pontos") box.classList.add("ac-pontos");

  let digs = String(e.numero == null ? "" : e.numero).replace(/\D/g, "").slice(0, 2);
  if (!digs) digs = "1";
  if (digs.length < 2) digs = "0" + digs;
  const atual = parseInt(digs, 10) || 1;
  const total = Math.min(12, parseInt(String(e.total || "").replace(/\D/g, ""), 10) || 0);

  const corpo = k.$("div", "ac-corpo", box);
  k.kicker(corpo, "capítulo", c.t);
  const linhaN = k.$("div", "ac-linhan", corpo);
  const num = k.$("div", "ac-num", linhaN);
  const paths = [];
  digs.split("").forEach((d) => {
    const s = k.$("div", "ac-dig", num, `<svg viewBox="-6 -10 72 120"><path pathLength="1" d="${D[d]}"/></svg>`);
    paths.push(s.querySelector("path"));
  });
  paths.forEach((p, i) => {
    const ti = t0 + i * 0.35;
    k.tl.fromTo(p, { opacity: 0 }, { opacity: 1, duration: 0.05 }, ti);
    k.tl.fromTo(p, { strokeDashoffset: 1 }, { strokeDashoffset: 0, duration: 0.8, ease: "power2.inOut" }, ti);
  });
  const tit = k.$("div", "ac-titulo", linhaN);
  k.palavras(tit, e.titulo || "", t0 + 0.5, 0.07);

  // linha que varre a tela
  const lin = k.$("div", "ac-linha", box);
  const fio = k.$("div", "ac-fio", lin);
  const cab = k.$("div", "ac-cab", lin);
  k.tl.fromTo(fio, { scaleX: 0 }, { scaleX: 1, duration: 0.9, ease: k.SUAVE }, t0 + 0.2);
  k.tl.fromTo(cab, { x: -14 * U }, { x: k.W, duration: 0.9, ease: k.SUAVE }, t0 + 0.2);
  k.tl.to(cab, { opacity: 0, duration: 0.2 }, t0 + 1.0);

  // progresso dos capítulos
  if (total > 0) {
    const bar = k.$("div", "ac-barra", box);
    for (let i = 1; i <= total; i++) {
      const s = k.$("div", "ac-seg" + (i === atual ? " ac-on" : i < atual ? " ac-feito" : ""), bar);
      const ts = t0 + 0.6 + i * 0.05;
      k.tl.fromTo(s, { opacity: 0, y: 2 * U }, { opacity: 1, y: 0, duration: 0.35, ease: k.SUAVE }, ts);
      if (i === atual) {
        const f = k.$("div", "ac-fill", s);
        k.tl.fromTo(f, { scaleX: 0 }, { scaleX: 1, duration: 0.6, ease: k.SUAVE }, t0 + 1.0);
      }
    }
  }

  if (tri) {
    k.tl.fromTo(corpo, { z: -60 * U, rotationY: 24, rotationX: -6, opacity: 0 },
      { z: 0, rotationY: 0, rotationX: 0, opacity: 1, duration: 1.2, ease: k.SUAVE }, c.t);
    k.tl.fromTo(num, { z: 40 * U }, { z: 8 * U, duration: 1.2, ease: k.SUAVE }, c.t);
    const fimT = Math.max(c.ate - 0.4, t0 + 1.4);
    k.tl.to(corpo, { rotationY: -6, rotationX: 2, z: 6 * U, duration: Math.max(0.5, fimT - (c.t + 1.2)), ease: "none" }, c.t + 1.2);
  } else {
    k.entra(corpo, c.t, { de: { y: 2 * U } });
  }
});
