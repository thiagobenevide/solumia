// Terço inferior discreto: de onde vem o dado que está sendo falado (do gráfico antigo fonte.html).
ESTUDIO.peca("fonte_dado", (k, c, raiz) => {
  const e = c.encaixes, b = c.botoes;
  k.veu(c, "baixo");
  const box = k.$("div", "tag fd-tag", raiz,
    `<div class="tx"><div class="tk">${k.esc(e.rotulo || "Fonte")}</div><div class="fd-l1">${k.rico(e.linha1 || "")}</div>` +
    (e.linha2 ? `<div class="fd-l2">${k.esc(e.linha2)}</div>` : "") +
    (b.link === "sim" ? `<div class="fd-link">Link na descrição ↓</div>` : "") + "</div>");
  k.entra(box, c.t, { de: { x: -6 * k.U, y: 0, filter: "blur(12px)" } });
  box.querySelectorAll(".tk, .fd-l1, .fd-l2, .fd-link").forEach((x, i) => k.entra(x, c.t + 0.2 + i * 0.15, { de: { y: 1.5 * k.U } }));
});
