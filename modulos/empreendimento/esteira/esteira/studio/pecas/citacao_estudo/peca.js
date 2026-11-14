// Migrada do kit (cena citacao_estudo); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("citacao_estudo", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.veu(c, "baixo");
  const vs = e.valores || [];
  const ano = (vs.find((x) => /ano/i.test(x.rotulo)) || {}).valor || (String(e.titulo + " " + vs.map((x) => x.valor).join(" ")).match(/\b(19|20)\d{2}\b/) || [""])[0];
  const resto = vs.filter((x) => !/ano/i.test(x.rotulo));
  const box = k.$("div", "tag citacao", raiz,
    `<div class="tx"><div class="tk">Estudo${ano ? " · " + k.esc(ano) : ""}</div><div class="ct">${k.rico(e.titulo)}</div>` +
    resto.map((x) => `<div class="cv">${k.esc(x.rotulo)} <b>${k.esc(x.valor)}</b></div>`).join("") +
    `<div class="cselo">Link na descrição ↓</div></div>`);
  k.entra(box, c.t, { de: { x: -6 * k.U, y: 0, filter: "blur(12px)" } });
  box.querySelectorAll(".tk, .ct, .cv, .cselo").forEach((e, i) => k.entra(e, c.t + 0.2 + i * 0.15, { de: { y: 1.5 * k.U } }));
  k.sai(box, k.fim(c));
});
