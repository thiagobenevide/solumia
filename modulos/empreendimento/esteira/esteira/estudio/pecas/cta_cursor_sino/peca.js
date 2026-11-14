// CTA gráfico: inscrever (cursor + botão + sino + contador), comentar (bolha) e próximo vídeo (cartão, opcional 2,5D).
ESTUDIO.peca("cta_cursor_sino", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const acao = ["inscrever", "comentar", "proximo_video"].includes(e.acao) ? e.acao : "inscrever";
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");
  const corpo = k.$("div", "cc-corpo", box);
  const t0 = c.t;
  const txt = k.$("div", "cc-texto", corpo);
  k.palavras(txt, e.texto, t0 + 0.1, 0.07);
  const palco = k.$("div", "cc-palco", corpo);

  if (acao === "inscrever") {
    const linha = k.$("div", "cc-linha", palco);
    const bt = k.$("div", "cc-bt", linha,
      '<span class="cc-ok"></span><span class="cc-l1">Inscrever-se</span><span class="cc-l2">Inscrito ✓</span>');
    const sino = k.$("div", "cc-sino", linha,
      '<svg viewBox="0 0 24 24"><path fill="currentColor" d="M12 2a1.5 1.5 0 0 1 1.5 1.5v.6A6.5 6.5 0 0 1 18.5 10.5v4l2 3v1h-17v-1l2-3v-4A6.5 6.5 0 0 1 10.5 4.1v-.6A1.5 1.5 0 0 1 12 2zm-2.2 18h4.4a2.2 2.2 0 0 1-4.4 0z"/></svg>');
    const cur = k.$("div", "cc-cursor", bt,
      '<svg viewBox="0 0 24 24"><path d="M5 3l14 8-6 2 4 7-3 1.5-4-7-5 4z" fill="var(--texto)" stroke="var(--fundo)" stroke-width="1.2" stroke-linejoin="round"/></svg>');
    k.entra(bt, t0 + 0.5, { de: { y: 3 * U, scale: 0.9 } });
    k.entra(sino, t0 + 0.6, { de: { y: 2 * U, scale: 0.8 } });
    k.tl.set(sino, { transformOrigin: "50% 10%" }, 0);
    k.tl.fromTo(cur, { x: 22 * U, y: 16 * U, opacity: 0 }, { x: 0, y: 0, opacity: 1, duration: 0.7, ease: k.SUAVE }, t0 + 0.9);
    // aperto
    k.tl.to(bt, { scale: 0.93, duration: 0.1, ease: "power2.in" }, t0 + 1.7);
    k.tl.to(bt, { scale: 1, duration: 0.3, ease: "back.out(3)" }, t0 + 1.8);
    k.tl.to(bt.querySelector(".cc-ok"), { opacity: 1, duration: 0.15 }, t0 + 1.75);
    k.tl.to(bt.querySelector(".cc-l1"), { opacity: 0, duration: 0.12 }, t0 + 1.75);
    k.tl.to(bt.querySelector(".cc-l2"), { opacity: 1, duration: 0.15 }, t0 + 1.8);
    k.tl.to(cur, { x: 7 * U, y: 7 * U, opacity: 0, duration: 0.4, ease: k.SUAVE }, t0 + 2.05);
    // sino balança
    [18, -16, 12, -9, 5, 0].forEach((r, i) => {
      k.tl.to(sino, { rotation: r, duration: 0.12, ease: "sine.inOut" }, t0 + 1.85 + i * 0.12);
    });
    // contador de inscritos
    if (e.detalhe) {
      const det = k.$("div", "cc-det", corpo);
      const num = b.contador === "nao" ? null : k.numero(e.detalhe);
      if (num) {
        det.innerHTML = '<span class="cc-v"></span><small>' + k.esc(num.depois) + "</small>";
        k.entra(det, t0 + 1.2, { de: { y: 2 * U } });
        k.contar(det.querySelector(".cc-v"), { ...num, depois: "" }, t0 + 1.3, 1.4, true);
      } else {
        det.classList.add("cc-txt");
        det.innerHTML = k.esc(e.detalhe);
        k.entra(det, t0 + 1.2, { de: { y: 2 * U } });
      }
    }
  } else if (acao === "comentar") {
    const bolha = k.$("div", "cc-bolha", palco, "<span></span><span></span><span></span>");
    k.tl.fromTo(bolha, { scale: 0.5, opacity: 0 }, { scale: 1, opacity: 1, duration: 0.5, ease: "back.out(2)" }, t0 + 0.5);
    k.tl.to(bolha.querySelectorAll("span"), { y: -1.2 * U, duration: 0.25, stagger: 0.12, repeat: 3, yoyo: true, ease: "sine.inOut" }, t0 + 1.1);
    if (e.detalhe) {
      const det = k.$("div", "cc-det cc-txt", corpo);
      k.palavras(det, e.detalhe, t0 + 1.0, 0.06);
    }
  } else {
    const cena = k.$("div", "cc-cena", palco);
    const cartao = k.$("div", "cc-cartao", cena,
      '<div class="cc-mini"><i class="cc-play"></i></div><div class="cc-tit">' + k.esc(e.detalhe || "Próximo vídeo") + "</div>");
    const play = cartao.querySelector(".cc-play");
    if (b.profundidade === "cartao_3d") {
      cena.classList.add("cc-3d");
      k.tl.fromTo(cartao, { z: -70 * U, y: 6 * U, rotationY: -35, rotationX: 12, opacity: 0 },
        { z: 0, y: 0, rotationY: -14, rotationX: 6, opacity: 1, duration: 1.0, ease: k.SUAVE }, t0 + 0.5);
      const dur = Math.max(0.5, c.ate - t0 - 2.2);
      k.tl.to(cartao, { rotationY: -6, rotationX: 2, duration: dur, ease: "none" }, t0 + 1.6);
    } else {
      k.entra(cartao, t0 + 0.5, { de: { y: 4 * U, scale: 0.92 } });
    }
    k.tl.to(play, { scale: 1.15, duration: 0.4, repeat: 3, yoyo: true, ease: "sine.inOut" }, t0 + 1.5);
  }
});
