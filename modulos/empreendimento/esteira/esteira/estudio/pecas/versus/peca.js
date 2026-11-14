// Migrada do kit (cena versus); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("versus", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.fundo(c);
  const box = k.$("div", "versus", raiz);
  let lados = (e.valores || []).slice(0, 2).map((x) => [x.rotulo, x.valor]);
  if (lados.length < 2) {
    const p = String(e.titulo).split(/\s+(?:x|×|vs\.?|versus|contra)\s+/i);
    lados = p.length >= 2 ? [[p[0], ""], [p[1], ""]] : [[e.titulo, ""], ["", ""]];
  }
  lados.forEach(([rot, val], i) => {
    const lado = k.$("div", "lado l" + i, box, `<div class="lk">${i ? "B" : "A"}</div><div class="lrot">${k.rico(rot)}</div>${val ? `<div class="lval">${k.esc(val)}</div>` : ""}`);
    k.entra(lado, c.t + 0.15 + i * 0.3, { de: k.V ? { y: (i ? 5 : -5) * k.U } : { x: (i ? 8 : -8) * k.U, y: 0, filter: "blur(12px)" } });
    const vn = lado.querySelector(".lval"), num = val && k.numero(val);
    if (vn && num) k.contar(vn, num, c.t + 0.4 + i * 0.3, 1.1, true);
  });
  const eixo = k.$("div", "eixo", box);
  k.tl.fromTo(eixo, k.V ? { scaleX: 0 } : { scaleY: 0 }, { scaleX: 1, scaleY: 1, duration: 0.9, ease: k.SUAVE }, c.t + 0.4);
  k.entra(k.$("div", "vs", box, "vs"), c.t + 0.55, { de: { scale: 0.6, y: 0 } });
  k.sai(box, k.fim(c));
});
