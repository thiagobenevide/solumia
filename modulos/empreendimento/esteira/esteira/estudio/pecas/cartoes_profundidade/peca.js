// Cartões em profundidade (2,5D): 2 a 4 cartões chegam do fundo e se arrumam em camadas (leque ou fila); a câmera
// gira devagar em volta e o último cartão fica em destaque. Só CSS 3D (translateZ/rotationY via GSAP).
ESTUDIO.peca("cartoes_profundidade", (k, c, raiz) => {
  const e = c.encaixes, b = c.botoes;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");
  const vel = { lenta: 1.4, normal: 1.0, rapida: 0.7 }[b.velocidade] || 1.0;
  const cena = k.$("div", "cp-cena", raiz);
  if (e.titulo) k.entra(k.$("div", "cp-tit", raiz, k.rico(e.titulo)), c.t, { de: { y: 2 * k.U } });
  const palco = k.$("div", "cp-palco", cena);
  const itens = (e.itens || []).slice(0, 4);
  const n = itens.length, leque = b.arranjo !== "fila";
  itens.forEach((x, i) => {
    const ult = i === n - 1;
    const card = k.$("div", "cp-card" + (ult ? " cp-ult" : ""), palco,
      `<div class="cp-n">${String(i + 1).padStart(2, "0")}</div><div class="cp-tx">${k.rico(x)}</div>`);
    const meio = (n - 1) / 2;
    const alvo = leque
      ? { x: (i - meio) * (k.V ? 4 : (n > 3 ? 37 : 44)) * k.U, y: (i - meio) * (k.V ? 21 : 2) * k.U, z: -(n - 1 - i) * 6 * k.U,
          rotationY: (i - meio) * -8 }
      : { x: (i - meio) * (k.V ? 3 : 12) * k.U, y: (i - meio) * (k.V ? 20 : 15) * k.U, z: -(n - 1 - i) * 18 * k.U, rotationY: -14 };
    const t = c.t + 0.3 + i * 0.35 * vel;
    k.tl.fromTo(card, { x: alvo.x * 0.3, y: alvo.y + 10 * k.U, z: -120 * k.U, rotationY: alvo.rotationY - 40, opacity: 0 },
      { ...alvo, opacity: ult ? 1 : 0.92, duration: 0.9 * vel, ease: k.SUAVE }, t);
  });
  const fim = Math.max(c.t + 1.5, c.ate - 0.3);
  k.tl.fromTo(palco, { rotationY: 8 }, { rotationY: -8, duration: Math.max(1, fim - c.t), ease: "none" }, c.t);
});
