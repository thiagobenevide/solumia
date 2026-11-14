// Pergunta gancho: a frase entra palavra por palavra, a palavra-chave ganha destaque, um "?" grande pulsa uma vez
// e, no fim, a pergunta encolhe para o canto e continua visível. Botão estilo=cartao: cartão que gira em profundidade.
ESTUDIO.peca("pergunta_gancho", (k, c, box) => {
  const { U, W, H } = k;
  const e = c.encaixes, b = c.botoes;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");

  const norm = (s) => String(s).normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]/g, "");
  const texto = String(e.pergunta || "").trim().replace(/[?\s]+$/, "");
  const alvo = new Set(String(e.destaque || "").split(/\s+/).map(norm).filter(Boolean));
  const palavras = texto.split(/\s+/).filter(Boolean);
  const carta = b.estilo === "cartao";
  if (carta) box.classList.add("pg-card");

  const wpx = (k.V ? 88 : 130) * U;
  const cena = k.$("div", "pg-cena", box);
  const corpo = k.$("div", "pg-corpo", cena);
  corpo.style.width = wpx + "px";
  const cartao = k.$("div", "pg-cartao", corpo);
  const frase = k.$("div", "pg-frase", cartao);

  const passo = 0.1, t0 = c.t + 0.2;
  const bat = c.batidas.destaque;
  palavras.forEach((p, i) => {
    const eh = alvo.has(norm(p));
    const w = k.$("span", "pg-w" + (eh ? " pg-d" : ""), frase, k.esc(p));
    const t = t0 + i * passo;
    k.entra(w, t, { de: { y: 2 * U } });
    if (eh) {
      const sub = k.$("i", "pg-sub", w);
      const tp = Math.max(bat != null ? bat : 0, t + 0.15);
      k.tl.fromTo(sub, { scaleX: 0 }, { scaleX: 1, duration: 0.4, ease: k.SUAVE }, tp);
      k.tl.to(w, { scale: 1.14, duration: 0.15, yoyo: true, repeat: 1, ease: "power2.out" }, tp);
    }
  });

  // "?" grande: entra e pulsa uma vez
  const tq = t0 + palavras.length * passo + 0.1;
  const q = k.$("div", "pg-q", cartao, "?");
  k.tl.fromTo(q, { scale: 0.4, opacity: 0 }, { scale: 1, opacity: 1, duration: 0.35, ease: "back.out(2)" }, tq);
  k.tl.to(q, { scale: 1.2, duration: 0.18, yoyo: true, repeat: 1, ease: "power2.out" }, tq + 0.45);

  // posição inicial: centro (sem medir nada)
  k.tl.set(corpo, { xPercent: -50, yPercent: -50 }, 0);

  // encolhe para o canto superior
  let ts = Math.max(tq + 0.9, c.ate - 1.6);
  if (ts + 0.8 > c.ate - 0.1) ts = Math.max(tq + 0.6, c.ate - 0.9);
  const s = k.V ? 0.5 : 0.4, m = 6 * U;
  const x = b.canto === "direita" ? W / 2 - m - wpx * s : m - W / 2;
  k.tl.to(corpo, { x, y: m - H / 2, xPercent: 0, yPercent: 0, scale: s, duration: 0.8, ease: k.SUAVE }, ts);

  if (carta) {
    k.entra(cartao, c.t, { de: { y: 3 * U } });
    k.tl.fromTo(cartao, { rotationY: -28, rotationX: 8 }, { rotationY: 10, rotationX: -2, duration: Math.max(0.5, ts - c.t), ease: "sine.inOut" }, c.t);
    k.tl.to(cartao, { rotationY: 0, rotationX: 0, duration: 0.8, ease: k.SUAVE }, ts);
  }
});
