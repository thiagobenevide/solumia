// Passado em arquivo 2,5D: cartão de época em perspectiva com o ano carimbado; épocas anteriores recuam em camadas atrás.
ESTUDIO.peca("passado_arquivo_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");
  box.classList.add("pa-" + (b.acabamento === "vidro" ? "vidro" : "papel"));

  const ang = k.V ? 0.6 : 1;
  const dur = Math.max(1.2, c.ate - c.t);
  const cena = k.$("div", "pa-cena", box);
  const palco = k.$("div", "pa-palco", cena);

  // épocas anteriores: placas atrás do cartão, cada uma mais funda
  const marcos = (Array.isArray(e.marcos) ? e.marcos : []).slice(0, 2);
  marcos.forEach((m, i) => {
    const p = k.$("div", "pa-placa", palco, `<span>${k.esc(String(m))}</span>`);
    const n = i + 1;
    k.tl.fromTo(p,
      { z: -70 * U, y: -1 * U, opacity: 0 },
      { z: -9 * n * U, y: -(k.V ? 6 : 5) * n * U, opacity: 1 - 0.28 * n, duration: 0.9, ease: k.SUAVE },
      c.t + 0.1 * (marcos.length - i));
  });

  // cartão principal
  const cartao = k.$("div", "pa-cartao", palco);
  const ano = k.$("div", "pa-ano", cartao, k.esc(e.ano));
  k.$("div", "pa-fio", cartao);
  const tit = k.$("div", "pa-titulo", cartao);
  const leg = k.$("div", "pa-legenda", cartao);

  k.tl.fromTo(cartao,
    { z: -45 * U, y: 5 * U, opacity: 0 },
    { z: 0, y: 0, opacity: 1, duration: 0.9, ease: k.SUAVE },
    c.t + 0.15);

  // ano carimbado na batida
  const tb = c.batidas.ano != null ? c.batidas.ano : c.t + 0.5;
  k.tl.fromTo(ano,
    { scale: 1.5, opacity: 0, rotation: -3 },
    { scale: 1, opacity: 1, rotation: 0, duration: 0.45, ease: "back.out(2)" },
    tb);
  k.tl.fromTo(cartao.querySelector(".pa-fio"),
    { scaleX: 0 }, { scaleX: 1, duration: 0.6, ease: k.SUAVE }, tb + 0.15);

  if (e.titulo) k.palavras(tit, e.titulo, tb + 0.3, 0.07);
  if (e.legenda) k.palavras(leg, e.legenda, tb + 0.3 + 0.07 * String(e.titulo || "").split(/\s+/).length + 0.2, 0.05);

  // câmera: respira até o fim
  const gira = b.movimento === "gira";
  k.tl.fromTo(palco,
    { rotationY: (gira ? -16 : -12) * ang, rotationX: 6 * ang, z: gira ? 0 : -8 * U },
    { rotationY: (gira ? 9 : -4) * ang, rotationX: 2 * ang, z: gira ? 0 : 4 * U, duration: dur, ease: "none" },
    c.t);
});
