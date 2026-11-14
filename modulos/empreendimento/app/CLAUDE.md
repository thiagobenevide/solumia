# App Flutter do empreendimento

Telas da produção de vídeos, montadas pela plataforma (`modulo_empreendimento.dart` → `plataforma/app/lib/modulos.dart`).
Fala com a API JSON da esteira (`modulos/empreendimento/esteira/esteira/web/api.py`, `/api/v1`, porta 8765).

## Mapa (achar aqui antes de abrir arquivo)

- `lib/src/api_esteira.dart`: um método por rota da API (`grep -n 'Future' ` lista todos). Rota nova: método
  aqui + rota em `web/api.py` (`grep -n '@router' web/api.py`).
- `lib/src/modelos.dart`: `fromJson` dos tipos (Canal, Roteiro, EpisodioResumo, Episodio…). Teste em `test/modelos_test.dart`.
- `lib/src/telas/empreendimento_tela.dart`: abas de topo → `producao_aba`, `roteiros_aba`, `fila_aba`,
  `monitor_aba` (+ `grafo.dart`, `serie_temporal.dart`), `processos_aba` (+ `ProcessoTela`), `acervo_aba`, `custos_aba`,
  `fabrica_aba` (painel ao vivo da fábrica: ideias do Claude → N1 da LLM local → portão → revisão → acervo, thumbs),
  `dataset_aba` (dataset das Craft Apps, adaptadores e backup), `opcoes_aba`.
- `lib/src/telas/episodio/episodio_tela.dart`: abas do episódio → `geral_aba`, `roteiro_aba`, `cortes_aba`,
  `cenas_aba`, `graficos_aba`, `thumbs_aba`, `video_final`.
- `lib/src/telas/editor/`: editor de gráficos/thumbs (`editor_tela.dart` é o maior arquivo, ~730 linhas: ler
  por trecho; `campos.dart` são os campos do formulário).
- `lib/src/youtube/`: aba **Canais** (gerência dos 5 canais) → `youtube_aba` → `canal_tela` (Gerência + uma aba
  por coleção) → `item_tela`; `formulario.dart` monta o formulário pelo esquema. Fala com `/api/youtube` do backend
  da plataforma (`api_youtube.dart`; backend em `modulos/empreendimento/youtube/`, notas do cofre).
- `lib/src/recording/`: página **Gravação** (grupo Captura) → `recording_tab` (Câmera | Estúdio). Android:
  `phone_camera_screen` + `camera_pro.dart` (canal do Kotlin `plataforma/app/android/.../recording/`: Camera2 +
  MediaCodec → TCP e MP4 local). PC: `receiver_screen` + `receiver.dart` (ffmpeg grava o take e remuxa para MOV,
  prévia UDP, cópia para o Estúdio, v4l2loopback); protocolo e args do ffmpeg em `protocol.dart` (teste
  `test/recording_protocol_test.dart`). Estúdio: `capture_studio_screen` (+ `studio_item_panel` formato/máscara/
  enquadramento, `studio_sources_panel` fontes/mixer) + `capture_api.dart` → motor GStreamer
  `modulos/empreendimento/capture` (`python -m capture`, API 127.0.0.1:5620; `model.py` puro e testado,
  `engine.py` pipeline, `overlay.py` desenho, `face.py` rosto, `api.py` rotas; venv: `infra/scripts/install_capture`).
- `lib/src/telas/util.dart`: widgets e formatações comuns — conferir aqui antes de criar helper novo.
- Núcleo comum (`plataforma/app_core/lib/src/`): `api.dart` (HTTP), `sondagem.dart` (polling), `tema.dart`.

Validar: `infra/scripts/verificar modulos/empreendimento/app` (na raiz do repositório).
