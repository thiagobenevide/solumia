// Citação de estudo 2,5D: folha de artigo inclinada sobre a mesa, câmera aproxima, marca-texto varre o trecho,
// tradução PT num cartão à frente e autor/ano num selo carimbado.
ESTUDIO.peca("citacao_estudo_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");
  if (b.marcador === "acento") box.classList.add("cx-m-acento");

  const forte = b.inclinacao === "forte";
  const rx = forte ? [28, 20] : [20, 12];
  const ry = forte ? [-16, -9] : [-10, -4];
  const d = Math.max(c.ate - c.t, 3);

  // tempos: folha -> marca-texto -> cartão -> selo
  const th = c.t + 0.8;
  const tcBase = c.batidas.traducao != null ? c.batidas.traducao : c.t + 1.9;
  const tc = Math.max(c.t + 1.0, Math.min(tcBase, c.ate - 1.4));
  const ts = Math.min(tc + 0.7, c.ate - 0.5);

  const cena = k.$("div", "cx-cena", box);
  const palco = k.$("div", "cx-palco", cena);
  if (c.takeover) {
    const mesa = k.$("div", "cx-mesa", palco);
    k.tl.set(mesa, { z: -2 * U });
  }

  // folha do artigo
  const folha = k.$("div", "cx-folha", palco);
  if (e.revista) k.$("div", "cx-rev", folha, k.esc(e.revista));
  const tr = k.$("p", "cx-tr", folha);
  const partes = String(e.trecho_en || "").split(/\*([^*]+)\*/);
  const tem = partes.length > 1;
  tr.innerHTML = partes.map((p, i) => {
    const marcado = tem ? i % 2 === 1 : true;
    return (p.match(/\S+\s*/g) || []).map(w => `<span class="cx-w${marcado ? " cx-mk" : ""}">${k.esc(w)}</span>`).join("");
  }).join("");
  k.$("div", "cx-linhas", folha, "<i></i><i></i><i></i><i></i>");
  k.entra(folha, c.t, { de: { y: 6 * U } });

  // câmera aproxima e a mesa "respira" até o fim
  k.tl.fromTo(palco,
    { z: -22 * U, rotationX: rx[0], rotationY: ry[0] },
    { z: 0, rotationX: rx[1], rotationY: ry[1], duration: d, ease: k.SUAVE }, c.t);

  // marca-texto
  const mk = tr.querySelectorAll(".cx-mk");
  if (mk.length) {
    k.tl.fromTo(mk, { backgroundSize: "0% 62%" },
      { backgroundSize: "100% 62%", duration: 0.2, ease: "none", stagger: Math.min(0.07, 1.2 / mk.length) }, th);
  }

  // cartão da tradução, à frente da folha
  const cartao = k.$("div", "cx-cartao", palco);
  k.$("span", "cx-pt", cartao, "PT");
  const tx = k.$("div", "cx-ctx", cartao);
  k.tl.fromTo(cartao,
    { z: 24 * U, y: 3 * U, opacity: 0 },
    { z: 10 * U, y: 0, opacity: 1, duration: 0.8, ease: k.SUAVE }, tc);
  k.palavras(tx, e.traducao, tc + 0.35, 0.045);

  // selo de autor e ano
  const selo = k.$("div", "cx-selo", palco,
    `<span class="cx-au">${k.esc(e.autor)}</span><b class="cx-an">${k.esc(e.ano)}</b>`);
  k.tl.fromTo(selo,
    { z: 22 * U, scale: 1.7, rotation: -16, opacity: 0 },
    { z: 6 * U, scale: 1, rotation: -5, opacity: 1, duration: 0.38, ease: "power3.out" }, ts);
});
