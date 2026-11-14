import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_concursos.dart';
import '../modelos.dart';
import 'concurso_tela.dart';
import 'radar_tela.dart';
import 'rumores_tela.dart';

Color corNivel(BuildContext context, String nivel) => switch (nivel) {
  'critico' => Theme.of(context).colorScheme.error,
  'aviso' => Colors.orange,
  _ => Theme.of(context).colorScheme.primary,
};

IconData iconeNivel(String nivel) => switch (nivel) {
  'critico' => Icons.error_outline,
  'aviso' => Icons.warning_amber,
  _ => Icons.info_outline,
};

/// Listagem dos concursos com os alertas do dia no topo; "Novo concurso" cadastra, envia o edital e
/// já pede o plano ao Claude.
class ConcursosTela extends StatelessWidget {
  const ConcursosTela({super.key, required this.api});

  final ApiConcursos api;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Column(
      children: [
        const TabBar(tabs: [
          Tab(icon: Icon(Icons.school_outlined), text: 'Meus concursos'),
          Tab(icon: Icon(Icons.map_outlined), text: 'Radar TI · mapa'),
          Tab(icon: Icon(Icons.campaign_outlined), text: 'Rumores TI'),
        ]),
        Expanded(
          child: Builder(
            builder: (context) => TabBarView(
              physics: const NeverScrollableScrollPhysics(), // o mapa usa o arrasto
              children: [
                MeusConcursos(api: api),
                RadarTela(
                  api: api,
                  aoAcompanhar: (id) {
                    DefaultTabController.of(context).animateTo(0);
                    abrirTela<void>(context, (_) => ConcursoTela(api: api, id: id), titulo: 'Concurso', icone: Icons.school_outlined);
                  },
                ),
                RumoresTela(api: api),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// Listagem dos concursos acompanhados com os alertas do dia no topo.
class MeusConcursos extends StatelessWidget {
  const MeusConcursos({super.key, required this.api});

  final ApiConcursos api;

  Future<(List<ResumoConcurso>, List<Alerta>)> _carregar() async => (await api.listar(), await api.alertas());

  Future<void> _abrir(BuildContext context, String id, Future<void> Function() recarregar) async {
    await abrirTela<void>(context, (_) => ConcursoTela(api: api, id: id), titulo: 'Concurso', icone: Icons.school_outlined);
    await recarregar();
  }

  @override
  Widget build(BuildContext context) => Sondagem<(List<ResumoConcurso>, List<Alerta>)>(
    intervalo: const Duration(seconds: 30),
    carregar: _carregar,
    construir: (context, dados, recarregar) {
      final (concursos, alertas) = dados;
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            final id = await showDialog<String>(context: context, builder: (_) => NovoConcurso(api: api));
            if (id != null && context.mounted) await _abrir(context, id, recarregar);
          },
          icon: const Icon(Icons.add),
          label: const Text('Novo concurso'),
        ),
        body: LarguraMaxima(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              for (final a in alertas.where((a) => a.nivel != 'info'))
                ListTile(
                  dense: true,
                  leading: Icon(iconeNivel(a.nivel), color: corNivel(context, a.nivel)),
                  title: Text(a.texto),
                  onTap: a.concursoId == null ? null : () => _abrir(context, a.concursoId!, recarregar),
                ),
              if (concursos.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Nenhum concurso ainda. Cadastre um e envie o edital: o Claude monta o fluxo de estudo, '
                    'as tarefas diárias até 1 semana antes da prova e os alertas de prazos.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final c in concursos) _Cartao(c: c, abrir: () => _abrir(context, c.id, recarregar)),
            ],
          ),
        ),
      );
    },
  );
}

class _Cartao extends StatelessWidget {
  const _Cartao({required this.c, required this.abrir});

  final ResumoConcurso c;
  final VoidCallback abrir;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final prazo = c.proximoPrazo;
    final estado = switch (c.estado) {
      'gerando' => 'O Claude está montando o plano…',
      'erro' => 'Falha ao gerar o plano',
      'sem_plano' => c.temEdital ? 'Plano ainda não gerado' : 'Envie o edital',
      _ => '${c.feitas}/${c.tarefas} tarefas${c.atrasadas > 0 ? ' · ${c.atrasadas} atrasada(s)' : ''}',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: abrir,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.nome, style: tema.textTheme.titleMedium),
                    Text([c.cargo, if (c.banca.isNotEmpty) c.banca].join(' · '), style: tema.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    if (c.estado == 'pronto') LinearProgressIndicator(value: c.progresso),
                    if (c.estado == 'gerando') const LinearProgressIndicator(),
                    const SizedBox(height: 4),
                    Text(estado, style: tema.textTheme.bodySmall),
                    if (prazo != null)
                      Text(
                        'Próximo prazo: ${prazo.titulo} — ${dataBr(prazo.data)}${prazo.hora.isEmpty ? '' : ' ${prazo.hora}'}',
                        style: tema.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Column(
                children: [
                  Text(c.diasParaProva?.toString() ?? '—', style: tema.textTheme.headlineMedium),
                  Text(c.dataProva == null ? 'sem data' : 'dias · ${dataBr(c.dataProva)}', style: tema.textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cadastro: dados do concurso + edital (link ou PDF). Ao salvar, cria, envia o edital e pede o
/// plano; devolve o id do concurso.
class NovoConcurso extends StatefulWidget {
  const NovoConcurso({super.key, required this.api});

  final ApiConcursos api;

  @override
  State<NovoConcurso> createState() => _NovoConcursoState();
}

class _NovoConcursoState extends State<NovoConcurso> {
  final _nome = TextEditingController();
  final _cargo = TextEditingController();
  final _banca = TextEditingController();
  final _link = TextEditingController();
  final _util = TextEditingController(text: '120');
  final _fds = TextEditingController(text: '240');
  final _obs = TextEditingController();
  DateTime? _prova;
  (String, List<int>)? _pdf;
  String? _etapa, _erro;

  Future<void> _escolherPdf() async {
    final r = await FilePicker.pickFiles(dialogTitle: 'Edital (PDF)', type: FileType.custom, allowedExtensions: ['pdf']);
    if (r.isEmpty) return;
    final bytes = await r.first.xFile.readAsBytes();
    setState(() => _pdf = (r.first.name, bytes));
  }

  Future<void> _salvar() async {
    if (_nome.text.trim().isEmpty || _cargo.text.trim().isEmpty) {
      setState(() => _erro = 'Informe o nome do concurso e o cargo/especialidade.');
      return;
    }
    if (_pdf == null && _link.text.trim().isEmpty) {
      setState(() => _erro = 'Cole o link do edital ou escolha o PDF.');
      return;
    }
    final api = widget.api;
    String? id;
    try {
      setState(() {
        _etapa = 'Criando o concurso…';
        _erro = null;
      });
      final c = await api.criar({
        'nome': _nome.text.trim(),
        'cargo': _cargo.text.trim(),
        'banca': _banca.text.trim(),
        'data_prova': ?(_prova == null ? null : iso(_prova!)),
        'minutos_util': int.tryParse(_util.text) ?? 120,
        'minutos_fds': int.tryParse(_fds.text) ?? 240,
        'observacoes': _obs.text.trim(),
      });
      id = c.id;
      setState(() => _etapa = 'Enviando o edital…');
      if (_pdf case (final nome, final bytes)) {
        await api.enviarEdital(id, nome, bytes);
      } else {
        await api.editalPorLink(id, _link.text.trim());
      }
      setState(() => _etapa = 'Pedindo o plano ao Claude…');
      await api.gerarPlano(id);
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      // concurso criado mas edital/plano falhou: abre assim mesmo, dá para tentar de novo lá dentro
      if (id != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        Navigator.pop(context, id);
      } else {
        setState(() {
          _etapa = null;
          _erro = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ocupado = _etapa != null;
    return AlertDialog(
      title: const Text('Novo concurso'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _nome, decoration: const InputDecoration(labelText: 'Concurso (ex.: TJPB 2026)')),
              TextField(controller: _cargo, decoration: const InputDecoration(labelText: 'Cargo / especialidade')),
              TextField(controller: _banca, decoration: const InputDecoration(labelText: 'Banca (opcional)')),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: Text(_prova == null ? 'Data da prova: a IA tira do edital' : 'Prova: ${dataBr(iso(_prova!))}')),
                  TextButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 730)),
                      );
                      if (d != null) setState(() => _prova = d);
                    },
                    child: const Text('Escolher'),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _util,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Min/dia útil'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _fds,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Min/dia fim de semana'),
                    ),
                  ),
                ],
              ),
              TextField(
                controller: _obs,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Sobre você (base, pontos fracos) — opcional'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _link,
                enabled: _pdf == null,
                decoration: const InputDecoration(labelText: 'Link do edital (PDF)'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(onPressed: ocupado ? null : _escolherPdf, icon: const Icon(Icons.picture_as_pdf), label: const Text('Escolher PDF')),
                  const SizedBox(width: 8),
                  if (_pdf != null) Expanded(child: Text(_pdf!.$1, overflow: TextOverflow.ellipsis)),
                ],
              ),
              if (_etapa != null) ...[const SizedBox(height: 12), const LinearProgressIndicator(), Text(_etapa!)],
              if (_erro != null) Text(_erro!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: ocupado ? null : () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: ocupado ? null : _salvar, child: const Text('Criar e gerar plano')),
      ],
    );
  }
}
