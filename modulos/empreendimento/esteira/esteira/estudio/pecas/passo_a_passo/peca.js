// Migrada do kit (cena passo_a_passo); dados no formato do diretor: encaixes titulo e valores.
ESTUDIO.peca("passo_a_passo", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes };
  k.veu(c, "baixo");
  const EXT = { um: 1, uma: 1, dois: 2, duas: 2, "três": 3, tres: 3, quatro: 4, cinco: 5, seis: 6, sete: 7, oito: 8, nove: 9, dez: 10 };
  const ext = e.titulo.replace(/\*/g, "").match(/^\s*passo\s+(\S+?)\s*[:.\-–—]/i);
  const n = (e.titulo.match(/\d+/) || [(ext && EXT[ext[1].toLowerCase()]) || c.passo || ""])[0];
  const box = k.$("div", "tag passo", raiz, `<div class="pn">${n ? k.esc(String(n).padStart(2, "0")) : k.icone(e.titulo + " " + c.frase)}</div><div class="tx"><div class="tk">${n ? "Passo" : "Regra"}</div><div class="pt">${k.rico(e.titulo.replace(/^\s*passo\s*\d+\s*[:.-]?\s*/i, ""))}</div></div>`);
  k.entra(box, c.t, { de: { x: -6 * k.U, y: 0, filter: "blur(12px)" } });
  k.entra(box.querySelector(".pn"), c.t + 0.15, { de: { scale: 0.6, y: 0 } });
  k.entra(box.querySelector(".pt"), c.t + 0.3);
  k.sai(box, k.fim(c));
});
