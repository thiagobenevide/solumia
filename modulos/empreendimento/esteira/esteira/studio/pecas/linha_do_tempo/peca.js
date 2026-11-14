// Migrada do kit (cena linha_do_tempo); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("linha_do_tempo", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.fundo(c);
  const box = k.$("div", "centro tempo", raiz);
  if (e.titulo) k.entra(k.$("div", "titulo", box, k.rico(e.titulo)), c.t);
  const trilho = k.$("div", "trilho", box);
  k.traco(k.$("div", "eixo", trilho), c.t + 0.15, 1.2);
  const marcos = (e.valores || []).slice(0, 5);
  marcos.forEach((x, i) => {
    const m = k.$("div", "marco", trilho, `<div class="ano">${k.esc(x.valor)}</div><div class="ponto"></div><div class="mrot">${k.rico(x.rotulo)}</div>`);
    m.style.left = (marcos.length > 1 ? (100 * i) / (marcos.length - 1) : 50) + "%";
    const t = c.t + 0.35 + i * Math.min(0.45, (c.ate - c.t - 0.8) / Math.max(marcos.length, 1));
    k.entra(m, t, { de: { y: -2 * k.U } });
    k.tl.fromTo(m.querySelector(".ponto"), { scale: 0 }, { scale: 1, duration: 0.5, ease: "back.out(3)" }, t);
  });
  k.sai(box, k.fim(c));
});
