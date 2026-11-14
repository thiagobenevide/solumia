// Migrada do kit (cena anel_percentual); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("anel_percentual", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  const pc = k.ajuste(c), pr = k.proporcao({ ...c, ...e });
  if (!pr) return k.outra("contador", c, raiz);
  k.fundo(c);
  const box = k.$("div", "anelp", raiz);
  const g = k.svg("svg", { viewBox: "0 0 100 100", class: "aneis" }, box);
  const marcas = k.svg("g", {}, g);
  const acesas = [];
  for (let q = 0; q < 60; q++) {
    const a = (q / 60) * Math.PI * 2 - Math.PI / 2;
    const l = k.svg("line", { x1: 50 + Math.cos(a) * 46.5, y1: 50 + Math.sin(a) * 46.5, x2: 50 + Math.cos(a) * 49.5, y2: 50 + Math.sin(a) * 49.5, class: "mk" }, marcas);
    if ((q / 60) * 100 < pr.p) acesas.push(l);
  }
  k.svg("circle", { cx: 50, cy: 50, r: 40, class: "trilha" }, g);
  const arco = k.svg("circle", { cx: 50, cy: 50, r: 40, class: "arco", pathLength: 100, transform: "rotate(-90 50 50)" }, g);
  const pg = k.svg("g", {}, g);
  k.svg("circle", { cx: 50, cy: 10, r: 2.4, class: "ponta" }, pg);
  const t0 = c.t + 0.2, dur = pc.contagem_s;
  k.entra(g, c.t, { de: { scale: 0.82, rotation: -40, y: 0 } });
  k.tl.fromTo(arco, { strokeDasharray: "0 100" }, { strokeDasharray: `${pr.p.toFixed(2)} 100`, duration: dur, ease: k.SUAVE }, t0);
  k.tl.fromTo(pg, { rotation: 0, svgOrigin: "50 50" }, { rotation: 3.6 * pr.p, svgOrigin: "50 50", duration: dur, ease: k.SUAVE }, t0);
  if (acesas.length) k.tl.to(acesas, { opacity: 1, duration: 0.08, stagger: dur / acesas.length }, t0);
  const tx = k.$("div", "anelt", box);
  if (k.fonteDe({ ...c, ...e })) k.entra(k.$("div", "kick2", tx, k.esc(k.fonteDe({ ...c, ...e }))), c.t + 0.1, { de: { x: -2 * k.U, y: 0 } });
  const n = k.numeroGrande(tx, pr.num, t0, dur, "pct");
  const barra = k.$("div", "barrap", tx, "<i></i>");
  k.entra(barra, t0 + 0.1, { de: { y: 0 } });
  k.tl.fromTo(barra.querySelector("i"), { scaleX: 0 }, { scaleX: pr.p / 100, duration: dur, ease: k.SUAVE }, t0 + 0.1);
  const ctx = pr.rot || e.titulo;
  if (ctx) k.entra(k.$("div", "ctx", tx, k.rico(ctx)), t0 + 0.35);
  k.auraFinal(n, t0 + dur);
  k.sai(box, k.fim(c));
});
