# Health and Personal Development

Spiritual: Bible reading, reflection and theology. Physical: workouts in the mini-gym (punching bag, plates, bars) and performance tracking. Mental: habits, focus against procrastination, anxiety control and self-discipline.

## Layout

```
saude/
├── backend/   Python package: FastAPI API, models and rules (runs on the VPS)
├── worker/    heavy LLM/GPU jobs (runs on the GPU PC)
└── app/       Flutter package with the module screens
```

Each part only exists once there is code for it. The platform (`plataforma/`) registers the
backend router, dispatches the worker jobs and mounts the app screens.

## Physical (implemented)

- Backend: `backend/` (`agent-saude`, package `saude`), mounted at `/api/saude`. Data in `$AGENT_DATA/saude/`
  (`exercicios.json`, `agenda.json`, `imagens/`). Initial catalog of 50 exercises for the mini-gym
  (`catalogo.py`); the images come from [free-exercise-db](https://github.com/yuhonas/free-exercise-db) (public
  domain), downloaded the first time and cached. The punching bag ones get the user's photo.
- App: `app/` (`agent_saude`): day/week/month calendar + drill-down library (area → group →
  exercise) on the right on a wide screen and below on the phone. Drag with the mouse (PC) or long press (Android).

| Route | What |
|---|---|
| `GET/POST /api/saude/exercicios` | areas + catalog; creates an own exercise |
| `PATCH/DELETE /api/saude/exercicios/{id}` | edits; deletes (and removes it from the agenda) |
| `GET/POST/DELETE /api/saude/exercicios/{id}/imagem?n=0\|1` | photo (start/end of the movement); uploads (multipart `arquivo`); removes |
| `GET /api/saude/agenda?de=&ate=` | items in the period |
| `POST /api/saude/agenda` · `PATCH/DELETE /api/saude/agenda/{id}` | schedules an exercise on a day; changes day, order, sets, load, `feito` |
| `POST /api/saude/agenda/copiar` | repeats a day/week (`de`, `ate`, `destino`) |

## Workout guide (implemented)

**Treinar** button on the Workouts screen: builds the session with the day's pending exercises (the Day view one,
otherwise today) and guides it set by set — adjustable reps and load, timed rest (default 60 s;
pause, resume, ±15/30 s, skip), pause of the whole workout, undo set, skip or swap the exercise.
Next time it shows what was done before and suggests the load (double progression, `sessoes.sugestao`). When
finishing: effort 1–10, notes, marks the items as done in the agenda and reads the Galaxy Watch heart rate
through Health Connect (session interval). The session goes into the Analysis context.

In the background (Android, `aviso_treino.dart`): with the guide out of the foreground (Spotify, screen off,
guide closed) there is a pinned notification with the stage and the rest countdown and an exact alarm at the end
of the rest (`USE_EXACT_ALARM`, `flutter_local_notifications` receivers in the manifest). The alarm uses the
last state the phone saw: a change made on the watch while the phone is idle arrives on the next
sync.

The state (phase, rest, pause) lives on the server (`sessoes.py`, `$AGENT_DATA/saude/sessoes.json`) and only
changes through commands; the app rereads it every 5 s. That way the watch can control the same session through the same routes.

| Route | What |
|---|---|
| `POST /api/saude/sessoes` (`data`, `descanso_s`) · `GET …/ativa` · `GET …?de=&ate=` | starts (or returns the one in progress); active; history |
| `GET/PATCH/DELETE /api/saude/sessoes/{id}` | session (with the server's `agora`); notes, effort, `frequencia`; discards |
| `POST …/{id}/comando` (`acao`) | `concluir_serie`, `pausar`, `continuar`, `pular_descanso`, `somar_descanso`, `ir_para`, `pular_exercicio`, `desfazer_serie`, `editar_serie`, `descanso_padrao` |
| `POST …/{id}/concluir` | closes, stores the summary (duration, sets, volume) and marks the agenda |
| `POST …/{id}/fc` (`amostras: [{em, bpm}]`) | live heartbeats from the watch (empty batch = sign of life); returns `estado`, `frequencia`, `fc_atual`, `controle`, `atual` |

## Watch app (Galaxy Watch, Wear OS)

`wear/`: its own Gradle project (Kotlin + Compose for Wear, minSdk 30, no store; Kotlin package
`com.thiagobenevide.agent.watch`, applicationId kept as `com.thiagobenevide.agent.relogio`). Talks straight to the
backend (`url` + one `CLIENT_API_KEYS` key), using the phone's internet over Bluetooth or Wi‑Fi.
Install: `modulos/saude/wear/instalar <ip:port>` (Wi‑Fi debugging on the watch; asks for the key without echo).
Update: `publicar_app` also publishes `relogio.apk` (same build); the watch Home shows "Atualizar app" when there is a new build. The first time, Wear OS asks to allow the app to install apps.

- **Navigation**: pages side by side (Home, Workout, Coach, Agenda, Alerts), switched by swiping
  sideways, with a page indicator; Home has shortcut cards.
- **Workout**: the same session as the guide (`/api/saude/sessoes`), in a player panel: progress ring on the
  edge, ⏮ undoes the set, the center button marks the set (during rest, pause/resume), ⏭ skips the exercise
  or the rest, ± reps, +30 s; voice volume with the buttons or the crown (`Volume.kt`, level on the
  edge), vibration at the end of the rest, screen kept on during the workout.
- **Background workout** (`WorkoutService.kt`): foreground service (`health` type) with a
  Health Services exercise (MeasureClient if another app already has one), on while a workout is in
  progress — it keeps going with the screen off or another app in front. Vibrates at the end of the rest, shows
  stage, countdown and ♥ in the notification and on the watch face (ongoing activity) and stops on its own when the
  workout ends (also when finished on the phone). `BODY_SENSORS` permission, or `health.READ_HEART_RATE`
  on Wear OS 6. With the watch app closed and a workout started on the phone, the watcher tells you to open it.
- **Live heart rate**: shows on the watch and on the phone guide (`fc_atual`). Batches every 10 s to `POST …/sessoes/{id}/fc`;
  the server keeps the peak of every 5 s, computes `frequencia` (`origem: relogio`, which Health Connect does not
  overwrite) and, when finishing, the peak of each set (`fc_max`).
- **Coach**: voice conversation (`/api/painel/voz`, 16 kHz WAV recorded on the watch) and spoken answer
  (`/falar`, on/off); actions run by the agent show up in the answer.
- **Today's agenda** (tap marks it done) and **Alerts** (`/api/painel/disciplina`).
- **In the background** (`Warnings.kt`): every 15 min (WorkManager) the coach's new alerts become
  notifications (each once a day) and the day's blocks get an alarm at their start time, with the
  "Feito" button. If the phone app/ntfy also notifies on the watch, turn off their mirroring
  in Galaxy Wearable to avoid duplicates.
- **Sensors without touching anything** (`Passive.kt`): the app registers the Health Services passive sensor
  (`PassiveService`, redone at boot) and steps, calories, distance, floors and heartbeat (with the background
  permission) arrive with the app closed; the Body page measures live on its own while it is on screen.
  After an update that renames these classes, open the app once (or restart the watch) to register them again.
- Tests: `./gradlew -q -Pbuild=1 testDebugUnitTest` in `wear/` (`-Pbuild` is required: without it `findProperty("build")`
  returns Gradle's `build` task).

## Mental and Spiritual (implemented)

Same package and router (`api_bem_estar.py`); data in `$AGENT_DATA/saude/mental/` and `.../espiritual/`.

| Route | What |
|---|---|
| `GET/POST /api/saude/mental/habitos` · `PATCH/DELETE …/{id}` · `POST …/{id}/marcar` | habits to build/avoid, weekdays, `sequencia` |
| `GET/POST /api/saude/mental/foco` | focus sessions (pomodoro), minutes per day |
| `GET /api/saude/mental/diario?de=&ate=` · `PUT …/diario/{data}` | mood 1–5, anxiety 0–10, triggers, gratitude |
| `GET /api/saude/espiritual/escopos` · `GET/POST /api/saude/espiritual/planos` | Bible reading plans (66 books, chapters split into N days) |
| `GET …/planos/{id}/leituras?de=&ate=` · `POST …/planos/{id}/marcar` | each day's reading; days read and late |

Reflections and theology studies are vault notes (tags `reflexao`/`teologia`) created by the app.

## Sleep and body (Galaxy Watch) and Analysis

Samsung Health has no cloud API: the Android app reads **Health Connect** (`health` package;
Samsung Health has to be syncing with it) and sends a summary per day, on its own: when opening the
app and every hour in the background (`workmanager`, `app/lib/src/sincronizacao.dart`, last 3 days,
with the address and token of the session that scheduled it; requires the background read permission). The old history,
the stress and Samsung's sleep score (which do not go to Health Connect) come in through the zip from Samsung Health ›
Settings › Download personal data. Data in `$AGENT_DATA/saude/relogio/` (`dias.json`,
`analises.json`, `estado.json`); sleep counts on the day the person wakes up. The analysis uses **only the
local LLM** (`app.state.saude_llm`) and crosses it with journal, focus, habits, workouts and the
finance, routines and studies context (`app.state.saude_contexto`, built in `main.py`).
Without Samsung's score, `dias` returns ours (`relogio.pontuar_sono`, `sono_pontuacao_estimada`):
duration (goal 8 h), efficiency (awake in bed), deep (~18%) and REM (~20%), from 0 to 100.

| Route | What |
|---|---|
| `GET /api/saude/relogio/dias?de=&ate=` · `PUT …/dias` | stored days; the app sends the Health Connect ones (overwrites) |
| `GET /api/saude/relogio/resumo?de=&ate=` · `GET …/estado` | averages and goals met; last sync per source |
| `POST /api/saude/relogio/importar` | export zip (multipart `arquivo`); only fills what is missing |
| `GET/POST /api/saude/relogio/analises` | stored analyses (20); asks for a new one (`dias`, `pergunta`) |

App: the module has no top tabs; the sections live in the side submenu (Workouts, Spiritual, Sleep and
body, Analysis, Habits, Focus, Mood and anxiety). Android: `MainActivity` is a `FlutterFragmentActivity`,
`minSdk` 26 and `health.READ_*` permissions in the manifest.

## Usage (social media and content control on Android)

Submodule of the mental part to cut aimless use of social media, videos, shopping, news
and adult content on the **Android phone and tablets** (no iOS). Personal data: it stays on the PC/VPS
and the reading is done **only by the local LLM** (`app.state.saude_llm`), never by an external service. Searches are never
stored as text — the device matches the search against keywords and records **only the category**.
WhatsApp is exempt (work) and never goes into the rules. Backend in `backend/consumo.py` +
`api_consumo.py`, mounted at `/api/saude/consumo`; data in `$AGENT_DATA/saude/consumo/`
(`config.json`, `pendencias.json`, `dispositivos.json`, `uso/<dia>.json`, `analises.json`).

**24 h lock**: tightening a rule takes effect right away; loosening it (freeing a category, raising a limit, removing
hours, an app or a domain, turning protection off) only applies 24 h later (`pendencias.json`) and can be
cancelled before that. Categories: social media, videos, shopping, news, browsers, adult content,
VPN/bypass. Each one has a mode (free/limit/blocked), minutes per day and forbidden hours.

| Route | What |
|---|---|
| `GET /api/saude/consumo/config` | rules, own apps and domains, pending changes, categories |
| `PUT …/regras/{categoria}` | sets mode/limit/hours (loosening becomes a 24 h pending change) |
| `PUT …/apps` · `DELETE …/apps/{pacote}` | watch an app in a category; stop watching |
| `POST …/dominios/{cat}` · `DELETE …/dominios/{cat}/{dom}` | extra domain to block; remove |
| `PUT …/protecao` · `DELETE …/pendencias/{id}` | turns the shield on/off; cancels a pending change |
| `POST …/sincronizar` | the device sends usage/events and receives the rules built for it to apply |
| `GET …/dispositivos` · `GET …/resumo?de=&ate=` | devices and their state; usage per category/app/hour |
| `GET/POST …/analises` | stored "watcher" readings (20); asks for a new one (`dias`, `pergunta`) |

App: **Consumo** section in the Health side submenu (`telas/consumo_tela.dart`), with the rules, the
devices, the usage and the "watcher". On Android it only **reads usage** through the native plugin (`android/.../usage/`,
`UsagePlugin`, channel `agent/saude/consumo`, `app/lib/src/consumo_nativo.dart`): **UsageStats**
(`PACKAGE_USAGE_STATS`) gives time per app, launches and minutes per hour. There is no blocking on the device:
accessibility, local DNS VPN and device admin were removed because the bank app
started flagging agent as suspicious. The only permission is usage reading (`permissoes`/`pedir`).
Native code is not covered by `infra/scripts/verificar` (only
ruff/pytest/flutter analyze): it needs a build on the device.
