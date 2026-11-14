// Núcleo das peças do motor EffectCraft (estudio/pecas/<id>/peca.jsx). O Python monta o script assim:
//   var DADOS = {...};  +  este núcleo  +  peca.jsx  +  _ec/fim.jsx
// DADOS: {encaixes, botoes, batidas, t0, dur, w, h, fps, pele: {fundo, fundo2, texto, destaque, apoio, acento,
//         fD, fT, fM, fE, fL}, area, instantes, tela_cheia}
// A peça desenha na comp CONTEUDO (camadas com nomes em português, editáveis à mão no EffectCraft) a partir de T0;
// o fim (_ec/fim.jsx) põe tudo na comp "Peça" com a saída e mede o texto fora da área segura.
// Pele por papel: nenhuma cor nem fonte fixa na peça; use cor("destaque"), corRGB("fundo"), fonte("fD", 800).

var E = DADOS.encaixes || {}, B = DADOS.botoes || {}, BAT = DADOS.batidas || {};
var W = DADOS.w, H = DADOS.h, DUR = DADOS.dur, FPS = DADOS.fps || 30, VERT = H > W, U = Math.min(W, H) / 100;
var T0 = DADOS.t0 || 0, FIM = Math.max(T0 + 0.6, DUR - 0.45);
var PELE = DADOS.pele;
var TAM = {}, ENTRE = {}, LIMITE = {};  // LIMITE: célula [x0, y0, x1, y1] do texto de caixa  // tamanho de fonte por camada de texto (o caber() encolhe)
var CONTEUDO = app.project.items.addComp("Conteúdo", W, H, 1, DUR, FPS);

// ---------------------------------------------------------------- pele
var PAPEIS_COR = {fundo: 1, fundo2: 1, texto: 1, destaque: 1, apoio: 1, acento: 1};
function cor(papel) {
  if (!PAPEIS_COR[papel]) throw new Error("cor: papel inexistente " + papel);
  return PELE[papel] || PELE.texto;
}
function rgb(h) {
  h = String(h).replace("#", "");
  return [parseInt(h.substr(0, 2), 16) / 255, parseInt(h.substr(2, 2), 16) / 255, parseInt(h.substr(4, 2), 16) / 255];
}
function corRGB(papel) { return rgb(cor(papel)); }
// mistura de duas cores da pele (t = 0 → a, 1 → b), em hex
function mistura(a, b, t) {
  var x = corRGB(a), y = corRGB(b), s = "#";
  for (var i = 0; i < 3; i++) { var v = Math.round((x[i] + (y[i] - x[i]) * t) * 255); s += (v < 16 ? "0" : "") + v.toString(16); }
  return s;
}
var NOMES_PESO = {100: "Thin", 200: "ExtraLight", 300: "Light", 400: "Regular", 500: "Medium", 600: "SemiBold",
                  700: "Bold", 800: "ExtraBold", 900: "Black"};
var _estilos = {};
function _disponiveis(familia) {
  if (_estilos[familia] === undefined) {
    var r = app.run("text.fonts", {query: familia});
    var f = null;
    for (var i = 0; r && r.families && i < r.families.length; i++) if (r.families[i].family === familia) f = r.families[i];
    _estilos[familia] = f ? f.styles : [];
  }
  return _estilos[familia];
}
// fonte(papel, peso, italico) → {font, style}: a família da pele e o estilo mais próximo que ela tiver
function fonte(papel, peso, italico) {
  var familia = PELE[papel] || PELE.fT;
  var tem = _disponiveis(familia), alvo = peso || 400, melhor = "Regular", dist = 1e9;
  for (var p in NOMES_PESO) {
    var nome = NOMES_PESO[p];
    if (italico) nome = (nome === "Regular" ? "" : nome + " ") + "Italic";
    var ok = false;
    for (var i = 0; i < tem.length; i++) if (tem[i] === nome) ok = true;
    if (ok && Math.abs(p - alvo) < dist) { dist = Math.abs(p - alvo); melhor = nome; }
  }
  if (dist === 1e9 && italico) return fonte(papel, peso, false);
  return {font: familia, style: melhor};
}

// ---------------------------------------------------------------- animação
function tr(l, nome) { return l.property("Transform").property(nome); }
function suavizar(prop, influencia) {
  for (var k = 1; k <= prop.numKeys; k++) {
    var dim = prop.value instanceof Array ? prop.value.length : 1;
    if (prop.propertyValueType === PropertyValueType.TwoD_SPATIAL || prop.propertyValueType === PropertyValueType.ThreeD_SPATIAL) dim = 1;
    var e = [], i;
    for (i = 0; i < dim; i++) e.push(new KeyframeEase(0, k === 1 ? 15 : influencia || 85));
    try { prop.setTemporalEaseAtKey(k, e, e); } catch (x) {}
  }
}
// chaves(prop, [[t, valor], ...]): keyframes suavizados (tempos em s da comp)
function chaves(prop, pares, influencia) {
  var atual = prop.value;
  for (var i = 0; i < pares.length; i++) {
    var v = pares[i][1];
    if (atual instanceof Array && !(v instanceof Array)) v = [v, v];
    if (atual instanceof Array) {  // camada 3D pede [x, y, z]: completa com o valor atual
      v = v.slice(0, atual.length);
      while (v.length < atual.length) v.push(atual[v.length]);
    } else if (v instanceof Array) v = v[0];
    prop.setValueAtTime(Math.max(0, pares[i][0]), v);
  }
  suavizar(prop, influencia);
}
function desfoque(l, pares) {
  var fx = l.property("Effects").addProperty("ADBE Gaussian Blur 2");
  fx.name = "Desfoque";
  chaves(fx.property(1), pares);
  return fx;
}
// filho acompanha o pai na posição e na opacidade
function filho(l, pai) {
  l.parent = pai;
  tr(l, "Opacity").expression = 'value * thisLayer.parent.transform.opacity / 100';
}
// entrar(l, "baixo" | "esq" | "dir" | "aparecer" | "escala", t, dur)
function entrar(l, tipo, t0, dur) {
  dur = dur || 0.7;
  var p = tr(l, "Position").value, o = tr(l, "Opacity");
  var dx = {esq: -6 * U, dir: 6 * U}[tipo] || 0, dy = tipo === "baixo" ? 3 * U : 0;
  chaves(o, [[t0, 0], [t0 + (tipo === "aparecer" ? dur : dur * 0.6), 100]]);
  if (dx || dy) chaves(tr(l, "Position"), [[t0, [p[0] + dx, p[1] + dy]], [t0 + dur, [p[0], p[1]]]]);
  if (tipo === "escala") chaves(tr(l, "Scale"), [[t0, [86, 86]], [t0 + dur, [100, 100]]]);
  if (tipo !== "aparecer") desfoque(l, [[t0, tipo === "baixo" ? 10 : 12], [t0 + dur * 0.8, 0]]);
}
// traço: escala a partir de 0 (ancoragem na borda esquerda; ver retangulo(..., ancoraEsq))
function traco(l, t0, dur, vertical) {
  chaves(tr(l, "Scale"), [[t0, vertical ? [100, 0] : [0, 100]], [t0 + (dur || 0.8), [100, 100]]]);
}
// contagem no Texto de origem (expressão editável): de 0 até `alvo` com `casas`, entre ini e ini + dura
function contagem(l, alvo, casas, ini, dura, antes, depois) {
  l.property("Source Text").expression =
    'var alvo=' + alvo + ', casas=' + (casas || 0) + ', ini=' + ini + ', dura=' + dura + ', a=' + JSON.stringify(antes || "") +
    ', d=' + JSON.stringify(depois || "") + ';\n' +
    'var x=Math.min(Math.max((time-ini)/dura,0),1), e=1-Math.pow(1-x,4), v=(alvo*e).toFixed(casas).split(".");\n' +
    'v[0]=v[0].replace(/\\B(?=(\\d{3})+(?!\\d))/g,"."); a + v.join(",") + d;';
}
// número falado em português → {antes, n, depois, casas}: "R$ 1.200" → R$ | 1200 ; "81,7%" → 81.7 %
function numero(txt) {
  var m = String(txt || "").match(/^(.*?)(\d[\d.]*(?:,\d+)?)(.*)$/);
  if (!m) return null;
  var casas = m[2].indexOf(",") >= 0 ? m[2].split(",")[1].length : 0;
  var n = parseFloat(m[2].replace(/\./g, "").replace(",", "."));
  return isNaN(n) ? null : {antes: m[1], n: n, depois: m[3], casas: casas};
}

// ---------------------------------------------------------------- texto e formas
// Remove *marcas*, devolve {texto, faixas: [[ini, fim]]} para colorir o destaque.
function destaques(s) {
  s = String(s || "");
  var out = "", faixas = [], ini = -1;
  for (var i = 0; i < s.length; i++) {
    var c = s.charAt(i);
    if (c === "*") { if (ini < 0) ini = out.length; else { faixas.push([ini, out.length]); ini = -1; } continue; }
    out += c;
  }
  return {texto: out, faixas: faixas};
}
// bloco(nome, texto, x, y, largura, e): parágrafo com o canto superior esquerdo em (x, y).
// e: {papel ("fD"...), peso, tam (px), cor (papel), alinhar ("centro"|"direita"), tracking, entrelinha, caps, italico}
function bloco(nome, s, x, y, w, e) {
  e = e || {};
  var d = destaques(s), alto = 1600;
  var l = CONTEUDO.layers.addBoxText([w, alto], d.texto || " ");
  l.name = nome;
  tr(l, "Anchor Point").setValue([-w / 2, -alto / 2]);
  tr(l, "Position").setValue([x, y]);
  var f = fonte(e.papel || "fT", e.peso || 500, e.italico);
  var p = {layer: l.id, font: f.font, style: f.style, size: e.tam || 4 * U, fill: cor(e.cor || "texto"),
           justify: {centro: "center", direita: "right"}[e.alinhar] || "left", allCaps: !!e.caps, tracking: e.tracking || 0};
  if (e.entrelinha) p.leading = Math.round(e.entrelinha * (e.tam || 4 * U));
  app.run("layer.setText", p);
  TAM[l.id] = p.size;
  if (e.entrelinha) ENTRE[l.id] = e.entrelinha;
  for (var i = 0; i < d.faixas.length; i++) app.run("layer.setText", {layer: l.id, range: d.faixas[i], fill: cor("destaque")});
  return l;
}
// linha(nome, texto, x, linhaDeBase, e): texto de uma linha; e.justify fixa a borda que não se mexe
function linha(nome, s, x, y, e) {
  e = e || {};
  var l = CONTEUDO.layers.addText(String(s));
  l.name = nome;
  var f = fonte(e.papel || "fD", e.peso || 700, e.italico);
  app.run("layer.setText", {layer: l.id, font: f.font, style: f.style, size: e.tam || 8 * U, fill: cor(e.cor || "texto"),
                            justify: e.justify || "left", tracking: e.tracking || 0});
  TAM[l.id] = e.tam || 8 * U;
  tr(l, "Position").setValue([x, y]);
  return l;
}
// caber(camadas): encolhe a fonte de quem sai da área segura (texto máximo) nos instantes medidos, mantendo o ponto de
// ancoragem (início da linha ou topo do parágrafo). Peças do N1 chamam no fim, depois das animações.
function _pos(l, t) {
  var p = tr(l, "Position").valueAtTime(t, false), x = p[0], y = p[1];
  for (var q = l.parent; q; q = q.parent) {
    var pp = tr(q, "Position").valueAtTime(t, false), aa = tr(q, "Anchor Point").valueAtTime(t, false);
    x += pp[0] - aa[0]; y += pp[1] - aa[1];
  }
  return [x, y];
}
function caber(camadas) {
  var m = (DADOS.area || 0.03) * Math.min(W, H) * 1.15, ts = DADOS.instantes && DADOS.instantes.length ? DADOS.instantes
    : [T0 + 0.3 * (FIM - T0), T0 + 0.6 * (FIM - T0), FIM - 0.05];
  for (var i = 0; i < camadas.length; i++) {
    var l = camadas[i];
    if (!l || !TAM[l.id]) continue;
    var lim = LIMITE[l.id], bx0 = m, by0 = m, bx1 = W - m, by1 = H - m;
    if (lim) { bx0 = Math.max(bx0, lim[0]); by0 = Math.max(by0, lim[1]); bx1 = Math.min(bx1, lim[2]); by1 = Math.min(by1, lim[3]); }
    for (var volta = 0; volta < 5; volta++) {
      var k = 1;
      for (var j = 0; j < ts.length; j++) {
        var t = ts[j], r = l.sourceRectAtTime(t, false);
        if (!r.width || !r.height) continue;
        var p = _pos(l, t), a = tr(l, "Anchor Point").valueAtTime(t, false), s = tr(l, "Scale").valueAtTime(t, false);
        var x0 = p[0] + (r.left - a[0]) * s[0] / 100, y0 = p[1] + (r.top - a[1]) * s[1] / 100;
        var x1 = x0 + r.width * s[0] / 100, y1 = y0 + r.height * s[1] / 100;
        var px = Math.min(Math.max(p[0], x0), x1), py = Math.min(Math.max(p[1], y0), y1);
        // folga de 1 px: o pé de letra de algumas fontes (Playfair) passa 0,1 px da borda da célula, com a âncora
        // na borda; a conta dava k = 0 e o texto encolhia até o piso
        // âncora na borda (k daria 0): encolhe pela razão espaço ÷ tamanho do texto (palavra mais larga que a célula)
        var kx = Math.min(1, (bx1 - bx0) / (x1 - x0)), ky = Math.min(1, (by1 - by0) / (y1 - y0));
        if (x1 > bx1 + 1 && x1 > px) k = Math.min(k, px < bx1 - 1 ? (bx1 - px) / (x1 - px) : kx);
        if (x0 < bx0 - 1 && x0 < px) k = Math.min(k, px > bx0 + 1 ? (px - bx0) / (px - x0) : kx);
        if (y1 > by1 + 1 && y1 > py) k = Math.min(k, py < by1 - 1 ? (by1 - py) / (y1 - py) : ky);
        if (y0 < by0 - 1 && y0 < py) k = Math.min(k, py > by0 + 1 ? (py - by0) / (py - y0) : ky);
      }
      // muito fora: encolher esconderia o erro de layout (o portão acusa); na célula da caixa, encolher é o certo
      if (k >= 0.999 || (k < 0.55 && !lim)) break;
      k = Math.max(k, 0.3);
      TAM[l.id] = Math.max(TAM[l.id] * k * 0.97, U);
      var q = {layer: l.id, size: TAM[l.id]};
      if (ENTRE[l.id]) q.leading = Math.round(ENTRE[l.id] * TAM[l.id]);
      app.run("layer.setText", q);
    }
  }
}
function largura(l, t) { return l.sourceRectAtTime(t || 0, false).width; }
// retangulo(nome, x, y, w, h, papel, opacidade, raio, ancoraEsq)
function retangulo(nome, x, y, w, h, papel, opacidade, raio, ancoraEsq) {
  var s = CONTEUDO.layers.addShape();
  s.name = nome;
  var g = s.property("Contents").addProperty("ADBE Vector Group");
  var r = g.property("Contents").addProperty("ADBE Vector Shape - Rect");
  r.property("Size").setValue([w, h]);
  if (raio) r.property("Roundness").setValue(raio);
  var f = g.property("Contents").addProperty("ADBE Vector Graphic - Fill");
  f.property("Color").setValue(corRGB(papel || "destaque"));
  if (opacidade !== undefined) f.property("Opacity").setValue(opacidade);
  tr(s, "Anchor Point").setValue(ancoraEsq ? [-w / 2, 0] : [0, 0]);
  tr(s, "Position").setValue(ancoraEsq ? [x, y + h / 2] : [x + w / 2, y + h / 2]);
  return s;
}
// elipse(nome, cx, cy, d, papel, contorno): círculo cheio (ou só contorno com a espessura dada)
function elipse(nome, cx, cy, d, papel, contorno, ini, fim) {
  var s = CONTEUDO.layers.addShape();
  s.name = nome;
  var g = s.property("Contents").addProperty("ADBE Vector Group");
  g.property("Contents").addProperty("ADBE Vector Shape - Ellipse").property("Size").setValue([d, d]);
  if (contorno) {
    var st = g.property("Contents").addProperty("ADBE Vector Graphic - Stroke");
    st.property("Color").setValue(corRGB(papel || "destaque"));
    st.property("Stroke Width").setValue(contorno);
    if (ini !== undefined) {  // arco: Trim Paths (fração da volta a partir do topo)
      var tm = g.property("Contents").addProperty("ADBE Vector Filter - Trim");
      tm.property("Start").setValue(Math.min(ini, fim) * 100);
      tm.property("End").setValue(Math.max(ini, fim) * 100);
    }
  } else {
    g.property("Contents").addProperty("ADBE Vector Graphic - Fill").property("Color").setValue(corRGB(papel || "destaque"));
  }
  tr(s, "Position").setValue([cx, cy]);
  return s;
}
// fundo da tela cheia: sólido na cor de fundo da pele + brilho suave na cor de destaque
function fundoTela() {
  var l = CONTEUDO.layers.addSolid(corRGB("fundo"), "Fundo", W, H, 1);
  l.moveToEnd();
  chaves(tr(l, "Opacity"), [[Math.max(0, T0 - 0.1), 0], [T0 + 0.35, 100]]);
  var br = elipse("Brilho", W / 2, H * 0.45, Math.max(W, H) * 0.7, "destaque");
  br.moveBefore(l);
  tr(br, "Opacity").setValue(10);
  desfoque(br, [[0, 18 * U]]);
  return l;
}
// véu na parte de baixo (peças por cima da mídia): sólido de fundo com degradê editável na máscara
function veuBaixo(opac) {
  var l = CONTEUDO.layers.addSolid(corRGB("fundo"), "Véu", W, H, 1);
  l.moveToEnd();
  var m = l.property("Masks").addProperty("Mask");
  m.name = "Degradê";
  var y0 = H * (VERT ? 0.4 : 0.5), f = new Shape();
  f.vertices = [[-50, y0], [W + 50, y0], [W + 50, H + 50], [-50, H + 50]];
  f.closed = true;
  m.property("Mask Path").setValue(f);
  m.property("Mask Feather").setValue([0, H * 0.35]);
  chaves(tr(l, "Opacity"), [[Math.max(0, T0 - 0.05), 0], [T0 + 0.4, (opac || 0.85) * 100]]);
  return l;
}
