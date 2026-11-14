import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/util.dart';
import 'jobs_api.dart';

/// List of résumés (Markdown in `<dados>/vagas/curriculos/`): one is the default, the base of the
/// résumés that Claude adapts for each job.
class ResumesScreen extends StatelessWidget {
  const ResumesScreen({super.key, required this.api});

  final ApiJobs api;

  Future<void> _action(BuildContext context, Future<void> Function() f, Future<void> Function() recarregar) async {
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
      carregar: api.resumes,
      intervalo: const Duration(seconds: 30),
      construir: (context, d, recarregar) {
        final items = [for (final c in d['curriculos'] as List) c as Doc];
        return Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
              children: [
                Text('Pasta: ${d['pasta']}', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                if (items.isEmpty) const Empty('Nenhum currículo.', icone: Icons.description_outlined),
                for (final c in items)
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
                          MaterialPageRoute<void>(builder: (_) => ResumeScreen(api: api, id: '${c['id']}')),
                        );
                        await recarregar();
                      },
                      trailing: PopupMenuButton<String>(
                        onSelected: (op) => _action(
                          context,
                          () => op == 'padrao' ? api.setDefault('${c['id']}') : api.removeResume('${c['id']}'),
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
                    MaterialPageRoute<void>(builder: (_) => ResumeScreen(api: api)),
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

/// Editor of one résumé (Markdown); without an `id`, creates a new one.
class ResumeScreen extends StatefulWidget {
  const ResumeScreen({super.key, required this.api, this.id});

  final ApiJobs api;
  final String? id;

  @override
  State<ResumeScreen> createState() => _ResumeScreenState();
}

class _ResumeScreenState extends State<ResumeScreen> {
  final _nome = TextEditingController();
  final _content = TextEditingController();
  String? _id;
  bool _loading = true;
  bool _isDefault = false;

  @override
  void initState() {
    super.initState();
    _id = widget.id;
    if (_id == null) {
      _loading = false;
    } else {
      widget.api.resume(_id!).then(
        (c) => setState(() {
          _nome.text = '${c['nome']}';
          _content.text = '${c['conteudo']}';
          _isDefault = c['padrao'] == true;
          _loading = false;
        }),
        onError: (Object e) => _warning('$e'),
      );
    }
  }

  @override
  void dispose() {
    _nome.dispose();
    _content.dispose();
    super.dispose();
  }

  void _warning(String texto) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto)));
  }

  Future<void> _save() async {
    try {
      final c = _id == null
          ? await widget.api.createResume(_nome.text.trim(), _content.text)
          : await widget.api.saveResume(_id!, _nome.text.trim(), _content.text);
      setState(() {
        _id = '${c['id']}';
        _isDefault = c['padrao'] == true;
      });
      _warning('Currículo salvo.');
    } catch (e) {
      _warning('$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_id == null ? 'Novo currículo' : 'Currículo'),
      actions: [
        if (_isDefault)
          const Padding(padding: EdgeInsets.only(right: 8), child: Chip(label: Text('Padrão'))),
        IconButton(
          tooltip: 'Copiar Markdown',
          icon: const Icon(Icons.copy),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: _content.text));
            _warning('Copiado.');
          },
        ),
        IconButton(tooltip: 'Salvar', icon: const Icon(Icons.save), onPressed: _loading ? null : _save),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              spacing: 12,
              children: [
                TextField(controller: _nome, decoration: const InputDecoration(labelText: 'Nome')),
                Expanded(
                  child: TextField(
                    controller: _content,
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
