# Dashboard e Accountability (Cobrador)

Logs de operação, consumo de recursos, disponibilidade e latência das LLMs; cobrador que acompanha metas e ações e alerta quando o planejamento desvia.

## Estrutura

```
painel/
├── backend/   pacote Python: API FastAPI, modelos e regras (roda na VPS)
├── worker/    jobs pesados de LLM/GPU (roda no PC com a GPU)
└── app/       pacote Flutter com as telas do módulo
```

Cada parte só existe quando houver código para ela. A plataforma (`plataforma/`) registra o
router do backend, despacha os jobs do worker e monta as telas do app.

## Cobrador (pronto)

- `backend/` → `/api/painel`: metas (`/metas`, `/metas/{id}/acoes`), agenda do dia (`/agenda/{dia}`,
  `/sugerir`, `PUT` devolve `contestacoes`, `/blocos/{id}/feito`), `/disciplina` (índice 0–100 e alertas),
  `/provedores` e `/conversar` (`local` = worker; `claude` com `GATEWAY_ANTHROPIC_API_KEY`).
  No chat, “anote …” cria nota no cofre e “pesquise …” responde com as notas da base.
- `app/`: abas Hoje (placar, alertas, agenda editável), Cobrador (chat) e Metas.
- Agente: o LLM pode terminar a resposta com um bloco ```acoes``` (criar tarefa/nota, mexer na
  agenda, registrar meta, concluir/mover tarefa); o servidor executa e devolve `executadas`
  (`painel/agente.py`). Consultas (`pesquisar_web`, `pesquisar_notas`, `analisar_desempenho`) voltam
  ao LLM numa segunda rodada antes da resposta final.
- Outros módulos: `Fontes.modulos` (registrado em `_acoes_modulos` no `main.py` da plataforma) dá
  ao agente `criar_caderno`, `criar_quadro`, `criar_fluxograma` (Design) e `criar_projeto_estudo`,
  `criar_leitura` (Estudos). Módulo novo = mais uma entrada ali.
- Velocidade: o prompt de sistema só tem o que quase não muda (instruções, agenda, até 40 tarefas
  abertas); hora e alertas vão na última mensagem, para o llama-server reaproveitar o cache.
- Desempenho: `GET /desempenho?dias=30` (`painel/desempenho.py`: concluídas, no prazo, atrasadas,
  aderência à agenda por dia da semana, metas); mensagens com “desempenho/produtividade” já levam a
  análise ao prompt.
- Voz: `POST /voz` (WAV → transcrição no worker → conversa) e `POST /falar` (texto → WAV). No worker:
  `uv sync --extra voz` (faster-whisper) e Piper (`WORKER_PIPER_MODELO`) ou `espeak-ng`.
- Notificações: no app, `VigiaCobrador` mostra os alertas novos no sistema (Linux/Android) a cada
  5 min; com o app fechado, `GATEWAY_PAINEL_NTFY_URL` manda push pelo ntfy.
  No Galaxy Watch, o app `modulos/saude/wear` mostra os alertas, toca alarme no início dos blocos
  e conversa com o cobrador por voz.
- Dashboard: `GET /dashboard` (pedidos, erros, p50/p95, tokens, log em `uso.jsonl`, CPU/RAM/GPU dos
  workers via heartbeat); aba LLMs no app.
