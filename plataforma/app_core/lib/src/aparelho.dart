import 'api.dart';
import 'tarefas.dart';

import 'aparelho_web.dart' if (dart.library.io) 'aparelho_io.dart' as impl;

/// Arquivos guardados no aparelho (pasta `Agent` dos documentos do app). Na web não há disco:
/// [discoDisponivel] é falso e o resto não deve ser chamado.
bool get discoDisponivel => impl.discoDisponivel;

/// Caminho do arquivo [nome] se ele já foi baixado por inteiro; senão nulo.
Future<String?> caminhoNoAparelho(String nome) => impl.caminhoNoAparelho(nome);

/// Baixa [caminho] (relativo à API ou URL absoluta) em pedaços para o arquivo [nome], continuando de
/// onde parou se um download anterior caiu no meio. O progresso vai para a [tarefa].
Future<String> baixarParaAparelho(ApiCliente api, String caminho, String nome, {TarefaFundo? tarefa}) =>
    impl.baixarParaAparelho(api, caminho, nome, tarefa: tarefa);
