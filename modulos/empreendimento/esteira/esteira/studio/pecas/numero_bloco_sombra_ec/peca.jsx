// Número de impacto 2,5D (motor EffectCraft): bloco espesso com sombra que vem de longe, unidade que encaixa ao lado
// e legenda num cartão à frente. Profundidade por escala, desfoque e camadas de extrusão; tudo pela pele.
var vel = {lenta: 1.6, normal: 1.0, rapida: 0.65}[B.velocidade] || 1.0;
var camadasEx = {fina: 4, media: 7, grossa: 11}[B.espessura] || 7;
if (DADOS.tela_cheia) fundoTela(); else veuBaixo(0.85);

var tnum = BAT.valor !== undefined ? BAT.valor : T0 + 0.15;
var valor = String(E.valor || "");
var unidade = String(E.unidade || "").replace(/^\s+/, "");

// medição: cabe o conjunto número + unidade na largura segura
var tam0 = (VERT ? 20 : 26) * U, maxW = W - 12 * U;
var sonda = linha("Sonda", valor, 0, 0, {papel: "fD", peso: 800, tam: tam0, tracking: -30});
var nw0 = largura(sonda); sonda.remove();
var uw0 = 0;
if (unidade) { sonda = linha("Sonda", unidade, 0, 0, {papel: "fD", peso: 700, tam: tam0 * 0.42}); uw0 = largura(sonda); sonda.remove(); }
var gap0 = unidade ? tam0 * 0.12 : 0;
var f = Math.min(1, maxW / Math.max(1, nw0 + uw0 + gap0));
var tam = tam0 * f, nw = nw0 * f, uw = uw0 * f, gap = gap0 * f;
var xn = (W - (nw + gap + uw)) / 2, base = H * 0.47 + tam * 0.35;
var esp = Math.max(0.12 * U, tam * 0.012);

// chegada em profundidade: pequeno e desfocado ao longe, passa um pouco do ponto e assenta
function chegada(l, t, dur, dx, dy, s0) {
  var p = tr(l, "Position").value;
  chaves(tr(l, "Position"), [[t, [p[0] + dx, p[1] + dy]], [t + dur, [p[0], p[1]]]]);
  chaves(tr(l, "Scale"), [[t, [s0, s0]], [t + dur, [104, 104]], [t + dur + 0.25, [100, 100]], [FIM, [102, 102]]]);
  chaves(tr(l, "Opacity"), [[t, 0], [t + dur * 0.5, 100]]);
  desfoque(l, [[t, 14], [t + dur * 0.85, 0]]);
}
// bloco espesso: camadas de extrusão (do fundo para a frente) e a face por cima
function blocoEspesso(nome, texto, x, y, t, dur, dx, dy, s0, o) {
  var camadas = [];
  for (var i = o.camadas; i >= 1; i--) {
    var c = linha(nome + " (profundidade " + i + ")", texto, x + i * esp * 0.8, y + i * esp, o.base);
    camadas.push(c);
  }
  var face = linha(nome + " (face)", texto, x, y, o.frente);
  camadas.push(face);
  for (var k = 0; k < camadas.length; k++) chegada(camadas[k], t, dur, dx, dy, s0);
  return face;
}

// sombra no chão, achatada e desfocada
var sombra = elipse("Sombra no chão", W / 2, base + esp * camadasEx + tam * 0.12, nw + gap + uw, "apoio");
tr(sombra, "Scale").setValue([100, 14]);
tr(sombra, "Opacity").setValue(0);
chaves(tr(sombra, "Opacity"), [[tnum, 0], [tnum + 0.8 * vel, 45]]);
desfoque(sombra, [[0, 2.2 * U]]);

blocoEspesso("Número", valor, xn, base, tnum, 0.9 * vel, 0, -4 * U, 34,
  {camadas: camadasEx, base: {papel: "fD", peso: 800, tam: tam, cor: "apoio", tracking: -30},
   frente: {papel: "fD", peso: 800, tam: tam, cor: "destaque", tracking: -30}});

if (unidade) {
  var tu = tnum + 0.75 * vel;
  blocoEspesso("Unidade", unidade, xn + nw + gap, base, tu, 0.7 * vel, 7 * U, 0, 62,
    {camadas: Math.max(2, Math.round(camadasEx * 0.5)), base: {papel: "fD", peso: 700, tam: tam * 0.42, cor: "apoio"},
     frente: {papel: "fD", peso: 700, tam: tam * 0.42, cor: "texto"}});
}

// legenda num cartão à frente (plano mais próximo: entra maior e mais nítido)
if (E.legenda) {
  var lw = VERT ? 86 * U : 72 * U, pad = 2.6 * U, tl = (VERT ? 4.8 : 3.8) * U;
  var sem = String(E.legenda).replace(/\*/g, "");
  var linhas = Math.min(3, Math.max(1, Math.ceil(sem.length * 0.52 * tl / (lw - 2 * pad))));
  var ch = linhas * tl * 1.3 + 2 * pad, cy = base + esp * camadasEx + 9 * U, tl0 = tnum + 1.15 * vel;
  var txt = bloco("Legenda", E.legenda, (W - lw) / 2 + pad, cy + pad, lw - 2 * pad,
                  {papel: "fT", peso: 600, tam: tl, cor: "texto", alinhar: "centro", entrelinha: 1.25});
  var cartao = retangulo("Cartão da legenda", (W - lw) / 2, cy, lw, ch, "fundo2", 94, 1.5 * U);
  var sc = retangulo("Sombra do cartão", (W - lw) / 2 + 0.6 * U, cy + 1.4 * U, lw, ch, "apoio", 35, 1.5 * U);
  var barra = retangulo("Filete de destaque", (W - lw) / 2, cy, 0.7 * U, ch, "destaque", 100, 0.3 * U);
  sc.moveAfter(txt); cartao.moveAfter(txt); barra.moveAfter(txt);
  cartao.moveAfter(barra); sc.moveAfter(cartao);
  var grupo = [txt, cartao, sc, barra];
  for (var g = 0; g < grupo.length; g++) {
    var pg = tr(grupo[g], "Position").value;
    chaves(tr(grupo[g], "Position"), [[tl0, [pg[0], pg[1] + 6 * U]], [tl0 + 0.7, [pg[0], pg[1]]]]);
    chaves(tr(grupo[g], "Scale"), [[tl0, [108, 108]], [tl0 + 0.7, [100, 100]]]);
    chaves(tr(grupo[g], "Opacity"), [[tl0, 0], [tl0 + 0.4, g === 2 ? 35 : (g === 1 ? 94 : 100)]]);
    desfoque(grupo[g], [[tl0, 8], [tl0 + 0.55, 0]]);
  }
}
