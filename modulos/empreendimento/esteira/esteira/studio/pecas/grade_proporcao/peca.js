// Migrada do kit (cena grade_proporcao); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("grade_proporcao", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  const pc = k.ajuste(c), pr = k.proporcao({ ...c, ...e });
  if (!pr) return k.outra("contador", c, raiz);
  k.fundo(c);
  const box = k.$("div", "centro gradep", raiz);
  const topo = k.$("div", "gtopo", box);
  k.numeroGrande(topo, pr.num, c.t + 0.15, pc.contagem_s, "gn");
  if (pr.rot || e.titulo) k.entra(k.$("div", "ctx", topo, k.rico(pr.rot || e.titulo)), c.t + 0.3);
  const gr = k.$("div", "grade10", box);
  const acesos = Math.round(pr.p), cel = [], on = [];
  for (let q = 0; q < 100; q++) cel.push(k.$("i", "", gr, "<b></b>"));
  // acende de baixo para cima, da esquerda para a direita (como um copo enchendo)
  for (let r = 9; r >= 0; r--) for (let col = 0; col < 10; col++) if (on.length < acesos) on.push(cel[r * 10 + col].firstChild);
  k.tl.fromTo(cel, { scale: 0, opacity: 0 }, { scale: 1, opacity: 1, duration: 0.3, stagger: { each: 0.004, from: "start" }, ease: k.SUAVE }, c.t + 0.05);
  if (on.length) k.tl.fromTo(on, { scale: 0 }, { scale: 1, duration: 0.25, stagger: pc.contagem_s / on.length, ease: k.SUAVE }, c.t + 0.35);
  k.sai(box, k.fim(c));
});
