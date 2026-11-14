// Fim das peças EffectCraft: põe o conteúdo na comp "Peça" com a saída (o núcleo faz a saída, como o kit) e mede,
// nos instantes pedidos, o texto visível fora da área segura (o portão lê as linhas "estouro ...").
var _peca = app.project.items.addComp("Peça", W, H, 1, DUR, FPS);
var _lc = _peca.layers.add(CONTEUDO);
_lc.name = "Conteúdo (saída da peça)";
var _o = tr(_lc, "Opacity");
_o.setValueAtTime(FIM, 100);
_o.setValueAtTime(Math.min(DUR, FIM + 0.4), 0);
desfoque(_lc, [[FIM, 0], [Math.min(DUR, FIM + 0.4), 6]]).name = "Desfoque de saída";

function _posComp(l, t) {
  var p = tr(l, "Position").valueAtTime(t, false), x = p[0], y = p[1];
  for (var q = l.parent; q; q = q.parent) {
    var pp = tr(q, "Position").valueAtTime(t, false), aa = tr(q, "Anchor Point").valueAtTime(t, false);
    x += pp[0] - aa[0]; y += pp[1] - aa[1];
  }
  return [x, y];
}
var _m = (DADOS.area || 0.03) * Math.min(W, H), _inst = DADOS.instantes || [], _fora = {};
for (var _i = 1; _i <= CONTEUDO.numLayers; _i++) {
  var _l = CONTEUDO.layer(_i);
  if (!_l.property("Source Text")) continue;
  for (var _k = 0; _k < _inst.length; _k++) {
    var _t = _inst[_k];
    if (tr(_l, "Opacity").valueAtTime(_t, false) < 5) continue;
    var _r = _l.sourceRectAtTime(_t, false);
    if (!_r.width || !_r.height) continue;
    var _p = _posComp(_l, _t), _a = tr(_l, "Anchor Point").valueAtTime(_t, false), _s = tr(_l, "Scale").valueAtTime(_t, false);
    var x0 = _p[0] + (_r.left - _a[0]) * _s[0] / 100, y0 = _p[1] + (_r.top - _a[1]) * _s[1] / 100;
    var x1 = x0 + _r.width * _s[0] / 100, y1 = y0 + _r.height * _s[1] / 100;
    if (x0 < _m || y0 < _m || x1 > W - _m || y1 > H - _m) _fora[_l.name] = 1;
  }
}
for (var _n in _fora) writeLn("estouro " + _n);
writeLn("ok " + CONTEUDO.numLayers + " camadas");
