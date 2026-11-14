// Número em bloco espesso 2,5D: vem de longe, para no centro, unidade encaixa ao lado, legenda num plano à frente.
ESTUDIO.peca("numero_sombra_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const vel = { lenta: 1.5, normal: 1.0, rapida: 0.7 }[b.velocidade] || 1.0;
  const dir = b.inclinacao === "direita" ? 1 : -1;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");
  if (dir > 0) box.classList.add("ns-dir");

  const cena = k.$("div", "ns-cena", box);
  const palco = k.$("div", "ns-palco", cena);
  const linha = k.$("div", "ns-linha", palco);
  const n = k.$("div", "ns-n", linha);
  const tn = c.batidas.valor != null ? c.batidas.valor : c.t + 0.15;

  const num = k.numero(e.valor);
  if (num) {
    const v = k.$("span", "ns-v", n);
    k.contar(v, { ...num, depois: "" }, tn + 0.1, 0.9 * vel, true);
  } else {
    n.textContent = e.valor;
  }

  // chegada de longe (ângulos moderados, já legível logo no início)
  k.tl.fromTo(palco,
    { z: -60 * U, opacity: 0, rotationY: -dir * 18, rotationX: 5, scale: 0.9 },
    { z: 0, opacity: 1, rotationY: dir * -8, rotationX: 2, scale: 1, duration: 0.8 * vel, ease: "power3.out" }, tn);

  // unidade encaixa ao lado
  if (e.unidade) {
    const un = k.$("div", "ns-un", linha, k.esc(e.unidade));
    k.tl.fromTo(un, { x: dir * 6 * U, opacity: 0, scale: 0.92 },
      { x: 0, opacity: 1, scale: 1, duration: 0.5 * vel, ease: "back.out(1.4)" }, tn + 0.6 * vel);
  }

  // legenda no plano à frente
  if (e.legenda) {
    const plano = k.$("div", "ns-plano", palco);
    const leg = k.$("div", "ns-leg", plano);
    k.palavras(leg, e.legenda, tn + 0.9 * vel, 0.06 * vel);
  }

  // câmera respira até o fim
  const ini = tn + 0.8 * vel;
  const dur = Math.max(0.5, c.ate - ini);
  k.tl.to(palco, { rotationY: dir * 5, rotationX: 1, duration: dur, ease: "none" }, ini);
});
