import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_saude.dart';
import '../consumo_nativo.dart';
import '../datas.dart';

void _avisar(BuildContext context, Object e) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));

const _modos = {'livre': 'Livre', 'limite': 'Com limite', 'bloqueado': 'Bloqueado'};
const _iconesCategoria = {
  'redes_sociais': Icons.forum_outlined,
  'videos': Icons.play_circle_outline,
  'compras': Icons.shopping_bag_outlined,
  'noticias': Icons.newspaper_outlined,
  'navegadores': Icons.public,
  'adulto': Icons.block,
  'vpn': Icons.vpn_lock_outlined,
};

/// Saúde › Mental › Consumo: regras com trava de 24 h, uso dos aparelhos e o "vigia" (LLM local).
class ConsumoTela extends StatefulWidget {
  const ConsumoTela({super.key, required this.api});

  final ApiSaude api;

  @override
  State<ConsumoTela> createState() => _ConsumoTelaState();
}

class _ConsumoTelaState extends State<ConsumoTela> {
  Map<String, dynamic>? _config;
  Map<String, dynamic>? _resumo;
  List<Map<String, dynamic>> _dispositivos = const [];
  Map<String, bool> _permissoes = const {};
  int _periodo = 7;
  bool _ocupado = false;

  @override
  void initState() {
    super.initState();
    _carregar();
    // num Android, aplica as regras do backend neste aparelho a cada abertura
    ConsumoNativo.sincronizar(widget.api);
  }

  Future<void> _carregar() async {
    try {
      final cfg = await widget.api.consumoConfig();
      final res = await widget.api.resumoConsumo(somarDias(hoje(), -(_periodo - 1)), hoje());
      final disp = await widget.api.dispositivos();
      final perm = await ConsumoNativo.permissoes();
      if (mounted) {
        setState(() => (_config = cfg, _resumo = res, _dispositivos = disp, _permissoes = perm));
      }
    } on ApiErro catch (e) {
      if (mounted) _avisar(context, e);
    }
  }

  Future<void> _pedirPermissao(String permissao) async {
    await ConsumoNativo.pedirPermissao(permissao);
    // ao voltar da tela do sistema, relê o estado (pode ainda estar concedendo)
    if (mounted) await _carregar();
  }

  Future<void> _acao(Future<Map<String, dynamic>> Function() f) async {
    if (_ocupado) return;
    setState(() => _ocupado = true);
    try {
      final r = await f();
      final pend = r['pendencia'] as Map<String, dynamic>?;
      if (mounted && pend != null) {
        _avisar(context, 'Afrouxar espera 24 h: libera ${_quando(pend['libera_em'] as String?)}.');
      }
      await _carregar();
      await ConsumoNativo.sincronizar(widget.api);
    } on ApiErro catch (e) {
      if (mounted) _avisar(context, e);
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _config;
    final tema = Theme.of(context);
    if (cfg == null) return const Center(child: CircularProgressIndicator());
    final categorias = (cfg['categorias'] as Map).cast<String, String>();
    final regras = (cfg['regras'] as Map).cast<String, dynamic>();
    final pendencias = (cfg['pendencias'] as List).cast<Map<String, dynamic>>();
    return RefreshIndicator(
      onRefresh: _carregar,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (ConsumoNativo.disponivel)
            _Permissoes(permissoes: _permissoes, aoPedir: _pedirPermissao),
          Row(
            children: [
              Expanded(child: Text('Regras por categoria', style: tema.textTheme.titleLarge)),
              if (_ocupado)
                const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Apertar vale na hora; afrouxar só depois de 24 h. O WhatsApp fica de fora — é o seu trabalho.',
            style: tema.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final c in categorias.keys)
            _CartaoRegra(
              categoria: c,
              nome: categorias[c]!,
              regra: (regras[c] as Map).cast<String, dynamic>(),
              ocupado: _ocupado,
              aoMudar: (r) => _acao(() => widget.api.definirRegra(c, r)),
            ),
          if (pendencias.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Esperando 24 h', style: tema.textTheme.titleMedium),
            for (final p in pendencias)
              Card(
                color: tema.colorScheme.tertiaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.hourglass_bottom),
                  title: Text(p['descricao'] as String? ?? 'Afrouxar regra'),
                  subtitle: Text('Libera ${_quando(p['libera_em'] as String?)}'),
                  trailing: TextButton(
                    onPressed: _ocupado
                        ? null
                        : () async {
                            await widget.api.cancelarPendencia(p['id'] as String);
                            await _carregar();
                          },
                    child: const Text('Cancelar'),
                  ),
                ),
              ),
          ],
          const Divider(height: 40),
          _Protecao(dispositivos: _dispositivos),
          const Divider(height: 40),
          Row(
            children: [
              Expanded(child: Text('Como foi o uso', style: tema.textTheme.titleLarge)),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 7, label: Text('7 d')),
                  ButtonSegment(value: 30, label: Text('30 d')),
                ],
                selected: {_periodo},
                onSelectionChanged: (s) {
                  setState(() => _periodo = s.first);
                  _carregar();
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Uso(resumo: _resumo, categorias: categorias),
          const SizedBox(height: 24),
          _Vigia(api: widget.api, periodo: _periodo),
        ],
      ),
    );
  }
}

String _quando(String? iso) {
  if (iso == null) return '—';
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  String dois(int n) => n.toString().padLeft(2, '0');
  return '${dois(d.day)}/${dois(d.month)} ${dois(d.hour)}:${dois(d.minute)}';
}

/// Cartão que aparece quando falta alguma autorização do Android para aplicar as regras.
class _Permissoes extends StatelessWidget {
  const _Permissoes({required this.permissoes, required this.aoPedir});

  final Map<String, bool> permissoes;
  final void Function(String permissao) aoPedir;

  // só a leitura de uso: acessibilidade, VPN e administrador foram removidos (bancos acusam o app)
  static const _itens = [
    ('uso', 'Leitura de uso', 'Para medir o tempo em cada app.', Icons.timelapse_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    if (permissoes.isEmpty) return const SizedBox.shrink();
    final faltando = _itens.where((i) => permissoes[i.$1] == false).toList();
    if (faltando.isEmpty) return const SizedBox.shrink();
    return Card(
      color: tema.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lock_outline, color: tema.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Faltam autorizações neste aparelho',
                      style: tema.textTheme.titleMedium
                          ?.copyWith(color: tema.colorScheme.onErrorContainer)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('Sem elas, as regras não são aplicadas aqui. Toque para conceder.',
                style: tema.textTheme.bodySmall
                    ?.copyWith(color: tema.colorScheme.onErrorContainer)),
            const SizedBox(height: 8),
            for (final i in faltando)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(i.$4, color: tema.colorScheme.onErrorContainer),
                title: Text(i.$2),
                subtitle: Text(i.$3),
                trailing: FilledButton(onPressed: () => aoPedir(i.$1), child: const Text('Conceder')),
                isThreeLine: true,
              ),
          ],
        ),
      ),
    );
  }
}

class _CartaoRegra extends StatelessWidget {
  const _CartaoRegra({
    required this.categoria,
    required this.nome,
    required this.regra,
    required this.ocupado,
    required this.aoMudar,
  });

  final String categoria;
  final String nome;
  final Map<String, dynamic> regra;
  final bool ocupado;
  final void Function(Map<String, dynamic> regra) aoMudar;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final modo = regra['modo'] as String? ?? 'livre';
    final limite = (regra['limite_min'] as num?)?.toInt() ?? 0;
    final horarios = (regra['horarios'] as List).cast<Map<String, dynamic>>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_iconesCategoria[categoria] ?? Icons.apps, color: tema.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(nome, style: tema.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final m in _modos.entries)
                  ChoiceChip(
                    label: Text(m.value),
                    selected: modo == m.key,
                    onSelected: ocupado ? null : (_) => aoMudar({...regra, 'modo': m.key}),
                  ),
              ],
            ),
            if (modo == 'limite') ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Limite por dia: '),
                  Text('$limite min', style: tema.textTheme.titleSmall),
                  Expanded(
                    child: Slider(
                      value: limite.clamp(5, 240).toDouble(),
                      min: 5,
                      max: 240,
                      divisions: 47,
                      label: '$limite min',
                      onChanged: ocupado ? null : (v) {},
                      onChangeEnd: ocupado
                          ? null
                          : (v) => aoMudar({...regra, 'limite_min': (v / 5).round() * 5}),
                    ),
                  ),
                ],
              ),
            ],
            if (modo != 'bloqueado') ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Bloqueado em:'),
                  for (final h in horarios)
                    InputChip(
                      label: Text('${h['inicio']}–${h['fim']}'),
                      onDeleted: ocupado
                          ? null
                          : () => aoMudar({
                              ...regra,
                              'horarios': [
                                for (final o in horarios) if (o != h) o,
                              ],
                            }),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('Horário'),
                    onPressed: ocupado
                        ? null
                        : () async {
                            final novo = await _escolherHorario(context);
                            if (novo != null) aoMudar({...regra, 'horarios': [...horarios, novo]});
                          },
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<Map<String, String>?> _escolherHorario(BuildContext context) async {
  final inicio = await showTimePicker(
    context: context,
    initialTime: const TimeOfDay(hour: 22, minute: 0),
    helpText: 'Começa a bloquear às',
  );
  if (inicio == null || !context.mounted) return null;
  final fim = await showTimePicker(
    context: context,
    initialTime: const TimeOfDay(hour: 7, minute: 0),
    helpText: 'Libera às',
  );
  if (fim == null) return null;
  String hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  return {'inicio': hm(inicio), 'fim': hm(fim)};
}

class _Protecao extends StatelessWidget {
  const _Protecao({required this.dispositivos});

  final List<Map<String, dynamic>> dispositivos;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Aparelhos', style: tema.textTheme.titleMedium),
        if (dispositivos.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Nenhum aparelho sincronizado ainda. Abra o app no celular e nos tablets para registrar.',
              style: tema.textTheme.bodyMedium,
            ),
          ),
        for (final d in dispositivos)
          _CartaoAparelho(dispositivo: d),
      ],
    );
  }
}

class _CartaoAparelho extends StatelessWidget {
  const _CartaoAparelho({required this.dispositivo});

  final Map<String, dynamic> dispositivo;

  static const _rotulos = {
    'uso': 'Leitura de uso',
  };

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final estado = (dispositivo['estado'] as Map?)?.cast<String, dynamic>() ?? const {};
    final desligados = [
      for (final e in estado.entries)
        if (e.value == false && _rotulos.containsKey(e.key)) _rotulos[e.key]!,
    ];
    final cor = desligados.isEmpty ? tema.colorScheme.primary : tema.colorScheme.error;
    return Card(
      child: ListTile(
        leading: Icon(desligados.isEmpty ? Icons.shield_outlined : Icons.gpp_bad_outlined, color: cor),
        title: Text(dispositivo['nome'] as String? ?? 'Aparelho'),
        subtitle: Text(
          'Visto ${_quando(dispositivo['visto_em'] as String?)}'
          '${desligados.isEmpty ? ' · tudo ativo' : ' · desligado: ${desligados.join(', ')}'}',
        ),
      ),
    );
  }
}

class _Uso extends StatelessWidget {
  const _Uso({required this.resumo, required this.categorias});

  final Map<String, dynamic>? resumo;
  final Map<String, String> categorias;

  @override
  Widget build(BuildContext context) {
    final r = resumo;
    final tema = Theme.of(context);
    if (r == null) return const Center(child: CircularProgressIndicator());
    final porDia = (r['por_dia'] as Map).cast<String, dynamic>();
    final apps = (r['apps'] as List).cast<Map<String, dynamic>>();
    if (porDia.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text('Sem dados de uso ainda. O app Android manda o tempo por app todo dia.',
            style: tema.textTheme.bodyMedium),
      );
    }
    final totais = <String, double>{};
    for (final dia in porDia.values) {
      for (final e in (dia as Map).cast<String, dynamic>().entries) {
        totais[e.key] = (totais[e.key] ?? 0) + (e.value as num).toDouble();
      }
    }
    final ordenadas = totais.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final rotular = {...categorias, 'outros': 'Outros apps'};
    final maxApp = apps.isEmpty ? 1.0 : (apps.first['minutos'] as num).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in ordenadas)
              Chip(
                avatar: Icon(_iconesCategoria[e.key] ?? Icons.apps, size: 18),
                label: Text('${rotular[e.key] ?? e.key}: ${_horas(e.value)}'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Apps campeões', style: tema.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final a in apps.take(8))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(a['nome'] as String? ?? '')),
                    Text('${_horas((a['minutos'] as num).toDouble())} · ${a['aberturas']}×',
                        style: tema.textTheme.bodySmall),
                  ],
                ),
                const SizedBox(height: 2),
                LinearProgressIndicator(
                  value: ((a['minutos'] as num).toDouble() / maxApp).clamp(0, 1),
                  backgroundColor: tema.colorScheme.surfaceContainerHighest,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

String _horas(double min) {
  if (min < 60) return '${min.round()} min';
  return '${(min / 60).floor()}h${(min % 60).round().toString().padLeft(2, '0')}';
}

class _Vigia extends StatefulWidget {
  const _Vigia({required this.api, required this.periodo});

  final ApiSaude api;
  final int periodo;

  @override
  State<_Vigia> createState() => _VigiaState();
}

class _VigiaState extends State<_Vigia> {
  Map<String, dynamic>? _analise;
  bool _pensando = false;

  @override
  void initState() {
    super.initState();
    _ultima();
  }

  Future<void> _ultima() async {
    try {
      final lista = await widget.api.analisesConsumo();
      if (mounted && lista.isNotEmpty) setState(() => _analise = lista.first);
    } on ApiErro catch (_) {}
  }

  Future<void> _analisar() async {
    setState(() => _pensando = true);
    try {
      final a = await widget.api.analisarConsumo(widget.periodo, '');
      if (mounted) setState(() => _analise = a);
    } on ApiErro catch (e) {
      if (mounted) _avisar(context, e);
    } finally {
      if (mounted) setState(() => _pensando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final a = _analise;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.visibility_outlined, color: tema.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text('O vigia', style: tema.textTheme.titleLarge)),
            FilledButton.icon(
              onPressed: _pensando ? null : _analisar,
              icon: _pensando
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome),
              label: Text(_pensando ? 'Pensando…' : 'Analisar'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text('Leitura franca pela sua LLM local — nada sai do seu PC.', style: tema.textTheme.bodySmall),
        const SizedBox(height: 12),
        if (a == null)
          Text('Peça uma análise quando houver alguns dias de uso registrados.',
              style: tema.textTheme.bodyMedium)
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${a['de']} a ${a['ate']} · ${_quando(a['criada_em'] as String?)}',
                      style: tema.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  VisualizadorMarkdown(texto: a['texto'] as String? ?? ''),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
