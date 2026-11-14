import 'package:flutter/material.dart';

/// Cores de texto e de marcador oferecidas na barra. Gravadas como HTML inline, que o Obsidian
/// também mostra: `<span style="color:#e03131">x</span>` e `<mark style="background:#ffd43b">x</mark>`.
const coresTexto = {
  'Vermelho': '#e03131',
  'Laranja': '#f08c00',
  'Amarelo': '#fab005',
  'Verde': '#2f9e44',
  'Azul': '#1c7ed6',
  'Roxo': '#9c36b5',
  'Rosa': '#d6336c',
  'Cinza': '#868e96',
};
const coresMarcador = {
  'Amarelo': '#ffd43b',
  'Verde': '#8ce99a',
  'Azul': '#74c0fc',
  'Rosa': '#faa2c1',
  'Laranja': '#ffc078',
};

/// Tamanhos de texto da barra, gravados como `<span style="font-size:1.25em">x</span>`.
const tamanhosTexto = {'Pequeno': '0.85em', 'Grande': '1.25em', 'Muito grande': '1.6em'};

Color? corCss(String? s) {
  final v = s?.trim().toLowerCase() ?? '';
  if (RegExp(r'^#[0-9a-f]{6}$').hasMatch(v)) return Color(int.parse('ff${v.substring(1)}', radix: 16));
  final nome = {for (final e in coresTexto.entries) e.key.toLowerCase(): e.value}[v] ?? const {
    'red': '#e03131', 'orange': '#f08c00', 'yellow': '#fab005', 'green': '#2f9e44',
    'blue': '#1c7ed6', 'purple': '#9c36b5', 'pink': '#d6336c', 'gray': '#868e96', 'grey': '#868e96',
  }[v];
  return nome == null ? null : corCss(nome);
}

final _prefixoBloco = RegExp(r'^\s*(#{1,6}\s+|>\s?|[-*+]\s\[[ xX]\]\s|[-*+]\s|\d+[.)]\s)?');

/// Pares de marcação inline que a seleção pode ter em volta (usados pelo pincel e pela borracha).
final _envoltorios = [
  (RegExp(r'<span style="[^"]*">$'), '</span>'),
  (RegExp(r'<mark(?: style="[^"]*")?>$'), '</mark>'),
  (RegExp(r'<u>$'), '</u>'),
  (RegExp(r'\*\*$'), '**'),
  (RegExp(r'~~$'), '~~'),
  (RegExp(r'==$'), '=='),
  (RegExp(r'(?<!\*)\*$'), '*'),
  (RegExp(r'`$'), '`'),
];

/// Controlador do corpo Markdown: o texto continua Markdown puro (compatível com o Obsidian), mas é
/// desenhado formatado enquanto se escreve, no estilo "live preview": as marcações (`**`, `#`, tags de
/// cor…) só aparecem na linha do cursor. Os métodos de edição servem à barra do [CampoMarkdown].
class ControladorMarkdown extends TextEditingController {
  ControladorMarkdown({super.text});

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    // durante composição de IME o padrão sublinha o trecho; mantém o comportamento nativo
    if (withComposing && value.isComposingRangeValid) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final base = style ?? DefaultTextStyle.of(context).style;
    final (ini, fim) = selection.isValid ? _linhas(selection) : (-1, -1);
    return TextSpan(style: base, children: _Formatador(Theme.of(context), base).editor(text, ini, fim));
  }

  TextSelection get _sel => selection.isValid ? selection : TextSelection.collapsed(offset: text.length);

  /// Início e fim das linhas que a seleção toca.
  (int, int) _linhas(TextSelection s) {
    final t = text;
    final a = s.start.clamp(0, t.length), b = s.end.clamp(0, t.length);
    final ini = a == 0 ? 0 : t.lastIndexOf('\n', a - 1) + 1;
    final fim = t.indexOf('\n', b);
    return (ini, fim < 0 ? t.length : fim);
  }

  /// Envolve a seleção com [antes]/[depois] (ou desfaz, se já estiver envolvida).
  void envolver(String antes, [String? depois]) {
    depois ??= antes;
    final s = _sel, t = text;
    final ja = s.start >= antes.length &&
        t.substring(s.start - antes.length, s.start) == antes &&
        t.length >= s.end + depois.length &&
        t.substring(s.end, s.end + depois.length) == depois;
    if (ja) {
      value = TextEditingValue(
        text: t.replaceRange(s.end, s.end + depois.length, '').replaceRange(s.start - antes.length, s.start, ''),
        selection: TextSelection(baseOffset: s.start - antes.length, extentOffset: s.end - antes.length),
      );
      return;
    }
    final dentro = s.textInside(t);
    value = TextEditingValue(
      text: t.replaceRange(s.start, s.end, '$antes$dentro$depois'),
      selection: TextSelection(baseOffset: s.start + antes.length, extentOffset: s.start + antes.length + dentro.length),
    );
  }

  /// Põe [prefixo] (recebe o nº da linha) no início de cada linha selecionada, trocando o prefixo de
  /// bloco que já houver; se todas já casam com [atual], remove (alterna).
  void prefixarLinhas(String Function(int i) prefixo, RegExp atual) {
    _trocarLinhas((linhas) {
      final tirar = linhas.every(atual.hasMatch);
      return [
        for (final (i, l) in linhas.indexed) tirar ? l.replaceFirst(atual, '') : '${prefixo(i)}${l.replaceFirst(_prefixoBloco, '')}',
      ];
    });
  }

  /// Recua (ou avança) as linhas selecionadas um nível, com tabulação como o Obsidian.
  void recuar({bool mais = true}) =>
      _trocarLinhas((linhas) => [for (final l in linhas) mais ? '\t$l' : l.replaceFirst(RegExp(r'^(\t| {1,4})'), '')]);

  /// Alinha as linhas selecionadas com `<p align="…">` (o Obsidian respeita); `left` tira o alinhamento.
  void alinhar(String lado) => _trocarLinhas((linhas) => [
    for (final l in linhas)
      if (_alinhada.firstMatch(l) case final m?)
        lado == 'left' ? m[2]! : '<p align="$lado">${m[2]}</p>'
      else
        lado == 'left' || l.trim().isEmpty ? l : '<p align="$lado">$l</p>',
  ]);

  static final _alinhada = RegExp(r'^<p align="(\w+)">(.*)</p>$');

  void _trocarLinhas(List<String> Function(List<String>) troca) {
    final s = _sel, t = text;
    final (ini, fim) = _linhas(s);
    final novas = troca(t.substring(ini, fim).split('\n')).join('\n');
    value = TextEditingValue(
      text: t.replaceRange(ini, fim, novas),
      selection: s.isCollapsed
          ? TextSelection.collapsed(offset: ini + novas.split('\n').first.length)
          : TextSelection(baseOffset: ini, extentOffset: ini + novas.length),
    );
  }

  /// Insere [bloco] em linhas próprias; o cursor vai para [cursor] (posição dentro do bloco) ou o fim.
  void inserirBloco(String bloco, {int? cursor}) {
    final s = _sel, t = text;
    final antes = s.start > 0 && t[s.start - 1] != '\n' ? '\n' : '';
    final depois = s.end < t.length && t[s.end] != '\n' ? '\n' : '';
    value = TextEditingValue(
      text: t.replaceRange(s.start, s.end, '$antes$bloco$depois'),
      selection: TextSelection.collapsed(offset: s.start + antes.length + (cursor ?? bloco.length)),
    );
  }

  /// Insere [texto] no lugar da seleção, com o cursor no fim (ou em [cursor] dentro do texto).
  void inserir(String texto, {int? cursor}) {
    final s = _sel;
    value = TextEditingValue(
      text: text.replaceRange(s.start, s.end, texto),
      selection: TextSelection.collapsed(offset: s.start + (cursor ?? texto.length)),
    );
  }

  /// Marcações inline em volta da seleção, da mais externa para a mais interna (pincel de formatação).
  List<(String, String)> formatosDaSelecao() {
    final s = _sel, t = text;
    var a = s.start, b = s.end;
    final achados = <(String, String)>[];
    var achou = true;
    while (achou) {
      achou = false;
      for (final (abre, fecha) in _envoltorios) {
        final m = abre.firstMatch(t.substring(0, a));
        if (m != null && t.startsWith(fecha, b)) {
          achados.insert(0, (m[0]!, fecha));
          a = m.start;
          b += fecha.length;
          achou = true;
          break;
        }
      }
    }
    return achados;
  }

  /// Aplica as marcações de [formatos] (mais externa primeiro) à seleção atual.
  void aplicarFormatos(List<(String, String)> formatos) {
    for (final (abre, fecha) in formatos) {
      envolver(abre, fecha);
    }
  }

  /// Borracha: tira a formatação inline (e títulos) da seleção ou, sem seleção, da linha do cursor.
  void limparFormatacao() {
    var s = _sel;
    if (s.isCollapsed) {
      final (ini, fim) = _linhas(s);
      s = TextSelection(baseOffset: ini, extentOffset: fim);
    }
    var t = text, a = s.start, b = s.end;
    // marcações que envolvem a seleção por fora
    selection = TextSelection(baseOffset: a, extentOffset: b);
    for (final (abre, fecha) in formatosDaSelecao().reversed) {
      t = t.replaceRange(b, b + fecha.length, '').replaceRange(a - abre.length, a, '');
      a -= abre.length;
      b -= abre.length;
    }
    final limpo = t
        .substring(a, b)
        .replaceAll(RegExp(r'</?(?:span|mark|u|p)\b[^>]*>'), '')
        .replaceAll(RegExp(r'\*\*|__|~~|=='), '')
        .replaceAllMapped(RegExp(r'\*([^*\n]+)\*'), (m) => m[1]!)
        .replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) => m[1]!)
        .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
    value = TextEditingValue(
      text: t.replaceRange(a, b, limpo),
      selection: TextSelection(baseOffset: a, extentOffset: a + limpo.length),
    );
  }

  /// Marca/desmarca a tarefa da linha [i] (`- [ ]` ↔ `- [x]`).
  void alternarTarefa(int i) {
    final linhas = text.split('\n');
    if (i >= linhas.length) return;
    linhas[i] = linhas[i].replaceFirstMapped(RegExp(r'^(\s*[-*+] \[)([ xX])\]'), (m) => '${m[1]}${m[2] == ' ' ? 'x' : ' '}]');
    text = linhas.join('\n');
  }
}

/// Como as marcações (`**`, `#`, tags) aparecem: visíveis e esmaecidas (linha do cursor),
/// ocultas mas presentes (resto do editor, o TextField exige todos os caracteres) ou removidas (leitura).
enum _Marcas { visiveis, ocultas, removidas }

class _Formatador {
  _Formatador(ThemeData tema, this.base, [this.modo = _Marcas.visiveis])
    : cs = tema.colorScheme,
      escuro = tema.brightness == Brightness.dark,
      tamanho = base.fontSize ?? 14;

  final TextStyle base;
  final ColorScheme cs;
  final bool escuro;
  final double tamanho;
  _Marcas modo;

  TextStyle get _mono => base.copyWith(
    fontFamily: 'monospace',
    fontFamilyFallback: const ['DejaVu Sans Mono', 'Courier New', 'Courier'],
    fontSize: tamanho * 0.92,
    backgroundColor: cs.surfaceContainerHighest,
  );

  TextStyle get _link => base.copyWith(color: cs.primary, decoration: TextDecoration.underline, decorationColor: cs.primary);

  /// Spans de uma marcação, conforme o [modo].
  List<InlineSpan> _m(String t, TextStyle st, {bool pequena = false}) => switch (modo) {
    _Marcas.removidas => const [],
    _Marcas.ocultas => [
      TextSpan(
        text: t,
        style: st.copyWith(fontSize: 0.01, color: Colors.transparent, backgroundColor: Colors.transparent, letterSpacing: 0),
      ),
    ],
    _Marcas.visiveis => [
      TextSpan(
        text: t,
        style: st.copyWith(
          color: cs.outline.withValues(alpha: 0.7),
          fontWeight: FontWeight.w400,
          fontStyle: FontStyle.normal,
          decoration: TextDecoration.none,
          backgroundColor: Colors.transparent,
          fontSize: pequena ? (st.fontSize ?? tamanho) * 0.7 : null,
        ),
      ),
    ],
  };

  TextStyle estiloTitulo(int nivel) => base.copyWith(
    fontSize: tamanho * const [1.9, 1.55, 1.3, 1.15, 1.05, 1.0][nivel - 1],
    fontWeight: nivel <= 2 ? FontWeight.w700 : FontWeight.w600,
    height: 1.35,
    color: nivel <= 2 ? cs.onSurface : null,
  );

  static final _titulo = RegExp(r'^(#{1,6}\s+)(.*)$');
  static final _regua = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');
  static final _citacao = RegExp(r'^(\s*>\s?)(.*)$');
  static final _tarefa = RegExp(r'^(\s*[-*+] \[([ xX])\] )(.*)$');
  static final _lista = RegExp(r'^(\s*(?:[-*+]|\d+[.)]) )(.*)$');
  static final _alinhada = RegExp(r'^(<p align="\w+">)(.*)(</p>)$');
  static final _inline = RegExp(
    r'(?<cod>`[^`\n]+`)'
    r'|(?<com>%%[^%\n]+%%)'
    r'|(?<img>!\[\[[^\]\n]+\]\]|!\[[^\]\n]*\]\([^)\n]+\))'
    r'|(?<wiki>\[\[[^\]\n]+\]\])'
    r'|(?<link>\[[^\]\n]+\]\([^)\n]+\))'
    r'|(?<span><span style="[^"]*">.+?</span>)'
    r'|(?<marca><mark(?: style="background(?:-color)?:\s*[^";]+;?")?>.+?</mark>)'
    r'|(?<sub><u>.+?</u>)'
    r'|(?<neg>\*\*[^*\n]+?\*\*|__[^_\n]+?__)'
    r'|(?<tac>~~[^~\n]+?~~)'
    r'|(?<real>==[^=\n]+?==)'
    r'|(?<ita>\*[^*\s][^*\n]*?\*|(?<!\w)_[^_\s][^_\n]*?_(?!\w))',
  );

  /// Texto do editor: marcações visíveis só nas linhas entre [ini] e [fim] (as do cursor).
  List<InlineSpan> editor(String texto, int ini, int fim) {
    final spans = <InlineSpan>[];
    var emCodigo = false;
    var pos = 0;
    for (final (i, linha) in texto.split('\n').indexed) {
      if (i > 0) spans.add(const TextSpan(text: '\n'));
      final ativa = pos <= fim && pos + linha.length >= ini;
      pos += linha.length + 1;
      modo = ativa ? _Marcas.visiveis : _Marcas.ocultas;
      if (linha.trimLeft().startsWith('```')) {
        spans.add(TextSpan(text: linha, style: _mono.copyWith(color: cs.primary)));
        emCodigo = !emCodigo;
      } else if (emCodigo) {
        spans.add(TextSpan(text: linha, style: _mono));
      } else {
        spans.addAll(_linha(linha));
      }
    }
    return spans;
  }

  List<InlineSpan> _linha(String l) {
    if (_titulo.firstMatch(l) case final m?) {
      final st = estiloTitulo(m[1]!.trim().length);
      return [..._m(m[1]!, st, pequena: true), ...spans(m[2]!, st)];
    }
    if (_regua.hasMatch(l)) {
      return [TextSpan(text: l, style: base.copyWith(color: cs.outlineVariant, letterSpacing: 6))];
    }
    if (_alinhada.firstMatch(l) case final m?) {
      return [..._m(m[1]!, base, pequena: true), ...spans(m[2]!, base), ..._m(m[3]!, base, pequena: true)];
    }
    if (l.trimLeft().startsWith('|')) {
      final linhaSep = RegExp(r'^[\s|:\-]+$').hasMatch(l);
      return [
        for (final parte in RegExp(r'\||[^|]+').allMatches(l).map((m) => m[0]!))
          TextSpan(
            text: parte,
            style: parte == '|' || linhaSep
                ? _mono.copyWith(color: cs.outline, backgroundColor: Colors.transparent)
                : _mono.copyWith(backgroundColor: Colors.transparent),
          ),
      ];
    }
    final simbolo = base.copyWith(color: cs.primary, fontWeight: FontWeight.w700);
    if (_citacao.firstMatch(l) case final m?) {
      final st = base.copyWith(fontStyle: FontStyle.italic, color: cs.onSurfaceVariant);
      return [TextSpan(text: m[1], style: simbolo.copyWith(backgroundColor: cs.primary.withValues(alpha: 0.25))), ...spans(m[2]!, st)];
    }
    if (_tarefa.firstMatch(l) case final m?) {
      final feita = m[2] != ' ';
      final st = feita ? base.copyWith(decoration: TextDecoration.lineThrough, color: cs.outline) : base;
      return [TextSpan(text: m[1], style: simbolo), ...spans(m[3]!, st)];
    }
    if (_lista.firstMatch(l) case final m?) {
      return [TextSpan(text: m[1], style: simbolo), ...spans(m[2]!, base)];
    }
    return spans(l, base);
  }

  /// Formatação inline, recursiva (ex.: cor dentro de negrito). Fora do modo leitura todo caractere é
  /// mantido: o TextField exige que os spans somem exatamente o texto do controlador.
  List<InlineSpan> spans(String s, TextStyle st) {
    final out = <InlineSpan>[];
    var pos = 0;
    for (final m in _inline.allMatches(s)) {
      if (m.start > pos) out.add(TextSpan(text: s.substring(pos, m.start), style: st));
      pos = m.end;
      final t = m[0]!;
      List<InlineSpan> envolto(int a, int b, TextStyle dentro, {bool pequena = false}) => [
        ..._m(t.substring(0, a), st, pequena: pequena),
        ...spans(t.substring(a, t.length - b), dentro),
        ..._m(t.substring(t.length - b), st, pequena: pequena),
      ];
      final link = st.merge(_link);
      if (m.namedGroup('cod') != null) {
        out.addAll([
          ..._m('`', st),
          TextSpan(text: t.substring(1, t.length - 1), style: _mono.copyWith(color: cs.tertiary)),
          ..._m('`', st),
        ]);
      } else if (m.namedGroup('com') != null) {
        if (modo != _Marcas.removidas) out.add(TextSpan(text: t, style: st.copyWith(color: cs.outline, fontStyle: FontStyle.italic)));
      } else if (m.namedGroup('img') != null) {
        final nome = t.startsWith('![[') ? t.substring(3, t.length - 2) : t.substring(2, t.indexOf(']('));
        if (modo == _Marcas.removidas) {
          out.add(TextSpan(text: '🖼 ${nome.isEmpty ? 'imagem' : nome}', style: link));
        } else {
          out.add(TextSpan(text: t, style: st.copyWith(color: cs.primary)));
        }
      } else if (m.namedGroup('wiki') != null) {
        final dentro = t.substring(2, t.length - 2);
        final barra = dentro.indexOf('|');
        if (modo == _Marcas.removidas) {
          out.add(TextSpan(text: barra < 0 ? dentro : dentro.substring(barra + 1), style: link));
        } else {
          out.addAll(envolto(2, 2, link));
        }
      } else if (m.namedGroup('link') != null) {
        final fecha = t.indexOf('](');
        out.addAll([
          ..._m('[', st),
          TextSpan(text: t.substring(1, fecha), style: link),
          ..._m(t.substring(fecha), st, pequena: true),
        ]);
      } else if (m.namedGroup('span') != null) {
        final abre = t.indexOf('>') + 1;
        final estilo = t.substring(0, abre);
        final cor = corCss(RegExp(r'(?<!-)color:\s*([^";]+)').firstMatch(estilo)?[1]);
        final em = double.tryParse(RegExp(r'font-size:\s*([\d.]+)em').firstMatch(estilo)?[1] ?? '');
        var dentro = cor == null ? st : st.copyWith(color: cor);
        if (em != null) dentro = dentro.copyWith(fontSize: (st.fontSize ?? tamanho) * em);
        out.addAll(envolto(abre, '</span>'.length, dentro, pequena: true));
      } else if (m.namedGroup('marca') != null) {
        final abre = t.indexOf('>') + 1;
        final cor = corCss(RegExp(r'background(?:-color)?:\s*([^";]+)').firstMatch(t)?[1]) ?? const Color(0xffffd43b);
        out.addAll(envolto(abre, '</mark>'.length, _realce(st, cor), pequena: true));
      } else if (m.namedGroup('sub') != null) {
        out.addAll(envolto(3, 4, st.copyWith(decoration: TextDecoration.underline), pequena: true));
      } else if (m.namedGroup('neg') != null) {
        out.addAll(envolto(2, 2, st.copyWith(fontWeight: FontWeight.w700)));
      } else if (m.namedGroup('tac') != null) {
        out.addAll(envolto(2, 2, st.copyWith(decoration: TextDecoration.lineThrough)));
      } else if (m.namedGroup('real') != null) {
        out.addAll(envolto(2, 2, _realce(st, const Color(0xffffd43b))));
      } else {
        out.addAll(envolto(1, 1, st.copyWith(fontStyle: FontStyle.italic)));
      }
    }
    if (pos < s.length) out.add(TextSpan(text: s.substring(pos), style: st));
    return out;
  }

  TextStyle _realce(TextStyle st, Color cor) => st.copyWith(
    backgroundColor: cor.withValues(alpha: escuro ? 0.35 : 0.6),
    color: escuro ? null : Colors.black87,
  );
}

/// Markdown renderizado para leitura (sem os símbolos): títulos, listas, tarefas (clicáveis se houver
/// [aoAlternarTarefa]), citações e callouts do Obsidian, código, tabelas, imagens, alinhamento e réguas.
class VisualizadorMarkdown extends StatelessWidget {
  const VisualizadorMarkdown({super.key, required this.texto, this.aoAlternarTarefa, this.estilo});

  final String texto;

  /// Recebe o nº da linha da tarefa clicada.
  final void Function(int linha)? aoAlternarTarefa;
  final TextStyle? estilo;

  static final _cerca = RegExp(r'^\s*```\s*(\w*)');
  static final _itemLista = RegExp(r'^(\s*)([-*+]|\d+[.)]) (\[[ xX]\] )?(.*)$');
  static final _imagem = RegExp(r'^\s*!\[[^\]]*\]\((https?://[^)\s]+)\)\s*$');
  static final _callout = RegExp(r'^\[!(\w+)\][+-]?\s*(.*)$');

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final base = estilo ?? tema.textTheme.bodyLarge!.copyWith(height: 1.55);
    final f = _Formatador(tema, base, _Marcas.removidas);
    final cs = tema.colorScheme;
    final linhas = texto.split('\n');
    final blocos = <Widget>[];
    Widget rico(String s, TextStyle st, {TextAlign alinhar = TextAlign.start}) =>
        Text.rich(TextSpan(style: st, children: f.spans(s, st)), textAlign: alinhar);

    var i = 0;
    while (i < linhas.length) {
      final l = linhas[i];
      final indice = i;
      if (l.trim().isEmpty) {
        i++;
        continue;
      }
      // bloco de código (Mermaid aparece como código com rótulo)
      if (_cerca.firstMatch(l) case final m?) {
        final codigo = <String>[];
        i++;
        while (i < linhas.length && !linhas[i].trimLeft().startsWith('```')) {
          codigo.add(linhas[i++]);
        }
        i++;
        blocos.add(_Codigo(linguagem: m[1]!, codigo: codigo.join('\n'), estilo: f._mono.copyWith(backgroundColor: Colors.transparent)));
        continue;
      }
      // comentário do Obsidian em várias linhas
      if (l.trim() == '%%') {
        i++;
        while (i < linhas.length && linhas[i].trim() != '%%') {
          i++;
        }
        i++;
        continue;
      }
      if (_Formatador._titulo.firstMatch(l) case final m?) {
        final nivel = m[1]!.trim().length;
        blocos.add(Padding(
          padding: EdgeInsets.only(top: nivel <= 2 ? 14 : 8, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              rico(m[2]!, f.estiloTitulo(nivel)),
              if (nivel <= 2) Divider(height: 10, color: cs.outlineVariant.withValues(alpha: 0.5)),
            ],
          ),
        ));
        i++;
        continue;
      }
      if (_Formatador._regua.hasMatch(l)) {
        blocos.add(Divider(height: 24, color: cs.outlineVariant));
        i++;
        continue;
      }
      if (l.trimLeft().startsWith('|')) {
        final tabela = <List<String>>[];
        while (i < linhas.length && linhas[i].trimLeft().startsWith('|')) {
          final t = linhas[i++].trim();
          if (RegExp(r'^[\s|:\-]+$').hasMatch(t)) continue;
          tabela.add(t.replaceFirst(RegExp(r'^\|'), '').replaceFirst(RegExp(r'\|$'), '').split('|').map((c) => c.trim()).toList());
        }
        blocos.add(_tabela(tabela, base, f, cs, rico));
        continue;
      }
      if (_Formatador._citacao.hasMatch(l)) {
        final dentro = <String>[];
        while (i < linhas.length && _Formatador._citacao.hasMatch(linhas[i])) {
          dentro.add(_Formatador._citacao.firstMatch(linhas[i++])![2]!);
        }
        blocos.add(_citacao(dentro, base, cs));
        continue;
      }
      if (_itemLista.firstMatch(l) case final m?) {
        final nivel = m[1]!.replaceAll('\t', '    ').length ~/ 2;
        final marcador = m[2]!, tarefa = m[3];
        final feita = tarefa != null && tarefa[1] != ' ';
        final st = feita ? base.copyWith(decoration: TextDecoration.lineThrough, color: cs.outline) : base;
        blocos.add(Padding(
          padding: EdgeInsets.only(left: 6.0 + nivel * 22, top: 2, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 26,
                child: tarefa != null
                    ? SizedBox(
                        height: (base.fontSize ?? 14) * 1.55,
                        child: Checkbox(
                          value: feita,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          onChanged: aoAlternarTarefa == null ? null : (_) => aoAlternarTarefa!(indice),
                        ),
                      )
                    : Text(
                        RegExp(r'\d').hasMatch(marcador) ? marcador : const ['•', '◦', '▪'][nivel % 3],
                        style: base.copyWith(color: cs.primary, fontWeight: FontWeight.w700),
                      ),
              ),
              Expanded(child: rico(m[4]!, st)),
            ],
          ),
        ));
        i++;
        continue;
      }
      if (_imagem.firstMatch(l) case final m?) {
        blocos.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(m[1]!, errorBuilder: (_, _, _) => rico(l, base)),
          ),
        ));
        i++;
        continue;
      }
      if (_Formatador._alinhada.firstMatch(l) case final m?) {
        final lado = RegExp(r'"(\w+)"').firstMatch(m[1]!)![1];
        final alinhar = switch (lado) {
          'center' => TextAlign.center,
          'right' => TextAlign.right,
          'justify' => TextAlign.justify,
          _ => TextAlign.start,
        };
        blocos.add(SizedBox(width: double.infinity, child: rico(m[2]!, base, alinhar: alinhar)));
        i++;
        continue;
      }
      // parágrafo: linhas comuns seguidas
      final paragrafo = <String>[];
      while (i < linhas.length && linhas[i].trim().isNotEmpty && !_inicioDeBloco(linhas[i])) {
        paragrafo.add(linhas[i++]);
      }
      if (paragrafo.isEmpty) paragrafo.add(linhas[i++]);
      blocos.add(Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: rico(paragrafo.join('\n'), base)));
    }
    if (blocos.isEmpty) {
      return Text('Nada escrito ainda.', style: base.copyWith(color: cs.outline, fontStyle: FontStyle.italic));
    }
    return SelectionArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: blocos),
    );
  }

  static bool _inicioDeBloco(String l) =>
      _cerca.hasMatch(l) ||
      _Formatador._titulo.hasMatch(l) ||
      _Formatador._regua.hasMatch(l) ||
      _Formatador._citacao.hasMatch(l) ||
      _Formatador._alinhada.hasMatch(l) ||
      _itemLista.hasMatch(l) ||
      l.trimLeft().startsWith('|') ||
      l.trim() == '%%';

  Widget _citacao(List<String> dentro, TextStyle base, ColorScheme cs) {
    final callout = dentro.isEmpty ? null : _callout.firstMatch(dentro.first);
    final tipo = callout?[1]!.toLowerCase();
    final (cor, icone) = switch (tipo) {
      null => (cs.primary, null),
      'tip' || 'dica' || 'success' => (const Color(0xff2f9e44), Icons.lightbulb_outline),
      'warning' || 'aviso' || 'caution' => (const Color(0xfff08c00), Icons.warning_amber_rounded),
      'danger' || 'error' || 'bug' => (const Color(0xffe03131), Icons.error_outline),
      'question' || 'faq' => (const Color(0xff9c36b5), Icons.help_outline),
      'quote' || 'cite' => (cs.outline, Icons.format_quote),
      _ => (const Color(0xff1c7ed6), Icons.info_outline),
    };
    final corpo = callout == null ? dentro : dentro.skip(1).toList();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
      decoration: BoxDecoration(
        color: cor.withValues(alpha: callout == null ? 0.06 : 0.12),
        border: Border(left: BorderSide(color: cor, width: 3)),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (callout != null)
            Row(
              spacing: 6,
              children: [
                Icon(icone, size: 18, color: cor),
                Expanded(
                  child: Text(
                    callout[2]!.isEmpty ? '${tipo![0].toUpperCase()}${tipo.substring(1)}' : callout[2]!,
                    style: base.copyWith(color: cor, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          if (corpo.isNotEmpty)
            VisualizadorMarkdown(
              texto: corpo.join('\n'),
              estilo: callout == null ? base.copyWith(color: cs.onSurfaceVariant) : base,
            ),
        ],
      ),
    );
  }

  Widget _tabela(
    List<List<String>> tabela,
    TextStyle base,
    _Formatador f,
    ColorScheme cs,
    Widget Function(String, TextStyle) rico,
  ) {
    if (tabela.isEmpty) return const SizedBox.shrink();
    final colunas = tabela.map((l) => l.length).reduce((a, b) => a > b ? a : b);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(color: cs.outlineVariant, borderRadius: BorderRadius.circular(6)),
          children: [
            for (final (n, linha) in tabela.indexed)
              TableRow(
                decoration: BoxDecoration(color: n == 0 ? cs.surfaceContainerHighest : null),
                children: [
                  for (var c = 0; c < colunas; c++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: rico(c < linha.length ? linha[c] : '', n == 0 ? base.copyWith(fontWeight: FontWeight.w700) : base),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Codigo extends StatelessWidget {
  const _Codigo({required this.linguagem, required this.codigo, required this.estilo});

  final String linguagem, codigo;
  final TextStyle estilo;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (linguagem.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Text(
                linguagem == 'mermaid' ? 'Fluxograma (Mermaid)' : linguagem,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.primary),
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: Text(codigo, style: estilo),
          ),
        ],
      ),
    );
  }
}
