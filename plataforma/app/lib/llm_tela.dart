import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

/// Escolha do modelo do LLM local (`/api/llm`): os `.gguf` do worker, trocados na hora, sem rebuild.
/// A troca é proibida enquanto outro módulo estiver usando o LLM; nesse caso mostra um aviso.
class TelaLlm extends StatefulWidget {
  const TelaLlm({super.key, required this.api});

  final ApiCliente api;

  @override
  State<TelaLlm> createState() => _TelaLlmState();
}

class _TelaLlmState extends State<TelaLlm> {
  late Future<Map<String, dynamic>> _estado = _ler();
  bool _trocando = false;

  Future<Map<String, dynamic>> _ler() async => (await widget.api.get('api/llm') as Map).cast<String, dynamic>();

  void _recarregar() => setState(() => _estado = _ler());

  Future<void> _trocar(String modelo) async {
    // Confere antes: se outro módulo estiver usando, nem tenta.
    final antes = await _ler();
    if (!mounted) return;
    final emUso = (antes['em_uso'] as List).cast<Map>();
    if (emUso.isNotEmpty) return _avisarEmUso(emUso);
    setState(() => _trocando = true);
    try {
      final novo = (await widget.api.put('api/llm', {'modelo': modelo}) as Map).cast<String, dynamic>();
      if (!mounted) return;
      setState(() => _estado = Future.value(novo));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Modelo trocado para $modelo')));
    } on ApiErro catch (e) {
      if (!mounted) return;
      if (e.status == 409) {
        // Alguém começou a usar entre a conferência e a troca.
        final agora = await _ler();
        if (mounted) await _avisarEmUso((agora['em_uso'] as List).cast<Map>(), e.mensagem);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.mensagem)));
      }
    } finally {
      if (mounted) setState(() => _trocando = false);
      _recarregar();
    }
  }

  Future<void> _avisarEmUso(List<Map> emUso, [String? mensagem]) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: Theme.of(context).colorScheme.error, size: 36),
      title: const Text('Troca de modelo bloqueada'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(
            mensagem ??
                'O LLM está sendo usado por outro módulo. Trocar agora interromperia o trabalho dele; '
                    'espere terminar e tente de novo.',
          ),
          for (final u in emUso)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.hourglass_top),
              title: Text('${u['origem']}'),
              subtitle: Text(
                '${u['tarefa']} · ${u['modelo'] == '' ? 'modelo atual' : u['modelo']}${_ha(u)}',
              ),
            ),
        ],
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Entendi'))],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Modelo de IA'),
      actions: [IconButton(tooltip: 'Atualizar', icon: const Icon(Icons.refresh), onPressed: _recarregar)],
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _estado,
      builder: (context, s) {
        if (s.hasError) {
          return Center(child: Text('Não carregou: ${s.error}', textAlign: TextAlign.center));
        }
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        return Stack(
          children: [
            _corpo(context, s.data!),
            if (_trocando)
              const ColoredBox(
                color: Color(0x88000000),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 16,
                    children: [CircularProgressIndicator(), Text('Carregando o modelo na GPU…')],
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );

  Widget _corpo(BuildContext context, Map<String, dynamic> e) {
    final cs = Theme.of(context).colorScheme;
    final modelos = (e['disponiveis'] as List).cast<String>();
    final emUso = (e['em_uso'] as List).cast<Map>();
    final escolhido = e['modelo'] as String;
    final carregados = (e['carregados'] as List).cast<String>();
    final conectado = (e['workers'] as int) > 0;
    return LarguraMaxima(
      largura: 900,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: Icon(conectado ? Icons.memory : Icons.power_off, color: conectado ? cs.primary : cs.error),
              title: Text(conectado ? 'Worker conectado (llama.cpp)' : 'Nenhum worker conectado'),
              subtitle: Text(
                conectado
                    ? 'Na GPU: ${carregados.isEmpty ? 'nenhum (carrega no primeiro uso)' : carregados.join(', ')}'
                    : 'Ligue o Worker no PC (infra/scripts/run_worker.sh).',
              ),
            ),
          ),
          if (emUso.isNotEmpty)
            Card(
              color: cs.errorContainer,
              child: ListTile(
                leading: Icon(Icons.lock_clock, color: cs.onErrorContainer),
                title: Text('Em uso agora — troca bloqueada', style: TextStyle(color: cs.onErrorContainer)),
                subtitle: Text(
                  emUso.map((u) => '${u['origem']}${_ha(u)}').join(' · '),
                  style: TextStyle(color: cs.onErrorContainer),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text('Modelos (.gguf)', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          if (conectado && modelos.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Nenhum .gguf na pasta de modelos do worker (~/agent-data/modelos). Copie e toque em atualizar.',
              ),
            ),
          for (final m in modelos)
            Card(
              child: ListTile(
                leading: Icon(
                  m == escolhido ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: m == escolhido ? cs.primary : null,
                ),
                title: Text(m),
                subtitle: carregados.contains(m) ? const Text('na GPU') : null,
                enabled: !_trocando,
                onTap: m == escolhido && carregados.contains(m) ? null : () => _trocar(m),
              ),
            ),
        ],
      ),
    );
  }

  /// A esteira usa o llama-server direto: dela só se sabe que está processando, não há quanto tempo.
  static String _ha(Map u) => u['ha_s'] == null ? '' : ' · há ${u['ha_s']} s';
}
