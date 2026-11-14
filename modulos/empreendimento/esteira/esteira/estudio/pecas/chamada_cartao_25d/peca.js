// Chamada em cartão 2,5D: cartão em perspectiva com camadas atrás, ação, linha de apoio e botão que o cursor aperta.
ESTUDIO.peca("chamada_cartao_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const dir = b.inclinacao === "direita" ? 1 : -1;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");

  const ICONES = {
    inscrever: '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M12 22a2 2 0 0 0 2-2h-4a2 2 0 0 0 2 2zm6-6v-5a6 6 0 0 0-5-5.9V4a1 1 0 0 0-2 0v1.1A6 6 0 0 0 6 11v5l-2 2v1h16v-1z"/></svg>',
    comentar: '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M4 3h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H9l-5 4v-4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z"/></svg>',
    proximo: '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M6 3.5l14 8.5-14 8.5z"/></svg>'
  };
  const destino = ICONES[b.destino] ? b.destino : "inscrever";

  const cena = k.$("div", "cc-cena", box);
  const palco = k.$("div", "cc-palco", cena);
  k.$("div", "cc-atras cc-a2", palco);
  k.$("div", "cc-atras cc-a1", palco);
  const card = k.$("div", "cc-card", palco);
  const acao = k.$("div", "cc-acao", card);
  const det = e.detalhe ? k.$("div", "cc-det", card) : null;
  const bot = k.$("div", "cc-botao", card);
  const ico = k.$("span", "cc-ico", bot, ICONES[destino]);
  k.$("span", "cc-bt", bot, k.esc(e.botao));
  const onda = k.$("div", "cc-onda", bot);
  const cur = k.$("div", "cc-cursor", card,
    '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 2l14 10-6.2 1.2L16 20l-3 1.4-3.2-6.6L5 19z" fill="var(--texto)" stroke="var(--fundo)" stroke-width="1.4" stroke-linejoin="round"/></svg>');

  const tn = c.batidas.acao != null ? c.batidas.acao : c.t + 0.15;
  const total = Math.max(1.5, c.ate - tn);

  // chegada do fundo
  k.tl.fromTo(palco,
    { opacity: 0, z: -70 * U, rotationY: dir * 32, rotationX: 8, y: 4 * U },
    { opacity: 1, z: 0, rotationY: dir * 14, rotationX: 4, y: 0, duration: 1.0, ease: k.SUAVE }, tn);
  // camadas atrás se abrem
  k.tl.fromTo(".p-chamada_cartao_25d .cc-a1", { z: 0, opacity: 0 }, { z: -5 * U, opacity: 1, duration: 0.9, ease: k.SUAVE }, tn + 0.3);
  k.tl.fromTo(".p-chamada_cartao_25d .cc-a2", { z: 0, opacity: 0 }, { z: -10 * U, opacity: 1, duration: 0.9, ease: k.SUAVE }, tn + 0.4);
  // a câmera respira até o fim
  k.tl.to(palco, { rotationY: dir * 7, rotationX: 1.5, duration: Math.max(0.6, total - 1.0), ease: "none" }, tn + 1.0);

  k.palavras(acao, e.acao, tn + 0.35, 0.07);
  if (det) k.palavras(det, e.detalhe, tn + 0.8, 0.04);
  k.entra(bot, tn + 0.7, { de: { y: 2 * U, scale: 0.9 } });

  // cursor aperta o botão
  const tp = Math.min(tn + 1.7, Math.max(tn + 1.0, c.ate - 0.9));
  k.tl.fromTo(cur, { opacity: 0, x: 22 * U, y: 16 * U }, { opacity: 1, x: 0, y: 0, duration: 0.7, ease: k.SUAVE }, tp - 0.7);
  k.tl.to(bot, { scale: 0.92, duration: 0.1, ease: "power2.in" }, tp);
  k.tl.to(cur, { scale: 0.85, duration: 0.1 }, tp);
  k.tl.to(bot, { scale: 1, duration: 0.35, ease: "back.out(3)" }, tp + 0.1);
  k.tl.to(cur, { scale: 1, duration: 0.2 }, tp + 0.1);
  k.tl.fromTo(onda, { scale: 0.8, opacity: 0.9 }, { scale: 1.7, opacity: 0, duration: 0.7, ease: "power2.out" }, tp);
  k.tl.fromTo(ico, { rotation: 0 }, { keyframes: [{ rotation: -18 }, { rotation: 14 }, { rotation: -8 }, { rotation: 0 }], duration: 0.6, ease: "power1.inOut" }, tp + 0.1);
  if (!k.PROIB.has("flash")) k.flash(tp);
});
