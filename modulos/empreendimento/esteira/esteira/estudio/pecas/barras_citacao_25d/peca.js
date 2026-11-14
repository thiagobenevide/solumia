// Barras 3D com citação: fonte em caixa alta, frase com destaque, duas barras prisma com valor contando, eixo e rodapé.
// Card de vidro em perspectiva, sem fundo cheio (sobre a mídia). Em tela cheia usa o fundo padrão do kit.
ESTUDIO.peca("barras_citacao_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const lado = b.lado || "direita";
  const dir = lado === "esquerda" ? -1 : lado === "direita" ? 1 : 0;
  const incl = { suave: [-10, -4, -20, -9], media: [-14, -6, -26, -12], forte: [-20, -8, -34, -16] }[b.inclinacao] || [-14, -6, -26, -12];
  const total = Math.max(1, c.ate - c.t);
  const aj = k.ajuste(c) || {};
  const dur = Math.min(Math.max(aj.contagem_s || 1.3, 0.6), 2);

  if (c.takeover) k.fundo(c);
  if (lado === "esquerda") box.classList.add("bc-esq");
  if (lado === "centro") box.classList.add("bc-centro");

  // dados das barras
  const lista = (Array.isArray(e.barras) ? e.barras : []).slice(0, 2)
    .map((p) => (p && typeof p === "object" ? p : { rotulo: "", valor: String(p || "") }));
  const nums = lista.map((p) => k.numero(String(p.valor || "")));
  const absn = nums.map((n) => (n ? Math.abs(Number(n.n)) || 0 : 0));
  const maxn = absn.length ? Math.max(...absn) : 0;
  const hmax = (k.V ? 33 : 25) * U;
  const alturas = lista.map((p, i) => hmax * (nums[i] && maxn > 0 ? Math.max(0.1, absn[i] / maxn) : 0.5));
  const maior = absn.length > 1 && absn[1] !== absn[0] ? (absn[1] > absn[0] ? 1 : 0) : -1;

  // card
  const rot = (k.V ? 0.5 : 1) * (lado === "centro" ? -4 : -12 * dir);
  const card = k.$("div", "bc-card", box);
  k.$("div", "bc-vidro", card);
  const t0 = c.t;
  k.tl.fromTo(card,
    { opacity: 0, x: dir * 10 * U, z: -25 * U, rotationY: rot + dir * -22 },
    { opacity: 1, x: 0, z: 0, rotationY: rot, duration: 0.8, ease: k.SUAVE }, t0);
  k.tl.fromTo(card, { y: 0.8 * U }, { y: -0.8 * U, duration: Math.max(0.2, total - 0.8), ease: "sine.inOut" }, t0 + 0.8);

  // fonte (kicker em caixa alta) e frase
  const topo = k.$("div", "bc-topo", card);
  if (e.fonte) k.kicker(topo, String(e.fonte).toUpperCase(), t0 + 0.25);
  const frase = k.$("div", "bc-frase", card);
  const nPal = String(e.frase || "").split(/\s+/).filter(Boolean).length;
  if (e.frase) k.palavras(frase, e.frase, t0 + 0.5, 0.05);

  // gráfico
  let tb = c.batidas && c.batidas.barras != null ? c.batidas.barras : t0 + 0.7 + nPal * 0.05;
  tb = Math.max(t0 + 0.6, Math.min(tb, c.ate - dur - 0.9));
  const graf = k.$("div", "bc-graf", card);
  const palco = k.$("div", "bc-palco", graf);
  const grade = k.$("div", "bc-grade", palco);
  grade.style.height = hmax + "px";
  k.$("div", "bc-eixoy", grade);
  k.$("div", "bc-base", grade);
  for (let i = 0; i <= 4; i++) {
    const m = k.$("div", "bc-marca", grade);
    m.style.bottom = (hmax * i / 4) + "px";
    k.tl.fromTo(m, { opacity: 0, scaleX: 0 }, { opacity: 1, scaleX: 1, transformOrigin: "0% 50%", duration: 0.45, ease: k.SUAVE }, tb - 0.4 + i * 0.07);
  }
  const barras = k.$("div", "bc-barras", palco);
  const rots = k.$("div", "bc-rots", card);
  lista.forEach((p, i) => {
    const col = k.$("div", "bc-col", barras);
    const barra = k.$("div", "bc-barra" + (i === maior ? " bc-maior" : ""), col);
    k.$("div", "bc-f", barra);
    k.$("div", "bc-l", barra);
    k.$("div", "bc-t", barra);
    const val = k.$("div", "bc-val", barra);
    const num = nums[i];
    const vn = k.$("div", "bc-vn", val, num ? `<span class="bc-v"></span><small>${k.esc(num.depois || "")}</small>` : k.esc(p.valor || ""));
    const ti = tb + i * 0.28;
    k.tl.fromTo(barra, { height: 0 }, { height: alturas[i], duration: dur, ease: k.SUAVE }, ti);
    k.entra(vn, ti + 0.1, { de: { y: 2 * U, scale: 0.9 } });
    if (num) k.contar(vn.querySelector(".bc-v"), { ...num, depois: "" }, ti + 0.1, dur, !num.casas);
    k.$("div", "bc-rot", rots, k.esc(p.rotulo || ""));
  });
  // respiração da câmera
  k.tl.fromTo(palco, { rotationY: incl[0], rotationX: incl[1] },
    { rotationY: incl[2], rotationX: incl[3], duration: Math.max(0.5, c.ate - t0 - 0.2), ease: "none" }, t0 + 0.1);

  // rodapé
  if (e.rodape) {
    const rp = k.$("div", "bc-rodape", card, k.esc(e.rodape));
    k.entra(rp, Math.min(tb + dur * 0.6, c.ate - 0.5), { de: { y: 1.5 * U } });
  }
});
