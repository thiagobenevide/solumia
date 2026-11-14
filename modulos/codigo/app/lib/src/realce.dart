import 'package:flutter/material.dart';

/// Realce de sintaxe do navegador de código (Python, Dart e shell), nas cores do tema escuro do
/// IntelliJ/VS Code. O texto inteiro é varrido de uma vez (strings e comentários de várias linhas
/// atravessam linhas) e devolvido já cortado por linha, para o `ListView` montar linha a linha.

enum Tipo { palavra, texto, numero, comentario, anotacao, classe, funcao, constante, proprio, variavel, interpolacao }

enum Linguagem { python, dart, shell }

Linguagem? linguagemDe(String caminho) {
  final nome = caminho.split('/').last.toLowerCase();
  final ext = nome.contains('.') ? nome.split('.').last : '';
  return switch (ext) {
    'py' || 'pyi' => Linguagem.python,
    'dart' => Linguagem.dart,
    'sh' || 'bash' || 'zsh' => Linguagem.shell,
    _ => const {'verificar', '.bashrc', '.profile', 'dockerfile'}.contains(nome) ? Linguagem.shell : null,
  };
}

Map<Tipo, Color> coresRealce(Brightness brilho) => brilho == Brightness.dark
    ? const {
        Tipo.palavra: Color(0xFFCF8E6D),
        Tipo.texto: Color(0xFF6AAB73),
        Tipo.numero: Color(0xFF2AACB8),
        Tipo.comentario: Color(0xFF7A7E85),
        Tipo.anotacao: Color(0xFFB3AE60),
        Tipo.classe: Color(0xFF4EC9B0),
        Tipo.funcao: Color(0xFF56A8F5),
        Tipo.constante: Color(0xFFC77DBB),
        Tipo.proprio: Color(0xFF94558D),
        Tipo.variavel: Color(0xFFC77DBB),
        Tipo.interpolacao: Color(0xFFCF8E6D),
      }
    : const {
        Tipo.palavra: Color(0xFF0033B3),
        Tipo.texto: Color(0xFF067D17),
        Tipo.numero: Color(0xFF1750EB),
        Tipo.comentario: Color(0xFF8C8C8C),
        Tipo.anotacao: Color(0xFF9E880D),
        Tipo.classe: Color(0xFF008080),
        Tipo.funcao: Color(0xFF00627A),
        Tipo.constante: Color(0xFF871094),
        Tipo.proprio: Color(0xFF94558D),
        Tipo.variavel: Color(0xFF871094),
        Tipo.interpolacao: Color(0xFF0033B3),
      };

const _palavras = {
  Linguagem.python: {
    'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue', 'def', //
    'del', 'elif', 'else', 'except', 'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda',
    'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'try', 'while', 'with', 'yield', 'match', 'case',
  },
  Linguagem.dart: {
    'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case', 'catch', 'class', 'const', //
    'continue', 'covariant', 'default', 'deferred', 'do', 'dynamic', 'else', 'enum', 'export', 'extends',
    'extension', 'external', 'factory', 'false', 'final', 'finally', 'for', 'get', 'hide', 'if', 'implements',
    'import', 'in', 'interface', 'is', 'late', 'library', 'mixin', 'new', 'null', 'on', 'operator', 'part',
    'required', 'rethrow', 'return', 'sealed', 'set', 'show', 'static', 'super', 'switch', 'sync', 'throw',
    'true', 'try', 'typedef', 'var', 'void', 'when', 'while', 'with', 'yield', 'int', 'double', 'num', 'bool',
  },
  Linguagem.shell: {
    'if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'until', 'do', 'done', 'case', 'esac', 'in', //
    'function', 'return', 'local', 'export', 'readonly', 'declare', 'set', 'unset', 'shift', 'exit', 'source',
    'trap', 'exec', 'eval', 'break', 'continue', 'true', 'false',
  },
};

const _embutidosPython = {
  'str', 'int', 'float', 'bool', 'bytes', 'list', 'dict', 'set', 'tuple', 'object', 'type', 'len', 'print', //
  'range', 'open', 'isinstance', 'super', 'enumerate', 'zip', 'map', 'filter', 'sorted', 'min', 'max', 'sum',
  'any', 'all', 'repr', 'getattr', 'setattr', 'hasattr', 'iter', 'next', 'abs', 'round', 'Exception',
};

typedef Trecho = (int inicio, int fim, Tipo tipo);

/// Linhas do texto com os trechos coloridos; `null` quando a linguagem não é reconhecida.
List<List<TextSpan>>? realcar(String texto, String caminho, TextStyle base, Brightness brilho) {
  final ling = linguagemDe(caminho);
  if (ling == null) return null;
  final cores = coresRealce(brilho);
  final trechos = _Varredor(texto, ling).varrer();
  final linhas = <List<TextSpan>>[[]];
  var pos = 0;
  void emitir(int ate, Color? cor) {
    while (pos < ate) {
      final quebra = texto.indexOf('\n', pos);
      final fim = quebra == -1 || quebra >= ate ? ate : quebra;
      if (fim > pos) linhas.last.add(TextSpan(text: texto.substring(pos, fim), style: cor == null ? base : base.copyWith(color: cor)));
      pos = fim;
      if (fim == quebra) {
        linhas.add([]);
        pos++;
      }
    }
  }

  for (final (ini, fim, tipo) in trechos) {
    emitir(ini, null);
    emitir(fim, cores[tipo]);
  }
  emitir(texto.length, null);
  return linhas;
}

class _Varredor {
  _Varredor(this.s, this.ling) : palavras = _palavras[ling]!;

  final String s;
  final Linguagem ling;
  final Set<String> palavras;
  final saida = <Trecho>[];
  var i = 0;
  String? anterior; // última palavra-chave/identificador, para `def`/`class` nomearem o seguinte

  static bool _letra(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127;
  static bool _digito(int c) => c >= 48 && c <= 57;

  int get _c => i < s.length ? s.codeUnitAt(i) : 0;

  List<Trecho> varrer() {
    while (i < s.length) {
      final c = _c;
      final ini = i;
      if (_comentario()) continue;
      if (c == 0x22 || c == 0x27) {
        _texto(ini, ini);
      } else if (ling == Linguagem.shell && c == 0x24) {
        _variavelShell();
      } else if (c == 0x40 && ling != Linguagem.shell) {
        i++;
        while (i < s.length && (_letra(_c) || _digito(_c) || _c == 0x2E)) {
          i++;
        }
        saida.add((ini, i, Tipo.anotacao));
      } else if (_digito(c) || (c == 0x2E && _digito(i + 1 < s.length ? s.codeUnitAt(i + 1) : 0))) {
        if (i > 0 && _letra(s.codeUnitAt(i - 1))) {
          i++;
          continue;
        }
        while (i < s.length && (_letra(_c) || _digito(_c) || _c == 0x2E)) {
          i++;
        }
        saida.add((ini, i, Tipo.numero));
      } else if (_letra(c)) {
        _identificador(ini);
      } else {
        i++;
      }
    }
    return saida;
  }

  bool _comentario() {
    final ini = i;
    final barra = ling == Linguagem.dart;
    if ((!barra && _c == 0x23) || (barra && s.startsWith('//', i))) {
      // `#` do shell só começa comentário no início de palavra (`$#`, `${#x}` não)
      if (ling == Linguagem.shell && i > 0 && !' \t\n;'.contains(s[i - 1])) return false;
      final fim = s.indexOf('\n', i);
      i = fim == -1 ? s.length : fim;
      saida.add((ini, i, Tipo.comentario));
      return true;
    }
    if (barra && s.startsWith('/*', i)) {
      final fim = s.indexOf('*/', i + 2);
      i = fim == -1 ? s.length : fim + 2;
      saida.add((ini, i, Tipo.comentario));
      return true;
    }
    return false;
  }

  void _identificador(int ini) {
    while (i < s.length && (_letra(_c) || _digito(_c))) {
      i++;
    }
    final p = s.substring(ini, i);
    // prefixo de string: f"", r'', b"", rb"" (Python) e r'' (Dart)
    if ((_c == 0x22 || _c == 0x27) && ling != Linguagem.shell && p.length <= 2 && RegExp(r'^[rRbBfFuU]+$').hasMatch(p)) {
      if (ling == Linguagem.python || p == 'r') {
        _texto(ini, i, cru: p.toLowerCase().contains('r'), formatado: p.toLowerCase().contains('f'));
        return;
      }
    }
    final antes = anterior;
    anterior = p;
    Tipo? tipo;
    if (palavras.contains(p)) {
      tipo = Tipo.palavra;
    } else if (ling == Linguagem.shell) {
      return;
    } else if (antes == 'def') {
      tipo = Tipo.funcao;
    } else if (antes == 'class' || antes == 'enum' || antes == 'mixin' || antes == 'extends' || antes == 'implements') {
      tipo = Tipo.classe;
    } else if (p == 'self' || p == 'cls' || p == 'this') {
      tipo = Tipo.proprio;
    } else if (ling == Linguagem.python && _embutidosPython.contains(p)) {
      tipo = Tipo.palavra;
    } else if (p.length > 1 && RegExp(r'^_?[A-Z][A-Z0-9_]*$').hasMatch(p)) {
      tipo = Tipo.constante;
    } else if (RegExp(r'^_?[A-Z]').hasMatch(p)) {
      tipo = Tipo.classe;
    } else if (_c == 0x28 || (ling == Linguagem.dart && _c == 0x3C && _chamadaGenerica())) {
      tipo = Tipo.funcao;
    }
    if (tipo != null) saida.add((ini, i, tipo));
  }

  /// `nome<T>(` em Dart é chamada com tipo genérico.
  bool _chamadaGenerica() {
    final fim = s.indexOf('>(', i);
    return fim != -1 && fim - i < 40 && !s.substring(i, fim).contains(RegExp(r'[;\n=]'));
  }

  void _variavelShell() {
    final ini = i;
    i++;
    if (_c == 0x7B) {
      final fim = s.indexOf('}', i);
      i = fim == -1 ? s.length : fim + 1;
    } else if (_c == 0x28) {
      i++; // `$(`: só o marcador; o comando de dentro segue o realce normal
    } else if (_letra(_c)) {
      while (i < s.length && (_letra(_c) || _digito(_c))) {
        i++;
      }
    } else if (i < s.length && r'0123456789@#?*$!-'.contains(s[i])) {
      i++;
    }
    saida.add((ini, i, Tipo.variavel));
  }

  /// String a partir de `ini` (prefixo incluso); a aspa começa em `i`.
  void _texto(int ini, int aspa, {bool cru = false, bool formatado = false}) {
    i = aspa;
    final q = s[i];
    final tripla = ling != Linguagem.shell && s.startsWith(q * 3, i);
    final fecho = tripla ? q * 3 : q;
    i += fecho.length;
    final interpola = !cru &&
        (ling == Linguagem.dart || formatado || (ling == Linguagem.shell && q == '"'));
    var trecho = ini;
    while (i < s.length) {
      final c = s[i];
      if (c == '\\' && !(ling == Linguagem.shell && q == "'")) {
        i += 2;
        continue;
      }
      if (s.startsWith(fecho, i)) {
        i += fecho.length;
        break;
      }
      if (c == '\n' && !tripla && ling != Linguagem.shell) break;
      final inicioInterp = interpola &&
          ((ling == Linguagem.python && c == '{' && !s.startsWith('{{', i)) ||
              (ling != Linguagem.python && c == r'$' && i + 1 < s.length && (s[i + 1] == '{' || _letra(s.codeUnitAt(i + 1)))));
      if (inicioInterp) {
        if (i > trecho) saida.add((trecho, i, Tipo.texto));
        final a = i;
        if (c == '{' || s[i + 1] == '{') {
          var nivel = 0;
          while (i < s.length && s[i] != '\n') {
            if (s[i] == '{') nivel++;
            if (s[i] == '}' && --nivel == 0) break;
            i++;
          }
          i = i < s.length && s[i] == '}' ? i + 1 : i;
        } else {
          i++;
          while (i < s.length && (_letra(_c) || _digito(_c))) {
            i++;
          }
        }
        saida.add((a, i, ling == Linguagem.shell ? Tipo.variavel : Tipo.interpolacao));
        trecho = i;
        continue;
      }
      if (formatado && s.startsWith('{{', i)) i++;
      i++;
    }
    if (i > s.length) i = s.length;
    if (i > trecho) saida.add((trecho, i, Tipo.texto));
  }
}

/// Ícone do arquivo pelo tipo, com a cor da linguagem (como nas árvores do IntelliJ/VS Code).
Widget iconeArquivo(String nome, Color padrao) {
  final n = nome.toLowerCase();
  final ext = n.contains('.') ? n.split('.').last : '';
  Widget selo(String rotulo, Color fundo, Color letra) => Container(
        width: 16,
        height: 16,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: fundo, borderRadius: BorderRadius.circular(3)),
        child: Text(rotulo, style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: letra, height: 1)),
      );
  return switch (ext) {
    'py' || 'pyi' => selo('Py', const Color(0xFF3776AB), const Color(0xFFFFD43B)),
    'dart' => const Icon(Icons.flutter_dash, size: 16, color: Color(0xFF29B6F6)),
    'sh' || 'bash' || 'zsh' => const Icon(Icons.terminal, size: 16, color: Color(0xFF89E051)),
    'md' => const Icon(Icons.article_outlined, size: 16, color: Color(0xFF519ABA)),
    'json' => const Icon(Icons.data_object, size: 16, color: Color(0xFFCBCB41)),
    'yaml' || 'yml' || 'toml' || 'ini' || 'cfg' => const Icon(Icons.settings_outlined, size: 16, color: Color(0xFFA074C4)),
    'png' || 'jpg' || 'jpeg' || 'svg' || 'gif' || 'webp' => const Icon(Icons.image_outlined, size: 16, color: Color(0xFFA074C4)),
    'html' || 'css' || 'js' || 'ts' => const Icon(Icons.code, size: 16, color: Color(0xFFE37933)),
    _ => n == 'verificar' || n == 'dockerfile'
        ? const Icon(Icons.terminal, size: 16, color: Color(0xFF89E051))
        : Icon(Icons.description_outlined, size: 16, color: padrao),
  };
}
