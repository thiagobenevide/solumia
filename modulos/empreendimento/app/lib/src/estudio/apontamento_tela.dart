import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import '../telas/util.dart';

const _auto = 'auto';
const _nenhuma = 'nenhuma';

/// Apontamento no roteiro: cada trecho da narração cortada recebe a cena (ou "auto", a IA local escolhe; ou
/// "nenhuma", só a mídia). Nas marcadas a IA local só preenche título e valores. Confirmar libera o diretor e põe a
/// produção na fila com o estilo, os formatos e a intensidade escolhidos na tela da produção.
class ApontamentoTela extends StatefulWidget {
  const ApontamentoTela({super.key, required this.api, required this.ep, required this.produzir});

  final ApiEsteira api;
  final String ep;
  final Json produzir; // {estilo, formatos, intensidade}

  @override
  State<ApontamentoTela> createState() => _ApontamentoTelaState();
}

class _ApontamentoTelaState extends State<ApontamentoTela> {
  late final Future<Json> _dados = widget.api.apontamento(widget.ep, estilo: '${widget.produzir['estilo'] ?? ''}');
  Map<int, String>? _marcas; // índice do trecho → cena
  List<Json> _trechos = [];

  static String _nome(String c) => switch (c) {
    _auto => 'auto (IA local)',
    _nenhuma => 'nenhuma (só mídia)',
    _ => c.replaceAll('_', ' '),
  };

  static String _tempo(num s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

  List<Json> get _lista => [
    for (final t in _trechos) {'texto': t['texto'], 'cena': _marcas![t['i'] as int] ?? _auto},
  ];

  Future<void> _salvar({required bool confirmar}) => acaoComAviso(context, () async {
    await widget.api.salvarApontamento(widget.ep, _lista, confirmar: confirmar, produzir: confirmar ? widget.produzir : null);
    if (confirmar && mounted) Navigator.pop(context);
    return confirmar ? 'Apontamento confirmado; produção na fila' : 'Apontamento salvo';
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Apontamento · ${widget.ep}'),
      actions: [
        TextButton(onPressed: _marcas == null ? null : () => _salvar(confirmar: false), child: const Text('Salvar')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('Confirmar e produzir'),
            onPressed: _marcas == null ? null : () => _salvar(confirmar: true),
          ),
        ),
      ],
    ),
    body: FutureBuilder<Json>(
      future: _dados,
      builder: (context, snap) {
        if (snap.hasError) return Vazio('${snap.error}', icone: Icons.error_outline);
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final d = snap.data!;
        _trechos = [for (final t in d['trechos'] as List) t as Json];
        _marcas ??= {for (final t in _trechos) if (t['cena'] != _auto) t['i'] as int: t['cena'] as String};
        final opcoes = [_auto, _nenhuma, for (final c in d['cenas'] as List) c as String];
        final marcadas = _marcas!.length;
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: _trechos.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Estilo ${d['estilo']} · ${_trechos.length} trechos · $marcadas marcados'
                  '${d['confirmado'] == true ? ' · confirmado' : ''}. Marque a cena onde você já sabe o que quer; '
                  'o resto fica com a IA local.',
                ),
              );
            }
            final t = _trechos[i - 1];
            final idx = t['i'] as int;
            final cena = _marcas![idx] ?? _auto;
            return Card(
              color: cena == _auto ? null : Theme.of(context).colorScheme.secondaryContainer,
              child: ListTile(
                leading: Text(_tempo(t['ini'] as num)),
                title: Text('${t['texto']}'),
                trailing: DropdownButton<String>(
                  value: opcoes.contains(cena) ? cena : _auto,
                  items: [for (final c in opcoes) DropdownMenuItem(value: c, child: Text(_nome(c)))],
                  onChanged: (v) => setState(() => v == null || v == _auto ? _marcas!.remove(idx) : _marcas![idx] = v),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}
