import 'package:flutter/material.dart';

/// Animações presas à rolagem (não a tempo): o conteúdo vai se formando conforme a pessoa explora
/// a tela e volta ao estado anterior se ela rolar de volta.

/// Mede onde o widget está dentro da área visível do [Scrollable] mais próximo e chama
/// [aoMedir] com a posição do topo (px, relativa ao topo da área) e a altura da área.
mixin _MedeRolagem<T extends StatefulWidget> on State<T> {
  ScrollPosition? _posicao;

  void aoMedir(double topo, double alturaArea);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nova = Scrollable.maybeOf(context)?.position;
    if (nova == _posicao) return;
    _posicao?.removeListener(_medir);
    _posicao = nova;
    _posicao?.addListener(_medir);
    WidgetsBinding.instance.addPostFrameCallback((_) => _medir());
  }

  void _medir() {
    if (!mounted) return;
    final caixa = context.findRenderObject();
    final area = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (caixa is! RenderBox || area is! RenderBox || !caixa.attached || !area.attached) return;
    final topo = caixa.localToGlobal(Offset.zero, ancestor: area).dy;
    aoMedir(topo, area.size.height);
  }

  @override
  void dispose() {
    _posicao?.removeListener(_medir);
    super.dispose();
  }
}

/// O bloco surge (opacidade, sobe e cresce um pouco) enquanto entra pela parte de baixo da tela.
/// Fora de uma rolagem, ou com "reduzir animações", aparece direto.
class RevelarAoRolar extends StatefulWidget {
  const RevelarAoRolar({super.key, required this.child, this.distancia = 48});

  final Widget child;

  /// Quanto o bloco sobe enquanto aparece.
  final double distancia;

  @override
  State<RevelarAoRolar> createState() => _RevelarAoRolarState();
}

class _RevelarAoRolarState extends State<RevelarAoRolar> with _MedeRolagem {
  double _p = 1;

  @override
  void aoMedir(double topo, double alturaArea) {
    // começa ao entrar pela borda de baixo e termina depois de subir 30% da área
    final p = ((alturaArea - topo) / (alturaArea * 0.30)).clamp(0.0, 1.0);
    if ((p - _p).abs() > 0.004) setState(() => _p = p);
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return widget.child;
    final p = Curves.easeOutCubic.transform(_p);
    return Opacity(
      opacity: p,
      child: Transform.translate(
        offset: Offset(0, widget.distancia * (1 - p)),
        child: Transform.scale(scale: 0.94 + 0.06 * p, child: widget.child),
      ),
    );
  }
}

/// Cabeçalho que a rolagem atravessa: ao rolar para baixo ele cresce, desce mais devagar que o
/// resto (paralaxe) e esmaece, como a câmera passando por ele.
class ZoomAoRolar extends StatefulWidget {
  const ZoomAoRolar({super.key, required this.child, this.zoom = 0.18});

  final Widget child;

  /// Quanto cresce até sair da tela (0.18 = 18%).
  final double zoom;

  @override
  State<ZoomAoRolar> createState() => _ZoomAoRolarState();
}

class _ZoomAoRolarState extends State<ZoomAoRolar> with _MedeRolagem {
  double _p = 0;
  double _subiu = 0;

  @override
  void aoMedir(double topo, double alturaArea) {
    final altura = (context.size?.height ?? 200).clamp(80.0, 600.0);
    final subiu = (-topo).clamp(0.0, altura);
    final p = subiu / altura;
    if ((p - _p).abs() > 0.004) {
      setState(() {
        _p = p;
        _subiu = subiu;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return widget.child;
    return Transform.translate(
      offset: Offset(0, _subiu * 0.45),
      child: Opacity(
        opacity: 1 - 0.75 * _p,
        child: Transform.scale(scale: 1 + widget.zoom * _p, child: widget.child),
      ),
    );
  }
}
