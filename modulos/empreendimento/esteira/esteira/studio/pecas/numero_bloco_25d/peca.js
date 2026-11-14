// Número em bloco 2,5D: o valor espesso vem do fundo, a unidade encaixa ao lado e a legenda fica num plano à frente.
ESTUDIO.peca("numero_bloco_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const vel = { lenta: 1.5, normal: 1.0, rapida: 0.65 }[b.velocidade] || 1.0;
  const lado = { esquerda: -1, direita: 1, frontal: 0 }[b.inclinacao];
  const sinal = lado == null ? 1 : lado;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");

  const cena = k.$("div", "nb-cena", box);
  const palco = k.$("div", "nb-palco", cena);
  const corpo = k.$("div", "nb-corpo", palco);
  const linha = k.$("div", "nb-linha", corpo);

  const num = k.numero(e.valor);
  const bloco = k.$("div", "nb-bloco", linha, num ? '<span class="nb-v"></span>' : k.esc(e.valor));
  const textoUn = e.unidade || (num && num.depois ? String(num.depois).trim() : "");
  const un = textoUn ? k.$("div", "nb-un", linha, k.esc(textoUn)) : null;
  const leg = e.legenda ? k.$("div", "nb-plano", corpo) : null;
  const legTx = leg ? k.$("div", "nb-leg", leg) : null;

  const tn = c.batidas.valor != null ? c.batidas.valor : c.t + 0.15;
  const dur = 0.9 * vel;

  // bloco: vem de longe, gira até parar de frente
  k.tl.fromTo(bloco,
    { z: -70 * U, scale: 0.7, opacity: 0, rotationY: -28 * sinal, rotationX: 10, transformOrigin: "50% 50%" },
    { z: 0, scale: 1, opacity: 1, rotationY: 0, rotationX: 0, duration: dur, ease: "power3.out" }, tn);
  if (num) k.contar(bloco.querySelector(".nb-v"), { ...num, depois: "" }, tn + 0.05, dur, true);

  // unidade: encaixa ao lado depois que o bloco pousa
  const tu = tn + dur * 0.8;
  if (un) {
    k.tl.fromTo(un,
      { x: 14 * U, z: -20 * U, opacity: 0, rotationY: 40 * sinal },
      { x: 0, z: 0, opacity: 1, rotationY: 0, duration: 0.55 * vel, ease: "back.out(1.6)" }, tu);
  }

  // legenda: plano à frente do bloco
  if (leg) {
    const tl0 = tu + 0.25 * vel;
    k.tl.fromTo(leg, { z: 0, y: 4 * U, opacity: 0 }, { z: 14 * U, y: 0, opacity: 1, duration: 0.6 * vel, ease: k.SUAVE }, tl0);
    k.palavras(legTx, e.legenda, tl0 + 0.1, 0.06 * vel);
  }

  // a câmera respira até o fim
  const t0 = tn + dur * 0.6;
  const resto = Math.max(1, c.ate - t0);
  k.tl.fromTo(palco, { rotationY: -4 * sinal, rotationX: 2 }, { rotationY: 5 * sinal, rotationX: -2, duration: resto, ease: "none" }, t0);
});
