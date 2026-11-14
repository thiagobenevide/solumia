// Migrada do kit (cena lista_itens); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("lista_itens", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.veu(c, "cheio");
  const box = k.$("div", "lista", raiz);
  const itens = (e.valores || []).length ? e.valores.map((x) => ({ t: x.rotulo, v: x.valor }))
    : String(e.titulo).split(/:|,|;| e /).slice(1).map((t) => ({ t: t.trim(), v: "" }));
  const titulo = (e.valores || []).length ? e.titulo : String(e.titulo).split(/:/)[0];
  if (titulo) k.entra(k.$("div", "titulo", box, k.rico(titulo)), c.t);
  const grade = k.$("div", "itens n" + Math.min(itens.length, 5), box);
  const passo = Math.min(0.45, (c.ate - c.t - 0.6) / Math.max(itens.length, 1));
  itens.slice(0, 5).forEach((x, i) => k.entra(k.$("div", "item", grade,
    `<div class="n">${String(i + 1).padStart(2, "0")}</div>${x.v ? `<div class="v">${k.esc(x.v)}</div>` : ""}<div class="t">${k.rico(x.t)}</div>`),
    c.t + 0.35 + i * passo, { de: { y: 4 * k.U } }));
  k.sai(box, k.fim(c));
});
