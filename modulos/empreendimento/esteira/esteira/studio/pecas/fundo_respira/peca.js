// Fundo que respira: gradientes lentos + partículas ou grão, em loop perfeito (vai e volta senoidal), sem texto.
ESTUDIO.peca("fundo_respira", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const estilo = b.estilo || "gradiente";
  const par = b.camadas === "paralaxe";
  // o encaixe "clima" não vira texto: só varia a semente da composição (determinístico)
  let sem = 0;
  const clima = e.clima ? String(e.clima) : "";
  for (let i = 0; i < clima.length; i++) sem = (sem * 31 + clima.charCodeAt(i)) % 997;
  if (c.takeover) k.fundo(c);
  const dur = Math.max(0.5, c.ate - c.t);
  const ciclo = 7;                                   // meio-ciclo (s) do vai e volta
  const reps = Math.ceil(dur / ciclo) + 1;           // yoyo finito, cobre a peça inteira
  const osc = (el, from, to, d, atraso) =>
    k.tl.fromTo(el, from, { ...to, duration: d, ease: "sine.inOut", repeat: reps, yoyo: true }, c.t + (atraso || 0));

  const cena = k.$("div", "fr-cena", box);
  // camada 1 (longe): manchas de gradiente
  const l1 = k.$("div", "fr-l fr-l1", cena);
  const cores = ["destaque", "apoio", "acento"];
  const forca = estilo === "gradiente" ? 1 : 0.6;
  for (let i = 0; i < 3; i++) {
    const m = k.$("div", "fr-mancha fr-m" + cores[i], l1);
    m.style.left = (14 + i * 34 + (k.rnd(i + 11 + sem) - 0.5) * 12) + "%";
    m.style.top = (22 + (i % 2) * 38 + (k.rnd(i + 21 + sem) - 0.5) * 12) + "%";
    m.style.opacity = String(0.55 * forca);
    osc(m, { x: -6 * U, y: 4 * U, scale: 0.9 }, { x: 6 * U, y: -5 * U, scale: 1.15 }, ciclo + i * 1.3, -i * 0.01);
  }
  // camada 2 (meio): partículas ou grão
  const l2 = k.$("div", "fr-l fr-l2", cena);
  const n = estilo === "particulas" ? 26 : estilo === "grao" ? 90 : 14;
  for (let i = 0; i < n; i++) {
    const p = k.$("div", "fr-p " + (estilo === "grao" ? "fr-g" : "fr-b"), l2);
    const r = 100 + i * 7 + sem;
    p.style.left = (k.rnd(r) * 100) + "%";
    p.style.top = (k.rnd(r + 1) * 100) + "%";
    const tam = estilo === "grao" ? 0.25 + k.rnd(r + 2) * 0.25 : 0.5 + k.rnd(r + 2) * 1.1;
    p.style.width = p.style.height = `calc(${tam.toFixed(2)} * var(--U))`;
    const d = ciclo * (0.8 + k.rnd(r + 3) * 0.9);
    const alto = estilo === "grao" ? 0.22 : 0.4;
    osc(p, { y: 0, x: 0, opacity: alto * 0.15 }, { y: (-3 - k.rnd(r + 4) * 6) * U, x: (k.rnd(r + 5) - 0.5) * 3 * U, opacity: alto * (0.5 + k.rnd(r + 6) * 0.5) }, d);
  }
  // camada 3 (perto): véu suave que garante a leitura da legenda
  k.$("div", "fr-veu", cena);
  const l3 = k.$("div", "fr-l fr-l3", cena);
  k.$("div", "fr-halo", l3);
  osc(l3.firstChild, { opacity: 0.35, scale: 0.95 }, { opacity: 0.7, scale: 1.05 }, ciclo * 0.9);

  // paralaxe leve: cada camada desliza uma distância diferente (plana: só as manchas respiram)
  if (par) {
    osc(l1, { x: -1.2 * U, y: 0.6 * U }, { x: 1.2 * U, y: -0.6 * U }, ciclo * 1.4);
    osc(l2, { x: -3 * U, y: 1.2 * U }, { x: 3 * U, y: -1.2 * U }, ciclo * 1.4);
    osc(l3, { x: -5.5 * U, y: 2 * U }, { x: 5.5 * U, y: -2 * U }, ciclo * 1.4);
  }
  k.tl.fromTo(cena, { opacity: 0 }, { opacity: 1, duration: 0.8, ease: k.SUAVE }, c.t);
});
