# Empreendimento Flutter app

Video production screens, mounted by the platform (`business_module.dart` → `plataforma/app/lib/modulos.dart`).
Talks to the esteira JSON API (`modulos/empreendimento/esteira/esteira/web/api.py`, `/api/v1`, port 8765).

## Map (look here before opening a file)

- `lib/src/api_esteira.dart`: one method per API route (`grep -n 'Future' ` lists them all). New route: method
  here + route in `web/api.py` (`grep -n '@router' web/api.py`).
- `lib/src/models.dart`: `fromJson` of the types (Channel, Script, EpisodeSummary, Episode…). Test in `test/models_test.dart`.
- `lib/src/screens/business_screen.dart`: top tabs → `production_tab`, `scripts_tab`, `queue_tab`,
  `monitor_tab` (+ `graph.dart`, `time_series.dart`), `processes_tab` (+ `ProcessScreen`), `library_tab`, `costs_tab`,
  `factory_tab` (live factory panel: Claude ideas → local LLM N1 → gate → review → library, thumbnails),
  `dataset_tab` (Craft Apps dataset, adapters and backup), `options_tab`.
- `lib/src/screens/episode/episode_screen.dart`: episode tabs → `general_tab`, `script_tab`, `cuts_tab`,
  `scenes_tab`, `graphics_tab`, `thumbs_tab`, `final_video`.
- `lib/src/screens/editor/`: graphics/thumbnail editor (`editor_screen.dart` is the largest file, ~950 lines: read
  it in parts; `fields.dart` are the form fields).
- `lib/src/studio/`: Studio (motion graphics pieces, styles, factory, production): `studio_tab`, `style_screen` +
  `style_tabs` (part file), `factory_screen`, `production_screen`, `piece_preview`, `library_screen`, `cut_screen`,
  `marking_screen`, `timeline`, `system`.
- `lib/src/youtube/`: **Channels** tab (management of the 5 channels) → `youtube_tab` → `channel_screen` (Management +
  one tab per collection) → `item_screen`; `form.dart` builds the form from the schema. Talks to the platform
  backend `/api/youtube` (`youtube_api.dart`; backend in `modulos/empreendimento/youtube/`, vault notes).
- `lib/src/jobs/`: **Jobs** section → `jobs_screen` (+ `jobs_map`), `resumes_screen`; `jobs_api.dart` talks to
  `/api/vagas`.
- `lib/src/recording/`: **Recording** page (Capture group) → `recording_tab` (Camera | Studio). Android:
  `phone_camera_screen` + `camera_pro.dart` (Kotlin channel `plataforma/app/android/.../recording/`: Camera2 +
  MediaCodec → TCP and local MP4). PC: `receiver_screen` + `receiver.dart` (ffmpeg records the take and remuxes to MOV,
  UDP preview, copy to the Studio, v4l2loopback); protocol and ffmpeg args in `protocol.dart` (test
  `test/recording_protocol_test.dart`). Studio: `capture_studio_screen` (+ `studio_item_panel` format/mask/
  framing, `studio_sources_panel` sources/mixer) + `capture_api.dart` → GStreamer engine
  `modulos/empreendimento/capture` (`python -m capture`, API 127.0.0.1:5620; `model.py` pure and tested,
  `engine.py` pipeline, `overlay.py` drawing, `face.py` face, `api.py` routes; venv: `infra/scripts/install_capture`).
- `lib/src/screens/util.dart`: shared widgets and formatting — check here before writing a new helper.
- Shared core (`plataforma/app_core/lib/src/`): `api.dart` (HTTP), `sondagem.dart` (polling), `tema.dart`.

Validate: `infra/scripts/verificar modulos/empreendimento/app` (at the repository root).
