// Monitor em perspectiva (2,5D): uma tela inclinada chega de longe girando, o conteúdo entra nela, um reflexo passa
// e a tela respira devagar durante a fala. Só CSS 3D (perspective + rotationY/rotationX/z do GSAP).
ESTUDIO.peca("monitor_perspectiva", (k, c, raiz) => {
  const e = c.encaixes, b = c.botoes;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");
  const lado = b.lado === "esquerda" ? -1 : 1;
  const ang = (b.inclinacao === "forte" ? 26 : 15) * lado;
  const cena = k.$("div", "mp-cena", raiz);
  const tela = k.$("div", "mp-tela", cena, '<div class="mp-barra"><i></i><i></i><i></i></div><div class="mp-conteudo"></div>');
  const cont = tela.querySelector(".mp-conteudo");
  const t0 = c.t, dur = Math.max(1.5, c.ate - c.t);
  k.tl.fromTo(tela, { rotationY: ang * 2.4, rotationX: 10, z: -70 * k.U, opacity: 0 },
    { rotationY: ang, rotationX: 4, z: 0, opacity: 1, duration: 1.1, ease: k.SUAVE }, t0);
  k.tl.to(tela, { rotationY: ang * 0.65, rotationX: 2, duration: Math.max(0.5, dur - 1.3), ease: "none" }, t0 + 1.1);
  if (e.rotulo) k.entra(k.$("div", "mp-rot", cont, k.esc(e.rotulo)), t0 + 0.45, { de: { y: 1.5 * k.U } });
  const tit = k.$("div", "mp-tit", cont, k.rico(e.titulo || ""));
  k.entra(tit, c.batidas.titulo != null ? c.batidas.titulo : t0 + 0.55, { de: { y: 2 * k.U } });
  const itens = (e.itens || []).slice(0, 3);
  const passo = Math.min(0.35, (dur - 1.4) / Math.max(itens.length, 1));
  itens.forEach((x, i) => k.entra(k.$("div", "mp-item", cont, k.rico(x)), t0 + 0.9 + i * passo, { de: { x: -2 * k.U, y: 0 } }));
  const reflexo = k.$("div", "mp-reflexo", tela);
  k.tl.fromTo(reflexo, { xPercent: -140 }, { xPercent: 140, duration: 1.5, ease: "power2.inOut" }, t0 + 0.7);
});
