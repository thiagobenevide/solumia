import 'api.dart';
import 'tarefas.dart';

const discoDisponivel = false;

Future<String?> caminhoNoAparelho(String nome) async => null;

Future<String> baixarParaAparelho(ApiCliente api, String caminho, String nome, {TarefaFundo? tarefa}) =>
    throw UnsupportedError('Sem disco na web');
