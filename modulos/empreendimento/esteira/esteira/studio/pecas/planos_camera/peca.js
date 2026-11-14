// Câmera passando por planos (2,5D): palavras-chave em planos de profundidade; a câmera avança atravessando os planos
// da frente e para no título, que fica nítido enquanto o resto desfoca. Para viradas e ideias-chave.
ESTUDIO.peca("planos_camera", (k, c, raiz) => {
  const e = c.encaixes, b = c.botoes;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");
  const cena = k.$("div", "pc-cena", raiz);
  const mundo = k.$("div", "pc-mundo", cena);
  const palavras = (e.palavras || []).slice(0, 4);
  const prof = b.profundidade === "funda" ? 70 : 45;
  palavras.forEach((w, i) => {
    const el = k.$("div", "pc-plano", mundo, k.esc(w));
    const lado = i % 2 ? 1 : -1;
    k.tl.set(el, { x: lado * (k.V ? 14 : 34) * k.U, y: (i % 3 - 1) * (k.V ? 22 : 14) * k.U, z: (i + 1) * prof * k.U * 0.6 });
  });
  const tit = k.$("div", "pc-tit", mundo, k.rico(e.titulo || ""));
  k.tl.set(tit, { z: 0 });
  const dur = Math.max(1.6, c.ate - c.t);
  // a câmera começa atrás dos planos (mundo empurrado para perto) e avança até o título
  k.tl.fromTo(mundo, { z: -(palavras.length + 1) * prof * k.U * 0.6 - 20 * k.U, rotationY: -6 },
    { z: 0, rotationY: 4, duration: Math.min(2.2, dur * 0.6), ease: k.SUAVE }, c.t);
  k.tl.to(mundo, { z: 8 * k.U, rotationY: 6, duration: Math.max(0.4, dur - Math.min(2.2, dur * 0.6)), ease: "none" },
    c.t + Math.min(2.2, dur * 0.6));
  const viagem = Math.min(2.2, dur * 0.6);
  const planos = mundo.querySelectorAll(".pc-plano");
  k.tl.fromTo(planos, { opacity: 0 }, { opacity: 0.55, duration: 0.5, stagger: 0.1 }, c.t);
  // a câmera atravessa os planos: cada um some quando ela passa (o da frente primeiro), o título fica sozinho
  k.tl.to([...planos].reverse(), { opacity: 0, duration: 0.35, stagger: viagem * 0.15 }, c.t + viagem * 0.45);
  const ttit = c.batidas.titulo != null ? Math.max(c.t + 0.3, c.batidas.titulo - 0.2) : c.t + 0.6;
  k.tl.fromTo(tit, { opacity: 0, filter: "blur(16px)" }, { opacity: 1, filter: "blur(0px)", duration: 0.9, ease: k.SUAVE }, ttit);
});
