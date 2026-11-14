// Barras 3D com citação: card de vidro em perspectiva com fonte, frase, dois prismas contando, eixo e rodapé.
ESTUDIO.peca("barras_vidro_fonte", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const vel = { lenta: 1.5, normal: 1.0, rapida: 0.7 }[b.velocidade] || 1.0;
  const flut = b.layout === "flutuante";
  const dur = Math.max(2, c.ate - c.t);
  if (c.takeover) k.fundo(c);
  if (flut) box.classList.add("bvf-flut");

  // dados
  const ps = (e.valores || []).slice(0, 2).map((p) => ({ rotulo: p.rotulo || "", valor: p.valor || "", num: k.numero(p.valor || "") }));
  const vals = ps.map((p) => (p.num ? Math.abs(p.num.n) : 0));
  const maxV = Math.max(...vals, 0) || 1;
  const nice = (x) => {
    const p = Math.pow(10, Math.floor(Math.log10(x)));
    const m = [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].find((q) => q * p >= x - 1e-9);
    return m * p;
  };
  const topo = nice(maxV / 0.78);
  const un = ps[0] && ps[0].num && ps[0].num.depois ? ps[0].num.depois.trim() : "";
  const unit = un.length <= 3 ? un : "";
  const f = (v) => v.toLocaleString("pt-BR", { maximumFractionDigits: 1 }) + unit;
  const venc = vals[0] >= vals[1] ? 0 : 1;

  // estrutura
  const cena = k.$("div", "bvf-cena", box);
  const card = k.$("div", "bvf-card", cena);
  const fonte = e.fonte ? k.$("div", "bvf-fonte", card, k.esc(e.fonte)) : null;
  const cit = e.citacao ? k.$("div", "bvf-cit", card) : null;
  const graf = k.$("div", "bvf-graf", card);
  const eixo = k.$("div", "bvf-eixo", graf);
  const area = k.$("div", "bvf-area", graf);
  const palco = k.$("div", "bvf-palco", area);
  const rod = e.rodape ? k.$("div", "bvf-rod", card, k.esc(e.rodape)) : null;

  // eixo: marcas 0, metade, topo
  const marcas = [0, 0.5, 1];
  const grades = [];
  marcas.forEach((m, i) => {
    const tk = k.$("div", "bvf-tk", eixo, i === 0 ? "0" : k.esc(f(topo * m)));
    tk.style.bottom = m * 100 + "%";
    const gl = k.$("div", "bvf-gl" + (i === 0 ? " bvf-base" : ""), area);
    gl.style.bottom = m * 100 + "%";
    grades.push(tk, gl);
  });

  // barras
  const cols = ps.map((p, i) => {
    const col = k.$("div", "bvf-col", palco);
    const barra = k.$("div", "bvf-b " + (i === venc ? "bvf-venc" : "bvf-out"), col,
      '<i class="bvf-top"></i><i class="bvf-lado"></i><i class="bvf-fr"></i>');
    const val = k.$("div", "bvf-val", barra, p.num
      ? `<span class="bvf-v"></span><small>${k.esc(p.num.depois)}</small>` : k.esc(p.valor));
    k.$("div", "bvf-rot", col, k.esc(p.rotulo));
    return { col, barra, val, p, pct: Math.max(4, (vals[i] / topo) * 100) };
  });

  // entrada do card (câmera "respira" até o fim)
  const vert = k.V;
  const r0 = vert ? (flut ? 6 : -6) : (flut ? 10 : -13);
  const dx = vert ? 0 : (flut ? -4 * U : 8 * U);
  k.tl.fromTo(card, { opacity: 0, x: dx, y: vert ? 5 * U : 0, rotationY: r0 * 2.2 },
    { opacity: 1, x: 0, y: 0, rotationY: r0, duration: 0.9, ease: k.SUAVE }, c.t);
  k.tl.to(card, { rotationY: r0 * 0.45, duration: Math.max(1, dur - 0.9), ease: "none" }, c.t + 0.9);
  if (flut) k.tl.to(cena, { y: -1.6 * U, duration: Math.max(1, dur), ease: "sine.inOut" }, c.t);

  // textos
  if (fonte) k.entra(fonte, c.t + 0.3, { de: { y: 1.5 * U } });
  if (cit) k.palavras(cit, e.citacao, c.t + 0.7, 0.05 * vel);

  // eixo e grades
  grades.forEach((g, i) => k.tl.fromTo(g, { opacity: 0 }, { opacity: 1, duration: 0.5, ease: k.SUAVE }, c.t + 1.3 + i * 0.05));

  // barras crescendo e valores contando
  const tb = c.t + 1.9;
  cols.forEach((o, i) => {
    const ti = tb + i * 0.3 * vel;
    k.tl.fromTo(o.barra, { height: "0%" }, { height: o.pct + "%", duration: 1.2 * vel, ease: k.SUAVE }, ti);
    k.entra(o.val, ti + 0.2, { de: { y: U } });
    if (o.p.num) k.contar(o.val.querySelector(".bvf-v"), { ...o.p.num, depois: "" }, ti + 0.05, 1.2 * vel, !o.p.num.casas);
    k.entra(o.col.querySelector(".bvf-rot"), ti, { de: { y: U } });
  });

  // o maior avança um pouco em profundidade
  k.tl.to(cols[venc].col, { z: 3 * U, duration: 0.8, ease: k.SUAVE }, tb + 1.6 * vel);

  if (rod) k.entra(rod, tb + 1.4 * vel, { de: { y: U } });
});
