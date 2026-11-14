// Migrada do kit (cena ranking); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("ranking", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  const pc = k.ajuste(c), vs = k.numeros({ ...c, ...e }).sort((a, b) => b.num.n - a.num.n).slice(0, 5);
  if (vs.length < 2) return k.outra("lista_itens", c, raiz);
  k.fundo(c);
  const box = k.$("div", "centro ranking", raiz);
  if (e.titulo) k.entra(k.$("div", "titulo", box, k.rico(e.titulo)), c.t);
  const max = vs[0].num.n || 1;
  const passo = Math.min(0.4, (c.ate - c.t - 1) / (vs.length + 1));
  const linhas = vs.map((x, i) => {
    const l = k.$("div", "rk" + (i ? "" : " top"), box,
      `<div class="rp">${i + 1}º</div><div class="rc"><div class="rr">${k.rico(x.rotulo)}</div><div class="rt"><div class="re"></div></div></div><div class="rv">${k.esc(x.valor)}</div>`);
    const t = c.t + 0.3 + i * passo;
    k.entra(l, t, { de: { x: -5 * k.U, y: 0 } });
    k.tl.fromTo(l.querySelector(".re"), { scaleX: 0 }, { scaleX: x.num.n / max, duration: pc.contagem_s + 0.3, ease: k.SUAVE }, t + 0.1);
    k.contar(l.querySelector(".rv"), x.num, t + 0.1, pc.contagem_s, true);
    return l;
  });
  // depois de todos na tela, só o 1º fica aceso (itens inativos na opacidade da Identidade)
  k.tl.to(linhas.slice(1), { opacity: k.inativos, duration: 0.4 }, c.t + 0.4 + vs.length * passo + pc.contagem_s);
  k.auraFinal(linhas[0].querySelector(".rp"), c.t + 0.4 + vs.length * passo + pc.contagem_s);
  k.sai(box, k.fim(c));
});
