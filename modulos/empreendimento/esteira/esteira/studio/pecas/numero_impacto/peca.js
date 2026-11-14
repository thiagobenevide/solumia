// Número de impacto: rótulo curto, número grande contando e uma linha de contexto. Neutra (serve a qualquer canal).
ESTUDIO.peca("numero_impacto", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const vel = { lenta: 1.6, normal: 1.0, rapida: 0.6 }[b.velocidade] || 1.0;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");
  if (b.alinhamento === "esquerda") box.classList.add("ni-esq");
  const corpo = k.$("div", "ni-corpo", box);
  if (e.rotulo) k.kicker(corpo, e.rotulo, c.t);
  const num = k.numero(e.numero);
  const n = k.$("div", "ni-n", corpo, num ? `<span class="ni-v"></span><small>${k.esc(num.depois)}</small>` : k.esc(e.numero));
  const tn = c.batidas.numero != null ? c.batidas.numero : c.t + 0.15;
  k.entra(n, tn, { de: { y: 4 * U, scale: 0.92 } });
  if (num) k.contar(n.querySelector(".ni-v"), { ...num, depois: "" }, tn + 0.05, 0.9 * vel, true);
  if (b.enfase === "traco") k.traco(k.$("div", "traco", corpo), tn + 0.5 * vel, 0.8 * vel);
  if (b.enfase === "anel") {
    const anel = k.$("div", "ni-anel", n);
    k.tl.fromTo(anel, { scale: 0.6, opacity: 0 }, { scale: 1, opacity: 1, duration: 0.6 * vel, ease: k.SUAVE }, tn + 0.2);
  }
  if (e.contexto) k.palavras(k.$("div", "ni-ctx", corpo), e.contexto, tn + 0.6 * vel, 0.06 * vel);
});
