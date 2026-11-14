import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'modelos.dart';

/// Cópia local de um quadro: o que o aparelho tem e se ainda falta mandar ao servidor.
class CopiaLocal {
  CopiaLocal(this.resumo, this.elementos, {required this.pendente, required this.apagados, this.paginaDe = const {}});

  final ResumoQuadro resumo;
  final List<Elemento> elementos;
  final bool pendente;
  final Set<String> apagados;
  final Map<String, String> paginaDe;
}

/// Cache offline dos quadros no aparelho (SharedPreferences: arquivo no Android/desktop,
/// localStorage na web). Sem o plugin (testes), vira um cache só em memória.
class CacheQuadros {
  CacheQuadros._(this._prefs, this._prefixo);

  /// [prefixo] separa coleções no aparelho (`design.caderno.` para os cadernos).
  static Future<CacheQuadros> abrir({String prefixo = 'design.quadro.'}) async {
    try {
      return CacheQuadros._(await SharedPreferences.getInstance(), prefixo);
    } catch (_) {
      return CacheQuadros._(null, prefixo);
    }
  }

  final SharedPreferences? _prefs;
  final Map<String, String> _memoria = {};
  final String _prefixo;

  String? _ler(String chave) => _prefs != null ? _prefs.getString(chave) : _memoria[chave];

  Iterable<String> get _chaves => (_prefs?.getKeys() ?? _memoria.keys).where((k) => k.startsWith(_prefixo));

  Future<void> guardar(
    Map<String, dynamic> resumo,
    List<Elemento> elementos, {
    required bool pendente,
    Set<String> apagados = const {},
    Map<String, String> paginaDe = const {},
  }) async {
    final chave = '$_prefixo${resumo['id']}';
    final texto = jsonEncode({
      'resumo': resumo,
      'elementos': [for (final e in elementos) jsonComPagina(e, paginaDe)],
      'pendente': pendente,
      'apagados': [...apagados],
    });
    if (_prefs == null) {
      _memoria[chave] = texto;
      return;
    }
    try {
      await _prefs.setString(chave, texto);
    } catch (_) {
      // Sem espaço (localStorage da web tem ~5 MB): o servidor continua sendo a fonte.
    }
  }

  CopiaLocal? ler(String id) {
    final texto = _ler('$_prefixo$id');
    if (texto == null) return null;
    final j = jsonDecode(texto) as Map<String, dynamic>;
    return CopiaLocal(
      ResumoQuadro.fromJson({...j['resumo'] as Map<String, dynamic>, 'total': (j['elementos'] as List).length}),
      [for (final e in j['elementos'] as List) ?Elemento.fromJson(e as Map<String, dynamic>)],
      pendente: j['pendente'] == true,
      apagados: {...(j['apagados'] as List? ?? const []).cast<String>()},
      paginaDe: paginasDosElementos(j['elementos'] as List),
    );
  }

  /// Quadros guardados no aparelho, para a galeria sem rede.
  List<ResumoQuadro> resumos() => [
    for (final k in _chaves)
      if (ler(k.substring(_prefixo.length)) case final c?) c.resumo,
  ]..sort((a, b) => (b.atualizado ?? DateTime(0)).compareTo(a.atualizado ?? DateTime(0)));

  Future<void> remover(String id) async {
    _memoria.remove('$_prefixo$id');
    await _prefs?.remove('$_prefixo$id');
  }
}
