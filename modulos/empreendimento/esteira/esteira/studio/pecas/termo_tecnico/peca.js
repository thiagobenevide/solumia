// Migrada do kit (cena termo_tecnico); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("termo_tecnico", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.veu(c, "baixo");
  const termo = String(e.titulo || c.ancora || "").replace(/[.!?]+$/, "");
  const def = ((e.valores || [])[0] || {}).rotulo || "";
  const box = k.$("div", "termo", raiz, `<div class="tmk">Termo</div><div class="tmw"></div><div class="tml"></div>${def ? `<div class="tmd">${k.rico(def)}</div>` : ""}`);
  k.entra(box, c.t, { de: { y: 3 * k.U } });
  const w = box.querySelector(".tmw");
  const passo = Math.min(0.05, 0.9 / Math.max(termo.length, 1));
  [...termo].forEach((ch, q) => k.tl.fromTo(k.$("span", "tc", w, k.esc(ch)), { opacity: 0 }, { opacity: 1, duration: 0.01 }, c.t + 0.2 + q * passo));
  const car = k.$("span", "caret", w);
  k.tl.fromTo(car, { opacity: 1 }, { opacity: 0, duration: 0.01, repeat: 5, yoyo: true, repeatDelay: 0.25 }, c.t + 0.2 + termo.length * passo);
  k.traco(box.querySelector(".tml"), c.t + 0.3 + termo.length * passo, 0.6);
  if (def) k.entra(box.querySelector(".tmd"), c.t + 0.5 + termo.length * passo);
  k.sai(box, k.fim(c));
});
