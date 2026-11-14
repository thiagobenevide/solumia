import 'dart:io';
import 'dart:math' as math;

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ota_update/ota_update.dart';

/// Build deste executável (`--dart-define=BUILD=...`, posto por `infra/scripts/publicar_app`); 0 = build
/// de desenvolvimento, que nunca se oferece para atualizar sozinho.
const buildAtual = int.fromEnvironment('BUILD');

/// Plataforma com pacote publicável em `/api/atualizacoes`; null = sem atualização pelo app (web etc.).
String? get _plataforma => kIsWeb ? null : (Platform.isAndroid ? 'android' : (Platform.isLinux ? 'linux' : null));

/// Cores da logo do Agent (gradiente azul → roxo), usadas nos anéis e no emblema.
const _azul = Color(0xFF356BEC);
const _anil = Color(0xFF5557E8);
const _roxo = Color(0xFF7543E5);
const _gradiente = [_azul, _anil, _roxo, _azul];

/// "12/11 às 05:56": o build é em minutos desde 1970 (ver `publicar_app`).
String _rotulo(int build) {
  if (build < 1000000) return 'build $build';
  final d = DateTime.fromMillisecondsSinceEpoch(build * 60000);
  String dois(int n) => n.toString().padLeft(2, '0');
  return '${dois(d.day)}/${dois(d.month)} às ${dois(d.hour)}:${dois(d.minute)}';
}

/// Build visto na última abertura; devolve o atual se mudou desde então (uma vez só por build).
Future<int?> _recemAtualizado() async {
  if (buildAtual == 0) return null;
  try {
    final a = await Armazem.abrir('app');
    final visto = await a.lerJson('atualizacao.json') as Map<String, dynamic>?;
    await a.gravarJson('atualizacao.json', {'build': buildAtual});
    final anterior = visto?['build'] as int?;
    return anterior != null && anterior < buildAtual ? buildAtual : null;
  } catch (_) {
    return null;
  }
}

/// Ícone "Atualizar app" da barra do topo: confere a versão publicada na VPS ao abrir e, com uma nova,
/// mostra o selo pulsando; o toque abre o diálogo animado (Android: instalador do sistema; Linux:
/// reinstala e reabre). Na primeira abertura depois de atualizar, comemora com a versão nova.
class BotaoAtualizar extends StatefulWidget {
  const BotaoAtualizar({super.key, required this.api});

  final ApiCliente api;

  @override
  State<BotaoAtualizar> createState() => _BotaoAtualizarState();
}

class _BotaoAtualizarState extends State<BotaoAtualizar> with SingleTickerProviderStateMixin {
  int _publicado = 0;
  late final _pulso = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  bool get _temNova => _publicado > buildAtual && buildAtual > 0;

  @override
  void initState() {
    super.initState();
    _conferir();
    _recemAtualizado().then((b) {
      if (b == null || !mounted) return;
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Atualizado',
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (_, _, _) => _DialogoAtualizado(build: b),
      );
    });
  }

  @override
  void dispose() {
    _pulso.dispose();
    super.dispose();
  }

  Future<int> _conferir() async {
    final p = _plataforma;
    if (p == null) return 0;
    try {
      final r = await widget.api.get('api/atualizacoes') as Map<String, dynamic>;
      final build = (r['plataformas'] as List).contains(p) ? r['build'] as int : 0;
      if (mounted) {
        setState(() => _publicado = build);
        _temNova ? _pulso.repeat(reverse: true) : _pulso.stop();
      }
      return build;
    } catch (_) {
      return 0; // sem rede ou backend antigo: o botão só não mostra o selo
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_plataforma == null) return const SizedBox.shrink();
    return IconButton(
      tooltip: _temNova ? 'Atualização disponível' : 'Atualizar app',
      icon: Badge(
        isLabelVisible: _temNova,
        backgroundColor: _roxo,
        child: ScaleTransition(
          scale: Tween(begin: 1.0, end: 1.15).animate(CurvedAnimation(parent: _pulso, curve: Curves.easeInOut)),
          child: Icon(Icons.system_update, color: _temNova ? _azul : null),
        ),
      ),
      onPressed: () async {
        await _conferir();
        if (context.mounted) {
          await showGeneralDialog<void>(
            context: context,
            barrierDismissible: false,
            barrierLabel: 'Atualizar app',
            barrierColor: Colors.black54,
            transitionDuration: const Duration(milliseconds: 280),
            transitionBuilder: (_, a, _, filho) => FadeTransition(
              opacity: a,
              child: ScaleTransition(scale: Tween(begin: 0.9, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)), child: filho),
            ),
            pageBuilder: (_, _, _) => _DialogoAtualizar(api: widget.api, publicado: _publicado),
          );
        }
      },
    );
  }
}

enum _Etapa { semVersao, emDia, oferta, baixando, instalando, confirme, erro }

class _DialogoAtualizar extends StatefulWidget {
  const _DialogoAtualizar({required this.api, required this.publicado});

  final ApiCliente api;
  final int publicado;

  @override
  State<_DialogoAtualizar> createState() => _DialogoAtualizarState();
}

class _DialogoAtualizarState extends State<_DialogoAtualizar> {
  late _Etapa _etapa = widget.publicado == 0
      ? _Etapa.semVersao
      : widget.publicado > buildAtual
      ? _Etapa.oferta
      : _Etapa.emDia;
  double _progresso = 0;
  String? _erro;

  bool get _rodando => _etapa == _Etapa.baixando || _etapa == _Etapa.instalando;

  (String, String) get _textos => switch (_etapa) {
    _Etapa.semVersao => ('Nada publicado', 'Nenhuma versão na VPS ainda (infra/scripts/publicar_app).'),
    _Etapa.emDia => ('Tudo em dia', 'Você já está na versão mais nova, de ${_rotulo(buildAtual)}.'),
    _Etapa.oferta => (
      'Nova versão disponível',
      'Publicada em ${_rotulo(widget.publicado)}${buildAtual == 0 ? ' (este é um build de desenvolvimento)' : ''}.',
    ),
    _Etapa.baixando => ('Baixando…', 'A versão nova está chegando. Pode deixar o app aberto.'),
    _Etapa.instalando => ('Instalando…', 'Preparando a versão nova.'),
    _Etapa.confirme => ('Quase lá!', 'Confirme a instalação na janela do Android. O app reabre atualizado.'),
    _Etapa.erro => ('Não deu certo', _erro ?? 'Falhou.'),
  };

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final (titulo, detalhe) = _textos;
    return Center(
      child: Material(
        color: tema.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Emblema(etapa: _etapa, progresso: _progresso),
                const SizedBox(height: 20),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  transitionBuilder: (filho, a) => FadeTransition(
                    opacity: a,
                    child: SlideTransition(position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(a), child: filho),
                  ),
                  child: Column(
                    key: ValueKey(_etapa),
                    children: [
                      Text(titulo, style: tema.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                      const SizedBox(height: 6),
                      Text(
                        detalhe,
                        textAlign: TextAlign.center,
                        style: tema.textTheme.bodyMedium?.copyWith(
                          color: _etapa == _Etapa.erro ? tema.colorScheme.error : tema.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  child: _etapa == _Etapa.baixando
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: TweenAnimationBuilder<double>(
                              tween: Tween(end: _progresso),
                              duration: const Duration(milliseconds: 300),
                              builder: (_, v, _) => LinearProgressIndicator(value: v, minHeight: 8, color: _anil),
                            ),
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: _rodando ? null : () => Navigator.pop(context),
                      child: Text(_etapa == _Etapa.oferta ? 'Depois' : 'Fechar'),
                    ),
                    if (widget.publicado > 0 && !_rodando && _etapa != _Etapa.confirme)
                      FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: _azul, foregroundColor: Colors.white),
                        onPressed: _atualizar,
                        icon: Icon(_etapa == _Etapa.erro ? Icons.refresh : Icons.system_update),
                        label: Text(switch (_etapa) {
                          _Etapa.erro => 'Tentar de novo',
                          _Etapa.oferta => 'Atualizar agora',
                          _ => 'Reinstalar',
                        }),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _ir(_Etapa e, {double? progresso, String? erro}) {
    if (!mounted) return;
    setState(() {
      _etapa = e;
      if (progresso != null) _progresso = progresso;
      _erro = erro;
    });
  }

  Future<void> _atualizar() async {
    _ir(_Etapa.baixando, progresso: 0);
    try {
      if (Platform.isAndroid) {
        await _android();
      } else {
        await _linux();
      }
    } catch (e) {
      _ir(_Etapa.erro, erro: 'Falhou: $e');
    }
  }

  /// Baixa o APK e abre o instalador do Android (que pede confirmação; mesma assinatura do instalado).
  Future<void> _android() async {
    final url = widget.api.url('api/atualizacoes/android').toString();
    await for (final ev in OtaUpdate().execute(url, headers: widget.api.cabecalhos, destinationFilename: 'agent.apk')) {
      switch (ev.status) {
        case OtaStatus.DOWNLOADING:
          final pct = double.tryParse(ev.value ?? '') ?? 0;
          _ir(_Etapa.baixando, progresso: pct / 100);
        case OtaStatus.INSTALLING:
        case OtaStatus.INSTALLATION_DONE:
          _ir(_Etapa.confirme, progresso: 1);
        default:
          _ir(_Etapa.erro, erro: 'Falhou (${ev.status.name}): ${ev.value ?? ''}');
      }
    }
  }

  /// Baixa o agent-linux.tar.gz, roda o instalar.sh dele (~/.local/opt/agent) e reabre o app novo.
  Future<void> _linux() async {
    final tmp = await Directory.systemTemp.createTemp('agent-atualizacao');
    final pacote = File('${tmp.path}/agent-linux.tar.gz');
    final cliente = HttpClient();
    try {
      final pedido = await cliente.getUrl(widget.api.url('api/atualizacoes/linux'));
      widget.api.cabecalhos.forEach(pedido.headers.set);
      final resp = await pedido.close();
      if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
      final total = resp.contentLength;
      var feito = 0;
      final saida = pacote.openWrite();
      await for (final bloco in resp) {
        saida.add(bloco);
        feito += bloco.length;
        if (total > 0) _ir(_Etapa.baixando, progresso: feito / total);
      }
      await saida.close();
    } finally {
      cliente.close();
    }
    _ir(_Etapa.instalando, progresso: 1);
    final tar = await Process.run('tar', ['-xzf', pacote.path, '-C', tmp.path]);
    if (tar.exitCode != 0) throw 'tar: ${tar.stderr}';
    final inst = await Process.run('bash', ['${tmp.path}/agent/instalar.sh']);
    if (inst.exitCode != 0) throw 'instalar.sh: ${inst.stderr}';
    await tmp.delete(recursive: true);
    final novo = '${Platform.environment['HOME']}/.local/opt/agent/agent';
    _ir(_Etapa.confirme, progresso: 1);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await Process.start(novo, const [], mode: ProcessStartMode.detached);
    exit(0);
  }
}

/// Emblema animado do diálogo: logo com halo girando (oferta), anel em gradiente com a porcentagem
/// (baixando), arco girando (instalando), ✓ desenhado (confirme/em dia) e tremida no erro.
class _Emblema extends StatefulWidget {
  const _Emblema({required this.etapa, required this.progresso});

  final _Etapa etapa;
  final double progresso;

  @override
  State<_Emblema> createState() => _EmblemaState();
}

class _EmblemaState extends State<_Emblema> with TickerProviderStateMixin {
  late final _giro = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  late final _check = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  late final _tremor = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));

  @override
  void initState() {
    super.initState();
    _aoMudar();
  }

  @override
  void didUpdateWidget(_Emblema antigo) {
    super.didUpdateWidget(antigo);
    if (antigo.etapa != widget.etapa) _aoMudar();
  }

  void _aoMudar() {
    if (widget.etapa == _Etapa.confirme || widget.etapa == _Etapa.emDia) _check.forward(from: 0);
    if (widget.etapa == _Etapa.erro) _tremor.forward(from: 0);
  }

  @override
  void dispose() {
    _giro.dispose();
    _check.dispose();
    _tremor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trilho = Theme.of(context).colorScheme.surfaceContainerHighest;
    final erro = Theme.of(context).colorScheme.error;
    final logo = Image.asset('assets/logo.png', package: 'agent_core', width: 64, height: 64);
    return SizedBox(
      width: 132,
      height: 132,
      child: AnimatedBuilder(
        animation: Listenable.merge([_giro, _check, _tremor]),
        builder: (context, _) {
          final e = widget.etapa;
          final dx = math.sin(_tremor.value * math.pi * 6) * 10 * (1 - _tremor.value);
          return Transform.translate(
            offset: Offset(dx, 0),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (e == _Etapa.baixando)
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: widget.progresso),
                    duration: const Duration(milliseconds: 300),
                    builder: (_, v, _) => CustomPaint(size: const Size.square(132), painter: _Anel(trilho, v, 0)),
                  )
                else if (e == _Etapa.oferta || e == _Etapa.instalando)
                  CustomPaint(
                    size: const Size.square(132),
                    painter: _Anel(
                      trilho,
                      e == _Etapa.oferta ? 0.3 : 0.15 + 0.5 * (0.5 + 0.5 * math.sin(_giro.value * 2 * math.pi)),
                      _giro.value,
                    ),
                  )
                else if (e == _Etapa.confirme || e == _Etapa.emDia)
                  CustomPaint(size: const Size.square(132), painter: _Anel(trilho, 1, 0)),
                if (e == _Etapa.baixando)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Opacity(opacity: 0.85, child: Image.asset('assets/logo.png', package: 'agent_core', width: 36, height: 36)),
                      const SizedBox(height: 4),
                      TweenAnimationBuilder<double>(
                        tween: Tween(end: widget.progresso * 100),
                        duration: const Duration(milliseconds: 300),
                        builder: (_, v, _) => Text(
                          '${v.toStringAsFixed(0)}%',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  )
                else if (e == _Etapa.confirme || e == _Etapa.emDia)
                  Transform.scale(
                    scale: Curves.elasticOut.transform(_check.value.clamp(0, 1)),
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: [_azul, _roxo], begin: Alignment.topLeft, end: Alignment.bottomRight),
                      ),
                      child: CustomPaint(painter: _Check(Curves.easeOut.transform(((_check.value - 0.25) / 0.75).clamp(0, 1)))),
                    ),
                  )
                else if (e == _Etapa.erro)
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: erro.withValues(alpha: 0.15)),
                    child: Icon(Icons.close_rounded, size: 40, color: erro),
                  )
                else
                  Transform.scale(scale: e == _Etapa.oferta ? 1 + 0.05 * math.sin(_giro.value * 2 * math.pi) : 1, child: logo),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Anel em gradiente da marca: [fracao] do círculo, girado por [giro] (0 a 1 = uma volta).
class _Anel extends CustomPainter {
  _Anel(this.trilho, this.fracao, this.giro);

  final Color trilho;
  final double fracao;
  final double giro;

  @override
  void paint(Canvas canvas, Size size) {
    const espessura = 9.0;
    final r = Rect.fromLTWH(espessura / 2, espessura / 2, size.width - espessura, size.height - espessura);
    canvas.drawArc(r, 0, 2 * math.pi, false, Paint()
      ..color = trilho
      ..style = PaintingStyle.stroke
      ..strokeWidth = espessura);
    if (fracao <= 0) return;
    final inicio = -math.pi / 2 + giro * 2 * math.pi;
    canvas.drawArc(
      r,
      inicio,
      2 * math.pi * fracao.clamp(0, 1),
      false,
      Paint()
        ..shader = SweepGradient(colors: _gradiente, transform: GradientRotation(inicio)).createShader(r)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = espessura,
    );
  }

  @override
  bool shouldRepaint(_Anel a) => a.fracao != fracao || a.giro != giro || a.trilho != trilho;
}

/// ✓ branco desenhado aos poucos ([t] de 0 a 1): primeiro a perna curta, depois a longa.
class _Check extends CustomPainter {
  _Check(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0) return;
    final w = size.width;
    final a = Offset(w * 0.28, w * 0.52);
    final b = Offset(w * 0.44, w * 0.68);
    final c = Offset(w * 0.74, w * 0.36);
    final l1 = (b - a).distance;
    final l2 = (c - b).distance;
    final feito = t * (l1 + l2);
    final caminho = Path()..moveTo(a.dx, a.dy);
    if (feito <= l1) {
      final p = a + (b - a) * (feito / l1);
      caminho.lineTo(p.dx, p.dy);
    } else {
      caminho.lineTo(b.dx, b.dy);
      final p = b + (c - b) * ((feito - l1) / l2);
      caminho.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(caminho, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.09
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_Check a) => a.t != t;
}

/// Comemoração na primeira abertura depois de atualizar: o ✓ cresce com mola, faíscas nas cores da
/// marca saem do centro e a mensagem sobe; fecha sozinha em 4 s (ou no toque).
class _DialogoAtualizado extends StatefulWidget {
  const _DialogoAtualizado({required this.build});

  final int build;

  @override
  State<_DialogoAtualizado> createState() => _DialogoAtualizadoState();
}

class _DialogoAtualizadoState extends State<_DialogoAtualizado> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..forward();

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(seconds: 4), () {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Center(
        child: Material(
          color: tema.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
          child: SizedBox(
            width: 300,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  final v = _c.value;
                  final selo = Curves.elasticOut.transform((v / 0.6).clamp(0, 1));
                  final traco = Curves.easeOut.transform(((v - 0.2) / 0.35).clamp(0, 1));
                  final faisca = Curves.easeOut.transform(((v - 0.15) / 0.75).clamp(0, 1));
                  final texto = Curves.easeOut.transform(((v - 0.45) / 0.4).clamp(0, 1));
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 160,
                        height: 140,
                        child: CustomPaint(
                          painter: _Faiscas(faisca),
                          child: Center(
                            child: Transform.scale(
                              scale: selo,
                              child: Container(
                                width: 84,
                                height: 84,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: const LinearGradient(colors: [_azul, _roxo], begin: Alignment.topLeft, end: Alignment.bottomRight),
                                  boxShadow: [BoxShadow(color: _anil.withValues(alpha: 0.5), blurRadius: 24 * selo.clamp(0, 1))],
                                ),
                                child: CustomPaint(painter: _Check(traco)),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Opacity(
                        opacity: texto,
                        child: Transform.translate(
                          offset: Offset(0, 12 * (1 - texto)),
                          child: Column(
                            children: [
                              Text('Atualizado!', style: tema.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 6),
                              Text(
                                'Você está na versão de ${_rotulo(widget.build)}.',
                                textAlign: TextAlign.center,
                                style: tema.textTheme.bodyMedium?.copyWith(color: tema.colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Faíscas que saem do centro em duas voltas e somem ([t] de 0 a 1).
class _Faiscas extends CustomPainter {
  _Faiscas(this.t);

  final double t;
  static const _cores = [_azul, _anil, _roxo, Color(0xFF4FC3F7), Color(0xFF5BD69B), Color(0xFFFFB547)];

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final c = size.center(Offset.zero);
    for (var k = 0; k < 18; k++) {
      final ang = k * 2 * math.pi / 18 + (k.isOdd ? 0.17 : 0);
      final dist = 40 + t * (k.isOdd ? 34 : 56);
      final p = c + Offset(math.cos(ang), math.sin(ang)) * dist;
      canvas.drawCircle(p, (1 - t) * 4 + 1, Paint()..color = _cores[k % _cores.length].withValues(alpha: 1 - t));
    }
  }

  @override
  bool shouldRepaint(_Faiscas a) => a.t != t;
}
