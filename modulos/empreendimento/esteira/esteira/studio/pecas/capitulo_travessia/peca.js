// Abertura de capítulo "travessia": número desenhado a traço, título ao lado, linha que varre a tela e barra de progresso.
// Botão perspectiva=camera: a câmera atravessa o contorno do número (CSS 3D).
ESTUDIO.peca("capitulo_travessia", (k, c, box) => {
  const { U, V } = k;
  const e = c.encaixes, b = c.botoes;
  const t = c.t;
  const cam = b.perspectiva === "camera";
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");
  if (cam) box.classList.add("ct-cam");

  // número do capítulo e total
  const digitos = String(e.numero == null ? "" : e.numero).replace(/\D/g, "").slice(0, 2);
  const atual = Math.max(1, parseInt(digitos, 10) || 1);
  const num = String(atual).padStart(2, "0");
  const total = Math.max(atual, parseInt(String(e.total == null ? "" : e.total).replace(/\D/g, ""), 10) || atual);

  // linha que varre a tela (atrás do conteúdo)
  const modoLinha = b.varredura || "horizontal";
  if (modoLinha !== "nenhuma") {
    const ln = k.$("div", "ct-varre ct-" + modoLinha, box);
    if (modoLinha === "vertical") {
      k.tl.fromTo(ln, { x: 0, opacity: 0 }, { x: k.W, opacity: 1, duration: 0.9, ease: "power2.inOut" }, t);
      k.tl.to(ln, { opacity: 0, duration: 0.2 }, t + 0.8);
    } else {
      k.tl.set(ln, { transformOrigin: "left center" }, t);
      k.tl.fromTo(ln, { scaleX: 0, opacity: 1 }, { scaleX: 1, duration: 0.55, ease: "power2.out" }, t);
      k.tl.set(ln, { transformOrigin: "right center" }, t + 0.55);
      k.tl.to(ln, { scaleX: 0, duration: 0.45, ease: "power2.in" }, t + 0.6);
    }
  }

  const cena = k.$("div", "ct-cena", box);
  const palco = k.$("div", "ct-palco", cena);
  const corpo = k.$("div", "ct-corpo", palco);

  // número desenhado a traço
  const h = (V ? 22 : 30) * U;
  const W = num.length * 62 + 14;
  const svg = (cls) => `<svg class="${cls}" viewBox="0 0 ${W} 100" style="width:${(W / 100 * h).toFixed(1)}px;height:${h}px"><text class="ct-t" x="${W / 2}" y="84" text-anchor="middle">${k.esc(num)}</text></svg>`;
  const nb = k.$("div", "ct-num", corpo, svg("ct-svg"));
  const txt = nb.querySelector(".ct-svg .ct-t");
  k.tl.fromTo(nb, { opacity: 0 }, { opacity: 1, duration: 0.1 }, t);
  k.tl.fromTo(txt, { strokeDashoffset: 2000 }, { strokeDashoffset: 0, duration: 1.1, ease: "power1.inOut" }, t + 0.05);
  k.tl.fromTo(txt, { fillOpacity: 0 }, { fillOpacity: 1, duration: 0.45, ease: k.SUAVE }, t + 0.95);

  if (cam) {
    // contorno-fantasma que a câmera atravessa
    const gh = k.$("div", "ct-gh", nb, svg("ct-svg ct-svg-gh"));
    const gt = gh.querySelector(".ct-t");
    k.tl.fromTo(gt, { strokeDashoffset: 2000 }, { strokeDashoffset: 0, duration: 0.9, ease: "power1.inOut" }, t + 0.05);
    k.tl.fromTo(gh, { z: 0, opacity: 0 }, { opacity: 1, duration: 0.1 }, t);
    k.tl.to(gh, { z: 95 * U, duration: 0.8, ease: "power2.in" }, t + 0.9);
    k.tl.to(gh, { opacity: 0, duration: 0.3, ease: "none" }, t + 1.4);
    k.tl.fromTo(nb, { z: -70 * U }, { z: 0, duration: 1.6, ease: k.SUAVE }, t);
    k.tl.fromTo(palco, { rotationY: -18, rotationX: 7 }, { rotationY: 0, rotationX: 0, duration: 1.7, ease: k.SUAVE }, t);
    const resto = Math.max(0.5, c.ate - t - 1.9);
    k.tl.to(palco, { rotationY: 5, rotationX: -2, duration: resto, ease: "none" }, t + 1.7);
  } else {
    k.tl.fromTo(nb, { scale: 0.92 }, { scale: 1, duration: 1.2, ease: k.SUAVE }, t);
  }

  // coluna de texto: kicker + título
  const col = k.$("div", "ct-col", corpo);
  k.kicker(col, "Capítulo " + num, t + 0.5);
  const tit = k.$("div", "ct-tit", col);
  k.palavras(tit, e.titulo || "", t + 0.7, 0.07);

  // barra de progresso dos capítulos
  const n = Math.min(total, 12);
  const idxAtual = total <= 12 ? atual - 1 : Math.round((atual - 1) / (total - 1) * (n - 1));
  const bar = k.$("div", "ct-bar", palco);
  const segs = [];
  for (let i = 0; i < n; i++) {
    const s = k.$("div", "ct-seg" + (i < idxAtual ? " feito" : i === idxAtual ? " on" : ""), bar);
    k.$("i", "ct-pre", s);
    segs.push(s);
  }
  k.tl.fromTo(segs, { scaleX: 0, opacity: 0 }, { scaleX: 1, opacity: 1, duration: 0.35, ease: k.SUAVE, stagger: 0.04, transformOrigin: "left center" }, t + 1.0);
  k.tl.fromTo(segs[idxAtual].querySelector(".ct-pre"), { scaleX: 0 }, { scaleX: 1, duration: 0.6, ease: k.SUAVE }, t + 1.3);
  k.tl.fromTo(segs[idxAtual], { scaleY: 1 }, { scaleY: 1.9, duration: 0.25, yoyo: true, repeat: 1, ease: "sine.inOut" }, t + 1.3);
});
