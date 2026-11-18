/// Núcleo comum do app: o que todo módulo usa e nenhum módulo possui.
library;

export 'src/abas.dart';
export 'src/api.dart';
export 'src/aparelho.dart';
export 'src/armazem.dart' show Armazem, ArmazemMemoria;
export 'src/campo_markdown.dart';
export 'src/fila_offline.dart';
export 'src/filtros_recolhiveis.dart';
export 'src/imagem_rede.dart';
export 'src/login.dart';
export 'src/lotes.dart';
export 'src/markdown.dart';
export 'src/microfone.dart' show BotaoMicrofone, transcreverFala;
export 'src/microfone_web.dart' if (dart.library.io) 'src/microfone_io.dart';
export 'src/leitura_voz.dart';
export 'src/tocador.dart';
export 'src/modulo.dart';
export 'src/nome_usuario.dart';
export 'src/responsivo.dart';
export 'src/seletor_cor.dart';
export 'src/sondagem.dart';
export 'src/tarefas.dart';
export 'src/tema.dart';
export 'src/titulo_aba.dart';
export 'src/vidro.dart';
