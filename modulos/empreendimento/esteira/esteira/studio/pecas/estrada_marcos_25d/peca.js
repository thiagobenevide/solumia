// Estrada de marcos 2,5D: a câmera avança por uma estrada e os marcos vêm de longe; o atual chega ao centro em destaque.
ESTUDIO.peca("estrada_marcos_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const lista = (Array.isArray(e.marcos) ? e.marcos : []).filter(m => m && (m.rotulo || m.valor)).slice(0, 6);
  if (!lista.length) return;
  const alvo = String(e.destaque || "").trim().toLowerCase();
  let h = lista.length - 1;
  if (alvo) {
    const q = lista.findIndex(m => String(m.rotulo).trim().toLowerCase() === alvo);
    if (q >= 0) h = q;
  }
  const itens = lista.slice(0, h + 1), n = itens.length;
  const f = e.foto;
  const src = typeof f === "string" ? f : ((f && (f.url || f.src || f.caminho)) || "");

  if (c.takeover) k.fundo(c);
  else { k.veu(c, "baixo"); box.classList.add("es25-leve"); }

  const cena = k.$("div", "es25-cena", box);
  const giro = k.$("div", "es25-giro", cena);
  const palco = k.$("div", "es25-palco", giro);
  k.$("div", "es25-estrada", palco, '<div class="es25-faixa"></div>');

  const passo = 60 * U, z0 = -12 * U;
  const zf = i => i * passo + z0;
  const roadY = (k.V ? 34 : 24) * U;
  const yM = (k.V ? -6 : -2) * U, yH = (k.V ? -16 : -10) * U;
  const xs = (k.V ? 25 : 34) * U;
  const lado = b.lado;
  const sinal = i => lado === "esquerda" ? -1 : lado === "direita" ? 1 : (i % 2 ? 1 : -1);

  const total = Math.max(1.2, c.ate - c.t - 0.9);
  const per = total / n;
  const dur = Math.min(1.2, per * 0.65);
  const T0 = c.t + 0.1;
  const chegada = i => T0 + 0.7 + i * per;
  const inicio = i => chegada(i) - dur;

  k.tl.set(palco, { z: zf(0) }, 0);

  itens.forEach((it, i) => {
    const hero = i === n - 1;
    const yc = hero ? yH : yM;
    const m = k.$("div", "es25-m" + (hero ? " es25-hero" : ""), palco);
    const poste = k.$("div", "es25-poste", m);
    poste.style.height = (roadY - yc) + "px";
    const card = k.$("div", "es25-card", m);
    let fo = null;
    if (hero && src) {
      fo = k.$("div", "es25-foto", card);
      fo.style.backgroundImage = 'url("' + String(src).replace(/"/g, "%22") + '")';
    }
    const an = k.$("div", "es25-ano", card, k.esc(String(it.rotulo || "")));
    const ro = k.$("div", "es25-rot", card, k.esc(String(it.valor || "")));
    k.tl.set(m, { xPercent: -50, yPercent: -50, x: hero ? 0 : sinal(i) * xs, y: yc, z: -i * passo }, 0);

    const rev = i <= 2 ? T0 + i * 0.12 : inicio(i - 2);
    k.tl.fromTo(m, { autoAlpha: 0 }, { autoAlpha: 1, duration: 0.5, ease: "power1.out" }, rev);
    k.tl.fromTo(card, { y: 2 * U }, { y: 0, duration: 0.6, ease: k.SUAVE }, rev);

    if (!hero) {
      const s = inicio(i + 1);
      k.tl.fromTo(m, { autoAlpha: 1 }, { autoAlpha: 0, duration: dur * 0.4, ease: "power1.in", immediateRender: false }, s);
      k.tl.set(m, { display: "none" }, s + dur * 0.4 + 0.02);
    } else {
      const ta = chegada(i) - 0.3;
      k.tl.fromTo(card, { scale: 0.94 }, { scale: 1, duration: 0.6, ease: "back.out(1.6)", immediateRender: false }, ta);
      k.tl.fromTo([an, ro], { y: 1.5 * U, autoAlpha: 0 }, { y: 0, autoAlpha: 1, duration: 0.5, ease: k.SUAVE, stagger: 0.12 }, ta);
      if (fo) k.tl.fromTo(fo, { autoAlpha: 0, scale: 1.08 }, { autoAlpha: 1, scale: 1, duration: 0.8, ease: k.SUAVE }, ta);
    }
  });

  for (let i = 1; i < n; i++) {
    k.tl.fromTo(palco, { z: zf(i - 1) }, { z: zf(i), duration: dur, ease: "power2.inOut", immediateRender: false }, inicio(i));
  }

  if (b.camera !== "fixa") {
    k.tl.fromTo(giro, { rotationY: -5, rotationX: 2.5 }, { rotationY: 3, rotationX: 0.8, duration: Math.max(1, c.ate - c.t), ease: "sine.inOut" }, c.t);
  }
});
