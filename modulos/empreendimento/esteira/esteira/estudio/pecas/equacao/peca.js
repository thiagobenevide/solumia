// Migrada do kit (cena equacao); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("equacao", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  const pc = k.ajuste(c), vs = k.numeros({ ...c, ...e });
  if (vs.length < 2) return k.outra("contador", c, raiz);
  k.fundo(c);
  const res = vs[vs.length - 1], termos = vs.slice(0, -1);
  const txt = e.titulo + " " + c.frase;
  const op = /\+|\bmais\b|soma/i.test(txt) ? "+" : /\bmenos\b|−/i.test(txt) ? "−" : /dividid|÷/i.test(txt) ? "÷" : "×";
  const box = k.$("div", "centro equacao", raiz);
  k.kicker(box, e.titulo, c.t);
  const linha = k.$("div", "eqlinha", box);
  const passo = Math.min(0.5, Math.max(0.2, (c.ate - c.t - 1.4) / (termos.length + 1)));
  let t = c.t + 0.25;
  termos.forEach((x, i) => {
    if (i) k.entra(k.$("div", "eqop", linha, op), t - 0.1, { de: { scale: 0.3, rotation: -90, y: 0 } });
    k.entra(k.$("div", "eqt", linha, `<div class="ev">${k.esc(x.valor)}</div><div class="er">${k.esc(x.rotulo)}</div>`), t, { de: { y: 3 * k.U } });
    t += passo;
  });
  k.entra(k.$("div", "eqop ig", linha, "="), t - 0.1, { de: { scale: 0.3, y: 0 } });
  const r = k.$("div", "eqt res", linha, `<div class="ev"><span class="nn"></span></div><div class="er">${k.esc(res.rotulo)}</div>`);
  k.entra(r, t, { de: { scale: 0.8, y: 0 } });
  k.contar(r.querySelector(".nn"), res.num, t + 0.05, pc.contagem_s, true);
  k.traco(k.$("div", "traco", box), t + 0.2, 0.7);
  k.auraFinal(r, t + pc.contagem_s);
  k.sai(box, k.fim(c));
});
