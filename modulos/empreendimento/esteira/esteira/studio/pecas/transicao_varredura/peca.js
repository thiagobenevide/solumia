// Transição de varredura: formas da paleta cobrem a tela e saem revelando a próxima cena.
ESTUDIO.peca("transicao_varredura", (k, c, box) => {
  const { U, W, H, tl } = k;
  const e = c.encaixes, b = c.botoes;
  const t0 = c.t;
  const d = Math.min(1.2, Math.max(0.6, c.ate - c.t));
  const dir = b.direcao || "esquerda_direita";
  const forma = b.forma || "diagonal";
  const vet = { esquerda_direita: [1, 0], direita_esquerda: [-1, 0], cima_baixo: [0, 1], baixo_cima: [0, -1] }[dir] || [1, 0];
  const base = { esquerda_direita: 0, direita_esquerda: 180, cima_baixo: 90, baixo_cima: 270 }[dir] || 0;
  const cores = ["ts-c1", "ts-c2", "ts-c3"];
  const palco = k.$("div", "ts-palco", box);

  if (forma === "faixas") {
    const N = 5, s = 0.025 * d;
    const horiz = vet[1] === 0;
    for (let i = 0; i < N; i++) {
      const f = k.$("div", "ts-faixa " + cores[i % 3], palco);
      f.style.cssText = horiz
        ? `left:0;width:100%;top:${(i * 100) / N}%;height:${100 / N + 0.5}%`
        : `top:0;height:100%;left:${(i * 100) / N}%;width:${100 / N + 0.5}%`;
      const p = horiz ? "xPercent" : "yPercent";
      const sg = horiz ? vet[0] : vet[1];
      const o = (sg > 0 ? i : N - 1 - i) * s;
      const ini = {}, meio = {}, fim = {};
      ini[p] = -101 * sg; meio[p] = 0; fim[p] = 101 * sg;
      tl.set(f, ini, t0);
      tl.to(f, { ...meio, duration: 0.4 * d, ease: "power3.out" }, t0 + o);
      tl.to(f, { ...fim, duration: 0.4 * d, ease: "power3.in" }, t0 + 0.5 * d + o);
    }
  } else if (forma === "iris") {
    const R = Math.hypot(W, H) * 0.8;
    const off = 0.25 * (vet[0] !== 0 ? W : H);
    const cx = -vet[0] * off, cy = -vet[1] * off;
    const hx = vet[0] * off, hy = vet[1] * off;
    const cob = k.$("div", "ts-circ ts-c1", palco);
    cob.style.width = cob.style.height = 2 * R + "px";
    tl.set(cob, { xPercent: -50, yPercent: -50, x: cx, y: cy, scale: 0 }, t0);
    tl.to(cob, { scale: 1, duration: 0.5 * d, ease: "power2.inOut" }, t0);
    const furo = k.$("div", "ts-furo", palco);
    tl.set(furo, { xPercent: -50, yPercent: -50, x: hx, y: hy, width: 0, height: 0, autoAlpha: 0 }, t0);
    tl.set(cob, { autoAlpha: 0 }, t0 + 0.5 * d);
    tl.set(furo, { autoAlpha: 1 }, t0 + 0.5 * d);
    tl.to(furo, { width: 2 * R, height: 2 * R, duration: 0.5 * d, ease: "power2.inOut" }, t0 + 0.5 * d);
  } else {
    const S = Math.hypot(W, H) * 1.05;
    const rot = base + (vet[0] !== 0 ? 18 : -18) * (vet[0] + vet[1] > 0 ? 1 : -1) * (vet[0] !== 0 ? 1 : -1);
    const w = k.$("div", "ts-giro", palco);
    w.style.width = w.style.height = S + "px";
    tl.set(w, { xPercent: -50, yPercent: -50, rotation: rot }, t0);
    const s = 0.07 * d;
    for (let i = 0; i < 3; i++) {
      const l = k.$("div", "ts-camada " + cores[i], w);
      tl.set(l, { xPercent: -101 }, t0);
      tl.to(l, { xPercent: 0, duration: 0.36 * d, ease: "power3.out" }, t0 + i * s);
      tl.to(l, { xPercent: 101, duration: 0.36 * d, ease: "power3.in" }, t0 + 0.5 * d + i * s);
    }
  }

  if (e.palavra) {
    const p = k.$("div", "ts-palavra", box, k.esc(e.palavra));
    tl.fromTo(p, { opacity: 0, y: 2 * U, scale: 0.94 }, { opacity: 1, y: 0, scale: 1, duration: 0.14 * d, ease: k.SUAVE }, t0 + 0.34 * d);
    tl.to(p, { opacity: 0, duration: 0.12 * d, ease: "power1.in" }, t0 + 0.64 * d);
  }
  tl.set(palco, { autoAlpha: 0 }, t0 + d);
});
