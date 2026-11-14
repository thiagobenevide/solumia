// Pergunta em palavras 2,5D: cada palavra chega de uma profundidade, a palavra-chave avança à frente, um ? gigante fica atrás.
ESTUDIO.peca("pergunta_palavras_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const giro = b.entrada === "giro";
  const sinal = b.inclinacao === "direita" ? 1 : -1;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");

  const cena = k.$("div", "pp-cena", box);
  const palco = k.$("div", "pp-palco", cena);
  const fundoQ = k.$("div", "pp-q", palco, "?");
  const texto = k.$("div", "pp-texto", palco);

  // separa as palavras; *marcadas* ficam em destaque (aceita mais de uma palavra entre asteriscos)
  let dentro = false;
  const toks = [];
  String(e.pergunta || "").split(/\s+/).filter(Boolean).forEach((w) => {
    if (w.startsWith("*")) dentro = true;
    const marcada = dentro;
    if (w.endsWith("*") || (w.endsWith("*.") || w.endsWith("*?"))) dentro = false;
    const limpa = w.replace(/\*/g, "");
    if (limpa) toks.push({ t: limpa, m: marcada });
  });
  if (!toks.some((x) => x.m) && e.palavra_chave) {
    const alvo = String(e.palavra_chave).toLowerCase();
    toks.forEach((x) => { if (x.t.toLowerCase().replace(/[?!.,]/g, "") === alvo) x.m = true; });
  }

  const t0 = c.t + 0.2;
  const passo = Math.min(0.14, 1.6 / Math.max(toks.length, 1));
  const els = toks.map((x, i) => {
    const w = k.$("span", "pp-w" + (x.m ? " pp-k" : ""), texto, k.esc(x.t));
    const prof = -(40 + 50 * k.rnd(i + 3)) * U;
    const desv = (k.rnd(i + 11) - 0.5) * 10 * U;
    k.tl.fromTo(w,
      { z: prof, x: desv, y: (k.rnd(i + 7) - 0.3) * 6 * U, rotationY: giro ? sinal * 70 : sinal * 25, rotationX: giro ? 0 : 12, opacity: 0 },
      { z: 0, x: 0, y: 0, rotationY: 0, rotationX: 0, opacity: 1, duration: 0.7, ease: k.SUAVE }, t0 + i * passo);
    return w;
  });

  const tFim = t0 + toks.length * passo + 0.5;
  // ? gigante ao fundo
  k.tl.fromTo(fundoQ, { z: -90 * U, opacity: 0, scale: 0.7 }, { z: -45 * U, opacity: 1, scale: 1, duration: 1.1, ease: k.SUAVE }, c.t + 0.1);
  k.tl.to(fundoQ, { rotationY: -sinal * 14, duration: Math.max(c.ate - c.t, 3), ease: "none" }, c.t + 0.1);

  // palavra-chave avança à frente e ganha o traço
  els.forEach((w, i) => {
    if (!toks[i].m) return;
    k.tl.to(w, { z: 9 * U, scale: 1.08, duration: 0.6, ease: k.SUAVE }, tFim + i * 0.05);
  });
  const marca = k.$("div", "traco pp-traco", cena);
  k.traco(marca, tFim + 0.1, 0.7);

  if (e.apoio) k.entra(k.$("div", "pp-apoio", cena, k.rico(k.esc(e.apoio))), tFim + 0.3, { de: { y: 3 * U } });

  // a câmera respira até o fim
  const dur = Math.max(c.ate - c.t, 3);
  k.tl.fromTo(palco, { rotationY: sinal * 9, rotationX: 4 }, { rotationY: -sinal * 7, rotationX: -2, duration: dur, ease: "none" }, c.t);
});
