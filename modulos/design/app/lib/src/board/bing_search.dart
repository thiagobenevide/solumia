import 'dart:convert';

import 'package:http/http.dart' as http;

/// Image search done by the device itself: the VPS (datacenter IP) gets an empty page from
/// Bing and a block from Google, so the phone/PC searches directly and the server only downloads the chosen one.
/// Same format as the `/imagens/busca` route. It does not run on the web (CORS): the caller falls back to the server.
const _filters = {
  'foto': '+filterui:photo-photo',
  'icone': '+filterui:photo-clipart',
  'figura': '+filterui:photo-linedrawing',
};
final _m = RegExp(r'\bm="([^"]+)"');
final _size = RegExp(r'(\d+)\s*(?:&#215;|×|x)\s*(\d+)');
final _entity = RegExp(r'&(#\d+|#x[0-9a-fA-F]+|quot|amp|lt|gt|apos);');

String _unescape(String s) => s.replaceAllMapped(_entity, (m) {
  final e = m.group(1)!;
  if (e.startsWith('#x')) return String.fromCharCode(int.parse(e.substring(2), radix: 16));
  if (e.startsWith('#')) return String.fromCharCode(int.parse(e.substring(1)));
  return const {'quot': '"', 'amp': '&', 'lt': '<', 'gt': '>', 'apos': "'"}[e]!;
});

Future<List<Map<String, dynamic>>> searchBing(String q, String type, int page) async {
  final url = Uri.https('www.bing.com', '/images/async', {
    'q': q,
    'first': '${page * 10 + 1}',
    'count': '10',
    'mmasync': '1',
    // Without `form=IRFLTR` Bing ignores the type filter.
    if (_filters[type] case final f?) ...{'qft': f, 'form': 'IRFLTR'},
  });
  final r = await http
      .get(
        url,
        headers: {
          'User-Agent':
              // Phone UA: with the desktop one Bing ignores the type filter.
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36',
          'Accept-Language': 'pt-BR,pt;q=0.9',
        },
      )
      .timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw Exception('Bing respondeu ${r.statusCode}');
  final results = <Map<String, dynamic>>[];
  for (final block in utf8.decode(r.bodyBytes, allowMalformed: true).split('class="iusc"').skip(1)) {
    final m = _m.firstMatch(block);
    if (m == null) continue;
    final data = jsonDecode(_unescape(m.group(1)!)) as Map<String, dynamic>;
    final murl = data['murl'] as String? ?? '';
    if (murl.isEmpty) continue;
    final t = _size.firstMatch(block);
    results.add({
      'url': murl,
      'miniatura': data['turl'] as String? ?? '',
      'titulo': _unescape(data['t'] as String? ?? ''),
      'largura': t == null ? 0 : int.parse(t.group(1)!),
      'altura': t == null ? 0 : int.parse(t.group(2)!),
    });
    if (results.length == 10) break;
  }
  if (results.isEmpty && page == 0) throw Exception('Bing não devolveu resultados');
  return results;
}
