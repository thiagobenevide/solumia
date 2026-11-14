import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'modelo.dart';

// Paleta e medidas do gerador de referência (`docs/wireframes-nd/_gerador/lib.py`).
const _fundo = Color(0xFFF3F4F6);
const _tinta = Color(0xFF111827);
const _suave = Color(0xFF6B7280);
const _linha = Color(0xFF9CA3AF);
const _clara = Color(0xFFE5E7EB);
const _branco = Colors.white;
const _escuro = Color(0xFF1F2937);

/// (forte, suave) de cada cor nomeada.
const cores = <String, (Color, Color)>{
  'azul': (Color(0xFF2563EB), Color(0xFFDBEAFE)),
  'ambar': (Color(0xFFD97706), Color(0xFFFEF3C7)),
  'vermelho': (Color(0xFFDC2626), Color(0xFFFEE2E2)),
  'verde': (Color(0xFF059669), Color(0xFFD1FAE5)),
  'roxo': (Color(0xFF7C3AED), Color(0xFFEDE9FE)),
  'ciano': (Color(0xFF0891B2), Color(0xFFCFFAFE)),
  'cinza': (_suave, _clara),
};

(Color, Color) corDoEstado(EstadoWf e) => switch (e) {
  EstadoWf.existe => cores['azul']!,
  EstadoWf.proposto => cores['ambar']!,
  EstadoWf.divergencia => cores['vermelho']!,
};

Color _corTexto(Object? nome) => switch (nome) {
  'suave' => _suave,
  'branco' => _branco,
  final String n when cores.containsKey(n) => cores[n]!.$1,
  _ => _tinta,
};

/// Medidas da prancha: cabeçalho, janela da tela (área útil abaixo da barra de título) e painel de notas.
class Prancha {
  Prancha(this.tela);

  final TelaWf tela;
  static const cabecalho = 72.0, margem = 24.0, barra = 30.0, larguraPainel = 586.0;

  Rect get janela => Rect.fromLTWH(margem, cabecalho + 16, tela.largura, tela.altura + barra);

  /// Origem das coordenadas dos componentes.
  Offset get origem => janela.topLeft + const Offset(0, barra);
  Rect get painel => Rect.fromLTWH(janela.right + 20, janela.top, larguraPainel, janela.height);
  Size get tamanho => Size(painel.right + margem, janela.bottom + margem);
}

/// PNG da [tela] inteira (cabeçalho, janela e notas), com o mesmo pintor do editor; vai no pacote da IA.
Future<Uint8List> renderizarTela(TelaWf tela, List<Componente> componentes) async {
  final tamanho = Prancha(tela).tamanho;
  final gravador = ui.PictureRecorder();
  PintorWireframe(tela, componentes).paint(Canvas(gravador), tamanho);
  final imagem = await gravador.endRecording().toImage(tamanho.width.ceil(), tamanho.height.ceil());
  try {
    final dados = await imagem.toByteData(format: ui.ImageByteFormat.png);
    return dados!.buffer.asUint8List();
  } finally {
    imagem.dispose();
  }
}

class PintorWireframe extends CustomPainter {
  PintorWireframe(this.tela, this.componentes, {this.selecionado, this.versao = 0});

  final TelaWf tela;
  final List<Componente> componentes;
  final String? selecionado;

  /// Sobe a cada mudança: o editor muta os componentes no lugar.
  final int versao;

  @override
  void paint(Canvas c, Size size) {
    final p = Prancha(tela);
    c.drawRect(Offset.zero & size, Paint()..color = _fundo);
    _cabecalho(c, size.width);
    _janela(c, p);
    c.save();
    c.clipRect(Rect.fromPoints(p.origem, p.janela.bottomRight));
    c.translate(p.origem.dx, p.origem.dy);
    for (final comp in componentes) {
      _componente(c, comp, Size(tela.largura, tela.altura));
    }
    for (final comp in componentes) {
      if (comp.nota != null) _marcador(c, comp.caixa.topLeft, comp.nota!, comp.estado);
    }
    final sel = componentes.where((e) => e.id == selecionado).firstOrNull;
    if (sel != null) {
      final azul = cores['azul']!.$1;
      c.drawRect(sel.caixa.inflate(2), Paint()..color = azul..style = PaintingStyle.stroke..strokeWidth = 1.5);
      c.drawRect(Rect.fromCenter(center: sel.caixa.bottomRight, width: 10, height: 10), Paint()..color = azul);
    }
    c.restore();
    _painel(c, p);
  }

  @override
  bool shouldRepaint(PintorWireframe old) =>
      old.versao != versao || old.selecionado != selecionado || old.tela != tela || old.componentes != componentes;

  // ---------- básicos ----------

  /// [ancora]: `la` (esquerda/topo), `lm` (esquerda/meio) ou `mm` (centro). Devolve a largura.
  double _texto(Canvas c, Offset o, String s, {double tam = 13, bool negrito = false, Color cor = _tinta, bool mono = false, String ancora = 'la', double? max, bool quebra = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(fontSize: tam, fontWeight: negrito ? FontWeight.bold : FontWeight.normal, color: cor, fontFamily: mono ? 'monospace' : null),
      ),
      textDirection: TextDirection.ltr,
      maxLines: quebra ? null : 1,
      ellipsis: quebra ? null : '…',
    )..layout(maxWidth: max ?? double.infinity);
    final d = switch (ancora) {
      'mm' => Offset(-tp.width / 2, -tp.height / 2),
      'lm' => Offset(0, -tp.height / 2),
      _ => Offset.zero,
    };
    tp.paint(c, o + d);
    return tp.width;
  }

  double _largura(String s, double tam, {bool negrito = true}) =>
      (TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: tam, fontWeight: negrito ? FontWeight.bold : null)),
        textDirection: TextDirection.ltr,
      )..layout()).width;

  void _ret(Canvas c, Rect r, {Color fundo = _branco, Color borda = _linha, double esp = 1, double raio = 6}) {
    final rr = RRect.fromRectAndRadius(r, Radius.circular(raio));
    c.drawRRect(rr, Paint()..color = fundo);
    if (esp > 0) c.drawRRect(rr, Paint()..color = borda..style = PaintingStyle.stroke..strokeWidth = esp);
  }

  void _tracejado(Canvas c, Rect r, Color cor, {double esp = 2}) {
    final tinta = Paint()..color = cor..strokeWidth = esp;
    void lado(Offset a, Offset b) {
      final total = (b - a).distance;
      for (var t = 0.0; t < total; t += 13) {
        c.drawLine(a + (b - a) * (t / total), a + (b - a) * (math.min(t + 8, total) / total), tinta);
      }
    }

    lado(r.topLeft, r.topRight);
    lado(r.bottomLeft, r.bottomRight);
    lado(r.topLeft, r.bottomLeft);
    lado(r.topRight, r.bottomRight);
  }

  void _marcador(Canvas c, Offset o, int n, EstadoWf e) {
    c.drawCircle(o, 13, Paint()..color = corDoEstado(e).$1);
    c.drawCircle(o, 13, Paint()..color = _branco..style = PaintingStyle.stroke..strokeWidth = 2);
    _texto(c, o, '$n', negrito: true, cor: _branco, ancora: 'mm');
  }

  // ---------- moldura ----------

  void _cabecalho(Canvas c, double w) {
    c.drawRect(Rect.fromLTWH(0, 0, w, Prancha.cabecalho), Paint()..color = _escuro);
    final titulo = [tela.codigo, tela.nome].where((s) => s.isNotEmpty).join('  ·  ');
    _texto(c, const Offset(24, 12), titulo, tam: 22, negrito: true, cor: _branco);
    _texto(c, const Offset(24, 44), tela.subtitulo, cor: const Color(0xFFD1D5DB));
    var x = w - 24;
    for (final e in EstadoWf.values.reversed) {
      final (cor, suave) = corDoEstado(e);
      final rotulo = e.rotulo.toUpperCase();
      final lw = _largura(rotulo, 12) + 44;
      x -= lw;
      _ret(c, Rect.fromLTWH(x, 22, lw - 8, 26), fundo: suave, borda: cor, raio: 12);
      c.drawCircle(Offset(x + 14, 35), 6, Paint()..color = cor);
      _texto(c, Offset(x + 25, 28), rotulo, tam: 12, negrito: true, cor: cor);
      x -= 6;
    }
  }

  void _janela(Canvas c, Prancha p) {
    final j = p.janela;
    _ret(c, j, raio: 10);
    c.drawRRect(
      RRect.fromRectAndCorners(Rect.fromLTWH(j.left, j.top, j.width, Prancha.barra), topLeft: const Radius.circular(10), topRight: const Radius.circular(10)),
      Paint()..color = _clara,
    );
    for (final (i, cor) in const [Color(0xFFEF4444), Color(0xFFF59E0B), Color(0xFF10B981)].indexed) {
      c.drawCircle(Offset(j.left + 20 + i * 18, j.top + 15), 6, Paint()..color = cor);
    }
    _texto(c, Offset(j.left + 80, j.top + 8), tela.caminho.join('  ›  '), tam: 12, cor: _suave);
  }

  void _painel(Canvas c, Prancha p) {
    final r = p.painel;
    _ret(c, r, raio: 10);
    _texto(c, Offset(r.left + 18, r.top + 14), 'Componentes · cliques · endpoints', tam: 15, negrito: true);
    c.drawLine(Offset(r.left, r.top + 44), Offset(r.right, r.top + 44), Paint()..color = _clara);
    var y = r.top + 58;
    final interno = r.width - 70;
    for (final n in tela.notas) {
      final cor = corDoEstado(n.estado).$1;
      _marcador(c, Offset(r.left + 30, y + 10), n.n, n.estado);
      y += _paragrafo(c, Offset(r.left + 52, y), n.titulo, interno, tam: 13, negrito: true, cor: n.estado == EstadoWf.existe ? _tinta : cor) + 4;
      for (final (rotulo, texto) in n.linhas) {
        y += _paragrafo(c, Offset(r.left + 52, y), texto, interno, rotulo: rotulo, cor: rotulo.isEmpty ? _suave : _tinta);
      }
      y += 12;
    }
  }

  double _paragrafo(Canvas c, Offset o, String s, double max, {String rotulo = '', double tam = 11, bool negrito = false, Color cor = _tinta}) {
    final tp = TextPainter(
      text: TextSpan(
        children: [
          if (rotulo.isNotEmpty) TextSpan(text: '$rotulo ', style: const TextStyle(fontWeight: FontWeight.bold, color: _suave)),
          TextSpan(text: s),
        ],
        style: TextStyle(fontSize: tam, fontWeight: negrito ? FontWeight.bold : null, color: cor, height: 1.3),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: max);
    tp.paint(c, o);
    return tp.height;
  }

  // ---------- componentes ----------

  void _componente(Canvas c, Componente comp, Size area) {
    final r = comp.caixa, p = comp.props;
    String s(String k) => '${p[k] ?? ''}';
    bool b(String k) => p[k] == true;
    List<Map> lista(String k) => [for (final i in p[k] as List? ?? const []) if (i is Map) i];
    switch (comp.tipo) {
      case 'texto':
        _texto(c, r.topLeft, s('texto'), tam: (p['tamanho'] as num? ?? 13).toDouble(), negrito: b('negrito'), mono: b('mono'), cor: _corTexto(p['cor']), max: math.max(r.width, 1), quebra: true);
      case 'botao':
        final (fundo, texto, borda) = switch (p['variante']) {
          'secundario' => (_branco, _tinta, _linha),
          'perigo' => (cores['vermelho']!.$1, _branco, cores['vermelho']!.$1),
          'sucesso' => (cores['verde']!.$1, _branco, cores['verde']!.$1),
          'fantasma' => (_branco, _suave, _clara),
          _ => (cores['azul']!.$1, _branco, cores['azul']!.$1),
        };
        _ret(c, r, fundo: fundo, borda: borda);
        _texto(c, r.center, '${s('icone')} ${s('texto')}'.trim(), negrito: true, cor: texto, ancora: 'mm');
      case 'botao_icone':
        _ret(c, r);
        _texto(c, r.center, s('icone'), tam: 15, negrito: true, cor: _suave, ancora: 'mm');
      case 'campo':
        _texto(c, r.topLeft, s('rotulo') + (b('obrigatorio') ? ' *' : ''), tam: 11, negrito: true, cor: _suave);
        final caixa = Rect.fromLTRB(r.left, r.top + 16, r.right, math.max(r.bottom, r.top + 30));
        _ret(c, caixa, fundo: b('somente_leitura') ? _clara : _branco, raio: 5);
        _texto(c, caixa.topLeft + const Offset(8, 7), s('valor'), tam: 12, cor: b('somente_leitura') ? _suave : _tinta, max: math.max(caixa.width - 50, 1));
        if (b('busca')) {
          final azul = cores['azul']!;
          _texto(c, Offset(caixa.right - 40, caixa.top + 7), '✕', tam: 12, cor: _suave);
          _ret(c, Rect.fromLTWH(caixa.right - 24, caixa.top + 4, 20, caixa.height - 8), fundo: azul.$2, borda: azul.$2, raio: 4);
          _texto(c, Offset(caixa.right - 14, caixa.center.dy), '⌕', tam: 14, negrito: true, cor: azul.$1, ancora: 'mm');
        }
        if (b('combo')) _texto(c, Offset(caixa.right - 16, caixa.center.dy), '▾', negrito: true, cor: _suave, ancora: 'mm');
      case 'caixa':
        final azul = cores['azul']!.$1;
        final q = Rect.fromLTWH(r.left, r.center.dy - 7, 14, 14);
        _ret(c, q, fundo: b('marcado') ? azul : _branco, borda: b('marcado') ? azul : _linha, raio: 3);
        if (b('marcado')) _texto(c, q.center, '✓', tam: 11, negrito: true, cor: _branco, ancora: 'mm');
        _texto(c, Offset(r.left + 22, r.center.dy), s('texto'), tam: 12, ancora: 'lm');
      case 'selo':
        final (cor, suave) = cores[p['cor']] ?? cores['azul']!;
        _ret(c, r, fundo: suave, borda: cor, raio: r.height / 2);
        _texto(c, r.center, s('texto'), tam: 11, negrito: true, cor: cor, ancora: 'mm');
      case 'abas':
        final azul = cores['azul']!;
        c.drawLine(Offset(r.left, r.top + 34), Offset(r.right, r.top + 34), Paint()..color = _clara..strokeWidth = 2);
        var x = r.left;
        for (final (i, item) in lista('itens').indexed) {
          final rotulo = '${item['texto'] ?? ''}';
          final w = _largura(rotulo, 13) + 36;
          final aba = Rect.fromLTWH(x, r.top, w, 34);
          if (i == p['ativa']) {
            _ret(c, aba, fundo: azul.$2, borda: azul.$2);
            c.drawLine(aba.bottomLeft, aba.bottomRight, Paint()..color = azul.$1..strokeWidth = 3);
          }
          _texto(c, aba.center, rotulo, negrito: true, cor: i == p['ativa'] ? azul.$1 : _suave, ancora: 'mm');
          final e = EstadoWf.de(item['estado']);
          if (e != EstadoWf.existe) _tracejado(c, aba.inflate(3), corDoEstado(e).$1);
          x += w + 10;
        }
      case 'cartoes':
        final itens = lista('itens');
        if (itens.isEmpty) break;
        final cw = (r.width - 10 * (itens.length - 1)) / itens.length;
        for (final (i, item) in itens.indexed) {
          final cx = r.left + i * (cw + 10);
          _ret(c, Rect.fromLTWH(cx, r.top, cw, r.height), borda: _clara, raio: 8);
          c.drawRect(Rect.fromLTWH(cx, r.top + 8, 4, r.height - 16), Paint()..color = cores['azul']!.$1);
          _texto(c, Offset(cx + 14, r.top + 12), '${item['rotulo'] ?? ''}', tam: 11, cor: _suave, max: math.max(cw - 20, 1));
          _texto(c, Offset(cx + 14, r.top + 32), '${item['valor'] ?? ''}', tam: 17, negrito: true, max: math.max(cw - 20, 1));
        }
      case 'tabela':
        _tabela(c, r, p, lista('colunas'));
      case 'paginador':
        _texto(c, Offset(r.left, r.top + 8), s('info'), tam: 11, cor: _suave);
        for (final (i, g) in const ['«', '‹', '1', '›', '»'].indexed) {
          final bt = Rect.fromLTWH(r.left + 260 + i * 30, r.top, 26, 26);
          _ret(c, bt, fundo: g == '1' ? cores['azul']!.$1 : _branco, raio: 4);
          _texto(c, bt.center, g, tam: 12, negrito: true, cor: g == '1' ? _branco : _suave, ancora: 'mm');
        }
      case 'menu':
        final itens = lista('itens');
        _ret(c, r.shift(const Offset(4, 4)), fundo: const Color(0xFFD1D5DB), borda: const Color(0xFFD1D5DB));
        _ret(c, r);
        for (final (i, item) in itens.indexed) {
          final iy = r.top + 4 + i * 32;
          final e = '${item['estado'] ?? 'existe'}';
          if (e == 'proposto') _ret(c, Rect.fromLTRB(r.left + 4, iy + 2, r.right - 4, iy + 30), fundo: cores['ambar']!.$2, borda: cores['ambar']!.$2, raio: 4);
          final cor = switch (e) { 'proposto' => cores['ambar']!.$1, 'divergencia' => cores['vermelho']!.$1, 'desabilitado' => _linha, _ => _tinta };
          _texto(c, Offset(r.left + 14, iy + 16), '${item['texto'] ?? ''}', negrito: e != 'desabilitado', cor: cor, ancora: 'lm');
        }
      case 'modal':
        c.drawRect(Offset.zero & area, Paint()..color = const Color(0x6E111827));
        _ret(c, r, raio: 10);
        _texto(c, r.topLeft + const Offset(20, 18), s('titulo'), tam: 17, negrito: true);
        _texto(c, Offset(r.right - 26, r.top + 18), '✕', tam: 16, negrito: true, cor: _suave);
        c.drawLine(Offset(r.left, r.top + 52), Offset(r.right, r.top + 52), Paint()..color = _clara);
      case 'painel':
        final fundo = switch (p['fundo']) { 'cinza' => _fundo, final String n when cores.containsKey(n) => cores[n]!.$2, _ => _branco };
        _ret(c, r, fundo: fundo, borda: _clara, raio: 8);
        if (s('titulo').isNotEmpty) _texto(c, r.topLeft + const Offset(16, 14), s('titulo'), tam: 15, negrito: true);
      case 'seta':
        final pts = [
          for (final q in p['pontos'] as List? ?? const [])
            if (q is List && q.length >= 2) r.topLeft + Offset((q[0] as num).toDouble(), (q[1] as num).toDouble()),
        ];
        if (pts.length < 2) break;
        final tinta = Paint()..color = p['cor'] == null ? _suave : _corTexto(p['cor'])..strokeWidth = 2;
        for (var i = 0; i < pts.length - 1; i++) {
          c.drawLine(pts[i], pts[i + 1], tinta);
        }
        final (a, z) = (pts[pts.length - 2], pts.last);
        final ang = math.atan2(z.dy - a.dy, z.dx - a.dx);
        c.drawPath(
          Path()
            ..moveTo(z.dx, z.dy)
            ..lineTo(z.dx - 10 * math.cos(ang - .4), z.dy - 10 * math.sin(ang - .4))
            ..lineTo(z.dx - 10 * math.cos(ang + .4), z.dy - 10 * math.sin(ang + .4))
            ..close(),
          tinta,
        );
    }
    if (comp.estado != EstadoWf.existe) {
      _tracejado(c, r.inflate(comp.tipo == 'modal' ? 5 : 4), corDoEstado(comp.estado).$1);
    }
  }

  void _tabela(Canvas c, Rect r, Map<String, dynamic> p, List<Map> colunas) {
    final linhas = [for (final l in p['linhas'] as List? ?? const []) if (l is List) l];
    final h = (p['altura_linha'] as num? ?? 30).toDouble();
    final w = colunas.fold<double>(0, (s, col) => s + (col['largura'] as num? ?? 0).toDouble());
    final total = Rect.fromLTWH(r.left, r.top, w, h * (linhas.length + 1));
    _ret(c, total, raio: 4);
    c.drawRect(Rect.fromLTWH(r.left + 1, r.top + 1, w - 2, h - 1), Paint()..color = const Color(0xFFF9FAFB));
    var x = r.left;
    for (final col in colunas) {
      final cw = (col['largura'] as num? ?? 0).toDouble();
      _texto(c, Offset(x + 8, r.top + h / 2), '${col['titulo'] ?? ''}', tam: 11, negrito: true, cor: _suave, ancora: 'lm');
      final e = EstadoWf.de(col['estado']);
      if (e != EstadoWf.existe) _tracejado(c, Rect.fromLTWH(x + 2, r.top + 2, cw - 4, total.height - 4), corDoEstado(e).$1, esp: 1);
      x += cw;
    }
    for (final (ri, linha) in linhas.indexed) {
      final y = r.top + h * (ri + 1);
      if (ri == p['destaque']) c.drawRect(Rect.fromLTWH(r.left + 1, y, w - 2, h), Paint()..color = cores['azul']!.$2);
      c.drawLine(Offset(r.left, y), Offset(r.left + w, y), Paint()..color = _clara);
      x = r.left;
      for (final (ci, col) in colunas.indexed) {
        final cw = (col['largura'] as num? ?? 0).toDouble();
        final v = ci < linha.length ? linha[ci] : '';
        if (v is Map && v['selo'] != null) {
          final (cor, suave) = cores[v['selo']] ?? cores['azul']!;
          final t = '${v['texto'] ?? ''}';
          final sw = _largura(t, 11) + 14;
          final selo = Rect.fromLTWH(x + 6, y + (h - 18) / 2, sw, 18);
          _ret(c, selo, fundo: suave, borda: cor, raio: 9);
          _texto(c, selo.center, t, tam: 11, negrito: true, cor: cor, ancora: 'mm');
        } else {
          final t = v is Map ? '${v['texto'] ?? ''}' : '$v';
          _texto(c, Offset(x + 8, y + h / 2), t, tam: 12, ancora: 'lm', max: math.max(cw - 12, 1));
        }
        x += cw;
      }
    }
  }
}
