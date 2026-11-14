// Linha do tempo em estrada (motor EffectCraft): os marcos (ano + rótulo) vêm de longe pela estrada,
// o atual para no centro em destaque e os seguintes esperam ao longe. Profundidade feita por perspectiva
// de ponto de fuga (posição, escala e opacidade por camada), sem câmera 3D: simples de editar à mão.
var lados = B.lados === "direita" ? "direita" : "alternados";
if (DADOS.tela_cheia) fundoTela(); else veuBaixo(0.9);

// ---- dados
var marcos = [], lista = E.marcos || [], i, k;
for (i = 0; i < lista.length && marcos.length < 6; i++) {
  var m = lista[i] || {};
  var an = String(m.rotulo !== undefined ? m.rotulo : (m.ano || "")), ro = String(m.valor !== undefined ? m.valor : (m.rotulo_marco || ""));
  if (an) marcos.push({ano: an, rotulo: ro});
}
var N = marcos.length, D = N - 1;
if (E.destaque) {
  var dq = String(E.destaque).toLowerCase();
  for (i = 0; i < N; i++) if (marcos[i].ano.toLowerCase() === dq || marcos[i].rotulo.toLowerCase() === dq) D = i;
}

if (N > 0) {
  // ---- geometria
  var CX = W / 2, YH = H * (VERT ? 0.25 : 0.22), YA = H * 0.58;
  var wb = (VERT ? 66 : 46) * U, dy = H - YH;
  var OFF = (VERT ? 30 : 26) * U;
  var CA = VERT ? 170 : 190, RS = VERT ? 165 : 190;

  // ---- estrada: faixa em trapézio (máscara editável) e bordas
  var estrada = CONTEUDO.layers.addSolid(corRGB("fundo2"), "Estrada", W, H, 1);
  var mk = estrada.property("Masks").addProperty("Mask");
  mk.name = "Trapézio da estrada";
  var fm = new Shape();
  fm.vertices = [[CX, YH], [CX + wb, H + 4], [CX - wb, H + 4]];
  fm.closed = true;
  mk.property("Mask Path").setValue(fm);
  mk.property("Mask Feather").setValue([2, 2]);
  chaves(tr(estrada, "Opacity"), [[T0, 0], [T0 + 0.7, DADOS.tela_cheia ? 70 : 45]]);

  var Lb = Math.sqrt(wb * wb + dy * dy), ang = Math.atan2(dy, wb) * 180 / Math.PI;
  var bd = retangulo("Borda direita da estrada", CX + wb / 2 - Lb / 2, (YH + H) / 2 - 0.2 * U, Lb, 0.4 * U, "apoio", 100);
  tr(bd, "Rotation").setValue(ang);
  chaves(tr(bd, "Opacity"), [[T0, 0], [T0 + 0.7, 70]]);
  var be = retangulo("Borda esquerda da estrada", CX - wb / 2 - Lb / 2, (YH + H) / 2 - 0.2 * U, Lb, 0.4 * U, "apoio", 100);
  tr(be, "Rotation").setValue(-ang);
  chaves(tr(be, "Opacity"), [[T0, 0], [T0 + 0.7, 70]]);

  // faixas centrais que correm em direção à câmera (expressão: editável)
  for (i = 0; i < 6; i++) {
    var fx = retangulo("Faixa central " + (i + 1), CX - 0.3 * U, 0, 0.6 * U, 4 * U, "texto", 100);
    var ph = '((time*0.45+' + i + '/6)%1)';
    tr(fx, "Position").expression =
      'var ph=' + ph + ', d=5*(1-ph), s=1/(1+0.6*d);\n[' + CX + ',' + YH + '+(' + H + '-' + YH + ')*s];';
    tr(fx, "Scale").expression = 'var ph=' + ph + ', d=5*(1-ph), s=1/(1+0.6*d);\n[100*s,100*s];';
    tr(fx, "Opacity").expression = 'var ph=' + ph + ';\n40*Math.min(1,ph*4,(1-ph)*4);';
  }

  // ---- estados de cada marco: d = distância até o marco atual (0 = atual, 1.. = ao longe, <0 = já passou)
  function estado(ix, passo) {
    var d = ix - passo, lado = (lados === "direita" || ix % 2 === 0) ? 1 : -1, e = {};
    if (d < 0) {
      e.ax = CX + lado * OFF * 1.6; e.ay = YA + 6 * U; e.as = CA * 1.3;
      e.rx = e.ax; e.ry = e.ay + 9 * U; e.rs = RS * 1.3;
      e.dx = CX; e.dy = YA + 15 * U; e.ds = 100; e.op = 0;
    } else if (d === 0) {
      e.ax = CX; e.ay = YA; e.as = CA;
      e.rx = CX; e.ry = YA + (VERT ? 8 : 8.5) * U; e.rs = RS;
      e.dx = CX; e.dy = YA + 15 * U; e.ds = 170; e.op = 100;
    } else {
      var dd = Math.min(d, 4), s = 1 / (1 + 0.6 * dd);
      e.ax = CX + lado * OFF * s; e.ay = YH + (YA - YH) * s; e.as = 100 * s;
      e.rx = e.ax; e.ry = e.ay + 5 * U * s; e.rs = 100 * s;
      e.dx = CX; e.dy = e.ay; e.ds = 100 * s;
      e.op = Math.max(0, 100 * (1.15 - 0.3 * d));
    }
    return e;
  }

  // ---- tempos
  var t0 = T0 + 0.9, seg = 1.0;
  if (D > 0) {
    seg = Math.min(1.8, Math.max(0.5, (FIM - 0.5 - t0) / D));
    if (BAT.destaque !== undefined) {
      var sb = (BAT.destaque - t0) / D;
      if (sb >= 0.5 && BAT.destaque < FIM - 0.2) seg = sb;
    }
  }
  var mov = Math.min(0.65, seg * 0.7);

  // ---- camadas (do mais longe para o mais perto, para o perto ficar por cima)
  for (i = N - 1; i >= 0; i--) {
    var mc = marcos[i];
    var pt = linha("Marco " + (i + 1) + " · ano", mc.ano, CX, YA, {papel: "fD", peso: 800, tam: 8 * U, cor: "destaque", justify: "center"});
    var rt = linha("Marco " + (i + 1) + " · rótulo", mc.rotulo || " ", CX, YA, {papel: "fT", peso: 600, tam: (VERT ? 3.8 : 3.2) * U, cor: "texto", justify: "center"});
    var pn = elipse("Marco " + (i + 1) + " · ponto na estrada", CX, YA, 2.4 * U, "destaque");

    var ks = [], pre = estado(i, -1);
    pre.op = 0;
    ks.push([Math.max(0, T0 + 0.1 * i), pre]);
    ks.push([t0, estado(i, 0)]);
    var prev = t0;
    for (k = 1; k <= D; k++) {
      var tk = t0 + k * seg, dep = tk - mov;
      if (dep > prev + 0.01) ks.push([dep, estado(i, k - 1)]);
      ks.push([tk, estado(i, k)]);
      prev = tk;
    }
    var pa = [], sa = [], pr = [], sr = [], pp = [], sp = [], op = [], oo = [];
    for (var j = 0; j < ks.length; j++) {
      var tt = ks[j][0], e = ks[j][1];
      pa.push([tt, [e.ax, e.ay]]); sa.push([tt, [e.as, e.as]]);
      pr.push([tt, [e.rx, e.ry]]); sr.push([tt, [e.rs, e.rs]]);
      pp.push([tt, [e.dx, e.dy]]); sp.push([tt, [e.ds, e.ds]]);
      op.push([tt, e.op]);
    }
    chaves(tr(pt, "Position"), pa); chaves(tr(pt, "Scale"), sa); chaves(tr(pt, "Opacity"), op);
    chaves(tr(rt, "Position"), pr); chaves(tr(rt, "Scale"), sr); chaves(tr(rt, "Opacity"), op);
    chaves(tr(pn, "Position"), pp); chaves(tr(pn, "Scale"), sp); chaves(tr(pn, "Opacity"), op);
    desfoque(pt, [[Math.max(0, T0 + 0.1 * i), 10], [t0, 0]]);
  }
}
