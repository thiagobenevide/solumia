// Diagrama de convergência em card de vidro: ícones com brilho -> curvas -> ponto -> painel de trilhas com cursor de tempo.
ESTUDIO.peca("diagrama_convergencia_vidro", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const vel = { lenta: 1.4, normal: 1.0, rapida: 0.7 }[b.velocidade] || 1.0;
  const total = Math.max(2, c.ate - c.t);
  const f = Math.min(vel, total / 7.2);
  const T = (x) => c.t + x * f;

  if (c.takeover) k.fundo(c);
  const lat = b.layout !== "flutuante";
  if (lat) box.classList.add("dc-lat");

  const cena = k.$("div", "dc-cena", box);
  const card = k.$("div", "dc-card", cena);
  k.entra(cena, c.t, { de: { y: 3 * U } });

  // inclinação do card: entra girando e "respira" até o fim
  const base = lat ? -9 : -15;
  const rest = Math.max(1, c.ate - c.t - 1.2);
  k.tl.fromTo(card, { rotationY: base - 14, rotationX: 7, z: -10 * U },
    { rotationY: base, rotationX: 3, z: 0, duration: 1.2, ease: k.SUAVE }, c.t);
  k.tl.to(card, { rotationY: base + 5, rotationX: 1, duration: rest, ease: "sine.inOut" }, c.t + 1.2);

  // ---------- diagrama ----------
  const ents = (e.entradas || []).slice(0, 3);
  const n = ents.length;
  const xs = n >= 3 ? [18, 50, 82] : n === 2 ? [30, 70] : [50];
  const dia = k.$("div", "dc-dia", card);
  const paths = xs.map((x) => `<path class="dc-cv" pathLength="1" d="M${x} 31 C${x} 40 50 37 50 46"/>`).join("");
  k.$("div", "dc-svg", dia,
    `<svg viewBox="0 0 100 56" preserveAspectRatio="xMidYMid meet" aria-hidden="true">${paths}<path class="dc-cv dc-stem" pathLength="1" d="M50 46 L50 56"/></svg>`);
  const cvs = dia.querySelectorAll(".dc-cv");

  ents.forEach((txt, i) => {
    const t = T(0.5 + i * 0.35);
    const no = k.$("div", "dc-no", dia);
    no.style.left = (xs[i] - 16) + "%";
    const circ = k.$("div", "dc-c", no);
    k.$("div", "dc-halo", circ);
    k.$("div", "dc-ic", circ, k.icone(txt));
    k.$("div", "dc-rot", no, k.esc(txt));
    k.entra(no, t, { de: { y: 2 * U, scale: 0.8 } });
    k.tl.fromTo(circ.querySelector(".dc-halo"), { scale: 1, opacity: 0.8 },
      { scale: 1.55, opacity: 0, duration: 0.9 * f + 0.2, ease: "power1.out" }, t + 0.25);
  });

  // curvas convergem
  const tc = T(1.7);
  cvs.forEach((p, i) => {
    const stem = p.classList.contains("dc-stem");
    const t0 = stem ? T(2.5) : tc + i * 0.08;
    k.tl.fromTo(p, { strokeDashoffset: 1, opacity: 0.2 },
      { strokeDashoffset: 0, opacity: 1, duration: (stem ? 0.4 : 0.8) * f + 0.15, ease: k.SUAVE }, t0);
  });
  const ponto = k.$("div", "dc-ponto", dia);
  k.$("div", "dc-anel", ponto);
  k.tl.fromTo(ponto, { scale: 0, opacity: 0 }, { scale: 1, opacity: 1, duration: 0.4, ease: "back.out(2)" }, T(2.3));
  k.tl.fromTo(ponto.firstChild, { scale: 1, opacity: 0.9 }, { scale: 4, opacity: 0, duration: 0.8, ease: "power1.out" }, T(2.4));

  // ---------- painel ----------
  const pan = k.$("div", "dc-pan", card);
  const cab = k.$("div", "dc-cab", pan);
  k.$("div", "dc-tit", cab, k.esc(e.titulo || ""));
  if (e.selo) k.$("div", "dc-selo", cab, k.esc(e.selo));
  k.entra(pan, T(2.6), { de: { y: 2 * U } });

  const trs = k.$("div", "dc-trs", pan);
  const trilhas = (e.trilhas || []).slice(0, 5);
  const A = [4, 22, 12, 38, 26], W = [30, 34, 40, 28, 36];
  const ov = k.$("div", "dc-ov", trs);
  const cur = k.$("div", "dc-cur", ov);
  const t0 = T(3.2);
  const D = Math.max(0.8, c.ate - 0.5 - t0);
  const segs = [];
  trilhas.forEach((txt, i) => {
    const row = k.$("div", "dc-row", trs);
    k.$("div", "dc-rl", row, k.esc(txt));
    const bar = k.$("div", "dc-rb", row);
    const seg = k.$("div", "dc-seg dc-s" + (i % 3), bar);
    seg.style.left = A[i] + "%";
    seg.style.width = W[i] + "%";
    segs.push(seg);
    k.entra(row, T(2.9) + i * 0.08, { de: { x: -2 * U } });
  });
  trs.appendChild(ov); // cursor por cima das linhas
  k.entra(cur, t0 - 0.1);
  k.tl.fromTo(cur, { left: "0%" }, { left: "100%", duration: D, ease: "none" }, t0);
  segs.forEach((s, i) => {
    k.tl.fromTo(s, { scaleX: 0 }, { scaleX: 1, duration: D * W[i] / 100, ease: "none" }, t0 + D * A[i] / 100);
  });
});
