import 'dart:convert';

import 'package:http/http.dart' as http;

/// Busca de imagens feita pelo próprio aparelho: a VPS (IP de datacenter) recebe página vazia do
/// Bing e bloqueio do Google, então o celular/PC busca direto e o servidor só baixa a escolhida.
/// Mesmo formato da rota `/imagens/busca`. Na web não roda (CORS): quem chama cai no servidor.
const _filtros = {
  'foto': '+filterui:photo-photo',
  'icone': '+filterui:photo-clipart',
  'figura': '+filterui:photo-linedrawing',
};
final _m = RegExp(r'\bm="([^"]+)"');
final _tamanho = RegExp(r'(\d+)\s*(?:&#215;|×|x)\s*(\d+)');
final _entidade = RegExp(r'&(#\d+|#x[0-9a-fA-F]+|quot|amp|lt|gt|apos);');

String _desescapar(String s) => s.replaceAllMapped(_entidade, (m) {
  final e = m.group(1)!;
  if (e.startsWith('#x')) return String.fromCharCode(int.parse(e.substring(2), radix: 16));
  if (e.startsWith('#')) return String.fromCharCode(int.parse(e.substring(1)));
  return const {'quot': '"', 'amp': '&', 'lt': '<', 'gt': '>', 'apos': "'"}[e]!;
});

Future<List<Map<String, dynamic>>> buscarNoBing(String q, String tipo, int pagina) async {
  final url = Uri.https('www.bing.com', '/images/async', {
    'q': q,
    'first': '${pagina * 10 + 1}',
    'count': '10',
    'mmasync': '1',
    // Sem `form=IRFLTR` o Bing ignora o filtro de tipo.
    if (_filtros[tipo] case final f?) ...{'qft': f, 'form': 'IRFLTR'},
  });
  final r = await http
      .get(
        url,
        headers: {
          'User-Agent':
              // UA de celular: com o de computador o Bing ignora o filtro de tipo.
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36',
          'Accept-Language': 'pt-BR,pt;q=0.9',
        },
      )
      .timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw Exception('Bing respondeu ${r.statusCode}');
  final resultados = <Map<String, dynamic>>[];
  for (final bloco in utf8.decode(r.bodyBytes, allowMalformed: true).split('class="iusc"').skip(1)) {
    final m = _m.firstMatch(bloco);
    if (m == null) continue;
    final dados = jsonDecode(_desescapar(m.group(1)!)) as Map<String, dynamic>;
    final murl = dados['murl'] as String? ?? '';
    if (murl.isEmpty) continue;
    final t = _tamanho.firstMatch(bloco);
    resultados.add({
      'url': murl,
      'miniatura': dados['turl'] as String? ?? '',
      'titulo': _desescapar(dados['t'] as String? ?? ''),
      'largura': t == null ? 0 : int.parse(t.group(1)!),
      'altura': t == null ? 0 : int.parse(t.group(2)!),
    });
    if (resultados.length == 10) break;
  }
  if (resultados.isEmpty && pagina == 0) throw Exception('Bing não devolveu resultados');
  return resultados;
}
