// Etiqueta numerada: pílula (ou vidro em perspectiva) com número contando + palavra em caixa alta, presa por um fio a um card.
// Por cima da mídia: sem fundo cheio.
ESTUDIO.peca("etiqueta_numerada", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const dir = b.posicao === "direita";
  const vidro = b.estilo === "vidro";
  if (c.takeover) k.fundo(c);
  box.classList.add(dir ? "et-dir" : "et-esq");
  if (vidro) box.classList.add("et-vidro");

  const cena = k.$("div", "et-cena", box);
  const col = k.$("div", "et-col", cena);
  const linha = k.$("div", "et-linha", col);
  const cart = k.$("div", "et-cart", linha);

  // número: preserva zeros à esquerda ("02") e contorna textos sem dígito
  const txt = e.numero != null ? String(e.numero) : "";
  const m = /^(\D*?)(\d+)(.*)$/.exec(txt);
  let nEl = null;
  if (m) {
    const antes = m[1], dig = m[2], depois = m[3];
    const alvo = parseInt(dig, 10);
    nEl = k.$("div", "et-n", cart);
    const pinta = (v) => { nEl.textContent = antes + String(Math.round(v)).padStart(dig.length, "0") + depois; };
    pinta(0);
    const o = { v: 0 };
    var contar = () => k.tl.to(o, { v: alvo, duration: 0.9, ease: "power2.out", onUpdate: () => pinta(o.v) }, tn + 0.2);
  } else if (txt) {
    nEl = k.$("div", "et-n", cart, k.esc(txt));
  }
  if (nEl) k.$("div", "et-sep", cart);
  if (e.palavra) k.$("div", "et-p", cart, k.esc(e.palavra));

  const pino = k.$("div", "et-pino", linha);
  const fio = k.$("div", "et-fio", pino);
  const ponto = k.$("div", "et-ponto", pino);
  const brilho = vidro ? k.$("div", "et-brilho", cart) : null;

  var tn = c.batidas.numero != null ? c.batidas.numero : c.t + 0.1;
  const lado = dir ? 1 : -1;
  const ang = vidro ? (dir ? -14 : 14) : 0;
  col.style.transformOrigin = dir ? "right center" : "left center";

  k.tl.fromTo(col,
    { x: lado * 18 * U, opacity: 0, rotationY: vidro ? ang * 3 : 0 },
    { x: 0, opacity: 1, rotationY: ang, duration: 0.75, ease: k.SUAVE }, tn);
  if (typeof contar === "function") contar();
  k.tl.fromTo(fio, { scaleX: 0 }, { scaleX: 1, duration: 0.4, ease: k.SUAVE }, tn + 0.5);
  k.tl.fromTo(ponto, { scale: 0 }, { scale: 1, duration: 0.4, ease: "back.out(2)" }, tn + 0.8);
  if (brilho) k.tl.fromTo(brilho, { xPercent: -120 }, { xPercent: 120, duration: 0.9, ease: "power1.inOut" }, tn + 0.4);

  if (e.complemento) {
    const ctx = k.$("div", "et-ctx", col);
    k.palavras(ctx, e.complemento, tn + 0.7, 0.05);
  }

  // a câmera "respira": leve flutuação até o fim
  const resto = c.ate - tn - 1.0;
  if (resto > 0.5) k.tl.to(col, { y: -0.7 * U, duration: resto, ease: "sine.inOut" }, tn + 0.9);
});
