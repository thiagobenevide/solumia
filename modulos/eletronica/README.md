# Electronics

"AutoCAD just for electronics": precision CAD to build computer, phone, monitor/TV and audio circuits —
schematic, simulation and board in the same project, with mouse, tablet and pen. Plan in
[docs/PLANO.md](docs/PLANO.md); physical bench in [docs/CATALOGO.md](docs/CATALOGO.md).

## Layout

```
eletronica/
├── backend/   Python package: FastAPI API, library, netlist and BOM (runs on the VPS)
├── worker/    (phase 3) ngspice simulation on the PC
└── app/       Flutter package with the module screens
```

## Today (phase 1 — schematic)

- `backend/` (`agent-eletronica`, mounted at `/api/eletronica`): projects in
  `$AGENT_DATA/eletronica/projetos/<id>.json` (`GATEWAY_ELETRONICA_DIR`). Routes: `GET /biblioteca`,
  list/create/get/edit (`titulo`, `pasta`), `PUT /projetos/{id}/esquematico` with `versao` (409 + current project),
  `GET …/netlist` (nets and loose pins), `GET …/bom` and `…/bom.csv`, duplicate, delete.
  `biblioteca.py`: ~57 symbols in µm (passives, semiconductors, ICs, electromechanical, sources, connectors,
  power). `netlist.py`: connects pins, ends and wire T-junctions on the same sheet; labels and power connect across sheets.
  KiCad (`kicad.py` + `bibliotecas.py`): reads `.kicad_sym` (KiCad 6–9; mm/y up → µm/y down, one
  entry per unit `<lib>:<nome>:<n>`, `extends`, 3-point arcs, bézier) and stores it in
  `$AGENT_DATA/eletronica/bibliotecas/<lib>.json` + `.indice.json`. Routes: `GET /bibliotecas`,
  `POST /bibliotecas/importar` (file), `GET|POST /bibliotecas/kicad` (official ones from the tag
  `GATEWAY_ELETRONICA_KICAD_VERSAO`, default 9.0.9 — KiCad 10 switched to `.kicad_symdir` folders),
  `DELETE /bibliotecas/{nome}`, `GET /biblioteca/busca?q=&biblioteca=`, `POST /biblioteca/simbolos` {ids}.
  `erc.py` + `GET …/erc` (phase 2): loose pin, shorted outputs, input-only net, power without a source,
  one-pin net with a label, duplicated ref (except units of the same IC), overlapping components, loose wire,
  single label; tests in `plataforma/backend/tests/test_eletronica_erc.py`.
  Tests: `plataforma/backend/tests/test_eletronica.py`.
- `app/` (`agent_eletronica`): project list + CAD screen. See `app/CLAUDE.md`.
- Simulation (phase 3, start): `spice.py` generates the SPICE netlist (GND → node 0, built-in generic models, parts without
  a model in `ignorados`) and reads the ngspice raw output; `api_simulacao.py`: `GET …/spice`, `POST …/simular` (op, tran,
  ac, dc → task) and `GET /simulacoes/{id}`. Runs as the worker's `simular_spice` task on the PC
  (`shared/ngspice.py`); without a worker, uses the backend's own ngspice if installed (otherwise 503).
  Tests: `plataforma/backend/tests/test_eletronica_simulacao.py`.
