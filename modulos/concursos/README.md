# Concursos

Cada concurso é cadastrado com o edital (PDF ou link). O Claude Code lê o edital e monta o fluxo de
conhecimento do cargo: disciplinas, tópicos na ordem em que devem ser estudados, horas, prazos do
edital e estratégia. Disso sai, por regra, o calendário de tarefas até 1 semana antes da prova.
Os alertas de prazo aparecem no app e vão por push (ntfy do Painel).

## Estrutura

```
concursos/
├── backend/   `agent-concursos` (pacote `concursos`) em `/api/concursos`; dados em `$AGENT_DATA/concursos/<id>/`
└── app/       `agent_concursos`: Listagem, Novo concurso, e por concurso as abas Hoje, Cronograma, Fluxo e Prazos
```

- `plano_ia.py`: prompt, sistema e esquema JSON do pedido ao Claude (tarefa `claude_json` do worker,
  `shared/claude_code.py`; sem worker, o `claude` do próprio PC; nunca a API da Anthropic).
- `cronograma.py`: distribui os tópicos pelos dias (min/dia útil e de fim de semana), intercalando as
  disciplinas; sábado treina a discursiva, domingo revisa a semana ou faz simulado (a cada 2 semanas);
  o que sobra antes da semana final vira revisão + questões; a semana final é só revisão leve e véspera.
  Se faltar tempo, comprime os tópicos na mesma proporção (`resumo_plano.fator`).
- `concursos.py`: armazenamento, edital (pdftotext), replanejar (feitas ficam, o resto vai de hoje
  em diante, sem chamar o Claude de novo) e alertas (prazos dos próximos 15 dias, contagem até a
  prova, tarefas de hoje e atrasadas).

Rotas: `GET/POST /`, `GET /alertas`, `GET/PATCH/DELETE /{id}`, `POST /{id}/edital` (multipart),
`POST /{id}/edital/link`, `POST /{id}/plano` (202, em segundo plano), `POST /{id}/replanejar`,
`PATCH /{id}/tarefas/{tid}`, `POST /{id}/prazos`, `DELETE /{id}/prazos/{pid}`.

## Radar de TI (aba "Radar TI · mapa")

- `radar.py`: a cada `concursos_radar_horas` (6 h; a 1ª coleta 60 s depois do boot) lê as listagens
  do PCI Concursos (nacional + 5 regiões), separa as de TI por palavra-chave e, para cada notícia
  nova com TI no texto, segue o site oficial citado (os PDFs do PCI ficam atrás de captcha) atrás
  do edital, tira dele os trechos de local/data/remuneração e pede à **LLM local** (worker, sem
  raciocínio) vagas/salários de TI, inscrições, data/horário da prova, cidades de aplicação e
  links. Até 12 chamadas à LLM por coleta; o resto fica na fila.
- `geo.py`: coordenadas pela lista de municípios do IBGE (baixada uma vez para
  `$AGENT_DATA/concursos/radar/`) e rota de carro pelo OSRM público (cache em `rotas/`; sem ele,
  linha reta × 1,3 marcada como estimada). Origem: `concursos_origem_cidade/uf` (Custódia/PE).
- App: mapa (flutter_map, tiles CARTO) com você, o local de prova mais próximo de cada concurso
  (cor pela distância, número de vagas de TI no pino), a sede e a rota desenhada com km e tempo;
  painel com vagas, salários, inscrições, prova, links e **Acompanhar** (escolhe a vaga → baixa o
  edital → o Claude monta o fluxo; a ficha do radar aparece no concurso).
- Rotas: `GET /radar`, `POST /radar/atualizar`, `GET /radar/{id}/rota`, `POST /radar/{id}/acompanhar`.

## Simulados e materiais (abas do concurso)

- `estudo.py` + `plano_ia.SISTEMA_SIMULADO`: o Claude cria questões inéditas no estilo da banca, na
  proporção do edital (ou de uma disciplina), preferindo tópicos já estudados; gabarito e
  comentário só voltam depois de entregar; desempenho por disciplina contra os 60% do edital.
- Materiais: busca na web (`Internet.buscar_web`, DuckDuckGo) por provas anteriores, questões,
  apostilas e vídeos; a LLM local classifica e descarta o inútil (só links que a busca trouxe).
- Rotas: `GET/POST /{id}/simulados`, `POST /{id}/simulados/{sid}/respostas`,
  `DELETE /{id}/simulados/{sid}`, `GET /{id}/materiais`, `POST /{id}/materiais/buscar`.
