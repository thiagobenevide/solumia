import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_notas.dart';
import '../controlador.dart';
import '../modelos.dart';
import 'painel_relacoes.dart';

/// Editor da nota aberta: título, tipo, campos do tipo (formulário), tags e texto com
/// autocompletar de `[[link]]`. Salva sozinho 1,5 s depois da última mudança (e com Ctrl+S).
/// [comAbas]: tablet/celular, com as relações numa segunda aba.
class EditorNota extends StatefulWidget {
  const EditorNota({super.key, required this.aberta, this.comAbas = false});

  final NotaAberta aberta;
  final bool comAbas;

  @override
  State<EditorNota> createState() => _EditorNotaState();
}

class _EditorNotaState extends State<EditorNota> {
  final _titulo = TextEditingController();
  final _corpo = ControladorMarkdown();
  final _tags = TextEditingController();
  Map<String, dynamic> _props = {};
  String _tipo = 'nota';
  String? _id;
  bool _sujo = false;
  Timer? _autoSalvar, _atraso;
  List<String> _sugestoes = [];
  List<TipoNota> _tipos = [];

  NotaAberta get _aberta => widget.aberta;
  ApiNotas get _api => _aberta.api;

  @override
  void initState() {
    super.initState();
    _aberta.addListener(_recarregar);
    _aberta.pendente = _salvarPendente;
    _corpo.addListener(_procurarLink);
    _api.tipos().then((t) => mounted ? setState(() => _tipos = t) : null, onError: (_) {});
    _recarregar();
  }

  @override
  void dispose() {
    _aberta.removeListener(_recarregar);
    if (_aberta.pendente == _salvarPendente) _aberta.pendente = null;
    _salvarPendente();
    _autoSalvar?.cancel();
    _atraso?.cancel();
    _titulo.dispose();
    _corpo.dispose();
    _tags.dispose();
    super.dispose();
  }

  /// Só repõe os campos quando muda de nota: salvar não pode mexer no cursor de quem digita.
  void _recarregar() {
    final n = _aberta.nota;
    if (n?.id == _id) return setState(() {});
    _id = n?.id;
    _sujo = false;
    _sugestoes = [];
    if (n != null) {
      _titulo.text = n.titulo;
      _corpo.text = n.corpo;
      _tags.text = n.tags.join(', ');
      _props = Map.of(n.propriedades);
      _tipo = n.tipo;
    }
    setState(() {});
  }

  void _mudou() {
    _sujo = true;
    _autoSalvar?.cancel();
    _autoSalvar = Timer(const Duration(milliseconds: 1500), _salvarPendente);
    setState(() {});
  }

  Future<void> _salvarPendente() async {
    _autoSalvar?.cancel();
    if (!_sujo || _aberta.nota == null || _titulo.text.trim().isEmpty) return;
    _sujo = false;
    await _aberta.salvar({
      'titulo': _titulo.text.trim(),
      'tipo': _tipo,
      'tags': [for (final t in _tags.text.split(',')) if (t.trim().isNotEmpty) t.trim()],
      'propriedades': _props,
      'corpo': _corpo.text,
    });
  }

  // ---------- [[ autocompletar ----------

  /// Posição do `[[` aberto antes do cursor, ou -1.
  int _inicioLink() {
    final pos = _corpo.selection.baseOffset;
    if (pos < 2) return -1;
    final antes = _corpo.text.substring(0, pos);
    final i = antes.lastIndexOf('[[');
    if (i < 0) return -1;
    final dentro = antes.substring(i + 2);
    return dentro.contains(']') || dentro.contains('\n') ? -1 : i;
  }

  void _procurarLink() {
    final i = _inicioLink();
    _atraso?.cancel();
    if (i < 0) {
      if (_sugestoes.isNotEmpty) setState(() => _sugestoes = []);
      return;
    }
    final q = _corpo.text.substring(i + 2, _corpo.selection.baseOffset);
    _atraso = Timer(const Duration(milliseconds: 200), () async {
      final s = await _api.sugestoes(q).catchError((_) => <String>[]);
      if (mounted) setState(() => _sugestoes = [...s, if (q.trim().isNotEmpty && !s.contains(q.trim())) q.trim()]);
    });
  }

  void _completarLink(String titulo) {
    final i = _inicioLink();
    if (i < 0) return;
    final pos = _corpo.selection.baseOffset;
    final depois = _corpo.text.substring(pos).startsWith(']]') ? pos + 2 : pos;
    _corpo.value = TextEditingValue(
      text: _corpo.text.replaceRange(i, depois, '[[$titulo]]'),
      selection: TextSelection.collapsed(offset: i + titulo.length + 4),
    );
    setState(() => _sugestoes = []);
  }

  void _inserir(String texto) {
    final sel = _corpo.selection.isValid ? _corpo.selection : TextSelection.collapsed(offset: _corpo.text.length);
    _corpo.value = TextEditingValue(
      text: _corpo.text.replaceRange(sel.start, sel.end, texto),
      selection: TextSelection.collapsed(offset: sel.start + texto.length),
    );
    _mudou();
  }

  // ---------- relações tipadas ----------

  Future<void> _novaRelacao() async {
    final tipo = _tipos.where((t) => t.id == _tipo).firstOrNull;
    final opcoes = {...?tipo?.relacoes, 'relacionada'}.toList();
    final rel = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Tipo de relação'),
        children: [
          for (final o in opcoes)
            SimpleDialogOption(onPressed: () => Navigator.pop(c, o), child: Text(o.replaceAll('_', ' '))),
        ],
      ),
    );
    if (rel == null || !mounted) return;
    final alvo = await escolherNota(context, _api);
    if (alvo == null) return;
    final atuais = _props[rel];
    _props[rel] = [...(atuais is List ? atuais : [?atuais]), '[[$alvo]]'];
    _mudou();
    await _salvarPendente();
  }

  @override
  Widget build(BuildContext context) {
    final n = _aberta.nota;
    if (n == null) {
      return Center(
        child: _aberta.carregando
            ? const CircularProgressIndicator()
            : Text(_aberta.erro ?? 'Escolha uma nota ou crie uma nova', textAlign: TextAlign.center),
      );
    }
    final editor = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _salvarPendente,
      },
      child: _editor(context),
    );
    if (!widget.comAbas) return editor;
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            tabs: [
              const Tab(text: 'Escrever'),
              Tab(text: 'Relações (${n.saidas.length + n.entradas.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(children: [editor, PainelRelacoes(aberta: _aberta)]),
          ),
        ],
      ),
    );
  }

  Widget _editor(BuildContext context) {
    final tema = Theme.of(context);
    final tipo = _tipos.where((t) => t.id == _tipo).firstOrNull;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Row(
          children: [
            PopupMenuButton<String>(
              tooltip: 'Tipo da nota',
              icon: Icon(iconeDoTipo(_tipo)),
              initialValue: _tipo,
              onSelected: (t) {
                _tipo = t;
                _mudou();
              },
              itemBuilder: (_) => [
                for (final t in _tipos)
                  PopupMenuItem(value: t.id, child: ListTile(leading: Icon(iconeDoTipo(t.id)), title: Text(t.nome))),
              ],
            ),
            Expanded(
              child: TextField(
                controller: _titulo,
                style: tema.textTheme.headlineSmall,
                decoration: const InputDecoration(border: InputBorder.none, hintText: 'Título'),
                onChanged: (_) => _mudou(),
              ),
            ),
            _estado(tema),
            PopupMenuButton<String>(
              onSelected: (_) => _excluir(),
              itemBuilder: (_) => const [PopupMenuItem(value: 'excluir', child: Text('Excluir nota'))],
            ),
          ],
        ),
        if (tipo != null && tipo.campos.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [for (final c in tipo.campos) SizedBox(width: 200, child: _campo(c))],
            ),
          ),
        TextField(
          controller: _tags,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.sell_outlined), hintText: 'tags, separadas por vírgula'),
          onChanged: (_) => _mudou(),
        ),
        const SizedBox(height: 8),
        if (_sugestoes.isNotEmpty)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final s in _sugestoes)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(avatar: const Icon(Icons.link, size: 16), label: Text(s), onPressed: () => _completarLink(s)),
                  ),
              ],
            ),
          ),
        CampoMarkdown(
          controle: _corpo,
          aoMudar: _mudou,
          dica: 'Escreva… [[ cria um link',
          extras: [
            _botao(Icons.link, 'Link', () => _inserir('[[')),
            _botao(Icons.hub_outlined, 'Relação', _novaRelacao),
          ],
        ),
      ],
    );
  }

  Widget _estado(ThemeData tema) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: _aberta.carregando
        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : Tooltip(
            message: _aberta.erro ?? (_sujo ? 'Salvando…' : 'Salvo'),
            child: Icon(
              _aberta.erro != null ? Icons.error_outline : (_sujo ? Icons.edit_outlined : Icons.cloud_done_outlined),
              size: 18,
              color: _aberta.erro != null ? tema.colorScheme.error : tema.colorScheme.outline,
            ),
          ),
  );

  Widget _botao(IconData icone, String texto, VoidCallback acao) =>
      TextButton.icon(onPressed: acao, icon: Icon(icone, size: 18), label: Text(texto));

  Widget _campo(Campo c) {
    final valor = _props[c.nome];
    final chave = ValueKey('$_id-${c.nome}');
    void definir(Object? v) {
      if (v == null || v == '') {
        _props.remove(c.nome);
      } else {
        _props[c.nome] = v;
      }
      _mudou();
    }

    final deco = InputDecoration(labelText: c.rotulo, isDense: true, border: const OutlineInputBorder());
    switch (c.tipo) {
      case 'opcoes':
        return DropdownButtonFormField<String>(
          key: chave,
          initialValue: c.opcoes.contains('$valor') ? '$valor' : null,
          decoration: deco,
          items: [for (final o in c.opcoes) DropdownMenuItem(value: o, child: Text(o))],
          onChanged: definir,
        );
      case 'data':
        final data = DateTime.tryParse('${valor ?? ''}');
        return InputDecorator(
          decoration: deco,
          child: InkWell(
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: data ?? DateTime.now(),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (d != null) definir(d.toIso8601String().substring(0, 10));
            },
            child: Text(data == null ? 'definir' : dataCurta(data)),
          ),
        );
      case 'link':
        final alvo = linkRe.firstMatch('${valor ?? ''}')?.group(1);
        return InputDecorator(
          decoration: deco,
          child: InkWell(
            onTap: () async {
              final t = await escolherNota(context, _api);
              if (t != null) definir('[[$t]]');
            },
            onLongPress: alvo == null ? null : () => _aberta.abrirOuCriar(alvo),
            child: Text(alvo ?? 'escolher nota'),
          ),
        );
      default:
        return TextFormField(
          key: chave,
          initialValue: valor == null ? '' : '$valor',
          decoration: deco,
          keyboardType: c.tipo == 'numero' ? TextInputType.number : null,
          onChanged: (v) => definir(c.tipo == 'numero' ? num.tryParse(v.replaceAll(',', '.')) : v),
        );
    }
  }

  Future<void> _excluir() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Excluir "${_titulo.text}"?'),
        content: const Text('O arquivo Markdown é apagado. Links para ela viram links quebrados.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
        ],
      ),
    );
    if (ok != true) return;
    _sujo = false;
    await _aberta.excluir();
  }
}

/// Diálogo de busca de nota por título. Devolve o título escolhido (ou digitado, para criar).
Future<String?> escolherNota(BuildContext context, ApiNotas api) => showDialog<String>(
  context: context,
  builder: (_) => _SeletorNota(api),
);

class _SeletorNota extends StatefulWidget {
  const _SeletorNota(this.api);

  final ApiNotas api;

  @override
  State<_SeletorNota> createState() => _SeletorNotaState();
}

class _SeletorNotaState extends State<_SeletorNota> {
  String _q = '';
  late Future<List<String>> _achadas = widget.api.sugestoes('');

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: TextField(
      autofocus: true,
      decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar nota'),
      onChanged: (q) => setState(() {
        _q = q.trim();
        _achadas = widget.api.sugestoes(_q);
      }),
      onSubmitted: (q) => Navigator.pop(context, q.trim().isEmpty ? null : q.trim()),
    ),
    content: SizedBox(
      width: 360,
      height: 320,
      child: FutureBuilder(
        future: _achadas,
        builder: (context, snap) {
          final lista = snap.data ?? const <String>[];
          return ListView(
            children: [
              for (final t in lista) ListTile(title: Text(t), onTap: () => Navigator.pop(context, t)),
              if (_q.isNotEmpty && !lista.contains(_q))
                ListTile(
                  leading: const Icon(Icons.add),
                  title: Text('Nova: $_q'),
                  onTap: () => Navigator.pop(context, _q),
                ),
            ],
          );
        },
      ),
    ),
  );
}
