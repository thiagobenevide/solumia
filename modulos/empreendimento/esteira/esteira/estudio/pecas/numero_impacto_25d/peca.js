// Número de impacto 2,5D: bloco espesso vem do fundo, unidade encaixa ao lado, legenda num plano à frente.
ESTUDIO.peca("numero_impacto_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const forte = b.profundidade === "forte";
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");

  const cena = k.$("div", "n25-cena", box);
  const palco = k.$("div", "n25-palco", cena);
  const linha = k.$("div", "n25-linha", palco);

  const num = k.numero(e.valor);
  const bloco = k.$("div", "n25-bloco", linha,
    num ? `<span class="n25-v"></span>` : k.esc(e.valor));
  const tn = c.batidas.valor != null ? c.batidas.valor : c.t + 0.15;

  // chegada de longe: z negativo, girado, parando de frente no centro
  const z0 = (forte ? -130 : -85) * U;
  const rot = forte ? 28 : 16;
  k.tl.fromTo(bloco,
    { z: z0, rotationY: -rot, rotationX: rot * 0.4, opacity: 0, transformOrigin: "50% 50%" },
    { z: 0, rotationY: 0, rotationX: 0, opacity: 1, duration: 0.85, ease: "power3.out" }, tn);
  if (num) k.contar(bloco.querySelector(".n25-v"), { ...num, depois: "" }, tn + 0.1, 0.85, true);
  const depois = num && num.depois ? num.depois.trim() : "";

  // unidade encaixa ao lado, vinda da direita e de trás
  const txtUni = e.unidade || depois;
  if (txtUni) {
    const uni = k.$("div", "n25-uni", linha, k.esc(txtUni));
    k.tl.fromTo(uni,
      { x: 10 * U, z: -30 * U, rotationY: 20, opacity: 0 },
      { x: 0, z: 0, rotationY: 0, opacity: 1, duration: 0.55, ease: "back.out(1.4)" }, tn + 0.8);
  }

  // legenda: plano levemente à frente do bloco
  if (e.legenda) {
    const plano = k.$("div", "n25-plano", palco);
    const leg = k.$("div", "n25-leg", plano);
    k.tl.set(plano, { z: 10 * U }, 0);
    k.tl.fromTo(plano, { y: 4 * U, opacity: 0 }, { y: 0, opacity: 1, duration: 0.5, ease: k.SUAVE }, tn + 1.0);
    k.palavras(leg, e.legenda, tn + 1.05, 0.06);
  }

  // câmera respira até o fim (ângulos pequenos)
  const dur = Math.max(1, c.ate - tn);
  k.tl.fromTo(palco, { rotationY: -2, rotationX: 1.5 },
    { rotationY: forte ? 5 : 3, rotationX: forte ? -3 : -1.5, duration: dur, ease: "none" }, tn);
});
