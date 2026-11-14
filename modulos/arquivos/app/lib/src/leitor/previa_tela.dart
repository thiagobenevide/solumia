import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../api_arquivos.dart';
import '../telas/acoes_destaque.dart';
import 'leitor_tela.dart';

/// Prévia de um PDF que ainda não está no Arquivos (ex.: documento da CVM). "Salvar" guarda em
/// [pasta], deixa no aparelho e troca a prévia pelo leitor (grifar e anotar).
Future<void> abrirPrevia(BuildContext context, ApiArquivos api, String nome, Uint8List pdf, {String pasta = ''}) =>
    abrirTela<void>(context, (_) => PreviaTela(api: api, nome: nome, pdf: pdf, pasta: pasta));

class PreviaTela extends StatefulWidget {
  const PreviaTela({super.key, required this.api, required this.nome, required this.pdf, this.pasta = ''});

  final ApiArquivos api;
  final String nome;
  final Uint8List pdf;
  final String pasta;

  @override
  State<PreviaTela> createState() => _PreviaTelaState();
}

class _PreviaTelaState extends State<PreviaTela> {
  bool _salvando = false;

  Future<void> _salvar() async {
    setState(() => _salvando = true);
    try {
      final (a, _) = await widget.api.enviar(widget.nome, widget.pdf, pasta: widget.pasta);
      await widget.api.offline.baixar(a, pdf: widget.pdf);
      if (!mounted) return;
      avisar(context, 'Salvo em Arquivos › ${widget.pasta.isEmpty ? 'raiz' : widget.pasta}.');
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => LeitorTela(api: widget.api, arquivo: a)),
      );
    } on ApiErro catch (e) {
      if (mounted) avisar(context, 'Não consegui salvar: ${e.mensagem}');
    } finally {
      if (mounted) setState(() => _salvando = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.nome, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton.icon(
            onPressed: _salvando ? null : _salvar,
            icon: _salvando
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_alt),
            label: const Text('Salvar'),
          ),
        ),
      ],
    ),
    body: PdfViewer.data(widget.pdf, sourceName: widget.nome),
  );
}
