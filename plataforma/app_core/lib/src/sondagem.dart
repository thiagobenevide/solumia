import 'dart:async';

import 'package:flutter/material.dart';

/// Carrega [carregar] agora e a cada [intervalo], e constrói com o último resultado. Se uma
/// atualização falhar, mantém os dados anteriores na tela com um aviso de conexão no topo.
class Sondagem<T> extends StatefulWidget {
  const Sondagem({
    super.key,
    required this.carregar,
    required this.construir,
    this.intervalo = const Duration(seconds: 3),
  });

  final Future<T> Function() carregar;
  final Widget Function(BuildContext context, T dados, Future<void> Function() recarregar) construir;
  final Duration intervalo;

  @override
  State<Sondagem<T>> createState() => _SondagemState<T>();
}

class _SondagemState<T> extends State<Sondagem<T>> {
  T? _dados;
  Object? _erro;
  bool _ocupado = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _recarregar();
    _timer = Timer.periodic(widget.intervalo, (_) => _recarregar());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _recarregar() async {
    if (_ocupado) return;
    _ocupado = true;
    try {
      final dados = await widget.carregar();
      if (mounted) {
        setState(() {
          _dados = dados;
          _erro = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _erro = e);
    } finally {
      _ocupado = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final dados = _dados;
    if (dados == null) {
      return _erro == null
          ? const Center(child: CircularProgressIndicator())
          : ErroComRetry(erro: _erro!, tentar: _recarregar);
    }
    return Column(
      children: [
        if (_erro != null)
          MaterialBanner(
            content: Text('Sem atualização: $_erro'),
            leading: const Icon(Icons.cloud_off),
            actions: [TextButton(onPressed: _recarregar, child: const Text('Tentar de novo'))],
          ),
        Expanded(child: widget.construir(context, dados, _recarregar)),
      ],
    );
  }
}

class ErroComRetry extends StatelessWidget {
  const ErroComRetry({super.key, required this.erro, required this.tentar});

  final Object erro;
  final VoidCallback tentar;

  @override
  // Rola quando a área é baixa (celular deitado, painel dividido).
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 48, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 12),
          Text('$erro', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: tentar, child: const Text('Tentar de novo')),
        ],
      ),
    ),
  );
}
