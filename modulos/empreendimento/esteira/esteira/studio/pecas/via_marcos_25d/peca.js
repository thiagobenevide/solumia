// Via de marcos 2,5D: cartões (ano + rótulo) vêm de longe por uma estrada em perspectiva; o destaque para no centro, com foto opcional.
ESTUDIO.peca("via_marcos_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");

  const lista = (e.marcos || []).map((m) => ({
    ano: String((m && (m.rotulo != null ? m.rotulo : m.ano)) || ""),
    txt: String((m && (m.valor != null ? m.valor : m.texto)) || ""),
  })).filter((m) => m.ano || m.txt);
  if (!lista.length) return;

  let d = lista.length - 1;
  if (e.destaque) {
    const alvo = String(e.destaque).trim();
    const i = lista.findIndex((m) => m.ano.trim() === alvo);
    if (i >= 0) d = i;
  }
  const marcos = lista.slice(0, d + 1);
  const n = marcos.length;
  const im = e.imagem;
  const src = typeof im === "string" ? im : (im && (im.url || im.src || im.caminho)) || "";

  const dur = Math.max(3, c.ate - c.t);
  const passo = n > 1 ? Math.min(1.8, Math.max(0.7, (dur - 0.2 - 1.8) / (n - 1))) : 0;
  const tempo = (i) => c.t + 0.2 + i * passo;

  // saída lateral contida: nunca ultrapassa a área segura
  const sx = k.V ? 8 : 38;
  const sz = k.V ? 5 : 20;

  // estrada (2D, converge no horizonte)
  const via = k.$("div", "ve-via", box);
  const eixo = k.$("div", "ve-eixo", box);
  k.$("div", "ve-horizonte", box);
  k.tl.fromTo(via, { opacity: 0 }, { opacity: 1, duration: 0.6, ease: k.SUAVE }, c.t);
  k.tl.fromTo(eixo, { opacity: 0, backgroundPosition: "0px 0px" },
    { opacity: 1, backgroundPosition: "0px " + (dur * 14 * U) + "px", duration: dur, ease: "none" }, c.t);

  // cena em perspectiva
  const cena = k.$("div", "ve-cena", box);
  const palco = k.$("div", "ve-palco", cena);
  if (b.camera !== "fixa") {
    k.tl.fromTo(palco, { rotationY: 2 }, { rotationY: -2, duration: dur, ease: "none" }, c.t);
  }

  const lado = (i) => (b.passagem === "esquerda" ? -1 : b.passagem === "direita" ? 1 : (i % 2 ? 1 : -1));

  marcos.forEach((m, i) => {
    const ehD = i === d;
    const card = k.$("div", "ve-card" + (ehD ? " ve-d" : ""), palco);
    let foto = null;
    if (ehD && src) {
      foto = k.$("div", "ve-foto", card);
      const img = k.$("img", "ve-img", foto);
      img.setAttribute("src", src);
      img.setAttribute("alt", "");
    }
    k.$("div", "ve-ano", card, k.esc(m.ano));
    if (m.txt) k.$("div", "ve-rot", card, k.esc(m.txt));
    k.tl.set(card, { xPercent: -50, yPercent: -50 }, 0);

    const ti = tempo(i), s = lado(i);
    k.tl.fromTo(card, { z: -130 * U, x: s * 6 * U, rotationY: -s * 8 },
      { z: 0, x: 0, rotationY: 0, duration: 0.9, ease: k.SUAVE }, ti);
    k.tl.fromTo(card, { opacity: 0 }, { opacity: 1, duration: 0.35, ease: "none" }, ti);

    if (!ehD) {
      const tn = tempo(i + 1);
      k.tl.fromTo(card, { x: 0, z: 0, rotationY: 0 },
        { x: s * sx * U, z: sz * U, rotationY: s * 14, duration: 0.7, ease: "power2.in", immediateRender: false }, tn);
      k.tl.fromTo(card, { opacity: 1 }, { opacity: 0, duration: 0.45, ease: "none", immediateRender: false }, tn + 0.15);
    } else if (foto) {
      k.tl.fromTo(foto, { clipPath: "inset(0 0 100% 0)" },
        { clipPath: "inset(0 0 0% 0)", duration: 0.7, ease: k.SUAVE }, ti + 0.5);
    }
  });

  // progresso: um ponto por marco
  const prog = k.$("div", "ve-prog", box);
  marcos.forEach((m, i) => {
    const p = k.$("span", "ve-ponto", prog);
    k.tl.fromTo(p, { opacity: 0.3, scale: 1 }, { opacity: 1, scale: 1.3, duration: 0.3, ease: k.SUAVE }, tempo(i) + 0.4);
  });
});
