// Migrada do kit (cena riscado); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("riscado", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.veu(c, "baixo");
  const box = k.$("div", "riscado", raiz);
  const itens = (e.valores || []).length ? e.valores.map((x) => [x.rotulo, x.valor].filter(Boolean).join(" · ")) : [e.titulo];
  const passo = Math.min(0.5, (c.ate - c.t - 1) / Math.max(itens.length, 1));
  itens.slice(0, 4).forEach((x, i) => {
    const p = k.$("div", "rs", box, `<span>${k.rico(x)}</span><i></i>`);
    const t = c.t + i * passo;
    k.entra(p, t, { de: { y: 2 * k.U } });
    k.tl.fromTo(p.querySelector("i"), { scaleX: 0 }, { scaleX: 1, duration: 0.35, ease: "power3.inOut" }, t + 0.35);
    k.tl.to(p.querySelector("span"), { opacity: k.inativos, duration: 0.3 }, t + 0.55);
  });
  k.sai(box, k.fim(c));
});
