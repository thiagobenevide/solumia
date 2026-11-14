# Public exams (Concursos)

Each exam is registered with its notice (PDF or link). Claude Code reads the notice and builds the knowledge flow
for the position: subjects, topics in the order they should be studied, hours, notice deadlines
and strategy. From that, a rule produces the task calendar up to 1 week before the exam.
Deadline alerts show up in the app and go out by push (Panel ntfy).

## Layout

```
concursos/
├── backend/   `agent-concursos` (package `concursos`) at `/api/concursos`; data in `$AGENT_DATA/concursos/<id>/`
└── app/       `agent_concursos`: List, New exam, and per exam the Today, Schedule, Flow and Deadlines tabs
```

- `plano_ia.py`: prompt, system and JSON schema of the request to Claude (`claude_json` worker task,
  `shared/claude_code.py`; without a worker, the PC's own `claude`; never the Anthropic API).
- `cronograma.py`: spreads the topics over the days (min/weekday and weekend), interleaving the
  subjects; Saturday trains the essay, Sunday reviews the week or runs a mock exam (every 2 weeks);
  what is left before the final week becomes review + questions; the final week is only light review and the day before.
  If time is short, it compresses the topics in the same proportion (`resumo_plano.fator`).
- `concursos.py`: storage, notice (pdftotext), replanning (done tasks stay, the rest goes from today
  on, without calling Claude again) and alerts (deadlines in the next 15 days, countdown to the
  exam, today's and late tasks).

Routes: `GET/POST /`, `GET /alertas`, `GET/PATCH/DELETE /{id}`, `POST /{id}/edital` (multipart),
`POST /{id}/edital/link`, `POST /{id}/plano` (202, in the background), `POST /{id}/replanejar`,
`PATCH /{id}/tarefas/{tid}`, `POST /{id}/prazos`, `DELETE /{id}/prazos/{pid}`.

## IT radar ("Radar TI · mapa" tab)

- `radar.py`: every `concursos_radar_horas` (6 h; the first collection 60 s after boot) reads the
  PCI Concursos listings (national + 5 regions), separates the IT ones by keyword and, for each new
  item with IT in the text, follows the official site it cites (the PCI PDFs sit behind a captcha) to find
  the notice, extracts the location/date/pay passages and asks the **local LLM** (worker, no
  reasoning) for IT positions/salaries, registration, exam date/time, exam cities and
  links. Up to 12 LLM calls per collection; the rest stays in the queue.
- `geo.py`: coordinates from the IBGE municipality list (downloaded once to
  `$AGENT_DATA/concursos/radar/`) and the driving route from the public OSRM (cache in `rotas/`; without it,
  straight line × 1.3 marked as an estimate). Origin: `concursos_origem_cidade/uf` (Custódia/PE).
- App: map (flutter_map, CARTO tiles) with you, the closest exam location of each exam
  (color by distance, number of IT positions on the pin), the headquarters and the drawn route with km and time;
  panel with positions, salaries, registration, exam, links and **Acompanhar** (pick the position → downloads the
  notice → Claude builds the flow; the radar sheet shows up in the exam).
- Routes: `GET /radar`, `POST /radar/atualizar`, `GET /radar/{id}/rota`, `POST /radar/{id}/acompanhar`.

## Mock exams and materials (exam tabs)

- `estudo.py` + `plano_ia.SISTEMA_SIMULADO`: Claude creates new questions in the exam board's style, in the
  notice's proportion (or for one subject), preferring topics already studied; answer key and
  commentary only come back after submitting; performance per subject against the notice's 60%.
- Materials: web search (`Internet.buscar_web`, DuckDuckGo) for past exams, questions,
  handouts and videos; the local LLM classifies and discards the useless ones (only links the search returned).
- Routes: `GET/POST /{id}/simulados`, `POST /{id}/simulados/{sid}/respostas`,
  `DELETE /{id}/simulados/{sid}`, `GET /{id}/materiais`, `POST /{id}/materiais/buscar`.
