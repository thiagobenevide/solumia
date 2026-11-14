// Comparação em 2,5D: dois pilares giram de frente para a câmera, valores crescem e o vencedor avança no eixo Z.
ESTUDIO.peca("comparacao_pilares_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const vel = { lenta: 1.5, normal: 1.0, rapida: 0.7 }[b.velocidade] || 1.0;
  const ang = b.giro === "marcado" ? 32 : 16;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");

  const cena = k.$("div", "cp-cena", box);
  const palco = k.$("div", "cp-palco", cena);

  const lados = [
    { rotulo: e.rotulo_a, valor: e.valor_a, sinal: 1 },
    { rotulo: e.rotulo_b, valor: e.valor_b, sinal: -1 },
  ];
  lados.forEach((l) => { l.num = k.numero(l.valor); });
  const na = lados[0].num ? lados[0].num.n : 0;
  const nb = lados[1].num ? lados[1].num.n : 0;
  const menorVence = b.vencedor === "menor";
  let venc = 0;
  if (na !== nb) venc = (na > nb) !== menorVence ? 0 : 1;
  const maxN = Math.max(na, nb, 1e-9);

  const t0 = c.t + 0.2;
  const tCresce = t0 + 0.35 * vel;
  const dCresce = 1.1 * vel;
  const tVence = tCresce + dCresce + 0.2 * vel;

  lados.forEach((l, i) => {
    const col = k.$("div", "cp-col", palco);
    const trilho = k.$("div", "cp-trilho", col);
    const pilar = k.$("div", "cp-pilar", trilho);
    const topo = k.$("div", "cp-topo", pilar);
    const val = k.$("div", "cp-val", pilar);
    const vn = k.$("span", "cp-vn", val);
    const un = e.unidade ? k.$("small", "cp-un", val, k.esc(e.unidade)) : null;
    k.$("div", "cp-rot", col, k.esc(l.rotulo || ""));

    const razao = l.num ? Math.max(0.18, Math.min(1, l.num.n / maxN)) : 0.5;
    const ehV = i === venc;

    k.tl.fromTo(col,
      { opacity: 0, rotationY: l.sinal * ang * 1.8, x: l.sinal * -4 * U, z: -8 * U },
      { opacity: 1, rotationY: l.sinal * ang * 0.5, x: 0, z: -3 * U, duration: 0.7 * vel, ease: k.SUAVE }, t0);
    k.tl.fromTo(pilar, { height: "0%" }, { height: (razao * 100) + "%", duration: dCresce, ease: k.SUAVE }, tCresce);
    k.tl.fromTo(val, { opacity: 0 }, { opacity: 1, duration: 0.3, ease: "none" }, tCresce);

    if (l.num) k.contar(vn, { ...l.num, depois: "" }, tCresce, dCresce, true);
    else vn.textContent = l.valor || "";
    if (un && l.num && l.num.depois) un.textContent = l.num.depois + " " + e.unidade;
    else if (!un && l.num && l.num.depois) k.$("small", "cp-un", val, k.esc(l.num.depois));

    if (ehV) {
      k.tl.to(col, { rotationY: 0, z: 7 * U, duration: 0.8 * vel, ease: k.SUAVE }, tVence);
      k.tl.to(topo, { opacity: 1, duration: 0.5 * vel, ease: "none" }, tVence);
    } else {
      k.tl.to(col, { rotationY: l.sinal * ang * 0.8, z: -7 * U, opacity: 0.85, duration: 0.8 * vel, ease: k.SUAVE }, tVence);
    }
  });

  // a câmera "respira" até o fim
  k.tl.fromTo(palco, { rotationY: -4 }, { rotationY: 4, duration: Math.max(1, c.ate - c.t), ease: "none" }, c.t);
});
