import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_saude.dart';
import '../datas.dart';
import '../health_connect.dart';
import '../sincronizacao.dart';

/// Painel do Galaxy Watch: sono, atividade, coração e corpo. No Android o Health Connect é lido sozinho
/// (ao abrir o app e a cada hora em segundo plano, ver `sincronizacao.dart`) e pelos botões; em
/// qualquer aparelho importa o zip da exportação do Samsung Health (histórico, estresse, nota do sono).
class RelogioTela extends StatefulWidget {
  const RelogioTela({super.key, required this.api});

  final ApiSaude api;

  @override
  State<RelogioTela> createState() => _RelogioTelaState();
}

class _RelogioTelaState extends State<RelogioTela> {
  final _leitor = LeitorHealthConnect();
  int _periodo = 30;
  List<Map<String, dynamic>>? _dias;
  Map<String, dynamic> _resumo = const {};
  Map<String, dynamic> _estado = const {};
  String? _ocupado;

  /// Leitura em segundo plano autorizada (null: ainda não sabe ou não é Android).
  bool? _automatico;

  ApiSaude get api => widget.api;

  @override
  void initState() {
    super.initState();
    _carregar();
    if (LeitorHealthConnect.disponivel) _verificarAutomatico();
  }

  Future<void> _verificarAutomatico() async {
    try {
      final ok =
          await _leitor.problema() == null && await _leitor.autorizado() && await _leitor.segundoPlanoAutorizado();
      if (mounted) setState(() => _automatico = ok);
    } catch (_) {
      if (mounted) setState(() => _automatico = false);
    }
  }

  /// Pede as permissões que faltam (leitura e segundo plano) e já sincroniza o período.
  Future<void> _ativarAutomatico() async {
    try {
      final problema = await _leitor.problema();
      if (problema != null) return _avisar(problema);
      if (!await _leitor.autorizado() && !await _leitor.autorizar()) {
        return _avisar('Sem permissão de leitura no Health Connect.');
      }
      if (!await _leitor.autorizarSegundoPlano()) {
        _avisar('Permita "acessar dados em segundo plano" para o agent no Health Connect.');
      }
    } catch (e) {
      _avisar(e);
    }
    await _verificarAutomatico();
    await _sincronizar(dias: _periodo);
  }

  void _avisar(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }

  Future<void> _carregar() async {
    final ate = hoje();
    final de = somarDias(ate, -(_periodo - 1));
    try {
      final r = await Future.wait([api.diasRelogio(de, ate), api.resumoRelogio(de, ate), api.estadoRelogio()]);
      if (!mounted) return;
      setState(() {
        _dias = r[0] as List<Map<String, dynamic>>;
        _resumo = r[1] as Map<String, dynamic>;
        _estado = r[2] as Map<String, dynamic>;
      });
    } on ApiErro catch (e) {
      _avisar(e);
      if (mounted) setState(() => _dias ??= []);
    }
  }

  /// Lê [dias] do Health Connect e envia ao backend; na primeira vez pede as permissões.
  Future<void> _sincronizar({required int dias}) async {
    if (_ocupado != null) return;
    try {
      final problema = await _leitor.problema();
      if (problema != null) return _avisar(problema);
      if (!await _leitor.autorizado()) {
        if (!await _leitor.autorizar()) return _avisar('Sem permissão de leitura no Health Connect.');
        await _verificarAutomatico();
      }
      final enviados = await sincronizarRelogio(
        api,
        _leitor,
        dias: dias,
        aoLer: (de, ate) {
          if (mounted) setState(() => _ocupado = 'Lendo ${diaCurto(de)} a ${diaCurto(ate)}…');
        },
      );
      _avisar('$enviados dias sincronizados do Health Connect.');
      await _carregar();
    } catch (e) {
      _avisar(e);
    } finally {
      if (mounted) setState(() => _ocupado = null);
    }
  }

  Future<void> _importar() async {
    final r = await FilePicker.pickFiles(
      dialogTitle: 'Exportação do Samsung Health (.zip)',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (r.isEmpty) return;
    setState(() => _ocupado = 'Importando ${r.first.name}…');
    try {
      final res = await api.importarSamsung(r.first.name, await r.first.xFile.readAsBytes());
      _avisar('${res['dias']} dias importados (${(res['arquivos'] as List).join(', ')}).');
      await _carregar();
    } on ApiErro catch (e) {
      _avisar(e);
    } finally {
      if (mounted) setState(() => _ocupado = null);
    }
  }

  String _quando(String? isoUtc) {
    final d = DateTime.tryParse(isoUtc ?? '')?.toLocal();
    if (d == null) return 'nunca';
    return '${diaCurto(d)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final dias = _dias;
    final tema = Theme.of(context);
    return RefreshIndicator(
      onRefresh: LeitorHealthConnect.disponivel ? () => _sincronizar(dias: 7) : _carregar,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Cabecalho(
            periodo: _periodo,
            mudarPeriodo: (p) {
              setState(() => _periodo = p);
              _carregar();
            },
            ocupado: _ocupado != null,
            sincronizar: LeitorHealthConnect.disponivel ? () => _sincronizar(dias: _periodo) : null,
            buscarAno: LeitorHealthConnect.disponivel ? () => _sincronizar(dias: 365) : null,
            importar: _importar,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _Estado(Icons.watch_outlined, 'Health Connect: ${_quando(_estado['health_connect'] as String?)}'),
              _Estado(Icons.folder_zip_outlined, 'Exportação: ${_quando(_estado['exportacao'] as String?)}'),
              if (_automatico == true) const _Estado(Icons.sync, 'Automática a cada hora'),
            ],
          ),
          if (_automatico == false) ...[
            const SizedBox(height: 8),
            Card(
              color: tema.colorScheme.secondaryContainer,
              child: ListTile(
                leading: const Icon(Icons.sync_disabled),
                title: const Text('Sincronização automática desligada'),
                subtitle: const Text('Permita a leitura em segundo plano para o relógio chegar sozinho, a cada hora.'),
                trailing: FilledButton(
                  onPressed: _ocupado == null ? _ativarAutomatico : null,
                  child: const Text('Ativar'),
                ),
              ),
            ),
          ],
          if (_ocupado != null) ...[
            const SizedBox(height: 8),
            Row(
              spacing: 8,
              children: [
                const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                Flexible(child: Text(_ocupado!)),
              ],
            ),
          ],
          const SizedBox(height: 16),
          if (dias == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (dias.isEmpty)
            const _SemDados()
          else ...[
            _Indicadores(key: ValueKey(_periodo), resumo: _resumo, ultimo: dias.last),
            const SizedBox(height: 16),
            _Graficos(
              key: ValueKey('g$_periodo'),
              dias: dias,
              de: somarDias(hoje(), -(_periodo - 1)),
              periodo: _periodo,
            ),
            const SizedBox(height: 16),
            _Exercicios(dias: dias),
          ],
        ],
      ),
    );
  }
}

/// Período e ações. No celular: período na largura toda e "Sincronizar" com as outras ações em
/// botões de ícone ao lado (antes os três botões grandes quebravam em linhas soltas).
class _Cabecalho extends StatelessWidget {
  const _Cabecalho({
    required this.periodo,
    required this.mudarPeriodo,
    required this.ocupado,
    required this.sincronizar,
    required this.buscarAno,
    required this.importar,
  });

  final int periodo;
  final ValueChanged<int> mudarPeriodo;
  final bool ocupado;
  final VoidCallback? sincronizar, buscarAno;
  final VoidCallback importar;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final estreito = c.maxWidth < 600;
      final periodos = SegmentedButton<int>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 7, label: Text('7 dias')),
          ButtonSegment(value: 30, label: Text('30 dias')),
          ButtonSegment(value: 90, label: Text('90 dias')),
        ],
        selected: {periodo},
        onSelectionChanged: (s) => mudarPeriodo(s.first),
      );
      final sinc = sincronizar == null
          ? null
          : FilledButton.icon(
              onPressed: ocupado ? null : sincronizar,
              icon: const Icon(Icons.sync),
              label: const Text('Sincronizar'),
            );
      final titulo = Text('Sono e corpo', style: Theme.of(context).textTheme.titleLarge);
      if (!estreito) {
        return Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            titulo,
            periodos,
            ?sinc,
            if (buscarAno != null)
              OutlinedButton.icon(
                onPressed: ocupado ? null : buscarAno,
                icon: const Icon(Icons.history),
                label: const Text('Buscar 1 ano'),
              ),
            OutlinedButton.icon(
              onPressed: ocupado ? null : importar,
              icon: const Icon(Icons.upload_file),
              label: const Text('Importar exportação'),
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          titulo,
          periodos,
          Row(
            spacing: 8,
            children: [
              if (sinc != null) Expanded(child: sinc) else const Spacer(),
              if (buscarAno != null)
                IconButton.outlined(
                  tooltip: 'Buscar 1 ano',
                  onPressed: ocupado ? null : buscarAno,
                  icon: const Icon(Icons.history),
                ),
              IconButton.outlined(
                tooltip: 'Importar exportação',
                onPressed: ocupado ? null : importar,
                icon: const Icon(Icons.upload_file),
              ),
            ],
          ),
        ],
      );
    },
  );
}

class _Estado extends StatelessWidget {
  const _Estado(this.icone, this.texto);

  final IconData icone;
  final String texto;

  @override
  Widget build(BuildContext context) {
    final estilo = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        Icon(icone, size: 14, color: estilo?.color),
        Flexible(child: Text(texto, style: estilo)),
      ],
    );
  }
}

/// Entrada escalonada: cada filho sobe e aparece [atraso] depois do anterior.
class _Entrada extends StatelessWidget {
  const _Entrada({required this.ordem, required this.child});

  final int ordem;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: Duration(milliseconds: 350 + 60 * min(ordem, 8)),
    curve: Interval(min(ordem, 8) * 60 / (350 + 60 * min(ordem, 8)), 1, curve: Curves.easeOutCubic),
    builder: (_, t, filho) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, 16 * (1 - t)), child: filho),
    ),
    child: child,
  );
}

class _SemDados extends StatelessWidget {
  const _SemDados();

  @override
  Widget build(BuildContext context) => const Card(
    child: Padding(
      padding: EdgeInsets.all(16),
      child: Text(
        'Nenhum dado do relógio neste período.\n\n'
        '• No celular: Samsung Health › Configurações › Health Connect, ative a sincronização; '
        'depois toque em "Sincronizar" aqui.\n'
        '• Histórico completo (com estresse e pontuação do sono): Samsung Health › Configurações › '
        'Baixar dados pessoais, e "Importar exportação" com o .zip.',
      ),
    ),
  );
}

String horas(num minutos) => '${minutos ~/ 60}h${(minutos % 60).round().toString().padLeft(2, '0')}';

class _Indicadores extends StatelessWidget {
  const _Indicadores({super.key, required this.resumo, required this.ultimo});

  final Map<String, dynamic> resumo;
  final Map<String, dynamic> ultimo;

  @override
  Widget build(BuildContext context) {
    final m = (resumo['medias'] as Map?)?.cast<String, num>() ?? const {};
    final metas = (resumo['metas'] as Map?)?.cast<String, dynamic>() ?? const {};
    String meta(String k) {
      final x = metas[k] as Map?;
      return x == null || x['dias'] == 0 ? '' : '${x['batidos']} de ${x['dias']} dias na meta';
    }

    (int, int)? progresso(String k) {
      final x = metas[k] as Map?;
      return x == null || x['dias'] == 0 ? null : ((x['batidos'] as num).toInt(), (x['dias'] as num).toInt());
    }

    String inteiro(num v) => '${v.round()}';
    final peso = (ultimo['peso_kg'] ?? m['peso_kg']) as num?;
    final cartoes = <_Cartao>[
      if (m['sono_min'] != null)
        _Cartao(
          'Sono médio',
          m['sono_min']!,
          horas,
          meta('sono_min'),
          Icons.bedtime_outlined,
          Colors.indigo.shade300,
          progresso('sono_min'),
        ),
      if (m['passos'] != null)
        _Cartao(
          'Passos por dia',
          m['passos']!,
          inteiro,
          meta('passos'),
          Icons.directions_walk,
          Colors.green.shade400,
          progresso('passos'),
        ),
      if (m['minutos_ativos'] != null)
        _Cartao(
          'Minutos ativos',
          m['minutos_ativos']!,
          inteiro,
          meta('minutos_ativos'),
          Icons.local_fire_department_outlined,
          Colors.orange,
          progresso('minutos_ativos'),
        ),
      if (m['fc_repouso'] != null)
        _Cartao(
          'FC em repouso',
          m['fc_repouso']!,
          (v) => '${v.round()} bpm',
          '',
          Icons.favorite_border,
          Colors.red.shade400,
        ),
      if (m['hrv_ms'] != null)
        _Cartao(
          'Variabilidade (HRV)',
          m['hrv_ms']!,
          (v) => '${v.round()} ms',
          '',
          Icons.monitor_heart_outlined,
          Colors.teal,
        ),
      if (m['estresse'] != null)
        _Cartao('Estresse', m['estresse']!, inteiro, 'de 0 a 100', Icons.psychology_outlined, Colors.amber.shade700),
      if (m['spo2'] != null) _Cartao('Oxigênio (SpO₂)', m['spo2']!, (v) => '${v.round()}%', '', Icons.air, Colors.cyan),
      if (m['sono_pontuacao'] != null)
        _Cartao(
          'Nota do sono',
          m['sono_pontuacao']!,
          inteiro,
          // sem a exportação do Samsung, o backend calcula pela duração e pelos estágios
          ultimo['sono_pontuacao_estimada'] == true ? 'pelos estágios do sono' : 'do Samsung Health',
          Icons.star_outline,
          Colors.purple.shade300,
        ),
      if (peso != null)
        _Cartao(
          'Peso',
          peso,
          (v) => '${v.toStringAsFixed(1)} kg',
          ultimo['gordura_pct'] != null ? '${ultimo['gordura_pct']}% de gordura' : '',
          Icons.monitor_weight_outlined,
          Colors.blueGrey.shade300,
        ),
      if (m['agua_ml'] != null)
        _Cartao(
          'Água',
          m['agua_ml']!,
          (v) => '${(v / 1000).toStringAsFixed(1)} L',
          meta('agua_ml'),
          Icons.water_drop_outlined,
          Colors.lightBlue,
          progresso('agua_ml'),
        ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        // 2 colunas no celular, até 5 em tela larga; cartões ocupam a largura toda.
        final colunas = (c.maxWidth / 200).floor().clamp(2, 5);
        final largura = (c.maxWidth - 12 * (colunas - 1)) / colunas;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (i, cartao) in cartoes.indexed)
              SizedBox(
                width: largura,
                child: _Entrada(ordem: i, child: cartao),
              ),
          ],
        );
      },
    );
  }
}

/// Indicador com o número subindo do zero e, quando há meta, a barra dos dias batidos.
class _Cartao extends StatelessWidget {
  const _Cartao(this.titulo, this.valor, this.formato, this.sub, this.icone, this.cor, [this.progresso]);

  final String titulo;
  final num valor;
  final String Function(num) formato;
  final String sub;
  final IconData icone;
  final Color cor;
  final (int, int)? progresso;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final p = progresso;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Row(
              spacing: 6,
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: cor.withValues(alpha: .18),
                  child: Icon(icone, size: 16, color: cor),
                ),
                Expanded(
                  child: Text(titulo, maxLines: 1, overflow: TextOverflow.ellipsis, style: tema.textTheme.labelLarge),
                ),
              ],
            ),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: valor.toDouble()),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (_, v, _) => FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  // no fim mostra o valor exato (a animação passa por frações)
                  formato(v == valor.toDouble() ? valor : v),
                  style: tema.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            if (p != null)
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: p.$1 / p.$2),
                duration: const Duration(milliseconds: 900),
                curve: Curves.easeOutCubic,
                builder: (_, t, _) => LinearProgressIndicator(
                  value: t,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                  color: cor,
                  backgroundColor: cor.withValues(alpha: .15),
                ),
              ),
            if (sub.isNotEmpty)
              Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: tema.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// Barras por dia, empilhadas quando há [partes] (ex.: estágios do sono), com eixo Y, linha da [meta],
/// média/mín/máx do período e detalhe do dia tocado (toque ou arraste sobre as barras).
class GraficoDias extends StatefulWidget {
  const GraficoDias({
    super.key,
    required this.titulo,
    required this.dias,
    required this.partes,
    this.meta,
    this.rotulo,
    this.unidade,
    this.passoY,
    this.aPartirDoMinimo = false,
  });

  final String titulo;
  final List<DateTime> dias;

  /// nome → (cor, valor por dia ISO).
  final Map<String, (Color, Map<String, num>)> partes;
  final num? meta;
  final String Function(num)? rotulo;

  /// Unidade mostrada junto do valor no detalhe (ex.: 'bpm').
  final String? unidade;

  /// Passo fixo das marcas do eixo Y (ex.: 120 min no sono); sem ele, um passo "redondo" automático.
  final num? passoY;

  /// Eixo Y começa perto do menor valor (FC, peso): a variação entre os dias fica visível.
  final bool aPartirDoMinimo;

  @override
  State<GraficoDias> createState() => _GraficoDiasState();
}

class _GraficoDiasState extends State<GraficoDias> with SingleTickerProviderStateMixin {
  static const _margemY = 44.0;
  static const _topo = 18.0;

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();
  String? _sel;

  String _assinatura(GraficoDias w) => [
    for (final d in w.dias) iso(d),
    for (final MapEntry(:key, value: (_, v)) in w.partes.entries) '$key${v.entries.map((e) => '${e.key}${e.value}')}',
  ].join('|');

  @override
  void didUpdateWidget(GraficoDias antigo) {
    super.didUpdateWidget(antigo);
    if (_assinatura(antigo) != _assinatura(widget)) {
      _sel = null;
      _anim.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  num? _total(String d) {
    num? soma;
    for (final (_, valores) in widget.partes.values) {
      final v = valores[d];
      if (v != null) soma = (soma ?? 0) + v;
    }
    return soma;
  }

  String _fmt(num v) => widget.rotulo?.call(v) ?? (v is int || v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1));

  String _fmtEixo(num v) {
    if (widget.rotulo != null) return widget.rotulo!(v);
    if (v.abs() >= 1000) {
      final k = v / 1000;
      return '${k == k.roundToDouble() ? k.round() : k.toStringAsFixed(1)}k';
    }
    return _fmt(v);
  }

  /// Passo "redondo" (1, 2, 2,5 ou 5 × 10ⁿ) para ~4 marcas no intervalo.
  static num _passoRedondo(num intervalo) {
    if (intervalo <= 0) return 1;
    final bruto = intervalo / 4;
    final mag = pow(10, (log(bruto) / ln10).floor());
    for (final m in [1, 2, 2.5, 5, 10]) {
      if (bruto <= m * mag) return m * mag;
    }
    return 10 * mag;
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final w = widget;
    final totais = {for (final d in w.dias) iso(d): _total(iso(d))};
    final comDados = [for (final v in totais.values) ?v];
    final maior = [...comDados, ?w.meta].fold<num>(0, max);
    final menor = comDados.isEmpty ? 0 : comDados.reduce(min);
    final passo = w.passoY ?? _passoRedondo(w.aPartirDoMinimo ? max<num>(maior - menor, 1) * 1.5 : max<num>(maior, 1));
    final piso = w.aPartirDoMinimo ? max<num>(0, (menor / passo).floor() * passo - passo) : 0;
    final teto = max<num>(piso + passo, ((maior / passo).floor() + 1) * passo);
    final marcas = [for (var t = piso; t <= teto + passo / 1000; t += passo) t];
    final media = comDados.isEmpty ? null : comDados.reduce((a, b) => a + b) / comDados.length;
    final sel = _sel ?? [for (final d in w.dias.reversed) if (totais[iso(d)] != null) iso(d)].firstOrNull;
    final n = w.dias.length;
    final cores = tema.colorScheme;

    Widget detalhe() {
      final dia = w.dias.where((d) => iso(d) == sel).firstOrNull;
      if (dia == null) return Text('Toque numa barra para ver o dia.', style: tema.textTheme.bodySmall);
      final total = totais[sel];
      final un = w.unidade == null ? '' : ' ${w.unidade}';
      final partesTxt = w.partes.length > 1 && total != null
          ? ' (${[for (final MapEntry(key: nome, value: (_, v)) in w.partes.entries) if (v[sel] != null) '$nome ${_fmt(v[sel]!)}'].join(' · ')})'
          : '';
      final diff = total != null && w.meta != null ? total - w.meta! : null;
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '${diasSemana[dia.weekday - 1]}, ${diaCurto(dia)}: ', style: tema.textTheme.bodySmall),
            TextSpan(
              text: total == null ? 'sem dados' : '${_fmt(total)}$un',
              style: tema.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            TextSpan(text: partesTxt, style: tema.textTheme.bodySmall),
            if (diff != null)
              TextSpan(
                text: diff >= 0 ? '  meta batida' : '  faltou ${_fmt(-diff)}',
                style: tema.textTheme.bodySmall?.copyWith(color: diff >= 0 ? Colors.green : cores.error),
              ),
          ],
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(w.titulo, style: tema.textTheme.titleMedium),
                if (w.partes.length > 1)
                  for (final MapEntry(key: nome, value: (cor, _)) in w.partes.entries)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 4,
                      children: [
                        Container(width: 10, height: 10, color: cor),
                        Text(nome, style: tema.textTheme.bodySmall),
                      ],
                    ),
                if (w.meta != null) Text('meta ${_fmt(w.meta!)}', style: tema.textTheme.bodySmall),
              ],
            ),
            if (media != null)
              Text(
                'média ${_fmt(media)} · mín ${_fmt(menor)} · máx ${_fmt(comDados.reduce(max))}'
                '${w.unidade == null ? '' : ' (${w.unidade})'}',
                style: tema.textTheme.bodySmall?.copyWith(color: cores.onSurfaceVariant),
              ),
            SizedBox(
              height: 170,
              child: LayoutBuilder(
                builder: (context, c) {
                  final area = c.maxHeight - _topo;
                  double y(num v) => area * ((v - piso) / (teto - piso)).clamp(0, 1);
                  void tocar(double x) {
                    final i = ((x - _margemY) / (c.maxWidth - _margemY) * n).floor();
                    if (i >= 0 && i < n) setState(() => _sel = iso(w.dias[i]));
                  }

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (e) => tocar(e.localPosition.dx),
                    onHorizontalDragUpdate: (e) => tocar(e.localPosition.dx),
                    child: AnimatedBuilder(
                      animation: _anim,
                      builder: (context, _) => Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (final t in marcas) ...[
                            Positioned(
                              left: _margemY,
                              right: 0,
                              bottom: y(t),
                              child: Container(height: 1, color: cores.outlineVariant.withValues(alpha: .35)),
                            ),
                            Positioned(
                              left: 0,
                              width: _margemY - 6,
                              bottom: y(t) - 7,
                              child: Text(
                                _fmtEixo(t),
                                textAlign: TextAlign.right,
                                style: tema.textTheme.labelSmall?.copyWith(color: cores.onSurfaceVariant, fontSize: 10),
                              ),
                            ),
                          ],
                          if (w.meta != null)
                            Positioned(
                              left: _margemY,
                              right: 0,
                              bottom: y(w.meta!),
                              child: Container(height: 1.5, color: cores.error.withValues(alpha: .7)),
                            ),
                          Positioned.fill(
                            left: _margemY,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final (i, d) in w.dias.indexed)
                                  Expanded(child: _barra(context, i, d, totais[iso(d)], y, iso(d) == sel)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: _margemY),
              child: n <= 14
                  ? Row(
                      children: [
                        for (final d in w.dias)
                          Expanded(
                            child: Text(
                              n <= 7 ? '${diasSemana[d.weekday - 1]}\n${d.day}' : '${d.day}',
                              textAlign: TextAlign.center,
                              style: tema.textTheme.labelSmall?.copyWith(
                                fontWeight: iso(d) == sel ? FontWeight.bold : null,
                                color: iso(d) == sel ? cores.primary : null,
                              ),
                            ),
                          ),
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(diaCurto(w.dias.first), style: tema.textTheme.labelSmall),
                        Text(diaCurto(w.dias[n ~/ 2]), style: tema.textTheme.labelSmall),
                        Text(diaCurto(w.dias.last), style: tema.textTheme.labelSmall),
                      ],
                    ),
            ),
            detalhe(),
          ],
        ),
      ),
    );
  }

  /// Uma coluna do gráfico: valor em cima (até 7 dias ou no dia selecionado) e a barra crescendo de baixo.
  Widget _barra(BuildContext context, int i, DateTime d, num? total, double Function(num) y, bool selecionado) {
    final tema = Theme.of(context);
    final n = widget.dias.length;
    if (total == null) return const SizedBox.shrink();
    final inicio = n <= 1 ? 0.0 : .4 * i / (n - 1);
    final cresce = Curves.easeOutCubic.transform(((_anim.value - inicio) / .6).clamp(0, 1));
    final altura = max(2.0, y(total) * cresce);
    final apagada = widget.dias.any((x) => iso(x) == _sel) && !selecionado;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (n <= 7 || selecionado)
          Opacity(
            opacity: cresce,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _fmtEixo(total),
                style: tema.textTheme.labelSmall?.copyWith(fontWeight: selecionado ? FontWeight.bold : null, fontSize: 10),
              ),
            ),
          ),
        const SizedBox(height: 2),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: apagada ? .45 : 1,
          child: Container(
            height: altura,
            margin: EdgeInsets.symmetric(horizontal: n > 45 ? .5 : (n > 14 ? 1 : 3)),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.vertical(top: Radius.circular(n > 14 ? 1 : 4)),
              border: selecionado ? Border.all(color: tema.colorScheme.onSurface, width: 1.5) : null,
            ),
            child: Column(
              children: [
                for (final (cor, valores) in widget.partes.values.toList().reversed)
                  if ((valores[iso(d)] ?? 0) > 0)
                    Expanded(flex: max(1, (valores[iso(d)]! * 100).round()), child: Container(color: cor)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Graficos extends StatelessWidget {
  const _Graficos({super.key, required this.dias, required this.de, required this.periodo});

  final List<Map<String, dynamic>> dias;
  final DateTime de;
  final int periodo;

  Map<String, num> _serie(String campo) => {
    for (final d in dias)
      if (d[campo] is num) d['data'] as String: d[campo] as num,
  };

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final eixo = [for (var i = 0; i < periodo; i++) somarDias(de, i)];
    final comEstagios = dias.any((d) => d['sono_profundo_min'] != null);
    final sonoLeve = {
      for (final d in dias)
        if (d['sono_min'] is num)
          d['data'] as String: comEstagios
              ? max<num>(0, (d['sono_min'] as num) - (d['sono_profundo_min'] ?? 0) - (d['sono_rem_min'] ?? 0))
              : d['sono_min'] as num,
    };
    final graficos = <Widget>[
      if (sonoLeve.isNotEmpty)
        GraficoDias(
          titulo: 'Sono por noite',
          dias: eixo,
          meta: 420,
          rotulo: horas,
          passoY: 120,
          partes: {
            if (comEstagios) 'profundo': (Colors.indigo, _serie('sono_profundo_min')),
            if (comEstagios) 'REM': (Colors.purple.shade300, _serie('sono_rem_min')),
            comEstagios ? 'leve' : 'sono': (Colors.lightBlue.shade300, sonoLeve),
          },
        ),
      if (_serie('passos').isNotEmpty)
        GraficoDias(titulo: 'Passos', dias: eixo, meta: 8000, unidade: 'passos', partes: {'passos': (cores.primary, _serie('passos'))}),
      if (_serie('minutos_ativos').isNotEmpty)
        GraficoDias(
          titulo: 'Minutos ativos',
          dias: eixo,
          meta: 30,
          unidade: 'min',
          partes: {'min': (Colors.orange, _serie('minutos_ativos'))},
        ),
      if (_serie('fc_repouso').isNotEmpty || _serie('fc_media').isNotEmpty)
        GraficoDias(
          titulo: _serie('fc_repouso').isNotEmpty ? 'FC em repouso (bpm)' : 'FC média (bpm)',
          dias: eixo,
          unidade: 'bpm',
          aPartirDoMinimo: true,
          partes: {'bpm': (Colors.red.shade400, _serie(_serie('fc_repouso').isNotEmpty ? 'fc_repouso' : 'fc_media'))},
        ),
      if (_serie('hrv_ms').isNotEmpty)
        GraficoDias(titulo: 'HRV (ms)', dias: eixo, unidade: 'ms', aPartirDoMinimo: true, partes: {'ms': (Colors.teal, _serie('hrv_ms'))}),
      if (_serie('estresse').isNotEmpty)
        GraficoDias(titulo: 'Estresse', dias: eixo, partes: {'estresse': (Colors.amber.shade700, _serie('estresse'))}),
      if (_serie('peso_kg').isNotEmpty)
        GraficoDias(
          titulo: 'Peso (kg)',
          dias: eixo,
          rotulo: (v) => v.toStringAsFixed(1),
          unidade: 'kg',
          aPartirDoMinimo: true,
          partes: {'kg': (Colors.blueGrey, _serie('peso_kg'))},
        ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final colunas = c.maxWidth >= 1100 ? 2 : 1;
        final largura = (c.maxWidth - 12 * (colunas - 1)) / colunas;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (i, g) in graficos.indexed)
              SizedBox(
                width: largura,
                child: _Entrada(ordem: i, child: g),
              ),
          ],
        );
      },
    );
  }
}

class _Exercicios extends StatelessWidget {
  const _Exercicios({required this.dias});

  final List<Map<String, dynamic>> dias;

  @override
  Widget build(BuildContext context) {
    final itens = [
      for (final d in dias.reversed)
        for (final e in (d['exercicios'] as List? ?? const []).cast<Map<String, dynamic>>()) (d['data'] as String, e),
    ];
    if (itens.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text('Exercícios registrados pelo relógio', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final (data, e) in itens.take(20))
            ListTile(
              dense: true,
              leading: const Icon(Icons.directions_run),
              title: Text('${e['tipo']} · ${e['minutos']} min'),
              subtitle: Text(
                [
                  '${diaCurto(DateTime.parse(data))} ${e['inicio'] ?? ''}',
                  if (e['calorias'] != null) '${e['calorias']} kcal',
                  if (e['distancia_km'] != null) '${e['distancia_km']} km',
                ].join(' · '),
              ),
            ),
        ],
      ),
    );
  }
}
