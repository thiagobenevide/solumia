import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../util.dart';

/// "Baixar" e "Enviar edição" de um arquivo de editor, para editar em qualquer máquina: baixa o arquivo
/// (com a mídia que ele usa) e, depois de salvo lá, envia de volta sobrescrevendo o do episódio.
class EdicaoRemota extends StatelessWidget {
  const EdicaoRemota({
    super.key,
    required this.url,
    required this.extensoes,
    required this.enviar,
    required this.feito,
    this.depois,
  });

  final String url;

  /// Extensões aceitas no envio, além de `zip` (o pacote baixado, recompactado).
  final List<String> extensoes;
  final Future<int> Function(String nome, List<int> bytes) enviar;

  /// Aviso depois do envio (o que acontece agora com o arquivo).
  final String feito;
  final VoidCallback? depois;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    children: [
      TextButton.icon(
        onPressed: () => abrirUrl(context, url),
        icon: const Icon(Icons.download, size: 18),
        label: const Text('Baixar'),
      ),
      TextButton.icon(
        onPressed: () => _enviar(context),
        icon: const Icon(Icons.upload, size: 18),
        label: const Text('Enviar edição'),
      ),
    ],
  );

  Future<void> _enviar(BuildContext context) async {
    final arquivos = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: [...extensoes, 'zip']);
    if (arquivos.isEmpty || !context.mounted) return;
    final a = arquivos.first;
    final confirmou = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Sobrescrever?'),
        content: Text('"${a.name}" substitui o arquivo atual do episódio (o atual fica guardado em log/envios/).'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sobrescrever')),
        ],
      ),
    );
    if (confirmou != true || !context.mounted) return;
    await acaoComAviso(context, () async {
      final faltando = await enviar(a.name, await a.xFile.readAsBytes());
      return faltando == 0 ? feito : '$feito Atenção: $faltando mídia(s) não achada(s) no episódio.';
    });
    depois?.call();
  }
}
