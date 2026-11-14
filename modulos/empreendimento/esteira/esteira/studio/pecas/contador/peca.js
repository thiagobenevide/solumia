// Migrada do kit (cena contador); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("contador", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.fundo(c);
  const box = k.$("div", "centro num", raiz);
  const vs = e.valores || [];
  const v = vs[0] || { rotulo: "", valor: e.titulo };
  k.kicker(box, vs.length ? e.titulo : "", c.t);
  const { num, html } = k.valorHtml(v.valor);
  const n = k.$("div", "numero", box, html);
  k.entra(n, c.t + 0.1, { de: { y: 4 * k.U, scale: 0.92 } });
  if (num) k.contar(n.querySelector(".nn"), num, c.t + 0.2, Math.min(1.6, Math.max(0.7, (c.ate - c.t) * 0.5)));
  k.traco(k.$("div", "traco", box), c.t + 0.55, 0.9);
  if (v.rotulo) k.entra(k.$("div", "legenda", box, k.rico(v.rotulo)), c.t + 0.75);
  if (vs[1] && /fonte/i.test(vs[1].rotulo)) k.entra(k.$("div", "fonte", box, "Fonte: " + k.esc(vs[1].valor)), c.t + 1.1, { de: { y: 0 } });
  k.sai(box, k.fim(c));
});
