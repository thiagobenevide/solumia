import 'package:agent_core/agent_core.dart';
import 'package:agent_notas/agent_notas.dart';
import 'package:flutter/material.dart';

import '../api_saude.dart';
import '../datas.dart';

/// Vida espiritual: plano de leitura bíblica com a leitura do dia, reflexões sobre o texto e estudos
/// de teologia. Reflexões e estudos são notas do vault (tags `reflexao` e `teologia`).
class EspiritualTela extends StatefulWidget {
  const EspiritualTela({super.key, required this.api});

  final ApiSaude api;

  @override
  State<EspiritualTela> createState() => _EspiritualTelaState();
}

class _EspiritualTelaState extends State<EspiritualTela> {
  ApiSaude get api => widget.api;
  List<Map<String, dynamic>>? _planos;
  String? _plano;
  List<Map<String, dynamic>> _semana = const [];
  List<NotaResumo> _reflexoes = const [];
  List<NotaResumo> _teologia = const [];

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Map<String, dynamic>? get _atual => _planos?.where((p) => p['id'] == _plano).firstOrNull;

  Future<void> _tentar(Future<void> Function() f) async {
    try {
      await f();
    } on ApiErro catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _carregar() => _tentar(() async {
    final planos = await api.planos();
    final reflexoes = await api.notasComTag('reflexao');
    final teologia = await api.notasComTag('teologia');
    setState(() {
      _planos = planos;
      _reflexoes = reflexoes;
      _teologia = teologia;
      if (_atual == null) _plano = planos.firstOrNull?['id'] as String?;
    });
    await _carregarSemana();
  });

  Future<void> _carregarSemana() async {
    final p = _atual;
    if (p == null) return;
    final s = await api.leiturasDoPlano(p['id'] as String, hoje(), somarDias(hoje(), 6));
    if (mounted) setState(() => _semana = s);
  }

  Future<void> _marcar(String data, bool feito) => _tentar(() async {
    await api.marcarLeitura(_plano!, DateTime.parse(data), feito);
    await _carregar();
  });

  Future<void> _novoPlano() async {
    final escopos = await api.escopos();
    if (!mounted) return;
    var escopo = 'biblia';
    var dias = 365.0;
    var inicio = hoje();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Novo plano de leitura'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: escopo,
                  decoration: const InputDecoration(labelText: 'O que ler'),
                  items: [
                    for (final e in escopos) DropdownMenuItem(value: e['id'] as String, child: Text(e['nome'] as String)),
                  ],
                  onChanged: (v) => setState(() => escopo = v!),
                ),
                Text('Em ${dias.round()} dias'),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final d in const [30, 90, 180, 365, 730])
                      ChoiceChip(label: Text('$d'), selected: dias.round() == d, onSelected: (_) => setState(() => dias = d.toDouble())),
                  ],
                ),
                Slider(value: dias, min: 7, max: 730, onChanged: (v) => setState(() => dias = v)),
                TextButton.icon(
                  icon: const Icon(Icons.event),
                  label: Text('Começa em ${diaLongo(inicio)}'),
                  onPressed: () async {
                    final d = await showDatePicker(context: context, initialDate: inicio, firstDate: DateTime(2020), lastDate: DateTime(2100));
                    if (d != null) setState(() => inicio = d);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Criar')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _tentar(() async {
      final p = await api.criarPlano({'escopo': escopo, 'dias': dias.round(), 'inicio': iso(inicio)});
      _plano = p['id'] as String;
      await _carregar();
    });
  }

  Future<void> _abrirNota(String id) async {
    final aberta = NotaAberta(api.notas)..abrir(id);
    await abrirTela(context, (_) => Scaffold(appBar: AppBar(title: const Text('Nota')), body: EditorNota(aberta: aberta)));
    await _carregar();
  }

  Future<void> _novaNota(String tag, String titulo, String corpo) => _tentar(() async {
    final nota = await api.notas.criar({'titulo': titulo, 'tags': [tag, 'espiritual'], 'corpo': corpo});
    await _abrirNota(nota.id);
  });

  Future<void> _refletir(Map<String, dynamic> dia) {
    final trechos = (dia['trechos'] as List).cast<String>();
    return _novaNota(
      'reflexao',
      'Reflexão ${dia['data']} — ${trechos.join(', ')}',
      '**Leitura:** ${trechos.join('; ')}\n\n## O que o texto diz\n\n## O que aprendo sobre Deus\n\n'
          '## Como aplico hoje\n\n## Oração\n',
    );
  }

  Future<void> _novoEstudo() async {
    final c = TextEditingController();
    final titulo = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Novo estudo de teologia'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Tema', hintText: 'ex.: Graça, Trindade, Escatologia'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Criar')),
        ],
      ),
    );
    if (titulo == null || titulo.trim().isEmpty) return;
    await _novaNota(
      'teologia',
      titulo.trim(),
      '## Definição\n\n## Textos-chave\n\n## Visões e autores\n\n## Conclusões\n\n## Ligações\n',
    );
  }

  @override
  Widget build(BuildContext context) {
    final planos = _planos;
    if (planos == null) return const Center(child: CircularProgressIndicator());
    final tema = Theme.of(context);
    final p = _atual;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final x in planos)
              ChoiceChip(
                label: Text(x['nome'] as String),
                selected: x['id'] == _plano,
                onSelected: (_) {
                  setState(() => _plano = x['id'] as String);
                  _tentar(_carregarSemana);
                },
              ),
            ActionChip(avatar: const Icon(Icons.add), label: const Text('Plano de leitura'), onPressed: _novoPlano),
          ],
        ),
        if (p == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Crie um plano (Bíblia em 1 ano, NT em 90 dias…) para ver a leitura de cada dia.', textAlign: TextAlign.center),
          )
        else ...[
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 6,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${p['nome_escopo']} · ${p['capitulos']} capítulos em ${p['dias']} dias',
                          style: tema.textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Excluir plano',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _tentar(() async {
                          await api.excluirPlano(p['id'] as String);
                          _plano = null;
                          await _carregar();
                        }),
                      ),
                    ],
                  ),
                  LinearProgressIndicator(value: (p['lidos'] as int) / (p['dias'] as int)),
                  Text('${p['lidos']} de ${p['dias']} dias lidos · termina em ${diaLongo(DateTime.parse(p['fim'] as String))}'),
                  if ((p['atrasados'] as List).isNotEmpty)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      leading: Icon(Icons.warning_amber, color: tema.colorScheme.error),
                      title: Text('${(p['atrasados'] as List).length} dias atrasados'),
                      children: [
                        for (final d in (p['atrasados'] as List).cast<String>().take(30))
                          CheckboxListTile(
                            dense: true,
                            value: false,
                            title: Text(diaLongo(DateTime.parse(d))),
                            onChanged: (_) => _marcar(d, true),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          for (final dia in _semana)
            Card(
              shape: dia['data'] == iso(hoje())
                  ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: tema.colorScheme.primary))
                  : null,
              child: ListTile(
                leading: Checkbox(value: dia['feito'] as bool, onChanged: (v) => _marcar(dia['data'] as String, v ?? false)),
                title: Text((dia['trechos'] as List).join('; ')),
                subtitle: Text('Dia ${dia['dia']} · ${diaLongo(DateTime.parse(dia['data'] as String))}'),
                trailing: IconButton(
                  tooltip: 'Escrever reflexão',
                  icon: const Icon(Icons.edit_note),
                  onPressed: () => _refletir(dia),
                ),
              ),
            ),
        ],
        const SizedBox(height: 16),
        _secao('Reflexões', _reflexoes, null),
        _secao('Teologia', _teologia, _novoEstudo),
      ],
    );
  }

  Widget _secao(String titulo, List<NotaResumo> notas, VoidCallback? criar) => Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(titulo, style: Theme.of(context).textTheme.titleMedium),
          trailing: criar == null ? null : IconButton(icon: const Icon(Icons.add), tooltip: 'Novo estudo', onPressed: criar),
        ),
        if (notas.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(criar == null ? 'Use o ✎ da leitura do dia para escrever uma reflexão.' : 'Nenhum estudo ainda.'),
          ),
        for (final n in notas.take(20))
          ListTile(
            dense: true,
            leading: const Icon(Icons.sticky_note_2_outlined),
            title: Text(n.titulo),
            subtitle: n.atualizada == null ? null : Text(diaLongo(n.atualizada!.toLocal())),
            onTap: () => _abrirNota(n.id),
          ),
      ],
    ),
  );
}
