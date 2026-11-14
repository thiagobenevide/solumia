// Pergunta no canto: a frase entra palavra por palavra, a palavra-chave em destaque, um ? grande pulsa uma vez
// e, no fim, a pergunta encolhe para o canto e fica como gancho. Formato "cartao": a frase num cartão que gira em profundidade.
ESTUDIO.peca("pergunta_canto", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const vel = { lenta: 1.5, normal: 1.0, rapida: 0.65 }[b.velocidade] || 1.0;
  const cartao = b.formato === "cartao";
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");
  box.classList.add(cartao ? "pg-cartao" : "pg-texto");
  box.classList.add(b.canto === "direita" ? "pg-dir" : "pg-esq");

  const norm = (s) => s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9]/g, "");
  const texto = String(e.pergunta || "").replace(/[?\s]+$/, "");
  const ws = texto.split(/\s+/).filter(Boolean);
  const n = Math.max(ws.length, 1);
  const alvo = new Set(String(e.destaque || "").split(/\s+/).map(norm).filter(Boolean));
  let hi = ws.map((w, i) => (alvo.has(norm(w)) ? i : -1)).filter((i) => i >= 0);
  if (!hi.length && ws.length) hi = [ws.length - 1];

  const corpo = k.$("div", "pg-corpo", box);
  const cena = k.$("div", "pg-cena", corpo);
  const cart = k.$("div", "pg-cart", cena);
  const frase = k.$("div", "pg-frase", cart);
  const dur = Math.max(c.ate - c.t, 1);
  const t0 = c.t + 0.2;
  const step = Math.min(0.13 * vel, Math.max(0.05, (dur * 0.4) / n));

  let tp = t0;
  ws.forEach((w, i) => {
    const marca = hi.includes(i);
    const s = k.$("span", "pg-w" + (marca ? " pg-d" : ""), frase, k.esc(w));
    const ti = t0 + i * step;
    k.tl.fromTo(s, { opacity: 0, y: 2.5 * U }, { opacity: 1, y: 0, duration: 0.35, ease: k.SUAVE }, ti);
    if (marca) {
      const sub = k.$("i", "pg-sub", s);
      const tb = c.batidas.destaque != null ? Math.max(c.batidas.destaque, ti) : ti + 0.25;
      tp = Math.max(tp, tb);
      k.tl.fromTo(s, { scale: 1 }, { scale: 1.12, duration: 0.2, ease: "power2.out", yoyo: true, repeat: 1 }, tb);
      k.tl.fromTo(sub, { scaleX: 0 }, { scaleX: 1, duration: 0.45, ease: k.SUAVE }, tb);
    }
  });

  const q = k.$("div", "pg-q", cart, "?");
  const tq = Math.max(t0 + n * step + 0.1, tp + 0.1);
  k.tl.fromTo(q, { opacity: 0, scale: 0.4 }, { opacity: 1, scale: 1.35, duration: 0.35, ease: "back.out(2)" }, tq);
  k.tl.to(q, { scale: 1, duration: 0.45, ease: "power2.out" }, tq + 0.35);

  let ts = Math.min(Math.max(tq + 1.0, c.t + dur * 0.6), c.ate - 0.9);
  ts = Math.max(ts, tq + 0.8);

  if (cartao) {
    const ini = c.t, ent = 0.9;
    k.tl.fromTo(cart, { rotationY: -38, rotationX: 10, z: -20 * U, opacity: 0 },
      { rotationY: -10, rotationX: 3, z: 0, opacity: 1, duration: ent, ease: k.SUAVE }, ini);
    k.tl.fromTo(q, { z: 0 }, { z: 6 * U, duration: 0.5, ease: k.SUAVE }, tq);
    k.tl.to(cart, { rotationY: 9, rotationX: -2, duration: Math.max(0.1, ts - (ini + ent)), ease: "sine.inOut" }, ini + ent);
    k.tl.to(cart, { rotationY: 0, rotationX: 0, duration: 0.8, ease: "power3.inOut" }, ts);
  }

  const dx = (b.canto === "direita" ? -3 : 3) * U;
  k.tl.to(corpo, { scale: 0.4, x: dx, y: 3 * U, duration: 0.8, ease: "power3.inOut" }, ts);
});
