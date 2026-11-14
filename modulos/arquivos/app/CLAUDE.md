# App Flutter de arquivos

Biblioteca + leitor PDF com anotação à tinta. Fala com `/api/arquivos` (ver `../README.md`).

## Mapa

- `lib/src/api_arquivos.dart`: um método por rota; `criarNota` usa `/api/notas`.
- `lib/src/offline.dart`: `AcervoOffline` (`api.offline`): arquivos baixados (PDF + original + anotações + meta no `Armazem`
  do `agent_core`) e `FilaOffline` de editar/excluir/enviar feitos sem conexão; `sincronizar` sobe tudo.
- `lib/src/modelos.dart`: `Arquivo`, `Traco`/`Destaque`/`TextoAnotado` (pontos PDF da página exibida, página 0-based)
  e `Anotacoes` (imutável; `mesclar` resolve conflito entre aparelhos). Teste em `test/anotacoes_test.dart`.
- `lib/src/telas/biblioteca_tela.dart`: abas Arquivos (grade, upload, pastas, menu) e `destaques_aba.dart`.
  `acoes_destaque.dart`: copiar referência, criar nota, comentar, traduzir, projetos.
  `projetos_leitura.dart`: projetos de leitura de Estudos (`projetosAtivos` carimba o que o `Anotador` cria;
  chips por destaque; tradução pela LLM local, objetivo `traduzir`).
- `lib/src/leitor/`: `leitor_tela.dart` (PdfViewer do `pdfrx` + barra), `camada_pagina.dart` (overlay por página:
  reconhecedor que ganha o gesto só para caneta/dispositivos permitidos, marca-texto inteligente),
  `estojo.dart` (ferramenta, cor e espessura por ferramenta), `pintura.dart` (pincéis), `geometria.dart`
  (retas, borracha, seleção de texto), `anotador.dart` (desfazer, autosalvar, mescla) (seletor de cor vem do `agent_core`).
  `diagramacao.dart`: `diagramar` (retângulos dos caracteres → `Bloco`s na ordem de leitura, com corpo, alinhamento e
  recuo) e `segmentar` (frases com índices dos caracteres). `traducao.dart`: `TradutorDocumento` (o documento todo, a
  partir da página na tela, cache em `/traducao`) e `PainelTraducao` (parágrafos como no PDF; selecionar o português
  marca as frases em inglês: destaque com `traducao`, no projeto ativo). `traducao_pagina.dart`: modo "Sobre a página"
  (`CamadaTraducao` pinta o português no lugar de cada bloco; `BarraTraducao`). Teste em `test/traducao_test.dart`.
  `leitura_guiada.dart`: `LeituraGuiada` (voz do worker frase a frase, palavra dita marcada pelo tempo de
  `/api/estudos/linguagem/fala`; tocar/segurar e arrastar traduz pela LLM local; "Criar tarefas" manda ao caderno
  de vocabulário; microfone grava a pessoa lendo e avalia) e `CamadaLeitura` (overlay por página, só com ela ligada).
  `leitura_guiada_barra.dart`: barra flutuante e cartão da tradução. `palavrasDe` corta as palavras como
  `shared/linguagem.py`. Teste em `test/leitura_guiada_test.dart`.
  `dados_tela.dart`: `CsvTela` (grade editável) e `XmlTela` (árvore + texto editável); leem o original do aparelho
  ou do `/original` e salvam por `offline.salvarOriginal` (PUT `/original`; sem conexão, fila `substituir`).
  Teste em `test/dados_test.dart`.
- `lib/src/externo/`: "Abrir com…" (LibreOffice, WordCraft/DeckCraft/GridCraft/PDFCraft, padrão do sistema) numa
  cópia temporária vigiada; cada gravação lá sobe sozinha. Desktop só (stub na web).
- `lib/src/editores/`: `abrirArquivo` abre `.docx` em `documento_tela.dart` (Quill + `docx.dart`: revisões
  `rev_ins`/`rev_del` = `autor|data` ⇄ `w:ins`/`w:del`, comentários ⇄ `comments.xml`; o modo Revisor passa toda
  digitação por `onReplaceText`), `.xlsx` em `planilha_tela.dart` (`xlsx.dart`) e `.pptx` em `apresentacao_tela.dart`
  (`pptx.dart`). `exportar.dart`: menu de exportação (rota `/exportar`) e Delta → Markdown. Testes em `test/docx_test.dart`,
  `test/xlsx_test.dart`, `test/pptx_test.dart`.
- `lib/src/editores/reescrita.dart`: `reescreverComClaude` (objetivos, comentários do orientador, antes/depois com motivo);
  backend em `plataforma/backend/src/backend/arquivos/reescrita.py` + `shared/claude_code.py` (`claude -p`).
- `lib/src/editores/collabora_tela.dart`: Collabora (WOPI) em iframe (web), webview (Android/iOS/macOS) ou
  navegador (Linux/Windows).
- Filtro por formato na grade: `Formato` (em `modelos.dart`) agrupa extensões; `abrirArquivo` escolhe o visualizador.

`pdfrx` usa PDFium nativo: `flutter test`/build Linux precisam de `clang` (web e Android não).
Validar: `infra/scripts/verificar modulos/arquivos/app`.
