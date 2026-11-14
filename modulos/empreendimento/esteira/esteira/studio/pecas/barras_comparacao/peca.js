// Migrada do kit (cena barras_comparacao); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("barras_comparacao", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.fundo(c);
  const box = k.$("div", "centro barras", raiz);
  if (e.titulo) k.entra(k.$("div", "titulo", box, k.rico(e.titulo)), c.t);
  const vs = (e.valores || []).slice(0, 4).map((x) => ({ ...x, num: k.numero(x.valor) }));
  const max = Math.max(...vs.map((x) => (x.num ? x.num.n : 0)), 1);
  const passo = Math.min(0.45, (c.ate - c.t) / (vs.length + 2));
  vs.forEach((x, i) => {
    const linha = k.$("div", "linhab" + (i === vs.length - 1 ? " ult" : ""), box,
      `<div class="rot"><span>${String(i + 1).padStart(2, "0")}</span>${k.esc(x.rotulo)}</div><div class="trilho"><div class="enche"></div></div><div class="val">${k.esc(x.valor)}</div>`);
    const t = c.t + 0.35 + i * passo;
    k.entra(linha, t, { de: { x: -4 * k.U, y: 0 } });
    k.tl.fromTo(linha.querySelector(".enche"), { scaleX: 0 }, { scaleX: x.num ? x.num.n / max : 0.5, duration: 1.1, ease: k.SUAVE }, t + 0.1);
    if (x.num) k.contar(linha.querySelector(".val"), x.num, t + 0.1, 1.1, true);
  });
  k.sai(box, k.fim(c));
});
