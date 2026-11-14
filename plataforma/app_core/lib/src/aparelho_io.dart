import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'tarefas.dart';

const discoDisponivel = true;

Future<File> _arquivo(String nome) async => File('${(await getApplicationDocumentsDirectory()).path}/Agent/$nome');

Future<String?> caminhoNoAparelho(String nome) async {
  final f = await _arquivo(nome);
  return await f.exists() ? f.path : null;
}

Future<String> baixarParaAparelho(ApiCliente api, String caminho, String nome, {TarefaFundo? tarefa}) async {
  final destino = await _arquivo(nome);
  await destino.parent.create(recursive: true);
  // `.parte` cresce pedaço a pedaço; só vira o arquivo final quando chega inteiro.
  final parte = File('${destino.path}.parte');
  final inicio = await parte.exists() ? await parte.length() : 0;
  final saida = await parte.open(mode: FileMode.append);
  try {
    await api.getEmPartes(
      caminho,
      saida.writeFrom,
      inicio: inicio,
      progresso: tarefa?.bytes,
      cancelado: () => tarefa?.cancelada ?? false,
    );
  } finally {
    await saida.close();
  }
  await parte.rename(destino.path);
  return destino.path;
}
