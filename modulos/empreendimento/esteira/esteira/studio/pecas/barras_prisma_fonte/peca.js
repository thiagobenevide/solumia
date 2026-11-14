// Barras prisma com citação: fonte em caixa alta, frase, dois prismas contando, eixo com marcas e rodapé da fonte.
ESTUDIO.peca("barras_prisma_fonte", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const layout = b.layout || "direita";
  const dur = Math.max(1, c.ate - c.t);
  if (c.takeover) k.fundo(c); else k.veu(c, "baixo");
  box.classList.add("bp-" + layout);

  const card = k.$("div", "bp-card", box);
  const painel = k.$("div", "bp-painel", card);
  const sinal = layout === "esquerda" ? -1 : 1;
  const rot = layout === "flutuante" ? -6 : -12 * sinal;

  k.entra(card, c.t, { de: { x: 6 * U * sinal, y: layout === "flutuante" ? 4 * U : 0, scale: 0.94 } });
  k.tl.fromTo(painel, { rotationY: rot * 1.8 }, { rotationY: rot, duration: 1.0, ease: k.SUAVE }, c.t);
  k.tl.to(painel, { rotationY: rot + 2 * sinal, rotationX: 1.5, duration: dur, ease: "none" }, c.t + 1.0);

  if (e.fonte) {
    const f = k.$("div", "bp-fonte", painel, k.esc(e.fonte));
    k.entra(f, c.t + 0.2, { de: { y: 2 * U } });
  }
  if (e.citacao) {
    const q = k.$("div", "bp-citacao", painel);
    k.palavras(q, "“" + e.citacao + "”", c.t + 0.5, 0.05);
  }

  const pares = (e.valores || []).slice(0, 2).map((p) => {
    const num = k.numero(p.valor);
    return { rotulo: p.rotulo, valor: p.valor, num, n: num ? Math.abs(num.n) : 0 };
  });
  const max = Math.max(...pares.map((p) => p.n), 1e-9);
  const HMAX = 19 * U;

  const graf = k.$("div", "bp-graf", painel);
  const area = k.$("div", "bp-area", graf);

  if (b.eixo !== "nenhuma") {
    [0, 0.5, 1].forEach((f, i) => {
      const v = Math.round(max * f * 10) / 10;
      const lin = k.$("div", "bp-marca", area, `<span>${String(v).replace(".", ",")}</span>`);
      lin.style.bottom = `calc(${f * 19} * var(--U))`;
      k.entra(lin, c.t + 0.9 + i * 0.06, { de: { x: -1 * U } });
    });
  }

  const cols = k.$("div", "bp-cols", area);
  const t0 = c.t + 1.3;
  pares.forEach((p, i) => {
    const vence = p.n >= max;
    const col = k.$("div", "bp-col" + (vence ? " bp-vence" : ""), cols);
    const val = k.$("div", "bp-val", col,
      p.num ? `<span class="bp-v"></span><small>${k.esc(p.num.depois)}</small>` : k.esc(p.valor));
    const pr = k.$("div", "bp-prisma", col,
      '<i class="bp-topo"></i><i class="bp-lado"></i>');
    const h = Math.max(0.05, p.n / max) * HMAX;
    const ti = t0 + i * 0.3;
    k.tl.fromTo(pr, { height: 0 }, { height: h, duration: 1.1, ease: k.SUAVE }, ti);
    k.entra(val, ti, { de: { y: 2 * U } });
    if (p.num) k.contar(val.querySelector(".bp-v"), { ...p.num, depois: "" }, ti + 0.05, 1.1, true);
  });

  const rots = k.$("div", "bp-rots", graf);
  pares.forEach((p, i) => {
    const r = k.$("div", "bp-rot", rots, k.esc(p.rotulo || ""));
    k.entra(r, t0 + i * 0.3, { de: { y: 1 * U } });
  });

  if (e.rodape) {
    const rd = k.$("div", "bp-rodape", painel, k.esc(e.rodape));
    k.entra(rd, t0 + 1.2, { de: { y: 1 * U } });
  }
});
