// Comparação 2,5D: dois cartões-pilar giram de frente para a câmera, os valores crescem e o vencedor avança no eixo Z.
ESTUDIO.peca("comparacao_25d", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const vel = { lenta: 1.5, normal: 1.0, rapida: 0.65 }[b.ritmo] || 1.0;
  const ang = b.giro === "marcado" ? 26 : 14;

  const lados = (Array.isArray(e.lados) ? e.lados : []).filter((l) => l && l.valor != null).slice(0, 2);
  if (lados.length < 2) { k.outra("barras_comparacao", c, box); return; }

  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");

  // valor numérico no formato pt-BR (1.234,5 / 3.200 / 12,5)
  const paraNumero = (txt) => {
    const m = String(txt).match(/\d[\d.,]*/);
    if (!m) return 0;
    let s = m[0].replace(/[.,]+$/, "");
    if (s.indexOf(",") >= 0) s = s.replace(/\./g, "").replace(",", ".");
    else if (/^\d{1,3}(\.\d{3})+$/.test(s)) s = s.replace(/\./g, "");
    return Number(s) || 0;
  };

  const corpo = k.$("div", "c25-corpo", box);
  if (e.unidade) k.kicker(corpo, e.unidade, c.t);
  const cena = k.$("div", "c25-cena", corpo);
  const palco = k.$("div", "c25-palco", cena);

  const dados = lados.map((l) => ({ l, num: k.numero(String(l.valor)), n: paraNumero(l.valor) }));
  const maximo = Math.max(dados[0].n, dados[1].n, 1);
  const empate = dados[0].n === dados[1].n;
  const venc = empate ? -1 : (dados[0].n > dados[1].n ? 0 : 1);

  const aj = k.ajuste(c) || {};
  const dur = (aj.contagem_s || 1.4) * vel;
  const tv = c.t + 0.9 * vel;
  const tw = tv + dur + 0.1;

  dados.forEach((d, i) => {
    const lado = i === 0 ? 1 : -1; // esquerda gira +, direita gira -
    const el = k.$("div", "c25-cartao " + (i === 0 ? "c25-a" : "c25-b"), palco,
      `<div class="c25-halo"></div><div class="c25-rot"></div><div class="c25-val"><span class="c25-v"></span><small></small></div><div class="c25-zona"><div class="c25-fill"></div></div>`);
    el.querySelector(".c25-rot").textContent = String(d.l.rotulo || "");
    const val = el.querySelector(".c25-v");
    const t0 = c.t + 0.1 + i * 0.15;
    k.tl.fromTo(el,
      { rotationY: -lado * 70, x: -lado * 10 * U, z: -12 * U, opacity: 0 },
      { rotationY: lado * ang, x: 0, z: 0, opacity: 1, duration: 0.9 * vel, ease: k.SUAVE }, t0);
    if (d.num) {
      el.querySelector("small").textContent = d.num.depois || "";
      k.contar(val, { ...d.num, depois: "" }, tv, dur, !d.num.casas);
    } else {
      val.textContent = String(d.l.valor);
    }
    const alvo = d.n > 0 ? Math.max(0.1, d.n / maximo) : 0.1;
    k.tl.fromTo(el.querySelector(".c25-fill"), { scaleY: 0 },
      { scaleY: alvo, duration: dur, ease: "power2.out", transformOrigin: "50% 100%" }, tv);

    if (venc === i) {
      k.tl.to(el, { z: 8 * U, rotationY: lado * ang * 0.3, scale: 1.03, duration: 0.7 * vel, ease: k.SUAVE }, tw);
      k.tl.to(el.querySelector(".c25-halo"), { opacity: 1, duration: 0.5 * vel, ease: k.SUAVE }, tw);
      k.auraFinal(el, tw + 0.3);
    } else if (venc >= 0) {
      k.tl.to(el, { z: -5 * U, opacity: 0.75, duration: 0.7 * vel, ease: k.SUAVE }, tw);
    }
  });

  // a câmera "respira" até o fim
  k.tl.fromTo(palco, { rotationY: -4 }, { rotationY: 4, duration: Math.max(1, c.ate - c.t), ease: "none" }, c.t);
});
