import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_eletronica.dart';

/// Bibliotecas do KiCad no servidor: baixar as oficiais (lista sugerida), importar um `.kicad_sym` do
/// aparelho e remover. Reimportar uma que já existe atualiza.
Future<void> mostrarBibliotecas(BuildContext context, ApiEletronica api) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640, maxHeight: 680), child: _Bibliotecas(api: api)),
  ),
);

class _Bibliotecas extends StatefulWidget {
  const _Bibliotecas({required this.api});

  final ApiEletronica api;

  @override
  State<_Bibliotecas> createState() => _BibliotecasState();
}

class _BibliotecasState extends State<_Bibliotecas> {
  List<Map<String, dynamic>> _importadas = [];
  List<String> _sugeridas = [];
  String _versao = '';
  final Set<String> _marcadas = {};
  bool _carregando = true, _trabalhando = false;
  String? _aviso;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    try {
      final (libs, kicad) = (await widget.api.bibliotecas(), await widget.api.kicad());
      if (!mounted) return;
      setState(() {
        _importadas = libs;
        _versao = '${kicad['versao']}';
        _sugeridas = [for (final n in kicad['sugeridas'] as List) '$n'];
        _carregando = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _aviso = 'Não carregou: $e';
          _carregando = false;
        });
      }
    }
  }

  bool _tem(String nome) => _importadas.any((b) => b['nome'] == nome);

  Future<void> _trabalhar(Future<String> Function() tarefa) async {
    setState(() {
      _trabalhando = true;
      _aviso = null;
    });
    try {
      final msg = await tarefa();
      if (mounted) setState(() => _aviso = msg);
    } catch (e) {
      if (mounted) setState(() => _aviso = 'Falhou: $e');
    } finally {
      if (mounted) setState(() => _trabalhando = false);
      await _carregar();
    }
  }

  Future<void> _baixar() => _trabalhar(() async {
    final r = await widget.api.baixarKicad(_marcadas.toList()..sort());
    _marcadas.clear();
    final ok = [for (final l in r) if (l['erro'] == null) '${l['nome']} (${l['total']})'];
    final erros = [for (final l in r) if (l['erro'] != null) '${l['nome']}: ${l['erro']}'];
    return [if (ok.isNotEmpty) 'Importadas: ${ok.join(', ')}', ...erros].join('\n');
  });

  Future<void> _arquivo() async {
    final a = (await FilePicker.pickFiles(type: FileType.any)).firstOrNull;
    if (a == null) return;
    final bytes = await a.xFile.readAsBytes();
    await _trabalhar(() async {
      final r = await widget.api.importarBiblioteca(a.name, bytes);
      return 'Importada ${r['nome']} com ${r['total']} símbolos.';
    });
  }

  Future<void> _remover(String nome) => _trabalhar(() async {
    await widget.api.removerBiblioteca(nome);
    return 'Removida $nome. Componentes já colocados dela aparecem como "?" até importar de novo.';
  });

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    if (_carregando) return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
    return Column(
      children: [
        ListTile(
          title: Text('Bibliotecas do KiCad', style: tema.textTheme.titleLarge),
          subtitle: Text('Oficiais do KiCad $_versao (licença CC-BY-SA 4.0) ou um arquivo .kicad_sym seu.'),
          trailing: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
        ),
        if (_trabalhando) const LinearProgressIndicator(),
        if (_aviso != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_aviso!, style: tema.textTheme.bodySmall),
          ),
        Expanded(
          child: ListView(
            children: [
              if (_importadas.isNotEmpty) ...[
                const _Titulo('Importadas'),
                for (final b in _importadas)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.inventory_2_outlined),
                    title: Text('${b['nome']}'),
                    subtitle: Text('${b['total']} símbolos · ${b['origem']}'),
                    trailing: IconButton(
                      tooltip: 'Remover',
                      onPressed: _trabalhando ? null : () => _remover('${b['nome']}'),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
              ],
              const _Titulo('Oficiais sugeridas (PC, celular, monitor e som)'),
              for (final n in _sugeridas)
                CheckboxListTile(
                  dense: true,
                  value: _marcadas.contains(n),
                  onChanged: _trabalhando ? null : (v) => setState(() => v == true ? _marcadas.add(n) : _marcadas.remove(n)),
                  title: Text(n),
                  subtitle: _tem(n) ? const Text('já importada — marcar atualiza') : null,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              TextButton(
                onPressed: _trabalhando
                    ? null
                    : () => setState(() => _marcadas.addAll(_sugeridas.where((n) => !_tem(n)))),
                child: const Text('Marcar as que faltam'),
              ),
              OutlinedButton.icon(
                onPressed: _trabalhando ? null : _arquivo,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Importar arquivo'),
              ),
              FilledButton.icon(
                onPressed: _trabalhando || _marcadas.isEmpty ? null : _baixar,
                icon: const Icon(Icons.download),
                label: Text('Baixar ${_marcadas.isEmpty ? '' : '(${_marcadas.length})'}'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Titulo extends StatelessWidget {
  const _Titulo(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(texto, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
  );
}
