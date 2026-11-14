# Personal Finance and Investments

Mapping of bank transactions and statements; study and selection of companies by accounting, reports and indicators (income statements; CVM open data).

## Layout

```
financas/
├── backend/   Python package: FastAPI API, models and rules (runs on the VPS)
├── worker/    heavy LLM/GPU jobs (runs on the GPU PC)
└── app/       Flutter package with the module screens
```

Each part only exists once there is code for it. The platform (`plataforma/`) registers the
backend router, dispatches the worker jobs and mounts the app screens.

## Implemented

CVM income statement, balance sheet and cash flow are read by the account description (banks and insurers have a different chart of
accounts); the number of shares comes from the capital composition (in thousands, with the scale fixed by earnings per share).
The Market sheet arrives in parts (year by year) with indicators, valuation and the per-year table.

- Backend: `backend/` (`agent-financas`, package `financas`), mounted at `/api/financas`. JSON data in
  `$AGENT_DATA/financas/` (`<colecao>.json`, `questionario.json`). `armazem.py` (schema and CRUD of the collections),
  `extrato.py` (OFX/CSV, counterparty, rules), `relatorios.py` (panel, flow, bills, schedules, goals),
  `analise.py` (indicators, valuation, checks, score and portfolio), `padroes.py` (categories and questionnaire).
- App: `app/` (`agent_financas`): tabs Panel, Statement, Planning (budget, goals, schedules), Accounts
  (credit card bills) and Investments (companies, sectors, portfolio, questionnaire). Company reports go
  to the Files module (folder `Finanças/<ticker>`) and open in the reader with annotation.

Convention: value > 0 comes in, < 0 goes out; categories of the `transferencia` type stay out of income and expenses.
Company score = 50% questionnaire + 30% indicator checks + 20% sector score (≥ 70 eligible, ≥ 50 watch).

| Route | What |
|---|---|
| `GET/POST /{colecao}` · `GET/PATCH/DELETE /{colecao}/{id}` | contas, categorias, transacoes, regras, metas, programacoes, empresas, setores, operacoes, proventos |
| `GET /transacoes?de=&ate=&conta_id=&categoria_id=&q=&sem_categoria=` | filtered statement |
| `POST /importar` (multipart `arquivo`, `conta_id`) | OFX or CSV, without duplicates, categorizes by rule/history |
| `POST /transacoes/lote` · `POST /regras/aplicar` | categorizes several (and creates a rule); reapplies rules |
| `GET /resumo?mes=AAAA-MM` | panel: totals, categories, budget, 50/30/20, indicators, net worth, goals |
| `GET /fluxo?meses=&ate=` · `GET /contrapartes?de=&ate=` | monthly cash flow; who receives/sends the most |
| `GET /faturas/{conta_id}` | credit card bills per month and limit usage |
| `GET /projecao?dias=` · `POST /programacoes/{id}/lancar` | pending occurrences and projected balance; posts to the statement |
| `GET /metas/progresso` | goals with contributions, progress and required monthly contribution |
| `POST /importar` (OFX/CSV/XLS/XLSX/PDF) | Nubank, Inter, BB, Mercado Pago and Itaú formats; a PDF or an odd layout becomes an AI task (202); the original goes to Files › `Finanças/Extratos/<conta>` |
| `POST /categorizar-ia` · `GET /tarefas/{id}` | AI categorizes what the rules did not catch (and the payment method) |
| `GET /parcelamentos` | installment purchases: paid, remaining, amount left, until when |
| `POST /cenarios/simular` · `POST /cenarios/perguntar` | save × finance (Price/SAC, MCMV) over the statement; the free question uses today's FIPE and CDI (`cenarios.py`, `ia.py`) |
| `GET /mercado/destaques?tipo=stock\|fund` | 10 biggest gains and losses of the day among the most traded on B3 |
| `POST /mercado/ativo` · `POST /empresas/{id}/importar-cvm` · `POST /mercado/guardar` | stock sheet (CVM income statement/balance sheet/cash flow, DFP/ITR/releases with link) or REIT (monthly report, P/BV, DY); imports the income statement; stores the PDF in Files (`cvm.py`, cache in `<dados>/cvm/`) |

Real-time data comes from the platform (`app.state.internet`, `plataforma/backend/src/backend/internet/`:
FIPE, currencies, quotes, dividends, Selic/CDI/IPCA, biggest gains/losses and web search).
| `GET /mercado/sugerir?q=` | search while typing (stocks and REITs): ticker by prefix, name, nickname (`cvm.NICKNAMES`), old name and similar name |
| `GET /estudo?objetivo=` · `PUT /estudo/objetivo` · `PATCH /estudo/itens` | finance track (`estudo.py`): levels → stages with the right book and chapters, articles, reports and practice; progress in `estudo_progresso` |
| `POST /estudo/livros` · `PUT /estudo/livros/{id}/tenho` · `POST /estudo/livros/{id}/guia` | books you own; Claude (Claude Code on the worker, `app.state.reescrita`) builds the non-linear guide |
| `POST /estudo/ler` · `GET /estudo/citacoes` | reading in Studies (Finance area) + "Trilha de Finanças" project; the project's highlights per work |
| `GET/PUT /questionario` | selection questions (target company or sector, block, weight) |
| `GET /empresas/ranking` · `GET /empresas/{id}/analise` · `GET /setores/{id}/analise` | ranking; full analysis |
| `GET /carteira` | positions, average price, result, dividends and allocation per sector |
