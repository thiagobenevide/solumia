// Dois lados frente a frente (método A × método B), cada um com até 3 atributos (do gráfico antigo comparacao.html).
ESTUDIO.peca("comparacao_atributos", (k, c, raiz) => {
  const e = c.encaixes, b = c.botoes;
  k.fundo(c);
  const lados = [
    { rot: e.rotulo_a, nome: e.nome_a, itens: e.itens_a || [] },
    { rot: e.rotulo_b, nome: e.nome_b, itens: e.itens_b || [] },
  ];
  lados.forEach((l, i) => {
    const d = b.destaque === "a" ? i === 0 : b.destaque === "b" ? i === 1 : false;
    const lado = k.$("div", "ca-lado ca-l" + i + (d ? " ca-d" : ""), raiz,
      `${l.rot ? `<div class="ca-rot">${k.esc(l.rot)}</div>` : ""}<div class="ca-nome">${k.rico(l.nome || "")}</div>`);
    const t = c.t + 0.15 + i * 0.25;
    k.entra(lado, t, { de: k.V ? { y: (i ? 5 : -5) * k.U } : { x: (i ? 8 : -8) * k.U, y: 0, filter: "blur(12px)" } });
    const ul = k.$("ul", "ca-itens", lado);
    l.itens.slice(0, 3).forEach((x, j) => k.entra(k.$("li", "", ul, k.rico(x)), t + 0.6 + j * 0.3, { de: { y: 2 * k.U } }));
  });
  k.entra(k.$("div", "ca-vs", raiz, "vs"), c.t + 0.45, { de: { scale: 0.6, y: 0 } });
  const eixo = k.$("div", "ca-eixo", raiz);
  k.tl.fromTo(eixo, k.V ? { scaleX: 0 } : { scaleY: 0 }, { scaleX: 1, scaleY: 1, duration: 0.8, ease: k.SUAVE }, c.t + 0.45);
});
