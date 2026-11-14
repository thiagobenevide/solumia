// Número de impacto (motor EffectCraft): rótulo, número grande contando, traço e linha de contexto.
// Tudo pela pele (cor/fonte por papel) e em U (1% do lado menor); camadas com nomes em português.
var vel = {lenta: 1.6, normal: 1.0, rapida: 0.6}[B.velocidade] || 1.0;
var esq = B.alinhamento === "esquerda";
if (DADOS.tela_cheia) fundoTela(); else veuBaixo(0.85);
var x0 = esq ? 10 * U : W / 2, alinhar = esq ? "esquerda" : "centro";
var tnum = BAT.numero !== undefined ? BAT.numero : T0 + 0.15;
var tam = (VERT ? 17 : 24) * U, base = H * 0.5 + tam * 0.3;
if (E.rotulo) {
  var r = bloco("Rótulo", E.rotulo, esq ? x0 : 0, base - tam * 1.05 - 3 * U, esq ? W - 2 * x0 : W,
                {papel: "fM", peso: 700, tam: (VERT ? 3 : 2.6) * U, cor: "destaque", alinhar: alinhar, caps: true, tracking: 300});
  entrar(r, "esq", T0, 0.6);
}
var num = numero(E.numero);
var final = num ? num.antes + String(num.n.toFixed(num.casas)).replace(".", ",").replace(/\B(?=(\d{3})+(?!\d))/g, ".") : E.numero;
var n = linha("Número (conta até o valor)", final, esq ? x0 : W / 2, base, {papel: "fD", peso: 800, tam: tam, cor: "destaque",
              justify: esq ? "left" : "center", tracking: -30});
if (num) contagem(n, num.n, num.casas, tnum + 0.05, 0.9 * vel, num.antes, "");
entrar(n, "baixo", tnum, 0.8);
if (num && num.depois) {
  var rn = n.sourceRectAtTime(DUR, false);
  var sf = linha("Unidade", num.depois.replace(/^\s+/, ""), (esq ? x0 : W / 2) + rn.left + rn.width + tam * 0.06, base,
                 {papel: "fD", peso: 700, tam: tam * 0.42, cor: "texto"});
  entrar(sf, "baixo", tnum + 0.1, 0.8);
}
if (B.enfase === "traco") {
  var tw = 48 * U;
  var t = retangulo("Traço", esq ? x0 : W / 2 - tw / 2, base + 5 * U, tw, 0.4 * U, "destaque", 100, 0, true);
  traco(t, tnum + 0.5 * vel, 0.8 * vel);
} else if (B.enfase === "anel") {
  var an = elipse("Anel", W / 2, base - tam * 0.35, tam * 2.4, "destaque", 0.5 * U);
  chaves(tr(an, "Scale"), [[tnum + 0.2, [60, 60]], [tnum + 0.2 + 0.6 * vel, [100, 100]]]);
  chaves(tr(an, "Opacity"), [[tnum + 0.2, 0], [tnum + 0.5, 100]]);
}
if (E.contexto) {
  var lw = VERT ? 88 * U : 110 * U;
  var cx = bloco("Contexto", E.contexto, esq ? x0 : (W - lw) / 2, base + 8 * U, lw,
                 {papel: "fT", peso: 500, tam: (VERT ? 5.6 : 4.2) * U, cor: "texto", alinhar: alinhar, entrelinha: 1.25});
  entrar(cx, "baixo", tnum + 0.6 * vel, 0.7);
}
