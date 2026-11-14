// Estrada do tempo: marcos vêm de longe pela via em perspectiva; o atual para no centro (foto opcional).
ESTUDIO.peca("estrada_tempo_25d", (k, c, box) => {
  const { U, V } = k;
  const e = c.encaixes, b = c.botoes;
  const marcos = (Array.isArray(e.marcos) ? e.marcos : []).slice(0, 6);
  const n = marcos.length;
  if (!n) return;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");

  let d = n - 1;
  if (e.destaque) {
    const q = String(e.destaque).trim().toLowerCase();
    const ix = marcos.findIndex((m) => String(m.rotulo).trim().toLowerCase() === q);
    if (ix >= 0) d = ix;
  }
  const f = e.foto;
  const src = typeof f === "string" ? f : f && (f.src || f.url || f.caminho);

  const dur = Math.max(3, c.ate - c.t);
  const s = Math.min(1.4, Math.max(0.7, (dur - 2.8) / (d + 1)));
  const t0 = c.t + 0.2;

  const cena = k.$("div", "et-cena", box);
  const palco = k.$("div", "et-palco", cena);
  const chao = k.$("div", "et-chao", palco);
  const eixo = k.$("div", "et-eixo et-m-" + (b.marcacao || "tracejada"), chao);

  k.tl.set(chao, { rotationX: 90, z: 60 * U, transformOrigin: "50% 100%" }, c.t);
  k.tl.fromTo(chao, { autoAlpha: 0 }, { autoAlpha: 1, duration: 0.6, ease: k.SUAVE }, c.t);
  const voltas = Math.max(2, Math.round(dur * 1.5));
  k.tl.fromTo(eixo, { backgroundPositionY: 0 }, { backgroundPositionY: 20 * U * voltas, duration: dur, ease: "none" }, c.t);
  if (b.camera !== "fixa") {
    k.tl.fromTo(palco, { rotationY: -5, rotationX: 3 }, { rotationY: 5, rotationX: -1, duration: dur, ease: "none" }, c.t);
  }

  marcos.forEach((m, i) => {
    const eh = i === d;
    const espera = i > d;
    const card = k.$("div", "et-card" + (eh ? " et-foco" : "") + (espera ? " et-espera" : ""), palco);
    let foto = null;
    if (eh && src) foto = k.$("div", "et-foto", card, `<img src="${k.esc(src)}" alt="">`);
    k.$("div", "et-ano", card, k.esc(m.rotulo));
    if (!espera) k.$("div", "et-rot", card, k.esc(m.valor));
    k.tl.set(card, { xPercent: -50, yPercent: -50, autoAlpha: 0 }, c.t);

    if (espera) {
      const j = i - d - 1;
      const lado = j % 2 ? 1 : -1;
      const x = lado * (V ? 22 : 36) * U;
      const z = -(60 + 40 * j) * U;
      const ta = t0 + s * (d + 1) + 0.3 + j * 0.15;
      k.tl.fromTo(card, { x, y: -4 * U, z: z - 80 * U, autoAlpha: 0 },
        { z, autoAlpha: 0.6, duration: 0.7, ease: k.SUAVE }, ta);
      return;
    }

    const a = t0 + s * (i + 1);
    if (eh) {
      const tr = s * 1.3;
      k.tl.fromTo(card, { x: 0, y: -6 * U, z: -300 * U }, { z: 0, duration: tr, ease: "power3.out" }, a - tr);
      k.tl.to(card, { autoAlpha: 1, duration: 0.3, ease: "none" }, a - tr);
      k.tl.fromTo(card, { scale: 1.06 }, { scale: 1, duration: 0.5, ease: k.SUAVE }, a);
      if (foto) k.tl.fromTo(foto, { autoAlpha: 0 }, { autoAlpha: 1, duration: 0.5, ease: k.SUAVE }, a);
    } else {
      const tr = s * 1.1;
      const lado = i % 2 ? 1 : -1;
      k.tl.fromTo(card, { x: 0, y: -4 * U, z: -300 * U }, { z: 0, duration: tr, ease: "power2.out" }, a - tr);
      k.tl.to(card, { autoAlpha: 1, duration: 0.3, ease: "none" }, a - tr);
      k.tl.to(card, {
        z: 35 * U, x: V ? 0 : lado * 30 * U, y: V ? -30 * U : -4 * U,
        autoAlpha: 0, duration: s * 0.75, ease: "power2.in",
      }, a + s * 0.35);
    }
  });
});
