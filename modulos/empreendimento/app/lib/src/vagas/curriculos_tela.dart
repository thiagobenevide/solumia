import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../telas/util.dart';
import 'api_vagas.dart';

/// Lista de currículos (Markdown em `<dados>/vagas/curriculos/`): um é o padrão, base dos
/// currículos que o Claude adapta para cada vaga.
class CurriculosTela extends StatelessWidget {
  const CurriculosTela({super.key, required this.api});

  final ApiVagas api;

  Future<void> _acao(BuildContext context, Future<void> Function() f, Future<void> Function() recarregar) async {
    try {
      await f();
      await recarregar();
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Currículos')),
    body: Sondagem<Doc>(
      carregar: api.curriculos,
      intervalo: const Duration(seconds: 30),
      construir: (context, d, recarregar) {
        final itens = [for (final c in d['curriculos'] as List) c as Doc];
        return Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
              children: [
                Text('Pasta: ${d['pasta']}', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                if (itens.isEmpty) const Vazio('Nenhum currículo.', icone: Icons.description_outlined),
                for (final c in itens)
                  Card(
                    margin: const EdgeInsets.only(top: 8),
                    child: ListTile(
                      leading: Icon(c['vaga'] == '' ? Icons.description_outlined : Icons.work_outline),
                      title: Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('${c['nome']}'),
                          if (c['padrao'] == true)
                            Chip(
                              label: const Text('Padrão'),
                              avatar: const Icon(Icons.star, size: 16),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                            ),
                        ],
                      ),
                      subtitle: Text(
                        '${c['vaga'] == '' ? 'Modelo' : 'Gerado para a vaga'} · ${'${c['em']}'.split('T').first}',
                      ),
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute<void>(builder: (_) => CurriculoTela(api: api, id: '${c['id']}')),
                        );
                        await recarregar();
                      },
                      trailing: PopupMenuButton<String>(
                        onSelected: (op) => _acao(
                          context,
                          () => op == 'padrao' ? api.definirPadrao('${c['id']}') : api.removerCurriculo('${c['id']}'),
                          recarregar,
                        ),
                        itemBuilder: (_) => [
                          if (c['padrao'] != true)
                            const PopupMenuItem(value: 'padrao', child: Text('Usar como padrão')),
                          const PopupMenuItem(value: 'remover', child: Text('Apagar')),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton.extended(
                icon: const Icon(Icons.add),
                label: const Text('Novo currículo'),
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(builder: (_) => CurriculoTela(api: api)),
                  );
                  await recarregar();
                },
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// Editor de um currículo (Markdown); sem `id`, cria um novo.
class CurriculoTela extends StatefulWidget {
  const CurriculoTela({super.key, required this.api, this.id});

  final ApiVagas api;
  final String? id;

  @override
  State<CurriculoTela> createState() => _CurriculoTelaState();
}

class _CurriculoTelaState extends State<CurriculoTela> {
  final _nome = TextEditingController();
  final _conteudo = TextEditingController();
  String? _id;
  bool _carregando = true;
  bool _padrao = false;

  @override
  void initState() {
    super.initState();
    _id = widget.id;
    if (_id == null) {
      _carregando = false;
    } else {
      widget.api.curriculo(_id!).then(
        (c) => setState(() {
          _nome.text = '${c['nome']}';
          _conteudo.text = '${c['conteudo']}';
          _padrao = c['padrao'] == true;
          _carregando = false;
        }),
        onError: (Object e) => _aviso('$e'),
      );
    }
  }

  @override
  void dispose() {
    _nome.dispose();
    _conteudo.dispose();
    super.dispose();
  }

  void _aviso(String texto) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto)));
  }

  Future<void> _salvar() async {
    try {
      final c = _id == null
          ? await widget.api.criarCurriculo(_nome.text.trim(), _conteudo.text)
          : await widget.api.salvarCurriculo(_id!, _nome.text.trim(), _conteudo.text);
      setState(() {
        _id = '${c['id']}';
        _padrao = c['padrao'] == true;
      });
      _aviso('Currículo salvo.');
    } catch (e) {
      _aviso('$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_id == null ? 'Novo currículo' : 'Currículo'),
      actions: [
        if (_padrao)
          const Padding(padding: EdgeInsets.only(right: 8), child: Chip(label: Text('Padrão'))),
        IconButton(
          tooltip: 'Copiar Markdown',
          icon: const Icon(Icons.copy),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: _conteudo.text));
            _aviso('Copiado.');
          },
        ),
        IconButton(tooltip: 'Salvar', icon: const Icon(Icons.save), onPressed: _carregando ? null : _salvar),
      ],
    ),
    body: _carregando
        ? const Center(child: CircularProgressIndicator())
        : Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              spacing: 12,
              children: [
                TextField(controller: _nome, decoration: const InputDecoration(labelText: 'Nome')),
                Expanded(
                  child: TextField(
                    controller: _conteudo,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      labelText: 'Conteúdo (Markdown)',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ),
  );
}
