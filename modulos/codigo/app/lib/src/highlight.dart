import 'package:flutter/material.dart';

/// Syntax highlighting of the code browser (Python, Dart and shell), in the colors of the IntelliJ/VS Code
/// dark theme. The whole text is scanned at once (multi-line strings and comments cross lines) and
/// returned already split by line, so the `ListView` builds line by line.

enum TokenKind { keyword, text, number, comment, annotation, typeName, function, constant, selfRef, variable, interpolation }

enum Language { python, dart, shell }

Language? languageOf(String path) {
  final name = path.split('/').last.toLowerCase();
  final ext = name.contains('.') ? name.split('.').last : '';
  return switch (ext) {
    'py' || 'pyi' => Language.python,
    'dart' => Language.dart,
    'sh' || 'bash' || 'zsh' => Language.shell,
    _ => const {'verificar', '.bashrc', '.profile', 'dockerfile'}.contains(name) ? Language.shell : null,
  };
}

Map<TokenKind, Color> highlightColors(Brightness brightness) => brightness == Brightness.dark
    ? const {
        TokenKind.keyword: Color(0xFFCF8E6D),
        TokenKind.text: Color(0xFF6AAB73),
        TokenKind.number: Color(0xFF2AACB8),
        TokenKind.comment: Color(0xFF7A7E85),
        TokenKind.annotation: Color(0xFFB3AE60),
        TokenKind.typeName: Color(0xFF4EC9B0),
        TokenKind.function: Color(0xFF56A8F5),
        TokenKind.constant: Color(0xFFC77DBB),
        TokenKind.selfRef: Color(0xFF94558D),
        TokenKind.variable: Color(0xFFC77DBB),
        TokenKind.interpolation: Color(0xFFCF8E6D),
      }
    : const {
        TokenKind.keyword: Color(0xFF0033B3),
        TokenKind.text: Color(0xFF067D17),
        TokenKind.number: Color(0xFF1750EB),
        TokenKind.comment: Color(0xFF8C8C8C),
        TokenKind.annotation: Color(0xFF9E880D),
        TokenKind.typeName: Color(0xFF008080),
        TokenKind.function: Color(0xFF00627A),
        TokenKind.constant: Color(0xFF871094),
        TokenKind.selfRef: Color(0xFF94558D),
        TokenKind.variable: Color(0xFF871094),
        TokenKind.interpolation: Color(0xFF0033B3),
      };

const _keywords = {
  Language.python: {
    'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue', 'def', //
    'del', 'elif', 'else', 'except', 'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda',
    'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'try', 'while', 'with', 'yield', 'match', 'case',
  },
  Language.dart: {
    'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case', 'catch', 'class', 'const', //
    'continue', 'covariant', 'default', 'deferred', 'do', 'dynamic', 'else', 'enum', 'export', 'extends',
    'extension', 'external', 'factory', 'false', 'final', 'finally', 'for', 'get', 'hide', 'if', 'implements',
    'import', 'in', 'interface', 'is', 'late', 'library', 'mixin', 'new', 'null', 'on', 'operator', 'part',
    'required', 'rethrow', 'return', 'sealed', 'set', 'show', 'static', 'super', 'switch', 'sync', 'throw',
    'true', 'try', 'typedef', 'var', 'void', 'when', 'while', 'with', 'yield', 'int', 'double', 'num', 'bool',
  },
  Language.shell: {
    'if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'until', 'do', 'done', 'case', 'esac', 'in', //
    'function', 'return', 'local', 'export', 'readonly', 'declare', 'set', 'unset', 'shift', 'exit', 'source',
    'trap', 'exec', 'eval', 'break', 'continue', 'true', 'false',
  },
};

const _pythonBuiltins = {
  'str', 'int', 'float', 'bool', 'bytes', 'list', 'dict', 'set', 'tuple', 'object', 'type', 'len', 'print', //
  'range', 'open', 'isinstance', 'super', 'enumerate', 'zip', 'map', 'filter', 'sorted', 'min', 'max', 'sum',
  'any', 'all', 'repr', 'getattr', 'setattr', 'hasattr', 'iter', 'next', 'abs', 'round', 'Exception',
};

typedef Span = (int start, int end, TokenKind type);

/// Text lines with the colored spans; `null` when the language is not recognized.
List<List<TextSpan>>? highlight(String text, String path, TextStyle base, Brightness brightness) {
  final lang = languageOf(path);
  if (lang == null) return null;
  final colors = highlightColors(brightness);
  final spans = _Scanner(text, lang).scan();
  final lines = <List<TextSpan>>[[]];
  var pos = 0;
  void emit(int ate, Color? color) {
    while (pos < ate) {
      final wrap = text.indexOf('\n', pos);
      final end = wrap == -1 || wrap >= ate ? ate : wrap;
      if (end > pos) lines.last.add(TextSpan(text: text.substring(pos, end), style: color == null ? base : base.copyWith(color: color)));
      pos = end;
      if (end == wrap) {
        lines.add([]);
        pos++;
      }
    }
  }

  for (final (start, end, type) in spans) {
    emit(start, null);
    emit(end, colors[type]);
  }
  emit(text.length, null);
  return lines;
}

class _Scanner {
  _Scanner(this.s, this.lang) : keywords = _keywords[lang]!;

  final String s;
  final Language lang;
  final Set<String> keywords;
  final output = <Span>[];
  var i = 0;
  String? anterior; // last keyword/identifier, so `def`/`class` name the next one

  static bool _isLetter(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127;
  static bool _isDigit(int c) => c >= 48 && c <= 57;

  int get _c => i < s.length ? s.codeUnitAt(i) : 0;

  List<Span> scan() {
    while (i < s.length) {
      final c = _c;
      final start = i;
      if (_comment()) continue;
      if (c == 0x22 || c == 0x27) {
        _string(start, start);
      } else if (lang == Language.shell && c == 0x24) {
        _shellVariable();
      } else if (c == 0x40 && lang != Language.shell) {
        i++;
        while (i < s.length && (_isLetter(_c) || _isDigit(_c) || _c == 0x2E)) {
          i++;
        }
        output.add((start, i, TokenKind.annotation));
      } else if (_isDigit(c) || (c == 0x2E && _isDigit(i + 1 < s.length ? s.codeUnitAt(i + 1) : 0))) {
        if (i > 0 && _isLetter(s.codeUnitAt(i - 1))) {
          i++;
          continue;
        }
        while (i < s.length && (_isLetter(_c) || _isDigit(_c) || _c == 0x2E)) {
          i++;
        }
        output.add((start, i, TokenKind.number));
      } else if (_isLetter(c)) {
        _identifier(start);
      } else {
        i++;
      }
    }
    return output;
  }

  bool _comment() {
    final start = i;
    final bar = lang == Language.dart;
    if ((!bar && _c == 0x23) || (bar && s.startsWith('//', i))) {
      // shell `#` only starts a comment at the start of a word (`$#`, `${#x}` do not)
      if (lang == Language.shell && i > 0 && !' \t\n;'.contains(s[i - 1])) return false;
      final end = s.indexOf('\n', i);
      i = end == -1 ? s.length : end;
      output.add((start, i, TokenKind.comment));
      return true;
    }
    if (bar && s.startsWith('/*', i)) {
      final end = s.indexOf('*/', i + 2);
      i = end == -1 ? s.length : end + 2;
      output.add((start, i, TokenKind.comment));
      return true;
    }
    return false;
  }

  void _identifier(int start) {
    while (i < s.length && (_isLetter(_c) || _isDigit(_c))) {
      i++;
    }
    final p = s.substring(start, i);
    // string prefix: f"", r'', b"", rb"" (Python) and r'' (Dart)
    if ((_c == 0x22 || _c == 0x27) && lang != Language.shell && p.length <= 2 && RegExp(r'^[rRbBfFuU]+$').hasMatch(p)) {
      if (lang == Language.python || p == 'r') {
        _string(start, i, raw: p.toLowerCase().contains('r'), formatted: p.toLowerCase().contains('f'));
        return;
      }
    }
    final antes = anterior;
    anterior = p;
    TokenKind? type;
    if (keywords.contains(p)) {
      type = TokenKind.keyword;
    } else if (lang == Language.shell) {
      return;
    } else if (antes == 'def') {
      type = TokenKind.function;
    } else if (antes == 'class' || antes == 'enum' || antes == 'mixin' || antes == 'extends' || antes == 'implements') {
      type = TokenKind.typeName;
    } else if (p == 'self' || p == 'cls' || p == 'this') {
      type = TokenKind.selfRef;
    } else if (lang == Language.python && _pythonBuiltins.contains(p)) {
      type = TokenKind.keyword;
    } else if (p.length > 1 && RegExp(r'^_?[A-Z][A-Z0-9_]*$').hasMatch(p)) {
      type = TokenKind.constant;
    } else if (RegExp(r'^_?[A-Z]').hasMatch(p)) {
      type = TokenKind.typeName;
    } else if (_c == 0x28 || (lang == Language.dart && _c == 0x3C && _genericCall())) {
      type = TokenKind.function;
    }
    if (type != null) output.add((start, i, type));
  }

  /// `name<T>(` in Dart is a call with a generic type.
  bool _genericCall() {
    final end = s.indexOf('>(', i);
    return end != -1 && end - i < 40 && !s.substring(i, end).contains(RegExp(r'[;\n=]'));
  }

  void _shellVariable() {
    final start = i;
    i++;
    if (_c == 0x7B) {
      final end = s.indexOf('}', i);
      i = end == -1 ? s.length : end + 1;
    } else if (_c == 0x28) {
      i++; // `$(`: only the marker; the inner command follows the normal highlighting
    } else if (_isLetter(_c)) {
      while (i < s.length && (_isLetter(_c) || _isDigit(_c))) {
        i++;
      }
    } else if (i < s.length && r'0123456789@#?*$!-'.contains(s[i])) {
      i++;
    }
    output.add((start, i, TokenKind.variable));
  }

  /// String from `start` (prefix included); the quote starts at `i`.
  void _string(int start, int quote, {bool raw = false, bool formatted = false}) {
    i = quote;
    final q = s[i];
    final triple = lang != Language.shell && s.startsWith(q * 3, i);
    final closing = triple ? q * 3 : q;
    i += closing.length;
    final interpolates = !raw &&
        (lang == Language.dart || formatted || (lang == Language.shell && q == '"'));
    var excerpt = start;
    while (i < s.length) {
      final c = s[i];
      if (c == '\\' && !(lang == Language.shell && q == "'")) {
        i += 2;
        continue;
      }
      if (s.startsWith(closing, i)) {
        i += closing.length;
        break;
      }
      if (c == '\n' && !triple && lang != Language.shell) break;
      final interpStart = interpolates &&
          ((lang == Language.python && c == '{' && !s.startsWith('{{', i)) ||
              (lang != Language.python && c == r'$' && i + 1 < s.length && (s[i + 1] == '{' || _isLetter(s.codeUnitAt(i + 1)))));
      if (interpStart) {
        if (i > excerpt) output.add((excerpt, i, TokenKind.text));
        final a = i;
        if (c == '{' || s[i + 1] == '{') {
          var level = 0;
          while (i < s.length && s[i] != '\n') {
            if (s[i] == '{') level++;
            if (s[i] == '}' && --level == 0) break;
            i++;
          }
          i = i < s.length && s[i] == '}' ? i + 1 : i;
        } else {
          i++;
          while (i < s.length && (_isLetter(_c) || _isDigit(_c))) {
            i++;
          }
        }
        output.add((a, i, lang == Language.shell ? TokenKind.variable : TokenKind.interpolation));
        excerpt = i;
        continue;
      }
      if (formatted && s.startsWith('{{', i)) i++;
      i++;
    }
    if (i > s.length) i = s.length;
    if (i > excerpt) output.add((excerpt, i, TokenKind.text));
  }
}

/// File icon by type, with the language color (as in the IntelliJ/VS Code trees).
Widget fileIcon(String name, Color pattern) {
  final n = name.toLowerCase();
  final ext = n.contains('.') ? n.split('.').last : '';
  Widget stamp(String label, Color background, Color letter) => Container(
        width: 16,
        height: 16,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(3)),
        child: Text(label, style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: letter, height: 1)),
      );
  return switch (ext) {
    'py' || 'pyi' => stamp('Py', const Color(0xFF3776AB), const Color(0xFFFFD43B)),
    'dart' => const Icon(Icons.flutter_dash, size: 16, color: Color(0xFF29B6F6)),
    'sh' || 'bash' || 'zsh' => const Icon(Icons.terminal, size: 16, color: Color(0xFF89E051)),
    'md' => const Icon(Icons.article_outlined, size: 16, color: Color(0xFF519ABA)),
    'json' => const Icon(Icons.data_object, size: 16, color: Color(0xFFCBCB41)),
    'yaml' || 'yml' || 'toml' || 'ini' || 'cfg' => const Icon(Icons.settings_outlined, size: 16, color: Color(0xFFA074C4)),
    'png' || 'jpg' || 'jpeg' || 'svg' || 'gif' || 'webp' => const Icon(Icons.image_outlined, size: 16, color: Color(0xFFA074C4)),
    'html' || 'css' || 'js' || 'ts' => const Icon(Icons.code, size: 16, color: Color(0xFFE37933)),
    _ => n == 'verificar' || n == 'dockerfile'
        ? const Icon(Icons.terminal, size: 16, color: Color(0xFF89E051))
        : Icon(Icons.description_outlined, size: 16, color: pattern),
  };
}
