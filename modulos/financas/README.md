# Finanças Pessoais e Investimentos

Mapeamento de transações e extratos bancários; estudo e seleção de empresas por contabilidade, relatórios e indicadores (DRE; dados abertos da CVM).

## Estrutura

```
financas/
├── backend/   pacote Python: API FastAPI, modelos e regras (roda na VPS)
├── worker/    jobs pesados de LLM/GPU (roda no PC com a GPU)
└── app/       pacote Flutter com as telas do módulo
```

Cada parte só existe quando houver código para ela. A plataforma (`plataforma/`) registra o
router do backend, despacha os jobs do worker e monta as telas do app.

## Implementado

DRE, balanço e fluxo da CVM são lidos pela descrição da conta (bancos e seguradoras têm outro plano de
contas); o número de ações vem da composição do capital (em mil, com a escala acertada pelo lucro por ação).
A ficha do Mercado chega por partes (ano a ano) com indicadores, valuation e a tabela por ano.

- Backend: `backend/` (`agent-financas`, pacote `financas`), montado em `/api/financas`. Dados em JSON em
  `$AGENT_DATA/financas/` (`<colecao>.json`, `questionario.json`). `armazem.py` (esquema e CRUD das coleções),
  `extrato.py` (OFX/CSV, contraparte, regras), `relatorios.py` (painel, fluxo, faturas, programações, metas),
  `analise.py` (indicadores, valuation, checagens, nota e carteira), `padroes.py` (categorias e questionário).
- App: `app/` (`agent_financas`): abas Painel, Extrato, Planejamento (orçamento, metas, programações), Contas
  (faturas do cartão) e Investimentos (empresas, setores, carteira, questionário). Relatórios das empresas vão
  para o módulo Arquivos (pasta `Finanças/<ticker>`) e abrem no leitor com anotação.

Convenção: valor > 0 entra, < 0 sai; categorias do tipo `transferencia` ficam fora de receitas e despesas.
Nota da empresa = 50% questionário + 30% checagens dos indicadores + 20% nota do setor (≥ 70 apta, ≥ 50 observar).

| Rota | O quê |
|---|---|
| `GET/POST /{colecao}` · `GET/PATCH/DELETE /{colecao}/{id}` | contas, categorias, transacoes, regras, metas, programacoes, empresas, setores, operacoes, proventos |
| `GET /transacoes?de=&ate=&conta_id=&categoria_id=&q=&sem_categoria=` | extrato filtrado |
| `POST /importar` (multipart `arquivo`, `conta_id`) | OFX ou CSV, sem duplicar, categoriza por regra/histórico |
| `POST /transacoes/lote` · `POST /regras/aplicar` | categoriza várias (e cria regra); reaplica regras |
| `GET /resumo?mes=AAAA-MM` | painel: totais, categorias, orçamento, 50/30/20, indicadores, patrimônio, metas |
| `GET /fluxo?meses=&ate=` · `GET /contrapartes?de=&ate=` | fluxo de caixa mensal; quem mais recebe/envia |
| `GET /faturas/{conta_id}` | faturas do cartão por mês e uso do limite |
| `GET /projecao?dias=` · `POST /programacoes/{id}/lancar` | ocorrências pendentes e saldo projetado; lança no extrato |
| `GET /metas/progresso` | metas com aportes, progresso e aporte mensal necessário |
| `POST /importar` (OFX/CSV/XLS/XLSX/PDF) | formatos de Nubank, Inter, BB, Mercado Pago e Itaú; PDF ou layout estranho vira tarefa da IA (202); o original vai para Arquivos › `Finanças/Extratos/<conta>` |
| `POST /categorizar-ia` · `GET /tarefas/{id}` | IA categoriza o que as regras não pegaram (e a forma de pagamento) |
| `GET /parcelamentos` | compras parceladas: pagas, faltam, valor restante, até quando |
| `POST /cenarios/simular` · `POST /cenarios/perguntar` | juntar × financiar (Price/SAC, MCMV) sobre o extrato; a pergunta livre usa FIPE e CDI de hoje (`cenarios.py`, `ia.py`) |
| `GET /mercado/destaques?tipo=stock\|fund` | 10 maiores altas e baixas do dia entre os mais negociados da B3 |
| `POST /mercado/ativo` · `POST /empresas/{id}/importar-cvm` · `POST /mercado/guardar` | ficha de ação (DRE/balanço/fluxo da CVM, DFP/ITR/releases com link) ou FII (informe mensal, P/VP, DY); importa a DRE; guarda o PDF no Arquivos (`cvm.py`, cache em `<dados>/cvm/`) |

Dados em tempo real vêm da plataforma (`app.state.internet`, `plataforma/backend/src/backend/internet/`:
FIPE, moedas, cotações, proventos, Selic/CDI/IPCA, maiores altas/baixas e busca na web).
| `GET /mercado/sugerir?q=` | busca enquanto digita (ações e FIIs): ticker pelo começo, nome, apelido (`cvm.NICKNAMES`), nome antigo e nome parecido |
| `GET /estudo?objetivo=` · `PUT /estudo/objetivo` · `PATCH /estudo/itens` | trilha de finanças (`estudo.py`): níveis → etapas com livro e capítulos certos, artigos, relatórios e prática; progresso em `estudo_progresso` |
| `POST /estudo/livros` · `PUT /estudo/livros/{id}/tenho` · `POST /estudo/livros/{id}/guia` | livros que você tem; o Claude (Claude Code no worker, `app.state.reescrita`) monta o guia não linear |
| `POST /estudo/ler` · `GET /estudo/citacoes` | leitura em Estudos (área Finanças) + projeto "Trilha de Finanças"; grifos do projeto por obra |
| `GET/PUT /questionario` | perguntas de seleção (alvo empresa ou setor, bloco, peso) |
| `GET /empresas/ranking` · `GET /empresas/{id}/analise` · `GET /setores/{id}/analise` | ranking; análise completa |
| `GET /carteira` | posições, preço médio, resultado, proventos e alocação por setor |
