import 'dart:async';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import 'api_codigo.dart';
import 'contas_claude.dart';
import 'modelos.dart';

/// Abas de pedidos ao Claude Code do PC: cada aba é uma conversa separada (como um terminal novo),
/// e várias podem trabalhar ao mesmo tempo.
class CodigoTela extends StatefulWidget {
  const CodigoTela({super.key, required this.api});

  final ApiCodigo api;

  @override
  State<CodigoTela> createState() => _CodigoTelaState();
}

class _CodigoTelaState extends State<CodigoTela> {
  List<AbaCodigo>? _abas;
  String? _atual;
  String? _indisponivel;
  Object? _erro;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _carregar();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _carregar());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _carregar() async {
    try {
      final abas = await widget.api.listar();
      final motivo = await widget.api.indisponivel();
      if (!mounted) return;
      setState(() {
        _abas = abas;
        _indisponivel = motivo;
        _erro = null;
        if (!abas.any((a) => a.id == _atual)) _atual = abas.isEmpty ? null : abas.last.id;
      });
    } catch (e) {
      if (mounted) setState(() => _erro = e);
    }
  }

  Future<void> _nova() async {
    final aba = await widget.api.criar('Aba ${(_abas?.length ?? 0) + 1}');
    setState(() {
      _abas = [...?_abas, aba];
      _atual = aba.id;
    });
  }

  Future<void> _renomear(AbaCodigo aba) async {
    final c = TextEditingController(text: aba.titulo);
    final titulo = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Renomear aba'),
        content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Salvar')),
        ],
      ),
    );
    if (titulo == null || titulo.trim().isEmpty) return;
    await widget.api.renomear(aba.id, titulo);
    await _carregar();
  }

  Future<void> _fechar(AbaCodigo aba) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Fechar "${aba.titulo}"?'),
        content: Text(
          aba.rodando
              ? 'O Claude desta aba será parado e o histórico apagado. As mudanças nos arquivos ficam.'
              : 'O histórico da aba será apagado. As mudanças nos arquivos ficam.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Fechar')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.api.excluir(aba.id);
    await _carregar();
  }

  Future<void> _verGit() => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Repositório no PC'),
      content: SizedBox(
        width: 560,
        child: FutureBuilder(
          future: widget.api.git(),
          builder: (ctx, s) {
            if (s.hasError) return Text('${s.error}');
            if (!s.hasData) return const LinearProgressIndicator();
            final mono = Theme.of(ctx).textTheme.bodySmall!.copyWith(fontFamily: 'monospace');
            return SingleChildScrollView(
              child: SelectableText('${s.data!['status']}\n\nÚltimos commits:\n${s.data!['log']}', style: mono),
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fechar'))],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final abas = _abas;
    if (abas == null) {
      return _erro != null ? ErroComRetry(erro: _erro!, tentar: _carregar) : const Center(child: CircularProgressIndicator());
    }
    final tema = Theme.of(context);
    final atual = [for (final a in abas) if (a.id == _atual) a].firstOrNull;
    return Column(
      children: [
        Material(
          color: tema.colorScheme.surfaceContainer,
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      for (final a in abas)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GestureDetector(
                            onDoubleTap: () => _renomear(a),
                            onLongPress: () => _renomear(a),
                            child: InputChip(
                              selected: a.id == _atual,
                              avatar: _Indicador(a),
                              label: Text(a.titulo),
                              onPressed: () => setState(() => _atual = a.id),
                              onDeleted: () => _fechar(a),
                              deleteButtonTooltipMessage: 'Fechar aba',
                            ),
                          ),
                        ),
                      IconButton(tooltip: 'Nova aba', onPressed: _nova, icon: const Icon(Icons.add)),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Contas do Claude (trocar ao bater o limite)',
                onPressed: () => mostrarContasClaude(context, widget.api),
                icon: const Icon(Icons.manage_accounts_outlined),
              ),
              IconButton(tooltip: 'Estado do git no PC', onPressed: _verGit, icon: const Icon(Icons.account_tree_outlined)),
            ],
          ),
        ),
        if (_indisponivel != null)
          MaterialBanner(
            content: Text(_indisponivel!),
            leading: const Icon(Icons.cloud_off),
            actions: [TextButton(onPressed: _carregar, child: const Text('Verificar'))],
          ),
        Expanded(
          child: atual == null
              ? Center(
                  child: FilledButton.icon(onPressed: _nova, icon: const Icon(Icons.add), label: const Text('Nova aba')),
                )
              : SessaoVista(key: ValueKey(atual.id), api: widget.api, sessao: atual, aoMudar: _carregar),
        ),
      ],
    );
  }
}

class _Indicador extends StatelessWidget {
  const _Indicador(this.aba);

  final AbaCodigo aba;

  @override
  Widget build(BuildContext context) {
    if (aba.rodando) return const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2));
    final cor = aba.estado == 'erro' ? Theme.of(context).colorScheme.error : Colors.green;
    return Icon(aba.eventos == 0 ? Icons.circle_outlined : Icons.circle, size: 12, color: cor);
  }
}

/// Uma aba: etapas do Claude ao vivo, caixa de pedido com imagens, parar e commit.
class SessaoVista extends StatefulWidget {
  const SessaoVista({super.key, required this.api, required this.sessao, required this.aoMudar});

  final ApiCodigo api;
  final AbaCodigo sessao;
  final VoidCallback aoMudar;

  @override
  State<SessaoVista> createState() => _SessaoVistaState();
}

class _SessaoVistaState extends State<SessaoVista> {
  late AbaCodigo _sessao = widget.sessao;
  final _etapas = <Etapa>[];
  final _texto = TextEditingController();
  final _rolagem = ScrollController();
  final _imagens = <(String, Uint8List)>[];
  bool _enviando = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _atualizar();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _atualizar());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _texto.dispose();
    _rolagem.dispose();
    super.dispose();
  }

  Future<void> _atualizar() async {
    try {
      final desde = _etapas.length;
      final (sessao, novas) = await widget.api.obter(_sessao.id, desde: desde);
      // Timer e envio podem buscar ao mesmo tempo: se outra busca já acrescentou etapas, descarta esta
      // (senão a mesma etapa entra duas vezes).
      if (!mounted || _etapas.length != desde) return;
      final mudouEstado = sessao.estado != _sessao.estado;
      final noFim = !_rolagem.hasClients || _rolagem.position.extentAfter < 80;
      setState(() {
        _sessao = sessao;
        _etapas.addAll(novas);
      });
      if (mudouEstado) widget.aoMudar();
      if (novas.isNotEmpty && noFim) _irParaFim();
    } catch (_) {
      // Sem conexão agora: tenta de novo no próximo ciclo.
    }
  }

  void _irParaFim() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_rolagem.hasClients) _rolagem.jumpTo(_rolagem.position.maxScrollExtent);
  });

  /// Roda a [acao] e devolve se deu certo (erro vira aviso na tela).
  Future<bool> _executar(Future<AbaCodigo> Function() acao) async {
    setState(() => _enviando = true);
    try {
      final s = await acao();
      if (mounted) setState(() => _sessao = s);
      widget.aoMudar();
      await _atualizar();
      _irParaFim();
      return true;
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return false;
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  Future<void> _enviar() async {
    final texto = _texto.text.trim();
    if (texto.isEmpty || _sessao.rodando) return;
    final imagens = [..._imagens];
    if (!await _executar(() => widget.api.enviar(_sessao.id, texto, imagens: imagens)) || !mounted) return;
    _texto.clear();
    setState(_imagens.clear);
  }

  Future<void> _anexar() async {
    for (final f in await FilePicker.pickFiles(type: FileType.image)) {
      final bytes = await f.xFile.readAsBytes();
      setState(() => _imagens.add((f.name, bytes)));
    }
  }

  /// Ctrl+V: imagem copiada (print ou arquivo de imagem) vira referência; senão cola o texto.
  Future<void> _colar() async {
    if (_sessao.rodando) return;
    Uint8List? imagem;
    var arquivos = <String>[];
    try {
      imagem = await Pasteboard.image;
      if (imagem == null) {
        arquivos = [
          for (final c in await Pasteboard.files())
            if (RegExp(r'\.(png|jpe?g|gif|webp|bmp)$', caseSensitive: false).hasMatch(c)) c,
        ];
      }
    } catch (_) {}
    if (imagem != null) {
      setState(() => _imagens.add(('colada-${DateTime.now().millisecondsSinceEpoch}.png', imagem!)));
      return;
    }
    if (arquivos.isNotEmpty) {
      for (final c in arquivos) {
        final bytes = await File(c).readAsBytes();
        setState(() => _imagens.add((c.split(Platform.pathSeparator).last, bytes)));
      }
      return;
    }
    final texto = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (texto == null || texto.isEmpty) return;
    final v = _texto.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    _texto.value = v.replaced(sel, texto);
  }

  Future<void> _commit() async {
    final mensagem = TextEditingController();
    var push = true;
    var publicar = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, definir) => AlertDialog(
          title: const Text('Commitar o que esta aba mudou'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: mensagem,
                  decoration: const InputDecoration(
                    labelText: 'Mensagem (opcional)',
                    helperText: 'Vazio: o Claude escreve no padrão do repositório',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enviar (git push)'),
                  value: push,
                  onChanged: (v) => definir(() => push = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Publicar versão do app'),
                  subtitle: const Text('infra/scripts/publicar_app: novo build no "Atualizar app"'),
                  value: publicar,
                  onChanged: (v) => definir(() => publicar = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Commitar')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _executar(
      () => widget.api.commit(_sessao.id, mensagem: mensagem.text, push: push, publicar: publicar),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final agora = _sessao.rodando ? atividade(_etapas) : '';
    return Column(
      children: [
        if (_sessao.rodando) ...[
          const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.bolt, size: 16),
                const SizedBox(width: 6),
                Expanded(child: Text(agora, maxLines: 1, overflow: TextOverflow.ellipsis, style: tema.textTheme.bodySmall)),
              ],
            ),
          ),
        ],
        Expanded(
          child: _etapas.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Descreva o recurso ou módulo que quer implementar. O Claude Code roda no PC, dentro do '
                      'repositório, seguindo o CLAUDE.md. Use várias abas para pedidos diferentes ao mesmo tempo.',
                      textAlign: TextAlign.center,
                      style: tema.textTheme.bodyMedium?.copyWith(color: tema.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _rolagem,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  itemCount: _etapas.length,
                  itemBuilder: (_, i) => _EtapaVista(etapa: _etapas[i], api: widget.api, sessao: _sessao.id),
                ),
        ),
        const Divider(height: 1),
        _caixa(tema),
      ],
    );
  }

  Widget _caixa(ThemeData tema) {
    final estreito = MediaQuery.sizeOf(context).width < 600;
    Widget campo() => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _enviar,
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): _colar,
      },
      child: TextField(
        controller: _texto,
        minLines: 1,
        // Com o teclado aberto sobra pouca altura: o campo rola por dentro em vez de crescer.
        maxLines: estreito ? 4 : 8,
        enabled: !_sessao.rodando,
        decoration: InputDecoration(
          hintText: _sessao.rodando
              ? 'O Claude está trabalhando nesta aba…'
              : _sessao.claudeSessao == null
              ? 'O que implementar? (Ctrl+Enter envia)'
              : 'Continuar a conversa desta aba… (Ctrl+Enter envia)',
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
    return SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_imagens.isNotEmpty)
            SizedBox(
              height: 64,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final (i, (nome, bytes)) in _imagens.indexed)
                    Padding(
                      padding: const EdgeInsets.only(right: 6, bottom: 6),
                      child: Stack(
                        children: [
                          Tooltip(
                            message: nome,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.memory(bytes, height: 58, width: 58, fit: BoxFit.cover),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            top: 0,
                            child: InkWell(
                              onTap: () => setState(() => _imagens.removeAt(i)),
                              child: const CircleAvatar(radius: 9, child: Icon(Icons.close, size: 12)),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          // No celular o campo ocupa a largura toda e os botões vão para a linha de baixo;
          // espremido entre eles o texto ficava ilegível e sumia com o teclado aberto.
          if (estreito) campo(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Imagens de referência',
                onPressed: _sessao.rodando ? null : _anexar,
                icon: const Icon(Icons.add_photo_alternate_outlined),
              ),
              if (estreito) const Spacer() else Expanded(child: campo()),
              const SizedBox(width: 4),
              if (_sessao.rodando)
                IconButton.filledTonal(
                  tooltip: 'Parar',
                  onPressed: _enviando ? null : () => _executar(() => widget.api.parar(_sessao.id)),
                  icon: const Icon(Icons.stop),
                )
              else ...[
                // Pedido ao Claude Code mexe no repositório: a fala entra no campo para conferir antes.
                BotaoMicrofone(
                  transcrever: widget.api.transcrever,
                  habilitado: !_enviando,
                  aoTranscrever: (t) => setState(() {
                    final atual = _texto.text.trimRight();
                    _texto.text = atual.isEmpty ? t : '$atual $t';
                  }),
                ),
                IconButton(
                  tooltip: 'Commit e versão',
                  onPressed: _enviando || _sessao.claudeSessao == null ? null : _commit,
                  icon: const Icon(Icons.commit),
                ),
                IconButton.filled(
                  tooltip: 'Enviar',
                  onPressed: _enviando ? null : _enviar,
                  icon: const Icon(Icons.send),
                ),
              ],
            ],
          ),
        ],
      ),
    ),
  );
  }
}

IconData _iconeFerramenta(String nome) => switch (nome) {
  'Bash' => Icons.terminal,
  'Read' => Icons.description_outlined,
  'Edit' || 'MultiEdit' || 'Write' || 'NotebookEdit' => Icons.edit_outlined,
  'Grep' || 'Glob' => Icons.search,
  'TodoWrite' => Icons.checklist,
  'WebFetch' || 'WebSearch' => Icons.public,
  _ => Icons.build_outlined,
};

class _EtapaVista extends StatelessWidget {
  const _EtapaVista({required this.etapa, required this.api, required this.sessao});

  final Etapa etapa;
  final ApiCodigo api;
  final String sessao;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final cores = tema.colorScheme;
    final pequeno = tema.textTheme.bodySmall!;
    final mono = pequeno.copyWith(fontFamily: 'monospace');
    switch (etapa.tipo) {
      case 'pedido':
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 640),
            margin: const EdgeInsets.only(top: 12, bottom: 6, left: 48),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: cores.primaryContainer, borderRadius: BorderRadius.circular(12)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (etapa.commit)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [const Icon(Icons.commit, size: 16), const SizedBox(width: 4), Text('Commit', style: pequeno)],
                  ),
                SelectableText(etapa.texto),
                if (etapa.imagens.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [for (final nome in etapa.imagens) _Miniatura(api: api, sessao: sessao, nome: nome)],
                    ),
                  ),
              ],
            ),
          ),
        );
      case 'inicio':
        return _linha(context, Icons.play_arrow, 'Claude Code iniciado${etapa.dados['modelo'] != null ? ' (${etapa.dados['modelo']})' : ''}');
      case 'texto':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: VisualizadorMarkdown(texto: etapa.texto, estilo: tema.textTheme.bodyMedium),
        );
      case 'ferramenta':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_iconeFerramenta(etapa.nome), size: 16, color: cores.primary),
              const SizedBox(width: 8),
              Text(etapa.nome, style: pequeno.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Expanded(child: SelectableText(etapa.resumo, style: mono, maxLines: 3)),
            ],
          ),
        );
      case 'resultado':
        if (etapa.resumo.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 24, bottom: 4),
          child: ExpansionTile(
            dense: true,
            tilePadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            title: Text(
              etapa.resumo.split('\n').first,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono.copyWith(color: etapa.erro ? cores.error : cores.onSurfaceVariant),
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(etapa.resumo, style: mono.copyWith(color: etapa.erro ? cores.error : null)),
              ),
            ],
          ),
        );
      case 'fim':
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 8),
          color: etapa.erro ? cores.errorContainer : cores.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(etapa.erro ? Icons.error_outline : Icons.check_circle_outline, size: 18),
                    const SizedBox(width: 6),
                    Text(etapa.erro ? 'Terminou com erro' : 'Concluído', style: tema.textTheme.titleSmall),
                    const Spacer(),
                    Text(etapa.rodape, style: pequeno),
                  ],
                ),
                if (etapa.texto.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  VisualizadorMarkdown(texto: etapa.texto, estilo: tema.textTheme.bodyMedium),
                ],
              ],
            ),
          ),
        );
    }
    return const SizedBox.shrink();
  }

  Widget _linha(BuildContext context, IconData icone, String texto) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Icon(icone, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Text(texto, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class _Miniatura extends StatelessWidget {
  const _Miniatura({required this.api, required this.sessao, required this.nome});

  final ApiCodigo api;
  final String sessao;
  final String nome;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: api.imagem(sessao, nome),
    builder: (context, s) => ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: s.hasData
          ? GestureDetector(
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => Dialog(child: InteractiveViewer(child: Image.memory(s.data!))),
              ),
              child: Image.memory(s.data!, width: 72, height: 72, fit: BoxFit.cover),
            )
          : const SizedBox.square(dimension: 72, child: Icon(Icons.image_outlined)),
    ),
  );
}
