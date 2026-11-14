// Capítulo em faixa: faixa varre a tela, bloco com o número, título palavra a palavra e linha de apoio.
ESTUDIO.peca("capitulo_faixa", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");
  if (b.direcao === "direita") box.classList.add("cf-dir");
  const dir = b.direcao === "direita" ? -1 : 1;
  const faixa = k.$("div", "cf-faixa", box);
  const bloco = k.$("div", "cf-bloco", faixa);
  const num = k.$("div", "cf-num", bloco, k.esc(e.numero));
  const txt = k.$("div", "cf-txt", faixa);
  const kick = k.$("div", "cf-kick", txt, "Capítulo");
  const tit = k.$("div", "cf-titulo", txt);
  k.tl.fromTo(faixa, { scaleX: 0, transformOrigin: dir === 1 ? "0% 50%" : "100% 50%" },
    { scaleX: 1, duration: 0.7, ease: k.SUAVE }, c.t);
  k.entra(num, c.t + 0.35, { de: { x: -dir * 6 * U, scale: 0.85 } });
  k.entra(kick, c.t + 0.5, { de: { y: 1.5 * U } });
  k.palavras(tit, e.titulo, c.t + 0.6, 0.09);
  if (b.detalhe !== "nenhum") k.traco(k.$("div", "traco", txt), c.t + 1.1, 0.7);
  if (e.subtitulo) {
    const sub = k.$("div", "cf-sub", txt, k.rico(k.esc(e.subtitulo)));
    k.entra(sub, c.t + 1.2, { de: { y: 2 * U } });
  }
});
