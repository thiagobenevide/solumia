// CTA com botão: cursor aperta o botão, o rótulo muda, o sino balança e o contador de inscritos sobe.
// Com cenario=cartao_25d (e acao proximo_video), o cartão do vídeo chega do fundo, inclinado e com sombra.
ESTUDIO.peca("cta_botao_sino", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const vel = { lenta: 1.3, normal: 1.0, rapida: 0.7 }[b.velocidade] || 1.0;
  const a = String(e.acao || "").toLowerCase();
  const acao = a.includes("coment") ? "comentar" : (a.includes("prox") || a.includes("video")) ? "proximo_video" : "inscrever";
  const cartao = b.cenario === "cartao_25d" && acao === "proximo_video";
  const sv = (d) => `<svg viewBox="0 0 24 24"><path d="${d}"/></svg>`;
  const SINO = "M12 2a2 2 0 0 0-2 2v.7C7.2 5.6 6 8 6 10.5V15l-2 2.5V19h16v-1.5L18 15v-4.5c0-2.5-1.2-4.9-4-5.8V4a2 2 0 0 0-2-2zm-2.5 18a2.5 2.5 0 0 0 5 0z";
  const BALAO = "M4 3h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H9l-5 4v-4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z";
  const PLAY = "M7 4v16l14-8z";
  const CHECK = "M9 16.2 4.8 12l-1.8 1.8L9 19.8 21 7.8 19.2 6z";
  const SETA = "M3 2l7.5 19 2.7-7.8L21 10.5z";
  const ROT = { inscrever: ["Inscrever-se", "Inscrito"], comentar: ["Comentar", "Enviado"], proximo_video: ["Próximo vídeo", "Assistir"] }[acao];
  const ico1 = { inscrever: "", comentar: BALAO, proximo_video: PLAY }[acao];
  const glande = { inscrever: SINO, comentar: BALAO, proximo_video: PLAY }[acao];

  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");

  const t0 = c.t;
  const corpo = k.$("div", "cs-corpo" + (cartao ? " cs-cartao" : ""), box);

  // cartão do próximo vídeo (2,5D)
  let palco = null, barra = null, play = null;
  if (cartao) {
    const cena = k.$("div", "cs-cena", corpo);
    palco = k.$("div", "cs-palco", cena);
    k.$("div", "cs-thumb", palco, `<div class="cs-playc"><span class="cs-gl">${sv(PLAY)}</span></div><i class="cs-barra"><b></b></i>`);
    k.$("div", "cs-ctit", palco, k.esc(e.detalhe || e.texto));
    barra = palco.querySelector(".cs-barra b");
    play = palco.querySelector(".cs-playc");
  }

  const col = k.$("div", "cs-col", corpo);
  const txt = k.$("div", "cs-texto", col);
  k.palavras(txt, e.texto, t0 + 0.05, 0.06 * vel);

  const linha = k.$("div", "cs-linha", col);
  const bw = k.$("div", "cs-bw", linha);
  const btn = k.$("div", "cs-btn", bw);
  const fill = k.$("div", "cs-fill", btn);
  const l1 = k.$("div", "cs-l", btn, (ico1 ? `<span class="cs-gl">${sv(ico1)}</span>` : "") + `<span>${k.esc(ROT[0])}</span>`);
  const l2 = k.$("div", "cs-l", btn, `<span class="cs-gl">${sv(CHECK)}</span><span>${k.esc(ROT[1])}</span>`);
  const onda = k.$("div", "cs-onda", bw);
  const cur = k.$("div", "cs-cur", bw, sv(SETA));

  let sino = null;
  if (!cartao) {
    sino = k.$("div", "cs-sino", linha, `<span class="cs-gl">${sv(glande)}</span>` + (acao === "inscrever" ? '<i class="cs-ponto"></i>' : ""));
  }

  const num = acao === "inscrever" && e.detalhe ? k.numero(e.detalhe) : null;
  let cont = null, det = null;
  if (e.detalhe && !cartao) {
    if (num) cont = k.$("div", "cs-cont", col, `<span class="cs-v"></span><small>${k.esc(num.depois)}</small>`);
    else det = k.$("div", "cs-det", col);
  }

  // tempos
  const tb = t0 + 0.45 * vel;
  let tc = tb + 0.9 * vel;
  if (c.batidas.acao != null) tc = Math.min(Math.max(c.batidas.acao, tb + 0.5), Math.max(tb + 0.5, c.ate - 1.8));
  const ts = Math.max(tb + 0.1, tc - 0.8 * vel);

  if (palco) {
    k.tl.fromTo(palco, { z: -60 * U, rotationY: 34, rotationX: 10, y: 6 * U, opacity: 0 },
      { z: 0, rotationY: -10, rotationX: 4, y: 0, opacity: 1, duration: 1.0 * vel, ease: k.SUAVE }, t0);
    k.tl.to(palco, { rotationY: -4, rotationX: 2, duration: Math.max(0.5, c.ate - (t0 + 1.1)), ease: "none" }, t0 + 1.1);
    k.tl.fromTo(barra, { scaleX: 0 }, { scaleX: 0.35, duration: 1.2 * vel, ease: "none" }, tc);
    k.tl.fromTo(play, { scale: 1 }, { scale: 1.18, duration: 0.15, yoyo: true, repeat: 1, ease: "sine.inOut" }, tc);
  }

  k.entra(bw, tb, { de: { y: 3 * U, scale: 0.85 } });

  // cursor chega, aperta e sai
  k.tl.fromTo(cur, { x: 18 * U, y: 16 * U, opacity: 0 },
    { x: 0, y: 0, opacity: 1, duration: Math.max(0.3, tc - 0.1 - ts), ease: "power2.out" }, ts);
  k.tl.to(btn, { scale: 0.93, duration: 0.1, ease: "power1.in" }, tc - 0.1);
  k.tl.to(btn, { scale: 1, duration: 0.3, ease: "back.out(3)" }, tc);
  k.tl.to(cur, { scale: 0.85, duration: 0.1 }, tc - 0.1);
  k.tl.to(cur, { scale: 1, duration: 0.2 }, tc);
  k.tl.to(cur, { x: 16 * U, y: 18 * U, opacity: 0, duration: 0.5, ease: "power2.in" }, tc + 0.35);
  k.tl.fromTo(onda, { scale: 1, opacity: 0.8 }, { scale: 1.35, opacity: 0, duration: 0.6, ease: "power2.out" }, tc);

  // rótulo e fundo trocam de estado
  k.tl.to(fill, { opacity: 1, duration: 0.2 }, tc);
  k.tl.to(l1, { opacity: 0, y: -U, duration: 0.15 }, tc);
  k.tl.fromTo(l2, { opacity: 0, y: U }, { opacity: 1, y: 0, duration: 0.25 }, tc + 0.05);
  k.tl.set(l1, { opacity: 1 }, 0);
  k.tl.set(l1, { opacity: 0 }, tc + 0.15);

  // sino balança
  if (sino) {
    k.tl.fromTo(sino, { opacity: 0, scale: 0.3, rotation: 0, transformOrigin: "50% 8%" },
      { opacity: 1, scale: 1, duration: 0.3, ease: "back.out(2)" }, tc);
    [22, -18, 14, -10, 6, -3, 0].forEach((v, i) => {
      k.tl.to(sino, { rotation: v, duration: 0.11, ease: "sine.inOut" }, tc + 0.25 + i * 0.11);
    });
    const ponto = sino.querySelector(".cs-ponto");
    if (ponto) k.tl.fromTo(ponto, { scale: 0 }, { scale: 1, duration: 0.25, ease: "back.out(3)" }, tc + 0.3);
  }

  // contador / detalhe
  if (cont) {
    const aj = k.ajuste(c) || {};
    const dur = (aj.contagem_s || 1.2) * vel;
    k.tl.fromTo(cont, { opacity: 0, y: 2 * U }, { opacity: 1, y: 0, duration: 0.3, ease: k.SUAVE }, tc + 0.1);
    k.contar(cont.querySelector(".cs-v"), { ...num, depois: "" }, tc + 0.15, dur, true);
  }
  if (det) k.palavras(det, e.detalhe, tc + 0.15, 0.05 * vel);
});
