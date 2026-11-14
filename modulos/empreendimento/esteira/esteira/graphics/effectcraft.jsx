// Gráficos da esteira no EffectCraft (modelo de objetos do After Effects + app.run para comandos da engine).
// Recebe `DADOS` (injetado pelo Python): {modelo, dados, dur, w, h, cor, fps}. Monta a comp "Conteúdo" com as
// camadas nomeadas em português (editáveis à mão) e a comp "Peça" com os efeitos de entrada/saída da peça.
// Coordenadas em px do quadro; tempos em s. Espelha os modelos HTML de `modelos/` (mesmas posições e tempos).

var D = DADOS.dados, W = DADOS.w, H = DADOS.h, DUR = DADOS.dur, FPS = DADOS.fps || 30, VERT = H > W;
var COR = DADOS.cor || "#ffd400";
var FONTES = {Inter: "InterVar", Playfair: "Playfair Display", Mono: "JetBrains Mono"};
var PESOS = {100: "Thin", 200: "ExtraLight", 300: "Light", 400: "Regular", 500: "Medium", 600: "SemiBold",
             700: "Bold", 800: "ExtraBold", 900: "Black"};

function rgb(h) {
  h = String(h).replace("#", "");
  if (h.length === 3) h = h.charAt(0) + h.charAt(0) + h.charAt(1) + h.charAt(1) + h.charAt(2) + h.charAt(2);
  return [parseInt(h.substr(0, 2), 16) / 255, parseInt(h.substr(2, 2), 16) / 255, parseInt(h.substr(4, 2), 16) / 255];
}
function estiloFonte(fonte, peso, italico) {
  var nome = PESOS[peso] || "Regular";
  if (italico) nome = (nome === "Regular" ? "" : nome + " ") + "Italic";
  return {font: FONTES[fonte] || fonte, style: nome};
}

var conteudo = app.project.items.addComp("Conteúdo", W, H, 1, DUR, FPS);
var peca = app.project.items.addComp("Peça", W, H, 1, DUR, FPS);

// ---------------------------------------------------------------- animação
function suavizar(prop, influencia) {
  for (var k = 1; k <= prop.numKeys; k++) {
    var dim = prop.value instanceof Array ? prop.value.length : 1;
    if (prop.propertyValueType === PropertyValueType.TwoD_SPATIAL || prop.propertyValueType === PropertyValueType.ThreeD_SPATIAL) dim = 1;
    var e = [], i;
    for (i = 0; i < dim; i++) e.push(new KeyframeEase(0, k === 1 ? 15 : influencia || 85));
    try { prop.setTemporalEaseAtKey(k, e, e); } catch (x) {}
  }
}
function chaves(prop, pares, influencia) {
  for (var i = 0; i < pares.length; i++) prop.setValueAtTime(Math.max(0, pares[i][0]), pares[i][1]);
  suavizar(prop, influencia);
}
function desfoque(l, pares) {
  var fx = l.property("Effects").addProperty("ADBE Gaussian Blur 2");
  fx.name = "Desfoque de entrada";
  chaves(fx.property(1), pares);
  return fx;
}
function tr(l, nome) { return l.property("Transform").property(nome); }
// filho acompanha o pai na posição e na opacidade (a opacidade não é herdada pelo parentesco)
function filho(l, pai) {
  l.parent = pai;
  tr(l, "Opacity").expression = 'value * thisLayer.parent.transform.opacity / 100';
}

// entrar-baixo / entrar-esq / entrar-dir / aparecer (keyframes dos modelos HTML)
function entrar(l, tipo, t0, dur) {
  var p = tr(l, "Position").value, o = tr(l, "Opacity");
  var dx = {esq: -80, dir: 80}[tipo] || 0, dy = tipo === "baixo" ? 40 : 0;
  chaves(o, [[t0, 0], [t0 + (tipo === "aparecer" ? dur : dur * 0.6), 100]]);
  if (dx || dy) chaves(tr(l, "Position"), [[t0, [p[0] + dx, p[1] + dy]], [t0 + dur, [p[0], p[1]]]]);
  if (tipo !== "aparecer") desfoque(l, [[t0, tipo === "baixo" ? 10 : 12], [t0 + dur * 0.8, 0]]);
}
// traço: escala horizontal (ou vertical) a partir de 0, com o ponto de ancoragem na borda
function traco(l, t0, dur, vertical) {
  var s = tr(l, "Scale");
  chaves(s, [[t0, vertical ? [100, 0] : [0, 100]], [t0 + dur, [100, 100]]]);
}
// remapeia os keyframes de um preset de animação de texto para [t0, t1]
function presetTexto(l, preset, t0, t1) {
  app.run("layer.applyTextPreset", {layer: l.id, preset: preset});
  var anims = l.property("Text").property("Animators");
  function percorrer(g) {
    for (var i = 1; i <= g.numProperties; i++) {
      var p = g.property(i);
      if (p.numProperties !== undefined && p.propertyType !== PropertyType.PROPERTY) { percorrer(p); continue; }
      if (!p.numKeys || p.numKeys < 2) continue;
      var k0 = p.keyTime(1), k1 = p.keyTime(p.numKeys), vals = [], ts = [];
      for (var k = 1; k <= p.numKeys; k++) { vals.push(p.keyValue(k)); ts.push(p.keyTime(k)); }
      while (p.numKeys) p.removeKey(1);
      for (k = 0; k < vals.length; k++) p.setValueAtTime(t0 + (ts[k] - k0) / Math.max(k1 - k0, 0.001) * (t1 - t0), vals[k]);
    }
  }
  if (anims) percorrer(anims);
}

// ---------------------------------------------------------------- texto e formas
// Remove *marcas* e <b></b>, devolve {texto, faixas: [[ini, fim]]} para colorir o destaque.
function destaques(s) {
  s = String(s || "").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/<\/?b>/g, "*");
  var out = "", faixas = [], ini = -1;
  for (var i = 0; i < s.length; i++) {
    var c = s.charAt(i);
    if (c === "*") { if (ini < 0) ini = out.length; else { faixas.push([ini, out.length]); ini = -1; } continue; }
    out += c;
  }
  return {texto: out, faixas: faixas};
}
// Bloco de texto (parágrafo) com o canto superior esquerdo do quadro em (x, y) e largura w.
// e: {fonte, peso, tam, cor, alinhar, tracking, entrelinha, caps, italico, destaque, sombra}
function bloco(comp, nome, s, x, y, w, e) {
  e = e || {};
  var d = destaques(s), alto = 1600;
  var l = comp.layers.addBoxText([w, alto], d.texto || " ");
  l.name = nome;
  tr(l, "Anchor Point").setValue([-w / 2, -alto / 2]);
  tr(l, "Position").setValue([x, y]);
  var f = estiloFonte(e.fonte || "Inter", e.peso || 500, e.italico);
  var p = {layer: l.id, font: f.font, style: f.style, size: e.tam || 40, fill: e.cor || "#f4f1ea",
           justify: {centro: "center", center: "center", direita: "right", right: "right"}[e.alinhar] || "left",
           allCaps: !!e.caps, tracking: e.tracking || 0};
  if (e.entrelinha) p.leading = Math.round(e.entrelinha * (e.tam || 40));
  app.run("layer.setText", p);
  for (var i = 0; i < d.faixas.length; i++)
    app.run("layer.setText", {layer: l.id, range: d.faixas[i], fill: e.destaque || COR});
  if (e.contorno) app.run("layer.setText", {layer: l.id, stroke: "#000000", applyStroke: true, strokeWidth: e.contorno,
                                            strokeOverFill: false});
  if (e.sombra) {
    var sh = l.property("Effects").addProperty("ADBE Drop Shadow");
    sh.property("Opacity").setValue(e.sombra * 255);
    sh.property("Distance").setValue(3);
    sh.property("Softness").setValue(18);
  }
  return l;
}
// Altura ocupada pelo texto de um bloco (do topo do quadro do bloco até o fim do texto).
function fundo(l) { var r = l.sourceRectAtTime(0, false); return tr(l, "Position").value[1] + r.top + r.height + 800; }
function topoTexto(l) { var r = l.sourceRectAtTime(0, false); return tr(l, "Position").value[1] + r.top + 800; }
function larguraTexto(l) { return l.sourceRectAtTime(0, false).width; }

// Texto de ponto (uma linha, sem caixa): a posição é a linha de base; `justify` fixa a borda que não se mexe.
function pontoTexto(comp, nome, s, e) {
  var l = comp.layers.addText(s);
  l.name = nome;
  var f = estiloFonte(e.fonte || "Inter", e.peso || 500);
  app.run("layer.setText", {layer: l.id, font: f.font, style: f.style, size: e.tam, fill: e.cor || "#ffffff",
                            justify: e.justify || "left", tracking: e.tracking || 0});
  return l;
}

// "LINK NA DESCRIÇÃO ↓": a fonte citada está na descrição do vídeo (o espectador sabe onde conferir).
function selo(comp, x, y, t0, escala) {
  escala = escala || 1;
  var tam = Math.round(19 * escala), pad = Math.round(14 * escala);
  var t = bloco(comp, "Link na descrição (texto)", "LINK NA DESCRIÇÃO ↓", x + pad, y + Math.round(9 * escala), 900,
                {fonte: "Mono", peso: 700, tam: tam, cor: "#0b0c10", caps: true, tracking: 120});
  var alto = fundo(t) - y + Math.round(9 * escala);
  var caixa = retangulo(comp, "Link na descrição", x, y, larguraTexto(t) + 2 * pad, alto, COR, 100, 6, true);
  t.moveBefore(caixa);
  filho(t, caixa);
  entrar(caixa, "baixo", t0, 0.6);
  return alto;
}

function retangulo(comp, nome, x, y, w, h, cor, opacidade, raio, ancoraEsq) {
  var s = comp.layers.addShape();
  s.name = nome;
  var g = s.property("Contents").addProperty("ADBE Vector Group");
  var r = g.property("Contents").addProperty("ADBE Vector Shape - Rect");
  r.property("Size").setValue([w, h]);
  if (raio) r.property("Roundness").setValue(raio);
  var f = g.property("Contents").addProperty("ADBE Vector Graphic - Fill");
  f.property("Color").setValue(rgb(cor));
  if (opacidade !== undefined) f.property("Opacity").setValue(opacidade);
  // ponto de ancoragem: centro, ou borda esquerda (traços que crescem da esquerda)
  tr(s, "Anchor Point").setValue(ancoraEsq ? [-w / 2, 0] : [0, 0]);
  tr(s, "Position").setValue(ancoraEsq ? [x, y + h / 2] : [x + w / 2, y + h / 2]);
  return s;
}
// Véu: sólido escuro; "baixo"/"esquerda" com máscara de borda suave (degradê editável no feather da máscara).
function veu(comp, tipo, opac, t0) {
  var l = comp.layers.addSolid([8 / 255, 9 / 255, 12 / 255], "Véu", W, H, 1);
  l.moveToEnd();
  if (tipo === "baixo" || tipo === "esquerda") {
    var m = l.property("Masks").addProperty("Mask");
    m.name = "Degradê";
    var f = new Shape(), x0, y0;
    if (tipo === "baixo") { y0 = H * (VERT ? 0.3 : 0.38); f.vertices = [[-50, y0 + H * 0.2], [W + 50, y0 + H * 0.2], [W + 50, H + 50], [-50, H + 50]]; }
    else { x0 = W * 0.6; f.vertices = [[-50, -50], [x0 - W * 0.2, -50], [x0 - W * 0.2, H + 50], [-50, H + 50]]; }
    f.closed = true;
    m.property("Mask Path").setValue(f);
    m.property("Mask Feather").setValue(tipo === "baixo" ? [0, H * 0.4] : [W * 0.4, 0]);
  }
  chaves(tr(l, "Opacity"), [[t0 || 0, 0], [(t0 || 0) + 0.45, opac * 100]]);
  return l;
}

// ---------------------------------------------------------------- caixas livres (editor do painel)
function caixas(lista) {
  for (var i = 0; i < (lista || []).length; i++) {
    var c = lista[i], x = W * c.x / 100, y = H * c.y / 100, w = W * c.w / 100;
    var l = bloco(conteudo, "Caixa " + (i + 1), c.texto, x, y, w, {
      fonte: c.fonte, peso: c.peso, tam: c.tam, cor: c.cor, alinhar: c.alinhar === "center" ? "centro" : c.alinhar,
      caps: c.maiusculas, destaque: c.cor_d || COR, entrelinha: 1.12,
      contorno: c.fundo === "contorno" ? Math.round(c.tam * 0.07) : 0, sombra: c.fundo === "nenhum" ? 0.75 : 0});
    if (c.fundo === "solido" || c.fundo === "vidro" || c.fundo === "tarja") {
      // fundo atrás do texto, do tamanho do texto (expressão: acompanha edições feitas à mão)
      var s = retangulo(conteudo, "Fundo da caixa " + (i + 1), 0, 0, 10, 10,
                        c.fundo === "vidro" ? "#080c18" : (c.cor_fundo || "#0a1122"), c.fundo === "vidro" ? 62 : 100, 6);
      s.moveAfter(l);
      var rect = s.property("Contents").property(1).property("Contents").property(1);
      var ref = 'var L=thisComp.layer("' + l.name + '"), b=L.sourceRectAtTime(time,false), m=' + Math.round(c.tam * 0.3) + ';';
      rect.property("Size").expression = ref + '[b.width + 2*m, b.height + m];';
      tr(s, "Anchor Point").setValue([0, 0]);
      tr(s, "Position").expression = ref + 'L.toComp([b.left + b.width/2, b.top + b.height/2]);';
      tr(s, "Opacity").expression = 'thisComp.layer("' + l.name + '").transform.opacity';
      if (c.fundo === "tarja") {
        var tj = retangulo(conteudo, "Tarja da caixa " + (i + 1), 0, 0, Math.round(c.tam * 0.14), 10, COR);
        tj.moveAfter(l);
        var r2 = tj.property("Contents").property(1).property("Contents").property(1);
        r2.property("Size").expression = ref + '[' + Math.round(c.tam * 0.14) + ', b.height + m];';
        tr(tj, "Position").expression = ref + 'L.toComp([b.left - m, b.top + b.height/2]);';
        tr(tj, "Opacity").expression = 'thisComp.layer("' + l.name + '").transform.opacity';
      }
    }
    var ent = c.entrada || "subir", t0 = c.atraso || 0, v = c.vel || 0.6;
    if (ent === "subir") entrar(l, "baixo", t0, v);
    else if (ent === "esquerda") entrar(l, "esq", t0, v);
    else if (ent === "fade") entrar(l, "aparecer", t0, v);
    else if (ent === "zoom") { chaves(tr(l, "Opacity"), [[t0, 0], [t0 + v * 0.6, 100]]); chaves(tr(l, "Scale"), [[t0, [80, 80]], [t0 + v, [100, 100]]]); }
    else if (ent === "revelar") presetTexto(l, "typewriter", t0, t0 + v);
  }
}

// ---------------------------------------------------------------- modelos
var MODELOS = {};

MODELOS.numero = function () {
  veu(conteudo, "total", 0.84, 0);
  var cx = 0, larg = W, y = H * 0.5 - (VERT ? 330 : 300);
  if (D.rotulo) { var r = bloco(conteudo, "Rótulo", D.rotulo, cx, y, larg, {fonte: "Mono", peso: 600, tam: 22, cor: COR, alinhar: "centro", caps: true, tracking: 220}); entrar(r, "baixo", 0.15, 0.7); }
  var n = String(D.prefixo || "") + String(D.valor) + String(D.sufixo || "");
  var tam = VERT ? (n.length <= 5 ? 200 : n.length <= 8 ? 150 : 118) : 250;
  // texto final da contagem (mesma regra da expressão): mede o número pronto para centralizar número + sufixo
  var partes = Number(D.valor).toFixed(D.casas).split(".");
  partes[0] = partes[0].replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  var final = String(D.prefixo || "") + partes.join(",");
  var base = y + 40 + tam * 0.93;  // linha de base do número
  // número alinhado à direita: a borda colada no sufixo não se mexe enquanto os dígitos crescem
  var num = pontoTexto(conteudo, "Número (conta até o valor)", final, {peso: 800, tam: tam, justify: "right", tracking: -40});
  var rn = num.sourceRectAtTime(0, false), wN = rn.width, sf = null, rs = null, gap = Math.round(tam * 0.07);
  if (D.sufixo) {
    sf = pontoTexto(conteudo, "Sufixo", String(D.sufixo), {peso: 700, tam: Math.round(tam * 0.42), cor: COR});
    rs = sf.sourceRectAtTime(0, false);
  }
  var total = wN + (sf ? gap + rs.width : 0), x0 = W / 2 - total / 2;
  tr(num, "Position").setValue([x0 + wN - (rn.left + rn.width), base]);
  if (sf) tr(sf, "Position").setValue([x0 + wN + gap - rs.left, base]);
  // contador: expressão no Texto de origem (edite o valor, as casas e o tempo aqui)
  num.property("Source Text").expression =
    'var alvo=' + D.valor + ', casas=' + D.casas + ', ini=.35, dura=1.2, pre=' + JSON.stringify(D.prefixo || "") + ';\n' +
    'var x=Math.min(Math.max((time-ini)/dura,0),1), e=1-Math.pow(1-x,4), v=(alvo*e).toFixed(casas).split(".");\n' +
    'v[0]=v[0].replace(/\\B(?=(\\d{3})+(?!\\d))/g,"."); pre + v.join(",");';
  entrar(num, "baixo", 0.25, 0.9);
  if (sf) entrar(sf, "baixo", 0.25, 0.9);
  var yl = y + 40 + tam * 1.15 + 34;
  var linha = retangulo(conteudo, "Traço", W / 2 - 260, yl, 520, 4, COR, 100, 0, true);
  traco(linha, 0.7, 0.9);
  if (D.legenda) {
    var lg = bloco(conteudo, "Legenda", D.legenda, VERT ? 90 : (W - 1300) / 2, yl + 38, VERT ? W - 180 : 1300,
                   {tam: VERT ? 48 : 46, cor: "#e9e4d8", alinhar: "centro", entrelinha: 1.3, destaque: COR});
    entrar(lg, "baixo", 0.9, 0.8);
  }
  if (D.fonte) {
    var fo = bloco(conteudo, "Fonte do dado", "Fonte: " + D.fonte, VERT ? 90 : 0, H - (VERT ? 440 : 90) - 30, VERT ? W - 180 : W,
                   {fonte: "Mono", tam: 22, cor: "#8f8a80", alinhar: "centro"});
    entrar(fo, "aparecer", 1.3, 0.6);
  }
};

MODELOS.citacao = function () {
  veu(conteudo, "total", 0.88, 0);
  // janela com a página do artigo: comp própria (recorta a imagem), câmera aproxima do trecho
  var jan = app.project.items.addComp("Janela do artigo", D.jw, D.jh, 1, DUR, FPS);
  jan.layers.addSolid(rgb("#1b1c20"), "Fundo da janela", D.jw, D.jh, 1);
  var arq = String(D.img).replace(/^file:\/\//, "");
  var item = app.project.importFile(new ImportOptions(new File(decodeURIComponent(arq))));
  item.name = "Página do artigo";
  var img = jan.layers.add(item);
  img.name = "Página (câmera)";
  tr(img, "Anchor Point").setValue([0, 0]);
  var cam = D.cam || 0.7, camDur = D.cam_dur || 2.1;  // câmera lenta: dá tempo de ver a página antes do trecho
  chaves(tr(img, "Position"), [[cam, [D.tx0, D.ty0]], [cam + camDur, [D.tx1, D.ty1]]], 70);
  chaves(tr(img, "Scale"), [[cam, [D.s0 * 100, D.s0 * 100]], [cam + camDur, [D.s1 * 100, D.s1 * 100]]], 70);
  for (var i = 0; i < (D.rects || []).length; i++) {
    var rc = D.rects[i];
    var m = retangulo(jan, "Marca-texto " + (i + 1), rc[0] - 6, rc[1] - 3, rc[2] - rc[0] + 12, rc[3] - rc[1] + 6, COR, 100, 3, true);
    m.parent = img;  // coordenadas em px da página (o ponto de ancoragem da imagem é o canto 0,0)
    tr(m, "Position").setValue([rc[0] - 6, (rc[1] + rc[3]) / 2]);
    tr(m, "Scale").setValue([100, 100]);
    tr(m, "Rotation").setValue(0);
    tr(m, "Opacity").setValue(50);
    m.blendingMode = BlendingMode.MULTIPLY;
    traco(m, D.t_marca + i * (D.passo_marca || 0.28), 0.5);
  }
  var lj = conteudo.layers.add(jan);
  lj.name = "Janela do artigo";
  tr(lj, "Position").setValue([D.jx + D.jw / 2, D.jy + D.jh / 2]);
  var sh = lj.property("Effects").addProperty("ADBE Drop Shadow");
  sh.property("Opacity").setValue(150); sh.property("Distance").setValue(40); sh.property("Softness").setValue(90);
  sh.property("Direction").setValue(180);
  entrar(lj, "esq", 0.1, 0.9);
  // ficha do estudo: autor em destaque, título, revista, trecho original (EN) e tradução (PT), link na descrição.
  // Se não couber na altura, é refeita com letra menor.
  var limite = VERT ? H - 140 : H - 110, criadas = [], escala = 1, yfim = 0;
  for (var tentativa = 0; tentativa < 5; tentativa++) {
    criadas = [];
    yfim = ficha(escala, criadas);
    if (yfim <= limite) break;
    for (var c = 0; c < criadas.length; c++) criadas[c].remove();
    escala *= 0.88;
  }
};

function ficha(k, criadas) {
  var y = D.fy, fw = D.fw, fx = D.fx;
  function b(nome, s, x, yy, w, e, t0) { var l = bloco(conteudo, nome, s, x, yy, w, e); criadas.push(l); entrar(l, "baixo", t0, 0.8); return l; }
  var r = b("Rótulo", D.rotulo, fx, y, fw, {fonte: "Mono", peso: 600, tam: 22, cor: COR, caps: true, tracking: 220}, 0.9);
  y = fundo(r) + Math.round(18 * k);
  if (D.autores) { var au = b("Autores", D.autores, fx, y, fw, {peso: 700, tam: Math.round(34 * k), cor: "#ffffff", entrelinha: 1.2}, 1.0); y = fundo(au) + Math.round(12 * k); }
  var ti = b("Título do estudo", D.titulo, fx, y, fw, {fonte: "Playfair", peso: 600, italico: true, tam: Math.round((VERT ? 38 : 36) * k), entrelinha: 1.15, cor: "#e9e4d8"}, 1.1);
  y = fundo(ti) + Math.round(10 * k);
  if (D.revista) { var rv = b("Revista", D.revista, fx, y, fw, {fonte: "Mono", tam: Math.round(19 * k), cor: "#8f8a80", entrelinha: 1.4}, 1.2); y = fundo(rv); }
  if (D.en) {
    y += Math.round(30 * k);
    var le = b("Trecho original (rótulo)", "TRECHO ORIGINAL", fx, y, fw, {fonte: "Mono", peso: 600, tam: Math.round(15 * k), cor: COR, tracking: 200}, D.t_marca);
    y = fundo(le) + Math.round(8 * k);
    var en = b("Trecho original (EN)", "“" + D.en + "”", fx, y, fw, {italico: true, tam: Math.round(28 * k), cor: "#c9c3b6", entrelinha: 1.38}, D.t_marca);
    y = fundo(en);
  }
  if (D.citacao) {
    y += Math.round((D.en ? 24 : 40) * k);
    var t0 = D.t_pt || D.t_marca;
    if (D.en) { var lp = b("Tradução (rótulo)", "TRADUÇÃO", fx, y, fw, {fonte: "Mono", peso: 600, tam: Math.round(15 * k), cor: COR, tracking: 200}, t0); y = fundo(lp) + Math.round(8 * k); }
    var tc = b("Trecho citado", "“" + D.citacao + "”", fx + 24, y, fw - 24,
               {fonte: "Playfair", peso: 500, tam: Math.round((VERT ? 42 : 38) * k), cor: "#ffffff", entrelinha: 1.32}, t0);
    app.run("layer.setText", {layer: tc.id, range: [0, 1], fill: COR});
    app.run("layer.setText", {layer: tc.id, range: [D.citacao.length + 1, D.citacao.length + 2], fill: COR});
    var alto = fundo(tc) - y;
    var barra = retangulo(conteudo, "Barra do trecho", fx, y, 4, alto, COR);
    criadas.push(barra); entrar(barra, "baixo", t0, 0.8);
    y = fundo(tc);
  }
  if (D.link) {
    y += Math.round(26 * k);
    var n0 = conteudo.numLayers;
    y += selo(conteudo, fx, y, 1.6, k);
    for (var i = 1; i <= conteudo.numLayers; i++) if (/^Link na descrição/.test(conteudo.layer(i).name)) criadas.push(conteudo.layer(i));
  }
  return y;
}

MODELOS.capitulo = function () {
  veu(conteudo, "total", 0.72, 0);
  var x = VERT ? 80 : 160, larg = W - x - (VERT ? 120 : 160);
  var tam = VERT ? (D.nome.length < 20 ? 104 : 84) : (D.nome.length < 28 ? 112 : 88);
  var nome = bloco(conteudo, "Nome do capítulo", D.nome, x, 0, VERT ? larg : Math.min(larg, 1450),
                   {fonte: "Playfair", peso: 700, italico: true, tam: tam, entrelinha: 1.05, tracking: -10});
  var altNome = fundo(nome) - topoTexto(nome);
  var sub = D.sub ? 28 + 40 : 0, rot = D.rotulo ? 34 + 26 : 0;
  var y0 = H / 2 - (altNome + sub + rot) / 2;
  if (D.rotulo) {
    var tc = retangulo(conteudo, "Traço do número", x, y0 + 12, 90, 3, COR, 100, 0, true);
    traco(tc, 0.1, 0.7);
    var r = bloco(conteudo, "Número do capítulo", D.rotulo, x + 112, y0, larg - 112, {fonte: "Mono", peso: 800, tam: 34, cor: COR, tracking: 300});
    entrar(r, "esq", 0.1, 0.7);
  }
  tr(nome, "Position").setValue([x, y0 + rot]);
  presetTexto(nome, "blurIn", 0.3, 0.3 + D.nome.length * 0.025 + 0.7);
  if (D.sub) {
    var s = bloco(conteudo, "Subtítulo", D.sub, x, y0 + rot + altNome + 28, larg, {tam: 30, cor: "#b9b3a6", entrelinha: 1.3});
    entrar(s, "baixo", 0.9, 0.8);
  }
};

MODELOS.comparacao = function () {
  veu(conteudo, "total", 0.82, 0);
  function lado(chave, x, y, w, alinhar, tipo, t0, corNome, tItens) {
    var nomeL = chave === "a" ? "A" : "B";
    if (D["rotulo_" + chave]) { var r = bloco(conteudo, "Rótulo " + nomeL, D["rotulo_" + chave], x, y, w, {fonte: "Mono", peso: 600, tam: 22, cor: "#8f8a80", caps: true, tracking: 220, alinhar: alinhar}); entrar(r, tipo, t0, 0.8); y = fundo(r) + 20; }
    var n = bloco(conteudo, "Nome " + nomeL, D["nome_" + chave], x, y, w, {peso: 800, tam: VERT ? 84 : 92, tracking: -30, cor: corNome, alinhar: alinhar});
    entrar(n, tipo, t0, 0.8); y = fundo(n) + (VERT ? 26 : 44);
    var itens = D["itens_" + chave] || [];
    for (var i = 0; i < itens.length; i++) {
      var it = bloco(conteudo, "Item " + nomeL + (i + 1), itens[i], x, y + 22, w, {tam: 34, cor: "#e6e1d6", entrelinha: 1.3, alinhar: alinhar});
      entrar(it, "baixo", tItens + i * 0.35, 0.6); y = fundo(it);
    }
  }
  if (VERT) {
    lado("a", 80, 300, W - 200, "esquerda", "esq", 0.15, "#f4f1ea", 0.9);
    lado("b", 80, 1000, W - 200, "esquerda", "dir", 0.3, COR, 1.05);
    var vs = bloco(conteudo, "vs", "vs", 80, 860, 300, {fonte: "Playfair", peso: 700, italico: true, tam: 64, cor: "#6f6a61"});
    entrar(vs, "aparecer", 0.5, 0.6);
  } else {
    lado("a", 170, 200, 700, "esquerda", "esq", 0.15, "#f4f1ea", 0.9);
    lado("b", W - 170 - 700, 200, 700, "direita", "dir", 0.3, COR, 1.05);
    var v = bloco(conteudo, "vs", "vs", W / 2 - 150, 250, 300, {fonte: "Playfair", peso: 700, italico: true, tam: 64, cor: "#6f6a61", alinhar: "centro"});
    entrar(v, "aparecer", 0.5, 0.6);
    var eixo = retangulo(conteudo, "Eixo", W / 2 - 1, 360, 2, 460, "#ffffff", 15);
    tr(eixo, "Anchor Point").setValue([0, -230]); tr(eixo, "Position").setValue([W / 2, 360]);
    traco(eixo, 0.5, 0.8, true);
  }
};

MODELOS.fonte = function () {
  var x = VERT ? 60 : 90, baixo = VERT ? 460 : 90, largMax = VERT ? 900 : 1100;
  var r = bloco(conteudo, "Rótulo", D.rotulo || "Fonte", x + 30, 0, largMax - 54, {fonte: "Mono", peso: 600, tam: 17, cor: COR, caps: true, tracking: 220});
  var l1 = bloco(conteudo, "Linha 1", D.linha1, x + 30, 0, largMax - 54, {peso: 600, tam: VERT ? 34 : 30, entrelinha: 1.25});
  var l2 = D.linha2 ? bloco(conteudo, "Linha 2", D.linha2, x + 30, 0, largMax - 54, {fonte: "Mono", tam: 20, cor: "#9a958b", entrelinha: 1.3}) : null;
  var hR = fundo(r) - topoTexto(r), h1 = fundo(l1) - topoTexto(l1), h2 = l2 ? fundo(l2) - topoTexto(l2) + 6 : 0;
  var alto = 20 + hR + 10 + h1 + h2 + 22, y = H - baixo - alto;
  var larg = Math.min(largMax, Math.max(larguraTexto(r), larguraTexto(l1), l2 ? larguraTexto(l2) : 0) + 54);
  tr(r, "Position").setValue([x + 30, y + 20 - 4]);
  tr(l1, "Position").setValue([x + 30, y + 20 + hR + 10 - 6]);
  if (l2) tr(l2, "Position").setValue([x + 30, y + 20 + hR + 10 + h1 + 6 - 4]);
  var cx = retangulo(conteudo, "Caixa", x, y, larg, alto, "#0a0b0e", 82, 10);
  cx.moveToEnd();
  var bar = retangulo(conteudo, "Barra", x, y, 6, alto, COR);
  // a caixa e a barra entram juntas (pai = caixa)
  filho(bar, cx);
  entrar(cx, "esq", 0, 0.7);
  entrar(r, "aparecer", 0.25, 0.5); entrar(l1, "aparecer", 0.25, 0.5);
  if (l2) entrar(l2, "aparecer", 0.4, 0.5);
  if (D.link) selo(conteudo, x, y + alto + 12, 0.6, 0.9);
};

MODELOS.frase = function () {
  var vh = VERT ? 0.7 : 0.62;
  var v = veu(conteudo, "baixo", 0.85, 0);
  var x = VERT ? 70 : 140, larg = W - x - (VERT ? 150 : 140);
  var tam = VERT ? Math.round(D.tamanho * 0.85) : D.tamanho;
  var txt = "", faixas = [];
  for (var i = 0; i < D.palavras.length; i++) {
    var p = D.palavras[i];
    if (i) txt += " ";
    if (p.d) faixas.push([txt.length, txt.length + p.t.length]);
    txt += p.t;
  }
  var alinhar = D.alinhar === "esquerda" ? "esquerda" : "centro";
  var l = bloco(conteudo, "Frase", txt, x, 0, larg, {peso: 800, tam: tam, caps: true, tracking: -20, entrelinha: 1.08, alinhar: alinhar});
  for (i = 0; i < faixas.length; i++) app.run("layer.setText", {layer: l.id, range: faixas[i], fill: COR});
  var alto = fundo(l) - topoTexto(l), base = H - (VERT ? (D.posicao === "baixo" ? 520 : 820) : (D.posicao === "baixo" ? 150 : 400));
  tr(l, "Position").setValue([x, base - alto - (topoTexto(l) - tr(l, "Position").value[1])]);
  var bx = alinhar === "esquerda" ? x : W / 2 - 60;
  var barra = retangulo(conteudo, "Barra", bx, base - alto - 40, 120, 6, COR, 100, 0, true);
  traco(barra, 0, 0.6);
  presetTexto(l, "fadeUpCharacters", 0.15, 0.15 + D.palavras.length * D.passo + 0.55);
};

MODELOS.lista = function () {
  veu(conteudo, "total", 0.8, 0);
  var topo = VERT ? 280 : 150;
  if (D.rotulo) { var r = bloco(conteudo, "Rótulo", D.rotulo, 0, topo, W, {fonte: "Mono", peso: 600, tam: 22, cor: COR, caps: true, tracking: 220, alinhar: "centro"}); entrar(r, "baixo", 0.1, 0.6); }
  if (D.titulo) { var t = bloco(conteudo, "Título", D.titulo, VERT ? 80 : 0, topo + 40, VERT ? W - 160 : W, {peso: 800, tam: VERT ? 58 : 64, tracking: -20, alinhar: "centro", entrelinha: 1.1}); entrar(t, "baixo", 0.2, 0.7); }
  var n = D.itens.length, gap = VERT ? 24 : 36, esq = VERT ? 70 : 120, pad = VERT ? 36 : 40;
  var y0 = VERT ? (D.titulo ? 560 : 440) : (D.titulo ? 380 : 300);
  var cw = VERT ? W - 140 : Math.min(520, (W - 2 * esq - gap * (n - 1)) / n);
  var x0 = VERT ? esq : (W - (cw * n + gap * (n - 1))) / 2;
  // 1) textos de cada cartão; 2) cartões do tamanho certo (na horizontal, todos da altura do maior)
  var cartoes = [], ys = y0, maior = 0, i;
  for (i = 0; i < n; i++) {
    var it = D.itens[i], x = VERT ? x0 : x0 + i * (cw + gap), y = VERT ? ys : y0, yy = y + (VERT ? 28 : 40), cs = [];
    var nm = "Item " + (i + 1) + " · ";
    var num = bloco(conteudo, nm + "número", (i < 9 ? "0" : "") + (i + 1), x + pad, yy, cw - 2 * pad, {fonte: "Mono", peso: 700, tam: 22, cor: COR, tracking: 150});
    cs.push(num); yy = fundo(num);
    if (it.valor) { var v = bloco(conteudo, nm + "valor", it.valor, x + pad, yy + 18, cw - 2 * pad, {peso: 800, tam: VERT ? 72 : (n <= 3 ? 84 : 64), cor: "#ffffff", tracking: -30}); cs.push(v); yy = fundo(v); }
    var tt = bloco(conteudo, nm + "título", it.titulo, x + pad, yy + 16, cw - 2 * pad, {peso: 700, tam: 34, entrelinha: 1.2}); cs.push(tt); yy = fundo(tt);
    if (it.detalhe) { var dd = bloco(conteudo, nm + "detalhe", it.detalhe, x + pad, yy + 12, cw - 2 * pad, {tam: 26, cor: "#b9b3a6", entrelinha: 1.35}); cs.push(dd); yy = fundo(dd); }
    var alto = yy - y + (VERT ? 32 : 44);
    maior = Math.max(maior, alto);
    cartoes.push({x: x, y: y, alto: alto, camadas: cs, foco: it.foco});
    if (VERT) ys = y + alto + gap;
  }
  for (i = 0; i < n; i++) {
    var c = cartoes[i];
    var card = retangulo(conteudo, "Item " + (i + 1) + " · cartão", c.x, c.y, cw, VERT ? c.alto : maior, c.foco ? COR : "#ffffff", c.foco ? 8 : 6, 18);
    card.moveToEnd();
    for (var k = 0; k < c.camadas.length; k++) filho(c.camadas[k], card);
    entrar(card, "baixo", D.tempos ? D.tempos[i] : 0.45 + i * D.passo, 0.75);
  }
  for (i = conteudo.numLayers; i >= 1; i--) if (conteudo.layer(i).name === "Véu") conteudo.layer(i).moveToEnd();
};

MODELOS.caixas = function () {
  if (D.veu && D.veu !== "nenhum") veu(conteudo, D.veu === "total" ? "total" : D.veu, D.veu === "total" ? 0.62 : 0.85, 0);
};

// ---------------------------------------------------------------- montagem
MODELOS[DADOS.modelo]();
caixas(DADOS.caixas);

// Peça: o conteúdo inteiro com o efeito de entrada (opcional) e a saída nos últimos 0,55 s
var lc = peca.layers.add(conteudo);
lc.name = "Conteúdo (efeitos da peça)";
var ef = DADOS.efeito || {}, ent = ef.entrada || "padrao", sai = ef.saida || "padrao", vel = ef.vel || 0.6;
var p0 = [W / 2, H / 2];
if (ent !== "padrao" && ent !== "nenhuma") {
  chaves(tr(lc, "Opacity"), [[0, 0], [vel, 100]]);
  if (ent === "subir") chaves(tr(lc, "Position"), [[0, [p0[0], p0[1] + H * 0.06]], [vel, p0]]);
  if (ent === "deslizar") chaves(tr(lc, "Position"), [[0, [p0[0] - W * 0.12, p0[1]]], [vel, p0]]);
  if (ent === "zoom") chaves(tr(lc, "Scale"), [[0, [86, 86]], [vel, [100, 100]]]);
  if (ent === "desfoque") desfoque(lc, [[0, 28], [vel, 0]]);
  if (ent === "revelar") {
    var wipe = lc.property("Effects").addProperty("ADBE Linear Wipe");
    if (wipe) { wipe.property("Wipe Angle").setValue(270); chaves(wipe.property("Transition Completion"), [[0, 100], [vel, 0]]); }
  }
}
if (sai !== "nenhuma") {
  var ts = DUR - 0.55, o = tr(lc, "Opacity");
  o.setValueAtTime(ts, o.numKeys ? o.valueAtTime(ts, false) : 100); o.setValueAtTime(DUR, 0);
  if (sai === "padrao") desfoque(lc, [[ts, 0], [DUR, 6]]).name = "Desfoque de saída";
  if (sai === "zoom") chaves(tr(lc, "Scale"), [[ts, [100, 100]], [DUR, [112, 112]]]);
  if (sai === "deslizar") chaves(tr(lc, "Position"), [[ts, p0], [DUR, [p0[0] + W * 0.12, p0[1]]]]);
  if (sai === "descer") chaves(tr(lc, "Position"), [[ts, p0], [DUR, [p0[0], p0[1] + H * 0.08]]]);
}
writeLn("ok " + DADOS.modelo + " " + conteudo.numLayers + " camadas");
