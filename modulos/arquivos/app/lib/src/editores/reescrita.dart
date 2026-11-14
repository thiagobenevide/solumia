import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_arquivos.dart';
import '../telas/acoes_destaque.dart';

/// Objetivos da reescrita (chaves de `shared/claude_code.py` → rótulo).
const objetivosReescrita = {
  'orientador': 'Revisar para o orientador',
  'feedback': 'Aplicar comentários do orientador',
  'formal': 'Linguagem acadêmica formal',
  'conciso': 'Mais conciso',
  'expandir': 'Desenvolver argumentação',
  'gramatica': 'Só gramática e ortografia',
};

/// Reescrita de um trecho pelo Claude Code (no PC, pela assinatura). Devolve o texto aceito, ou
/// `null`. [arquivoId] manda o documento inteiro como contexto (coerência com o resto do TCC);
/// sem [trecho], o campo começa vazio para colar.
Future<String?> reescreverComClaude(
  BuildContext context,
  ApiArquivos api, {
  String trecho = '',
  String? arquivoId,
  String? titulo,
}) => abrirTela<String>(
  context,
  (_) => _ReescritaTela(api: api, trecho: trecho, arquivoId: arquivoId, titulo: titulo),
  titulo: 'Reescrever com Claude',
  icone: Icons.auto_fix_high,
);

class _ReescritaTela extends StatefulWidget {
  const _ReescritaTela({required this.api, required this.trecho, this.arquivoId, this.titulo});

  final ApiArquivos api;
  final String trecho;
  final String? arquivoId;
  final String? titulo;

  @override
  State<_ReescritaTela> createState() => _ReescritaTelaState();
}

class _ReescritaTelaState extends State<_ReescritaTela> {
  late final _trecho = TextEditingController(text: widget.trecho);
  final _feedback = TextEditingController();
  final _instrucao = TextEditingController();
  final _sugestao = TextEditingController();
  String _objetivo = 'orientador';
  bool _trabalhando = false;
  Map<String, dynamic>? _resultado;

  @override
  void dispose() {
    for (final c in [_trecho, _feedback, _instrucao, _sugestao]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _reescrever() async {
    if (_trecho.text.trim().isEmpty) return avisar(context, 'Cole ou selecione o trecho a reescrever.');
    if (_objetivo == 'feedback' && _feedback.text.trim().isEmpty) {
      return avisar(context, 'Cole os comentários do orientador.');
    }
    setState(() => _trabalhando = true);
    try {
      final r = await widget.api.reescrever(
        trecho: _trecho.text,
        objetivo: _objetivo,
        instrucao: _instrucao.text,
        feedback: _feedback.text,
        arquivoId: widget.arquivoId,
      );
      if (!mounted) return;
      _sugestao.text = r['texto'] as String? ?? '';
      setState(() => _resultado = r);
    } on ApiErro catch (e) {
      if (mounted) avisar(context, 'Não consegui reescrever: ${e.mensagem}');
    } finally {
      if (mounted) setState(() => _trabalhando = false);
    }
  }

  Widget _campo(TextEditingController c, String rotulo, {int linhas = 3, String? dica}) => TextField(
    controller: c,
    minLines: linhas,
    maxLines: linhas + 8,
    decoration: InputDecoration(labelText: rotulo, hintText: dica, border: const OutlineInputBorder()),
  );

  @override
  Widget build(BuildContext context) {
    final r = _resultado;
    final mudancas = [...(r?['mudancas'] as List? ?? const []).cast<Map<String, dynamic>>()];
    final observacoes = (r?['observacoes'] as String? ?? '').trim();
    final tema = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.titulo == null ? 'Reescrever com Claude' : 'Reescrever · ${widget.titulo}'),
        actions: [
          if (r != null) ...[
            IconButton(
              tooltip: 'Copiar sugestão',
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _sugestao.text));
                if (context.mounted) avisar(context, 'Sugestão copiada.');
              },
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(context, _sugestao.text),
                icon: const Icon(Icons.check),
                label: const Text('Aplicar'),
              ),
            ),
          ],
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final MapEntry(:key, :value) in objetivosReescrita.entries)
                ChoiceChip(
                  label: Text(value),
                  selected: _objetivo == key,
                  onSelected: (_) => setState(() => _objetivo = key),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_objetivo == 'feedback') ...[
            _campo(_feedback, 'Comentários do orientador', dica: 'Cole aqui o que o orientador pediu.'),
            const SizedBox(height: 12),
          ],
          _campo(_trecho, 'Trecho', linhas: 6),
          const SizedBox(height: 12),
          _campo(_instrucao, 'Pedido adicional (opcional)', linhas: 1, dica: 'ex.: manter em até 150 palavras'),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _trabalhando ? null : _reescrever,
                icon: _trabalhando
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_fix_high),
                label: Text(_trabalhando ? 'Claude está reescrevendo…' : (r == null ? 'Reescrever' : 'Refazer')),
              ),
              const SizedBox(width: 12),
              if (widget.arquivoId != null)
                Expanded(
                  child: Text(
                    'O documento inteiro vai como contexto, para manter a coerência.',
                    style: tema.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
          if (r != null) ...[
            const Divider(height: 32),
            _campo(_sugestao, 'Sugestão (pode ajustar antes de aplicar)', linhas: 6),
            if (observacoes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                color: tema.colorScheme.tertiaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: const Text('Para você resolver'),
                  subtitle: Text(observacoes),
                ),
              ),
            ],
            if (mudancas.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('O que mudou e por quê', style: tema.textTheme.titleSmall),
              for (final m in mudancas)
                ListTile(
                  dense: true,
                  title: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: m['antes'] as String? ?? '',
                          style: TextStyle(
                            decoration: TextDecoration.lineThrough,
                            color: tema.colorScheme.error,
                          ),
                        ),
                        const TextSpan(text: '  →  '),
                        TextSpan(
                          text: m['depois'] as String? ?? '',
                          style: TextStyle(color: tema.colorScheme.primary),
                        ),
                      ],
                    ),
                  ),
                  subtitle: Text(m['motivo'] as String? ?? ''),
                ),
            ],
          ],
        ],
      ),
    );
  }
}
