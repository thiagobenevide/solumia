// Migrada do kit (cena grafico_linha); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("grafico_linha", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  const pc = k.ajuste(c), pts = k.numeros({ ...c, ...e });
  if (pts.length < 2) return k.outra("linha_do_tempo", c, raiz);
  k.fundo(c);
  const box = k.$("div", "centro glinha", raiz);
  const cab = k.$("div", "gcab", box);
  if (e.titulo) k.entra(k.$("div", "titulo", cab, k.rico(e.titulo)), c.t);
  const ult = pts[pts.length - 1];
  const GW = 160, GH = 64;
  const g = k.svg("svg", { viewBox: `0 0 ${GW} ${GH + 12}`, class: "gl" }, box);
  const id = "gg" + (c.id ?? Math.round(c.t * 100));
  const df = k.svg("defs", {}, g), lg = k.svg("linearGradient", { id, x1: 0, y1: 0, x2: 0, y2: 1 }, df);
  k.svg("stop", { offset: "0", "stop-color": "var(--destaque)", "stop-opacity": ".45" }, lg);
  k.svg("stop", { offset: "1", "stop-color": "var(--destaque)", "stop-opacity": "0" }, lg);
  for (let q = 0; q <= 3; q++) k.svg("line", { x1: 4, x2: GW - 4, y1: 4 + (q * (GH - 8)) / 3, y2: 4 + (q * (GH - 8)) / 3, class: "gr" }, g);
  const vals = pts.map((p) => p.num.n), mx = Math.max(...vals), mn = Math.min(0, ...vals);
  const xy = pts.map((p, i) => [8 + (i * (GW - 16)) / (pts.length - 1), 6 + (1 - (p.num.n - mn) / (mx - mn || 1)) * (GH - 12)]);
  const d = xy.map(([x, y], i) => (i ? "L" : "M") + x.toFixed(1) + " " + y.toFixed(1)).join(" ");
  const area = k.svg("path", { d: `${d} L${xy[xy.length - 1][0].toFixed(1)} ${GH} L${xy[0][0].toFixed(1)} ${GH} Z`, fill: `url(#${id})`, opacity: 0 }, g);
  const ln = k.svg("path", { d, class: "gline", pathLength: 1 }, g);
  const dur = Math.max(0.8, pc.contagem_s * 1.6);
  k.tl.fromTo(ln, { strokeDashoffset: 1 }, { strokeDashoffset: 0, duration: dur, ease: "power2.inOut" }, c.t + 0.3);
  k.tl.to(area, { attr: { opacity: 1 }, duration: 0.6 }, c.t + 0.3 + dur * 0.6);
  xy.forEach(([x, y], i) => {
    const ti = c.t + 0.3 + (dur * i) / (xy.length - 1);
    const pt = k.svg("circle", { cx: x, cy: y, r: i === xy.length - 1 ? 2.2 : 1.4, class: i === xy.length - 1 ? "gp ult" : "gp" }, g);
    k.tl.fromTo(pt, { scale: 0, svgOrigin: `${x} ${y}` }, { scale: 1, svgOrigin: `${x} ${y}`, duration: 0.35, ease: k.SUAVE }, ti);
    const lb = k.svg("text", { x, y: GH + 9, class: "gtx", "text-anchor": "middle" }, g);
    lb.textContent = pts[i].rotulo || "";
    k.tl.fromTo(lb, { opacity: 0 }, { opacity: 1, duration: 0.3 }, ti);
  });
  k.numeroGrande(cab, ult.num, c.t + 0.3 + dur * 0.7, pc.contagem_s, "gfin");
  k.sai(box, k.fim(c));
});
