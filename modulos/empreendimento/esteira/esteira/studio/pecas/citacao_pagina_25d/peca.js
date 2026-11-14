// Citação de estudo: página do artigo em perspectiva, câmera percorre e aproxima do trecho, resto desfoca, marca-texto linha a linha.
ESTUDIO.peca("citacao_pagina_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes, tl = k.tl;
  if (c.takeover) k.fundo(c); else k.veu(c, "cheio");
  const esq = b.lado === "esquerda";
  if (esq) box.classList.add("cp-esq");
  const forte = b.perspectiva === "forte";
  const dir = esq ? -1 : 1;
  const rotY = dir * (forte ? 26 : 13);
  const rotX = forte ? 8 : 4;
  const clamp = (v, a, z) => Math.max(a, Math.min(z, v));

  // ---- dados da página ----
  const p = (e.pagina && typeof e.pagina === "object") ? e.pagina : { img: e.pagina || "" };
  const img = p.img || p.imagem || p.src || p.url || "";
  const iw = +(p.w || p.largura || p.width) || 1000;
  const ih = +(p.h || p.altura || p.height) || 1300;
  const brutos = p.rects || p.grifos || p.retangulos || [];
  const norm = (r) => {
    let a = Array.isArray(r) ? r.slice(0, 4)
      : [r.x0 != null ? r.x0 : r.x, r.y0 != null ? r.y0 : r.y,
         r.x1 != null ? r.x1 : (r.x + r.w), r.y1 != null ? r.y1 : (r.y + r.h)];
    a = a.map(Number);
    const frac = Math.max(...a) <= 1.5;
    return [a[0] / (frac ? 1 : iw), a[1] / (frac ? 1 : ih), a[2] / (frac ? 1 : iw), a[3] / (frac ? 1 : ih)]
      .map((v) => clamp(v, 0, 1));
  };
  let rects = brutos.map(norm).filter((r) => r.every((v) => isFinite(v)) && r[2] > r[0] && r[3] > r[1]);
  if (!rects.length) rects = [[.14, .4, .86, .43], [.14, .44, .86, .47], [.14, .48, .6, .51]];
  rects.sort((a, z) => (a[1] - z[1]) || (a[0] - z[0]));
  const bx0 = Math.min(...rects.map((r) => r[0])), bx1 = Math.max(...rects.map((r) => r[2]));
  const by0 = Math.min(...rects.map((r) => r[1])), by1 = Math.max(...rects.map((r) => r[3]));
  const cx = (bx0 + bx1) / 2, cy = (by0 + by1) / 2;

  // ---- tempos ----
  const bt = c.batidas.trecho_en != null ? c.batidas.trecho_en : c.t + 2.6;
  const n = rects.length;
  const passo = clamp((c.ate - bt - 2.2) / Math.max(n, 1), 0.2, 0.5);
  const tc = c.t + 0.9;
  const dc = clamp(bt - 0.1 - tc, 1.0, 2.2);
  const tp = clamp(bt + 0.6 + n * passo * 0.5, bt + 0.4, Math.max(bt + 0.4, c.ate - 1.4));

  // ---- cena 2,5D ----
  const cena = k.$("div", "cp-cena", box);
  const jan = k.$("div", "cp-janela", cena);
  const folha = k.$("div", "cp-folha", jan);
  folha.style.aspectRatio = iw + " / " + ih;
  folha.style.transformOrigin = (cx * 100) + "% " + (cy * 100) + "%";

  const papel = (pai) => {
    const pp = k.$("div", "cp-papel", pai);
    for (let i = 0; i < 34; i++) {
      const l = k.$("i", "cp-linha", pp);
      l.style.top = (6 + i * 2.7) + "%";
      l.style.width = (i % 9 === 8 ? 40 : 70 + k.rnd(i) * 18) + "%";
    }
    return pp;
  };
  const camada = (cls) => {
    const el = k.$("div", "cp-camada " + cls, folha);
    if (img) { const im = k.$("img", "cp-img", el); im.src = img; im.alt = ""; }
    else papel(el);
    return el;
  };
  const base = camada("cp-base");
  const nitida = camada("cp-nitida");
  const pad = 0.025;
  const ins = [by0 - pad, 1 - bx1 - pad, 1 - by1 - pad, bx0 - pad].map((v) => clamp(v, 0, 1) * 100);
  nitida.style.clipPath = "inset(" + ins.map((v) => v + "%").join(" ") + ")";

  const marcas = rects.map((r) => {
    const m = k.$("div", "cp-marca", folha);
    m.style.left = (r[0] * 100 - 0.6) + "%";
    m.style.top = (r[1] * 100 - 0.2) + "%";
    m.style.width = ((r[2] - r[0]) * 100 + 1.2) + "%";
    m.style.height = ((r[3] - r[1]) * 100 + 0.4) + "%";
    return m;
  });
  k.$("div", "cp-lupa", jan);

  // entrada e respiração da janela
  tl.fromTo(jan, { opacity: 0, rotationY: rotY * 2.4, rotationX: rotX * 2, z: -25 * U, x: -dir * 6 * U },
    { opacity: 1, rotationY: rotY, rotationX: rotX, z: 0, x: 0, duration: 1.1, ease: k.SUAVE }, c.t);
  tl.to(jan, { rotationY: rotY * 0.55, rotationX: rotX * 0.4, duration: Math.max(1, c.ate - c.t - 1.4), ease: "none" }, c.t + 1.1);

  // câmera: percorre a página e aproxima do trecho
  const jw = k.V ? 84 : 62, jh = k.V ? 58 : 84;
  const vis = jh / (jw * ih / iw);
  const bw = Math.max(bx1 - bx0, 0.05), bh = Math.max(by1 - by0, 0.03);
  const s = clamp(Math.min(0.78 / bw, 0.8 * vis / bh), 1.15, 3.2);
  tl.fromTo(folha, { scale: 1, xPercent: 0, yPercent: 0 },
    { scale: s, xPercent: (0.5 - cx) * 100, yPercent: (vis / 2 - cy) * 100, duration: dc, ease: "power2.inOut" }, tc);
  tl.fromTo(base, { filter: "blur(0px) brightness(1)" },
    { filter: "blur(" + (0.35 * U) + "px) brightness(.75)", duration: dc, ease: "power1.inOut" }, tc);
  tl.fromTo(nitida, { opacity: 0 }, { opacity: 1, duration: dc * 0.6, ease: "none" }, tc + dc * 0.3);

  // marca-texto linha a linha, na batida da fala
  marcas.forEach((m, i) => {
    tl.fromTo(m, { scaleX: 0, opacity: 0.2, transformOrigin: "0% 50%" },
      { scaleX: 1, opacity: 0.55, duration: 0.45, ease: k.SUAVE }, bt + i * passo);
  });

  // ---- ficha ----
  const fic = k.$("div", "cp-ficha", box);
  if (e.autores) k.entra(k.$("div", "cp-autores", fic, k.esc(e.autores)), c.t + 0.5, { de: { y: 3 * U } });
  k.entra(k.$("div", "cp-titulo", fic, k.esc(e.titulo)), c.t + 0.65, { de: { y: 3 * U } });
  if (e.revista) k.entra(k.$("div", "cp-revista", fic, k.esc(e.revista)), c.t + 0.8, { de: { y: 3 * U } });
  const g1 = k.$("div", "cp-leg", fic, "TRECHO ORIGINAL");
  const en = k.$("div", "cp-en", fic, k.esc(e.trecho_en));
  k.entra(g1, bt - 0.15, { de: { y: 2 * U } });
  k.entra(en, bt - 0.05, { de: { y: 3 * U } });
  const g2 = k.$("div", "cp-leg", fic, "TRADUÇÃO");
  const tr = k.$("div", "cp-trad", fic);
  k.entra(g2, tp - 0.15, { de: { y: 2 * U } });
  k.entra(tr, tp - 0.1, { de: { y: 2 * U } });
  k.palavras(tr, e.traducao, tp, 0.05);
  if (b.selo !== "nao") {
    const selo = k.$("div", "cp-selo", fic, "LINK NA DESCRIÇÃO ↓");
    k.entra(selo, Math.min(tp + 0.7, Math.max(tp, c.ate - 0.8)), { de: { y: 2 * U, scale: 0.9 } });
  }
});
