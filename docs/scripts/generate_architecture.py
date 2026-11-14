# ruff: noqa: E501  (box and arrow tables: one per line)
"""Generates docs/architecture.drawio: one tab per module, lanes (where it runs) × boxes (components) × arrows (data).

Usage (at the root): python3 docs/scripts/generate_architecture.py docs/architecture.drawio
When the architecture changes, edit the pages below and generate again (the .drawio file is not edited by hand)."""
import sys
from html import escape
from xml.sax.saxutils import quoteattr

STYLE = {
    "app": "rounded=1;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;align=left;spacingLeft=8;verticalAlign=top;spacingTop=4;",
    "api": "rounded=1;whiteSpace=wrap;html=1;fillColor=#d5e8d4;strokeColor=#82b366;align=left;spacingLeft=8;verticalAlign=top;spacingTop=4;",
    "pc": "rounded=1;whiteSpace=wrap;html=1;fillColor=#ffe6cc;strokeColor=#d79b00;align=left;spacingLeft=8;verticalAlign=top;spacingTop=4;",
    "ai": "rounded=1;whiteSpace=wrap;html=1;fillColor=#e1d5e7;strokeColor=#9673a6;align=left;spacingLeft=8;verticalAlign=top;spacingTop=4;",
    "data": "shape=cylinder3;whiteSpace=wrap;html=1;boundedLbl=1;backgroundOutline=1;size=10;fillColor=#fff2cc;strokeColor=#d6b656;align=left;spacingLeft=8;verticalAlign=top;spacingTop=12;",
    "ext": "rounded=1;whiteSpace=wrap;html=1;fillColor=#f5f5f5;strokeColor=#666666;fontColor=#333333;align=left;spacingLeft=8;verticalAlign=top;spacingTop=4;dashed=1;",
    "note": "shape=note;whiteSpace=wrap;html=1;size=14;fillColor=#fffbe6;strokeColor=#b3a369;align=left;spacingLeft=8;verticalAlign=top;spacingTop=6;",
}
LANE = "swimlane;startSize=28;html=1;fillColor=#f8f9fa;strokeColor=#adb5bd;fontStyle=1;horizontal=1;rounded=1;"
ARROW = "edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;endArrow=block;endFill=1;strokeColor=#495057;fontSize=10;labelBackgroundColor=#ffffff;"
WIDTH, GAP, X0, Y0, ROW_HEIGHT = 270, 40, 30, 90, 120


def label(title, lines):
    body = "<br>".join(escape(x) for x in lines)
    return f"<b>{escape(title)}</b>" + (f"<br><font style=\"font-size:10px\">{body}</font>" if lines else "")


def page(name, title, lanes, boxes, arrows, note=None):
    """lanes: [name]; boxes: [(id, lane, row, title, [lines], kind, height_in_rows=1)]; arrows: [(from, to, label)]"""
    cells = ['<mxCell id="0"/>', '<mxCell id="1" parent="0"/>']
    cells.append(f'<mxCell id="t" value={quoteattr(f"<b>{escape(title)}</b>")} style="text;html=1;fontSize=18;align=left;" '
                 f'vertex="1" parent="1"><mxGeometry x="{X0}" y="20" width="1400" height="40" as="geometry"/></mxCell>')
    rows = max(c[2] + (c[6] if len(c) > 6 else 1) for c in boxes)
    height = rows * ROW_HEIGHT + 50
    for i, r in enumerate(lanes):
        x = X0 + i * (WIDTH + GAP)
        cells.append(f'<mxCell id="r{i}" value={quoteattr(escape(r))} style="{LANE}" vertex="1" parent="1">'
                     f'<mxGeometry x="{x}" y="{Y0 - 30}" width="{WIDTH + 20}" height="{height}" as="geometry"/></mxCell>')
    for c in boxes:
        id_, lane, row, box_title, details, kind = c[:6]
        h = (c[6] if len(c) > 6 else 1) * ROW_HEIGHT - 25
        x = X0 + 10 + lanes.index(lane) * (WIDTH + GAP)
        y = Y0 + 10 + row * ROW_HEIGHT
        cells.append(f'<mxCell id="{id_}" value={quoteattr(label(box_title, details))} style="{STYLE[kind]}" vertex="1" parent="1">'
                     f'<mxGeometry x="{x}" y="{y}" width="{WIDTH}" height="{h}" as="geometry"/></mxCell>')
    for k, (a, b, txt) in enumerate(arrows):
        cells.append(f'<mxCell id="s{k}" value={quoteattr(escape(txt))} style="{ARROW}" edge="1" parent="1" source="{a}" '
                     f'target="{b}"><mxGeometry relative="1" as="geometry"/></mxCell>')
    if note:
        x = X0 + len(lanes) * (WIDTH + GAP)
        cells.append(f'<mxCell id="nota" value={quoteattr(label(note[0], note[1]))} style="{STYLE["note"]}" vertex="1" '
                     f'parent="1"><mxGeometry x="{x}" y="{Y0 - 30}" width="320" height="{max(200, 22 * len(note[1]) + 50)}" '
                     f'as="geometry"/></mxCell>')
    page_width = X0 + len(lanes) * (WIDTH + GAP) + (360 if note else 0)
    return (f'<diagram id="{name}" name={quoteattr(name)}><mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" '
            f'guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="{page_width}" '
            f'pageHeight="{Y0 + height + 40}" math="0" shadow="0"><root>' + "".join(cells) + "</root></mxGraphModel></diagram>")


APP, VPS, PC, AI, DATA = "App (Flutter)", "VPS · FastAPI backend", "PC · worker / esteira", "AI", "Data ($AGENT_DATA)"
P = []

# ---------------------------------------------------------------- 1. overview
P.append(page("0 · Overview", "Overview: who talks to whom (topology and main flow)",
    ["Clients", "VPS (Docker)", "PC at home (GPU)", "Data and services"],
    [("cli", "Clients", 0, "Flutter app", ["Android, iOS, tablet, Linux, web", "one package per module (agent_<m>)", "login: password + TOTP → JWT"], "app", 2),
     ("oai", "Clients", 2, "OpenAI-compatible clients", ["Claude Code, Cursor…", "sk_ key on /v1/*"], "ext"),
     ("ntfy", "Clients", 3, "ntfy (push)", ["Cobrador and deadline alerts"], "ext"),
     ("nginx", "VPS (Docker)", 0, "nginx + certbot", ["TLS, /api, /v1, /esteira/"], "api"),
     ("back", "VPS (Docker)", 1, "backend (FastAPI)", ["auth · /v1 · /api/notas · /api/arquivos", "/api/<module> (module routers)", "worker registry (WebSocket)"], "api", 2),
     ("tunel", "VPS (Docker)", 3, "tunnel (sshd)", ["receives the PC's reverse SSH", "publishes the esteira as tunel:8765"], "api"),
     ("collab", "VPS (Docker)", 4, "Collabora (CODE)", ["edits DOCX/XLSX/PPTX via WOPI"], "ext"),
     ("worker", "PC at home (GPU)", 0, "worker", ["WS client: chat, jobs, events", "llama.cpp · Claude Code · voice · PC commands"], "pc", 2),
     ("esteira", "PC at home (GPU)", 2, "esteira (./dark, :8765)", ["video pipeline + /api/v1 API", "Craft Apps (CLI/MCP)"], "pc", 2),
     ("llm", "PC at home (GPU)", 4, "llama-server (llama.cpp)", ["GGUF models in ~/agent-data/modelos", "+ LoRA adapters per app"], "ai"),
     ("dvps", "Data and services", 0, "$AGENT_DATA on the VPS", ["agent-data volume: JSON/JSONL/Markdown", "per module: <module>/…"], "data", 2),
     ("dpc", "Data and services", 2, "~/agent-data on the PC + vault", ["projects, library, dataset, models", "Obsidian vault (scripts, notes)"], "data", 2),
     ("drive", "Data and services", 4, "Google Drive", ["backup per module (rclone)", "current + versions (7/4/12)"], "ext")],
    [("cli", "nginx", "HTTPS + JWT"), ("oai", "nginx", "HTTPS sk_"), ("nginx", "back", ""), ("back", "dvps", "reads/writes"),
     ("worker", "back", "WebSocket (the PC opens it)"), ("esteira", "tunel", "reverse SSH"), ("nginx", "tunel", "/esteira/"),
     ("back", "collab", "WOPI"), ("worker", "llm", "inference"), ("esteira", "llm", "inference"), ("esteira", "dpc", ""),
     ("dpc", "drive", "daily backup"), ("back", "ntfy", "push")],
    ("Principles", ["• No port open at home: the PC opens the WebSocket and the tunnel.", "• No central database: files per module;",
                    "  SQLite only as a rebuildable index.", "• Claude only through Claude Code (claude -p) on the PC.",
                    "• Serialized GPU: one heavy slot at a time", "  (core/locks.py).", "• Secrets outside git (.env, google/)."])))

# ---------------------------------------------------------------- 2. platform
P.append(page("1 · Platform", "Platform: backend, worker, protocol and main app",
    [APP, VPS, PC, DATA],
    [("shell", APP, 0, "plataforma/app", ["shell, navigation, AI Model screen", "app update, PC shutdown"], "app"),
     ("core", APP, 1, "app_core / app_notas", ["Modulo, ApiCliente, Sondagem, theme", "notes editor, relations"], "app"),
     ("auth", VPS, 0, "auth", ["scrypt + TOTP + JWT HS256"], "api"),
     ("v1", VPS, 1, "/v1 (OpenAI-compatible)", ["chat/models → worker or Claude"], "api"),
     ("ws", VPS, 2, "/ws + worker_registry", ["WorkerHello, Heartbeat (CPU/RAM/GPU)", "ChatRequest/Response, WorkerEvent, jobs"], "api"),
     ("notas", VPS, 3, "/api/notas (vault)", ["Markdown + YAML frontmatter", "in-memory index, [[backlinks]]"], "api"),
     ("inet", VPS, 4, "internet/tools", ["FIPE, currencies, B3, Selic/IPCA, web search"], "api"),
     ("wk", PC, 2, "worker (ws_client)", ["providers/llamacpp: starts/swaps llama-server", "codigo.* · contas.* · voice · pc"], "pc", 2),
     ("cc", PC, 4, "shared/claude_code", ["claude -p (PC subscription)", "several accounts (CLAUDE_CONFIG_DIR)"], "ai"),
     ("dnotas", DATA, 3, "notes vault", ["$AGENT_DATA/notas/**.md"], "data"),
     ("dmod", DATA, 0, "GGUF models", ["~/agent-data/modelos"], "data")],
    [("shell", "auth", "login"), ("core", "notas", "notes CRUD"), ("shell", "v1", "chat"), ("v1", "ws", "forwards"),
     ("ws", "wk", "chat_request / job"), ("wk", "ws", "events, heartbeat"), ("notas", "dnotas", ""), ("wk", "dmod", "loads"),
     ("wk", "cc", "Claude tasks")],
    ("Contracts", ["• module backend = uv package agent-<m>", "  with an APIRouter mounted at /api/<m>.",
                   "• module worker registers executors", "  per job type (<m>.<action>).",
                   "• module app = Flutter package agent_<m>", "  that exports its routes (pub workspace).",
                   "• Model swap blocked (409) while", "  another module uses the LLM."])))

# ---------------------------------------------------------------- 3. empreendimento: esteira
P.append(page("2 · Empreendimento · esteira", "Empreendimento: video esteira (script + narration → final video)",
    ["Inputs", "Stages (./dark <stage> <channel-NNN>)", "Craft Apps / AI", DATA],
    [("rot", "Inputs", 0, "Script (Obsidian vault)", ["Notas/Empreendimento/YouTube/<channel>", "> [!cite] citations with DOI"], "ext"),
     ("wav", "Inputs", 1, "Narration (WAV) or camera", ["dark or presenter mode"], "ext"),
     ("perf", "Inputs", 2, "Channel profile", ["perfis/<channel>.toml + config.toml", "Studio style"], "ext"),
     ("app", "Inputs", 4, "App (Empreendimento tab)", ["queue, monitor, episode, editor,", "Studio, Dataset, Options"], "app", 2),
     ("tr", "Stages (./dark <stage> <channel-NNN>)", 0, "transcribe · clean · cuts", ["faster-whisper, forced alignment", "edges on silence, retakes, stutters"], "pc"),
     ("cen", "Stages (./dark <stage> <channel-NNN>)", 1, "scenes · curate", ["splits into scenes, LLM curation"], "pc"),
     ("bus", "Stages (./dark <stage> <channel-NNN>)", 2, "search · rate", ["open banks; library before the APIs", "local vision scores the media"], "pc"),
     ("gra", "Stages (./dark <stage> <channel-NNN>)", 3, "graphics / Studio", ["motion graphics pieces (HTML/EC)", "direction picks a piece per moment"], "pc"),
     ("mon", "Stages (./dark <stage> <channel-NNN>)", 4, "assemble · thumbnail", ["N1 FilmCraft → project and render", "N1 PhotoCraft → A/B thumbnails"], "pc"),
     ("llm", "Craft Apps / AI", 0, "local llama.cpp", ["per operation (Options)", "JSON grammar from the schema"], "ai"),
     ("cl", "Craft Apps / AI", 1, "Claude Code (claude -p)", ["'claude' slot in parallel", "quota limit (Options)"], "ai"),
     ("ec", "Craft Apps / AI", 3, "EffectCraft", ["N1 piece → JSX script → render"], "ext"),
     ("fc", "Craft Apps / AI", 4, "FilmCraft · PhotoCraft", ["headless MCP / <app>-cli"], "ext"),
     ("proj", DATA, 0, "projetos/<channel>/<NNN>/", ["transcript, cuts, scenes, media,", "graphics, .fcproj, final video"], "data", 2),
     ("acv", DATA, 2, "acervo/ (SQLite + FTS5)", ["every download with metadata", "vision scores (not redone)"], "data"),
     ("cache", DATA, 3, "cache/", ["trace.jsonl, options.json, queue,", "processes.jsonl, claude_quota.json"], "data"),
     ("ds", DATA, 4, "dataset/ (see tab 3)", ["each decision becomes an N1 record"], "data")],
    [("rot", "tr", ""), ("wav", "tr", ""), ("tr", "cen", ""), ("cen", "bus", ""), ("bus", "gra", ""), ("gra", "mon", ""),
     ("perf", "gra", "style"), ("cen", "llm", ""), ("bus", "acv", "queries/writes"), ("gra", "ec", ""), ("mon", "fc", ""),
     ("tr", "proj", ""), ("mon", "proj", "final video"), ("mon", "ds", ""), ("app", "cache", "API :8765 /api/v1"), ("cen", "cl", "")],
    ("Execution rules", ["• One heavy slot at a time (locks.py);", "  the 'claude' slot runs in parallel.",
                         "• Trace and events → app Monitor/graph.", "• A graphic edited by hand becomes manual: true.",
                         "• Configuration: config.toml ← profile ←", "  project config.toml.",
                         "• 9:16 Shorts: id channel-NNNx."])))

# ---------------------------------------------------------------- 4. empreendimento: N1, dataset and factory
P.append(page("3 · Empreendimento · N1, dataset and factory", "Empreendimento: N1 vocabulary, Craft Apps dataset, piece factory and fine-tuning",
    ["Who decides", "N1 (esteira/n1)", "Dataset (esteira/dataset)", "Training / models"],
    [("cla", "Who decides", 0, "Claude Code", ["creates ideas in batches (sheet + concept)", "reviews the proof: problem, cause, rule"], "ai", 2),
     ("loc", "Who decides", 2, "Local LLM (gemma-4)", ["writes the piece N1 (size and ideas)", "up to 4 rounds with the gate error"], "ai"),
     ("pes", "Who decides", 3, "Person (app)", ["approves/rejects pieces, edits and thumbnail", "manual edits in FilmCraft/PhotoCraft"], "app"),
     ("ec", "N1 (esteira/n1)", 0, "effectcraft.py", ["Piece: text, rectangle, ellipse/arc,", "repeat (grid, assets, slices), animations", "→ compiler → JSX + core (fit)"], "pc", 2),
     ("fc", "N1 (esteira/n1)", 2, "filmcraft.py", ["Edit: ops per track (V1–V4, A1–A3)", "→ executor → MCP commands"], "pc"),
     ("pc", "N1 (esteira/n1)", 3, "photocraft.py", ["Declarative composition, relational layout", "[photo] treatment + PhotoDecision"], "pc"),
     ("gate", "N1 (esteira/n1)", 4, "Gate + guide", ["schema, compiles, safe area, local vision", "N1 EC guide + Lessons (from Claude)"], "pc"),
     ("reg", "Dataset (esteira/dataset)", 0, "records/<app>/<task>/YYYY-MM.jsonl", ["append-only; context, N1 output,", "gate, origin, versions"], "data", 2),
     ("art", "Dataset (esteira/dataset)", 2, "artifacts/ (by sha256)", ["large prompts and N1"], "data"),
     ("idx", "Dataset (esteira/dataset)", 3, "index.db (SQLite)", ["rebuildable; status per task"], "data"),
     ("exp", "Dataset (esteira/dataset)", 4, "export", ["SFT / DPO / eval (gold), manifest", "split by group; edit in 45 s chunks"], "data"),
     ("tr", "Training / models", 0, "app training (QLoRA, unsloth)", ["base ≤ 12B (gemma-4-12b-it)", "training venv; worker stopped (VRAM)"], "pc", 2),
     ("ad", "Training / models", 2, "adapters/<app>-vN.gguf", ["+ manifest (losses, export hash)"], "data"),
     ("ban", "Training / models", 3, "bench (n1_*)", ["base × candidate on gold", "promotes <app>-current only if it wins"], "pc"),
     ("pre", "Training / models", 4, "llama-server --models-preset", ["base + LoRA per app → inference"], "ai")],
    [("cla", "loc", "ideas"), ("loc", "ec", "piece.n1.json"), ("ec", "gate", ""), ("gate", "cla", "passed → review"),
     ("cla", "gate", "rules → Lessons"), ("gate", "reg", "round + verdict"), ("pes", "reg", "verdicts / edits"),
     ("fc", "reg", "assemble"), ("pc", "reg", "thumbnail"), ("reg", "idx", ""), ("reg", "art", ""), ("idx", "exp", ""),
     ("exp", "tr", "SFT"), ("tr", "ad", ""), ("ad", "ban", ""), ("ban", "pre", "promoted")],
    ("Layers", ["• N2: high-level decision (what to show).", "• N1: vocabulary per app (validated JSON,", "  llama.cpp grammar).",
                "• N0: Craft Apps commands.", "• Deterministic executor/compiler", "  N1 → N0 (proven equivalence).",
                "• Minimums to train: piece animation 500,", "  edit 1500 chunks, thumbnail 300…"])))

# ---------------------------------------------------------------- 5. youtube
P.append(page("4 · Empreendimento · YouTube", "Empreendimento: YouTube channels as vault notes",
    [APP, VPS, DATA],
    [("ca", APP, 0, "Channels tab (lib/src/youtube)", ["channels tab → channel screen → item screen", "form built from the schema"], "app", 2),
     ("api", VPS, 0, "/api/youtube (youtube/api.py)", ["channels.py: one channel = one vault folder", "schema.py: collections and fields"], "api", 2),
     ("imp", VPS, 2, "python -m youtube.importer", ["copies the Obsidian vault into the platform vault"], "api"),
     ("cof", DATA, 0, "vault: YouTube/<channel>/", ["channel note (tipo: canal)", "Temas · História · Roteiros · Método"], "data", 2),
     ("vault", DATA, 2, "Obsidian vault", ["Notas/Empreendimento/YouTube/**.md"], "ext")],
    [("ca", "api", "HTTPS + JWT"), ("api", "cof", "Markdown"), ("vault", "imp", ""), ("imp", "cof", "")],
    ("Channels", ["finlumia · benehistory · cosmoatomico", "embarcados · thiagobenevide", "", "Nothing lives outside Markdown;",
                  "the notes also show up in /api/notas."])))


def module(tab, title, screens, routes, pc, data, arrows, note):
    lanes = [APP, VPS] + ([PC] if pc else []) + [DATA]
    boxes = [(f"a{i}", APP, i, t, d, "app") for i, (t, d) in enumerate(screens)]
    boxes += [(f"b{i}", VPS, i, t, d, "api") for i, (t, d) in enumerate(routes)]
    boxes += [(f"p{i}", PC, i, t, d, k) for i, (t, d, k) in enumerate(pc or [])]
    boxes += [(f"d{i}", DATA, i, t, d, "data") for i, (t, d) in enumerate(data)]
    P.append(page(tab, title, lanes, boxes, arrows, note))


module("5 · Files", "Files: study library with annotations and editing",
       [("Reader and annotations", ["PDF with ink, highlights with text", "reading projects"]), ("Editors", ["DOCX (revisions), XLSX, PPTX", "Export ODT/PDF/CSV/Markdown"])],
       [("/api/arquivos (library)", ["meta.json, original, documento.pdf", "LibreOffice converts DOCX/PPTX"]), ("WOPI → Collabora", ["collaborative editing of the original"]),
        ("rewriting · mapping", ["rewriting of passages (thesis)", "reverse citation map"])],
       [("Claude Code (worker)", ["claude_json on the PC"], "ai")],
       [("arquivos/<id>/", ["meta.json · original.<ext> · documento.pdf", "annotations"])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("b0", "d0", ""), ("b1", "d0", "reads/writes original"), ("b2", "p0", "job"), ("a1", "b2", "")],
       ("Flow", ["Upload → conversion to PDF → reader.", "Marked passages feed the reading", "projects (Studies module)."]))

module("6 · Studies", "Studies: readings, reading projects, languages and notes",
       [("Readings and projects", ["books/articles, marked passages"]), ("Languages A1–C2", ["tracks and sessions"]), ("Notes", ["editor with backlinks (app_notas)"])],
       [("/api/estudos", ["studies and projects"]), ("languages", ["schedule from fixed rules", "(CEFR guided hours)"]), ("/api/notas", ["syntheses and annotations"])],
       None,
       [("estudos/*.json", ["leituras.json · idiomas.json · projetos.json"]), ("arquivos/", ["annotations with a projects field"]), ("notes vault", ["Markdown"])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("a2", "b2", ""), ("b0", "d0", ""), ("b1", "d0", ""), ("b0", "d1", "passages"), ("b2", "d2", "")],
       ("Note", ["No LLM in the language schedule:", "rules from the level, minutes/day", "and weekdays."]))

module("7 · Health", "Health: physical, mental and spiritual",
       [("Workouts", ["schedule, sets, load"]), ("Mental", ["habits, focus, journal"]), ("Spiritual", ["Bible reading plans"])],
       [("/api/saude (workouts)", ["mini-gym catalog", "free-exercise-db images"]), ("/api/saude/mental", ["habits, pomodoro, mood"]), ("/api/saude/espiritual", ["scope split into N days"])],
       None,
       [("saude/", ["exercicios.json · agenda.json · imagens/"]), ("saude/mental/", ["habitos.json · foco.json · diario.json"]), ("saude/planos.json + notes", ["reflections in the vault"])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("a2", "b2", ""), ("b0", "d0", ""), ("b1", "d1", ""), ("b2", "d2", "")],
       ("Note", ["Everything in JSON in the module folder;", "reflections and theology as notes."]))

module("8 · Routines", "Routines: Kanban with a timer",
       [("Kanban board", ["pending · in progress · done", "timer per task"])],
       [("/api/rotinas (board)", ["order per column, time sessions"])],
       None,
       [("rotinas/tarefas.json", ["sessions {inicio, fim} in ISO UTC"])],
       [("a0", "b0", ""), ("b0", "d0", "")],
       ("Integration", ["The Panel (Cobrador) reads the tasks", "to measure performance and schedule."]))

module("9 · Design", "Design: whiteboard, flowcharts and wireframes",
       [("Whiteboard", ["pressure pen, shapes, text"]), ("Flows and wireframes", ["generated or adjusted by AI"])],
       [("/api/design (boards)", ["boards in JSON"]), ("flows · AI wireframe", ["the LLM only decides the structure (JSON)"]), ("drawio · images", [".drawio ↔ board; Google Images"])],
       [("LLM (worker)", ["structure of blocks and links"], "ai")],
       [("design/quadros/<id>.json", ["+ wireframes/"])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("b1", "p0", ""), ("b0", "d0", ""), ("b2", "d0", "imports/exports")],
       ("Note", ["The flow layout is computed in code;", "the AI only returns blocks and links."]))

module("10 · Electronics", "Electronics: circuit CAD (schematic, ERC, simulation)",
       [("Schematic editor", ["components, wires, labels, sheets"]), ("Libraries", ["symbols (KiCad .kicad_sym)"]), ("Simulation", ["ngspice results"])],
       [("/api/eletronica (projects)", ["netlist, BOM, ERC"]), ("libraries · KiCad", ["KiCad mm/y↑ → µm/y↓"]), ("simulation · spice", ["netlist → executor"])],
       [("worker: ngspice", ["shared/ngspice.py"], "pc")],
       [("eletronica/projetos/<id>.json", []), ("eletronica/bibliotecas/<lib>.json", [])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("a2", "b2", ""), ("b0", "d0", ""), ("b1", "d1", ""), ("b2", "p0", "job")],
       ("Phases", ["1: schematic (done)", "2: board", "3: simulation on the worker"]))

module("11 · Code", "Code: remote Claude Code in the repository",
       [("Tabs (sessions)", ["request + reference images", "live steps"])],
       [("/api/codigo (sessions)", ["meta.json, eventos.jsonl"])],
       [("worker: codigo.*", ["send · stop · tree · file", "reads the stream-json"], "pc"), ("Claude Code in the repo", ["claude -p --resume (per tab)", "loads CLAUDE.md"], "ai")],
       [("codigo/sessoes/<id>/", ["meta.json · eventos.jsonl · imagens/"])],
       [("a0", "b0", ""), ("b0", "p0", "job codigo.enviar"), ("p0", "p1", ""), ("p0", "b0", "WorkerEvent (steps)"), ("b0", "d0", "")],
       ("Note", ["Several tabs run at the same time;", "Claude accounts can be switched from the app", "(contas.*)."]))

module("12 · Public exams", "Public exams: notices, study plan, radar and jobs",
       [("Exams", ["Today, Schedule, Flow, Deadlines"]), ("Radar and rumors", ["open IT exams"]), ("Jobs and résumés", ["list + résumés in Markdown"])],
       [("/api/concursos", ["AI plan → study structure", "schedule up to 1 week before"]), ("radar · rumors · geo", ["PCI Concursos, IBGE, OSRM"]), ("/api/vagas", ["résumés"])],
       [("Claude Code", ["reads the notice, researches jobs"], "ai"), ("Local LLM", ["reads radar news"], "ai")],
       [("concursos/<id>/", ["notice, plan, calendar"]), ("concursos/radar/", ["rotas/ (cache)"]), ("vagas/curriculos/<id>.md", [])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("a2", "b2", ""), ("b0", "p0", "claude_json"), ("b1", "p1", ""), ("b2", "p0", ""),
        ("b0", "d0", ""), ("b1", "d1", ""), ("b2", "d2", "")],
       ("Alerts", ["Deadlines show up in the app and go", "out by push (Panel ntfy)."]))

module("13 · Finances", "Finances: statements, budget, scenarios and companies (CVM)",
       [("Statements and budget", ["OFX/CSV, categories, 50/30/20"]), ("Scenarios", ["pay upfront × finance"]), ("Companies", ["income statement, balance sheet, indicators"])],
       [("/api/financas (statements, reports)", ["categorization rules"]), ("scenarios · AI", ["the LLM only interprets text;", "the math is in the code"]), ("CVM · analysis", ["DFP/ITR/FCA (open data)"])],
       [("LLM (worker)", ["odd statements, categories"], "ai")],
       [("financas/<collection>.json", ["warehouse: schema per collection"]), ("CVM cache", ["downloaded statements"])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("a2", "b2", ""), ("b1", "p0", ""), ("b0", "d0", ""), ("b2", "d1", "")],
       ("Note", ["No API key for CVM.", "Sector questionnaire editable from the app."]))

module("14 · Panel", "Panel: LLM usage, Cobrador and alerts",
       [("Dashboard", ["latency, errors, tokens per provider"]), ("Cobrador", ["goals, today's schedule, disputes"])],
       [("meter", ["uso.jsonl + memory"]), ("cobrador · agent · performance", ["the agent requests actions in an acoes block", "performance per window of days"]), ("notifier", ["new alerts → ntfy (once a day)"])],
       [("LLM (worker or Claude)", ["drafts reminders"], "ai")],
       [("painel/", ["uso.jsonl · goals · schedule · sent"]), ("notes (status, prazo, cobra)", ["vault goals/tasks"])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("b1", "p0", ""), ("b0", "d0", ""), ("b1", "d1", "reads"), ("b2", "d0", "")],
       ("Sources", ["gateway requests, esteira trace,", "tasks (Routines) and notes with a deadline."]))

P.append(page("15 · Infra and backup", "Infrastructure, deployment and backup",
    ["Scripts (infra/scripts)", "VPS", "PC (systemd --user)", "Destinations"],
    [("inst", "Scripts (infra/scripts)", 0, "instalar_vps · atualizar_vps", ["Docker, secrets, nginx, TLS (idempotent)"], "ext"),
     ("con", "Scripts (infra/scripts)", 1, "conectar_vps", ["worker + tunnel as services"], "ext"),
     ("pub", "Scripts (infra/scripts)", 2, "publicar_app · empacotar_linux", ["app updates"], "ext"),
     ("bk", "Scripts (infra/scripts)", 3, "backup", ["--instalar · --testar · --restaurar", "rclone sync per module"], "ext"),
     ("ver", "Scripts (infra/scripts)", 4, "verificar", ["ruff · pytest · flutter analyze of what changed"], "ext"),
     ("dc", "VPS", 0, "docker-compose", ["gateway · tunel · collabora · nginx · certbot"], "api", 2),
     ("svc", "PC (systemd --user)", 0, "agent-worker · agent-esteira · agent-tunel", ["user services"], "pc", 2),
     ("tim", "PC (systemd --user)", 3, "agent-backup.timer (03:30)", ["+ agent-backup-teste.timer (monthly)"], "pc"),
     ("gd", "Destinations", 3, "gdrive:<module>/atual", ["versoes/<date> (7 daily, 4 weekly, 12 monthly)"], "data", 2),
     ("est", "Destinations", 0, "plataforma/backup.json", ["state of the last backup (app)"], "data")],
    [("inst", "dc", ""), ("con", "svc", ""), ("tim", "bk", "triggers"), ("bk", "gd", "rclone"), ("bk", "est", "")],
    ("Note", ["rclone's own OAuth (gdrive remote).", "A service account cannot upload files.", "VPS optional in the backup (BACKUP_VPS)."])))

xml = '<?xml version="1.0" encoding="UTF-8"?>\n<mxfile host="app.diagrams.net" type="device">' + "".join(P) + "</mxfile>\n"
with open(sys.argv[1], "w") as output:
    output.write(xml)
print(len(P), "tabs")
