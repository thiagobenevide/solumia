// Migrada do kit (cena lettering); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("lettering", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.fundo(c);
  const pc = k.ajuste(c);
  const box = k.$("div", "centro letreiro", raiz);
  const txt = String(e.titulo || c.frase).replace(/[.]+$/, "");
  const marcadas = /\*/.test(txt);
  const ws = txt.replace(/\*(.+?)\*/g, (_, m) => m.split(/\s+/).map((x) => "*" + x).join(" ")).split(/\s+/).filter(Boolean);
  const porLinha = ws.length > 6 ? 3 : ws.length > 3 ? 2 : 1;
  const linhas = [];
  for (let k = 0; k < ws.length; k += porLinha) linhas.push(ws.slice(k, k + porLinha));
  const passo = Math.min(0.32, (c.ate - c.t - 0.8) / Math.max(linhas.length, 1));
  linhas.forEach((ln, i) => {
    const d = marcadas ? ln.some((w) => w.startsWith("*")) : i === linhas.length - 1 && linhas.length > 1;
    const l = k.$("div", "ll" + (d ? " d" : "") + (i % 2 ? " fina" : ""), box);
    const s = k.$("span", "", l, k.esc(ln.map((w) => w.replace(/^\*/, "")).join(" ")));
    const t = c.t + 0.1 + i * passo;
    k.tl.fromTo(s, { yPercent: 110 }, { yPercent: 0, duration: k.MOV.entrada_s + 0.35, ease: k.SUAVE }, t);
    if (d) k.tl.fromTo(k.$("i", "hl", l), { scaleX: 0 }, { scaleX: 1, duration: 0.45, ease: k.SUAVE }, t + 0.25);
  });
  k.tl.fromTo(box, { scale: 1 }, { scale: 1 + 0.05 * pc.tamanho, duration: Math.max(1, c.ate - c.t), ease: "none" }, c.t);
  k.sai(box, k.fim(c));
});
