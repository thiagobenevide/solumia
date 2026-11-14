// Etiqueta numerada lateral: pílula com número contando + palavra em caixa alta, cartão de vidro opcional. Sem fundo cheio.
ESTUDIO.peca("etiqueta_lateral_vidro", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const dir = b.lado === "direita";
  box.classList.add(dir ? "ev-dir" : "ev-esq");
  const t0 = c.batidas.numero != null ? c.batidas.numero : c.t + 0.15;
  const sinal = dir ? 1 : -1;

  const cena = k.$("div", "ev-cena", box);
  const palco = k.$("div", "ev-palco", cena);
  const pilula = k.$("div", "ev-pilula", palco);
  const numEl = k.$("span", "ev-num", pilula);
  k.$("span", "ev-sep", pilula);
  k.$("span", "ev-pal", pilula, k.esc(String(e.palavra || "").toUpperCase()));

  // número: conta de 0 até o valor, mantendo zeros à esquerda (ex.: 02)
  const bruto = String(e.numero == null ? "" : e.numero);
  const digitos = bruto.replace(/\D/g, "");
  if (digitos && /^\d+$/.test(bruto.trim())) {
    const alvo = parseInt(digitos, 10), larg = bruto.trim().length;
    const o = { v: 0 };
    numEl.textContent = "0".repeat(larg);
    k.tl.to(o, {
      v: alvo, duration: Math.min(0.9, 0.25 + alvo * 0.08), ease: "power2.out",
      onUpdate: () => { numEl.textContent = String(Math.round(o.v)).padStart(larg, "0"); },
    }, t0 + 0.15);
  } else {
    numEl.textContent = bruto;
  }

  // entrada: desliza de fora da tela com giro leve
  k.tl.fromTo(palco, { x: sinal * 14 * U, opacity: 0, rotationY: sinal * -24, transformOrigin: dir ? "100% 50%" : "0% 50%" },
    { x: 0, opacity: 1, rotationY: sinal * -9, duration: 0.7, ease: k.SUAVE }, t0);
  k.tl.fromTo(pilula, { clipPath: dir ? "inset(0 0 0 100%)" : "inset(0 100% 0 0)" },
    { clipPath: "inset(0 0% 0 0)", duration: 0.55, ease: k.SUAVE }, t0);

  if (e.legenda) {
    const vidro = k.$("div", "ev-vidro", palco);
    k.tl.fromTo(vidro, { opacity: 0, y: 3 * U }, { opacity: 1, y: 0, duration: 0.5, ease: k.SUAVE }, t0 + 0.45);
    k.palavras(k.$("div", "ev-leg", vidro), e.legenda, t0 + 0.6, 0.06);
  }

  // câmera respira até o fim
  const fim = Math.max(t0 + 1.2, c.ate - 0.3);
  k.tl.to(palco, { rotationY: sinal * -4, duration: fim - (t0 + 0.8), ease: "sine.inOut" }, t0 + 0.8);
});
