# Saúde e Desenvolvimento Pessoal

Espiritual: leitura, reflexão bíblica e teologia. Físico: treinos na mini-academia (saco de pancada, anilhas, barras) e registro de performance. Mental: hábitos, foco contra a procrastinação, controle de ansiedade e autodisciplina.

## Estrutura

```
saude/
├── backend/   pacote Python: API FastAPI, modelos e regras (roda na VPS)
├── worker/    jobs pesados de LLM/GPU (roda no PC com a GPU)
└── app/       pacote Flutter com as telas do módulo
```

Cada parte só existe quando houver código para ela. A plataforma (`plataforma/`) registra o
router do backend, despacha os jobs do worker e monta as telas do app.

## Físico (implementado)

- Backend: `backend/` (`agent-saude`, pacote `saude`), montado em `/api/saude`. Dados em `$AGENT_DATA/saude/`
  (`exercicios.json`, `agenda.json`, `imagens/`). Catálogo inicial de 50 exercícios para a mini-academia
  (`catalogo.py`); as imagens vêm do [free-exercise-db](https://github.com/yuhonas/free-exercise-db) (domínio
  público), baixadas na primeira vez e guardadas em cache. Os de saco de pancada recebem a foto do usuário.
- App: `app/` (`agent_saude`): calendário dia/semana/mês + biblioteca em drill-down (área → grupo →
  exercício) à direita na tela larga e embaixo no celular. Arrastar com o mouse (PC) ou toque longo (Android).

| Rota | O quê |
|---|---|
| `GET/POST /api/saude/exercicios` | áreas + catálogo; cria exercício próprio |
| `PATCH/DELETE /api/saude/exercicios/{id}` | edita; exclui (e tira da agenda) |
| `GET/POST/DELETE /api/saude/exercicios/{id}/imagem?n=0\|1` | foto (início/fim do movimento); envia (multipart `arquivo`); remove |
| `GET /api/saude/agenda?de=&ate=` | itens do período |
| `POST /api/saude/agenda` · `PATCH/DELETE /api/saude/agenda/{id}` | marca exercício no dia; muda dia, ordem, séries, carga, `feito` |
| `POST /api/saude/agenda/copiar` | repete um dia/semana (`de`, `ate`, `destino`) |

## Guia de treino (implementado)

Botão **Treinar** na tela de Treinos: monta a sessão com os exercícios pendentes do dia (o da visão Dia,
senão hoje) e conduz série a série — repetições e carga ajustáveis, descanso cronometrado (padrão 60 s;
pausar, continuar, ±15/30 s, pular), pausa do treino inteiro, desfazer série, pular ou trocar de exercício.
Na próxima vez mostra o que foi feito antes e sugere a carga (progressão dupla, `sessoes.sugestao`). Ao
concluir: esforço 1–10, notas, marca os itens como feitos na agenda e lê a frequência cardíaca do Galaxy
Watch pelo Health Connect (intervalo da sessão). A sessão entra no contexto da Análise.

Em segundo plano (Android, `aviso_treino.dart`): com o guia fora da frente (Spotify, tela apagada,
guia fechado) fica uma notificação fixa com a etapa e a contagem do descanso e um alarme exato no fim
do descanso (`USE_EXACT_ALARM`, receivers do `flutter_local_notifications` no manifesto). O alarme usa o
último estado que o celular viu: mudança feita no relógio com o celular parado chega na próxima
sincronização.

O estado (fase, descanso, pausa) fica no servidor (`sessoes.py`, `$AGENT_DATA/saude/sessoes.json`) e só
muda por comandos; o app relê a cada 5 s. Assim o relógio pode controlar a mesma sessão pelas mesmas rotas.

| Rota | O quê |
|---|---|
| `POST /api/saude/sessoes` (`data`, `descanso_s`) · `GET …/ativa` · `GET …?de=&ate=` | inicia (ou devolve a em andamento); ativa; histórico |
| `GET/PATCH/DELETE /api/saude/sessoes/{id}` | sessão (com `agora` do servidor); notas, esforço, `frequencia`; descarta |
| `POST …/{id}/comando` (`acao`) | `concluir_serie`, `pausar`, `continuar`, `pular_descanso`, `somar_descanso`, `ir_para`, `pular_exercicio`, `desfazer_serie`, `editar_serie`, `descanso_padrao` |
| `POST …/{id}/concluir` | fecha, guarda o resumo (duração, séries, volume) e marca a agenda |
| `POST …/{id}/fc` (`amostras: [{em, bpm}]`) | batimentos ao vivo do relógio (lote vazio = sinal de vida); devolve `estado`, `frequencia`, `fc_atual`, `controle`, `atual` |

## App do relógio (Galaxy Watch, Wear OS)

`wear/`: projeto Gradle próprio (Kotlin + Compose for Wear, minSdk 30, sem loja). Fala direto com o
backend (`url` + uma chave de `CLIENT_API_KEYS`), usando a internet do celular por Bluetooth ou o Wi‑Fi.
Instalar: `modulos/saude/wear/instalar <ip:porta>` (depuração por Wi‑Fi no relógio; pede a chave sem eco).
Atualizar: o `publicar_app` também publica o `relogio.apk` (mesmo build); o Início do relógio mostra "Atualizar app" quando há build novo. Na primeira vez o Wear OS pede para autorizar o app a instalar apps.

- **Navegação**: páginas lado a lado (Início, Treino, Cobrador, Agenda, Alertas), trocadas deslizando
  para os lados, com indicador de página; o Início tem cartões de atalho.
- **Treino**: a mesma sessão do guia (`/api/saude/sessoes`), num painel de player: anel de progresso na
  borda, ⏮ desfaz a série, botão central marca a série (no descanso, pausa/continua), ⏭ pula exercício
  ou descanso, ± repetições, +30 s; volume da voz pelos botões ou pela coroa (`Volume.kt`, nível na
  borda), vibração no fim do descanso, tela acesa durante o treino.
- **Treino em segundo plano** (`TreinoServico.kt`): serviço em primeiro plano (tipo `health`) com um
  exercício do Health Services (MeasureClient se outro app já tiver um), ligado enquanto há treino em
  andamento — continua com a tela apagada ou outro app na frente. Vibra no fim do descanso, mostra
  etapa, contagem e ♥ na notificação e no mostrador (atividade em andamento) e para sozinho quando o
  treino termina (também se concluído no celular). Permissão `BODY_SENSORS`, ou `health.READ_HEART_RATE`
  no Wear OS 6. Com o app do relógio fechado e treino começado no celular, o vigia avisa para abrir.
- **Frequência cardíaca ao vivo**: aparece no relógio e no guia do celular (`fc_atual`). Lotes a cada 10 s em `POST …/sessoes/{id}/fc`;
  o servidor guarda o pico de cada 5 s, calcula `frequencia` (`origem: relogio`, que o Health Connect não
  sobrescreve) e, ao concluir, o pico de cada série (`fc_max`).
- **Cobrador**: conversa por voz (`/api/painel/voz`, WAV 16 kHz gravado no relógio) e resposta falada
  (`/falar`, liga/desliga); ações executadas pelo agente aparecem na resposta.
- **Agenda de hoje** (tocar marca feito) e **Alertas** (`/api/painel/disciplina`).
- **Em segundo plano** (`Avisos.kt`): a cada 15 min (WorkManager) os alertas novos do cobrador viram
  notificação (uma vez por dia cada) e os blocos do dia ganham alarme no horário de início, com o
  botão "Feito". Se o app do celular/ntfy também notificar no relógio, desligue o espelhamento deles
  no Galaxy Wearable para não duplicar.
- **Sensores sem tocar em nada** (`Passivo.kt`): o app registra o sensor passivo do Health Services
  (`PassivoServico`, refeito no boot) e passos, calorias, distância, andares e o batimento (com a permissão
  de segundo plano) chegam com o app fechado; a página Corpo mede ao vivo sozinha enquanto está na tela.
- Testes: `./gradlew -q testDebugUnitTest` em `wear/`.

## Mental e Espiritual (implementado)

Mesmo pacote e router (`api_bem_estar.py`); dados em `$AGENT_DATA/saude/mental/` e `.../espiritual/`.

| Rota | O quê |
|---|---|
| `GET/POST /api/saude/mental/habitos` · `PATCH/DELETE …/{id}` · `POST …/{id}/marcar` | hábitos a construir/evitar, dias da semana, `sequencia` |
| `GET/POST /api/saude/mental/foco` | sessões de foco (pomodoro), minutos por dia |
| `GET /api/saude/mental/diario?de=&ate=` · `PUT …/diario/{data}` | humor 1–5, ansiedade 0–10, gatilhos, gratidão |
| `GET /api/saude/espiritual/escopos` · `GET/POST /api/saude/espiritual/planos` | planos de leitura bíblica (66 livros, capítulos divididos em N dias) |
| `GET …/planos/{id}/leituras?de=&ate=` · `POST …/planos/{id}/marcar` | leitura de cada dia; dias lidos e atrasados |

Reflexões e estudos de teologia são notas do vault (tags `reflexao`/`teologia`) criadas pelo app.

## Sono e corpo (Galaxy Watch) e Análise

O Samsung Health não tem API na nuvem: o app Android lê o **Health Connect** (pacote `health`;
o Samsung Health precisa estar sincronizando com ele) e envia um resumo por dia, sozinho: ao abrir o
app e a cada hora em segundo plano (`workmanager`, `app/lib/src/sincronizacao.dart`, últimos 3 dias,
com o endereço e o token da sessão que agendou; exige a permissão de leitura em segundo plano). O histórico antigo,
o estresse e a pontuação do sono do Samsung (que não vão ao Health Connect) entram pelo zip de Samsung Health ›
Configurações › Baixar dados pessoais. Dados em `$AGENT_DATA/saude/relogio/` (`dias.json`,
`analises.json`, `estado.json`); o sono conta no dia em que a pessoa acorda. A análise usa **só a
LLM local** (`app.state.saude_llm`) e cruza com diário, foco, hábitos, treinos e o contexto de
finanças, rotinas e estudos (`app.state.saude_contexto`, montado em `main.py`).
Sem a nota do Samsung, `dias` devolve a nossa (`relogio.pontuar_sono`, `sono_pontuacao_estimada`):
duração (meta 8 h), eficiência (acordado na cama), profundo (~18%) e REM (~20%), de 0 a 100.

| Rota | O quê |
|---|---|
| `GET /api/saude/relogio/dias?de=&ate=` · `PUT …/dias` | dias guardados; o app envia os do Health Connect (sobrescreve) |
| `GET /api/saude/relogio/resumo?de=&ate=` · `GET …/estado` | médias e metas batidas; última sincronização por origem |
| `POST /api/saude/relogio/importar` | zip da exportação (multipart `arquivo`); só preenche o que falta |
| `GET/POST /api/saude/relogio/analises` | análises guardadas (20); pede uma nova (`dias`, `pergunta`) |

App: o módulo não tem abas no topo; as seções ficam no submenu lateral (Treinos, Espiritual, Sono e
corpo, Análise, Hábitos, Foco, Humor e ansiedade). Android: `MainActivity` é `FlutterFragmentActivity`,
`minSdk` 26 e permissões `health.READ_*` no manifesto.

## Consumo (controle de redes sociais e conteúdo no Android)

Submódulo da parte mental para cortar o uso sem propósito de redes sociais, vídeos, compras, notícias
e conteúdo adulto no **celular e nos tablets Android** (nada de iOS). Dados pessoais: ficam no PC/VPS
e a leitura é **só pela LLM local** (`app.state.saude_llm`), nunca por serviço externo. Buscas nunca
são guardadas como texto — o aparelho casa a busca com palavras-chave e registra **só a categoria**.
WhatsApp é isento (trabalho) e nunca entra nas regras. Backend em `backend/consumo.py` +
`api_consumo.py`, montado em `/api/saude/consumo`; dados em `$AGENT_DATA/saude/consumo/`
(`config.json`, `pendencias.json`, `dispositivos.json`, `uso/<dia>.json`, `analises.json`).

**Trava de 24 h**: apertar uma regra vale na hora; afrouxar (liberar categoria, subir limite, tirar
horário, app ou domínio, desligar a proteção) só se aplica 24 h depois (`pendencias.json`) e pode ser
cancelado antes. Categorias: redes sociais, vídeos, compras, notícias, navegadores, conteúdo adulto,
VPN/contorno. Cada uma tem modo (livre/limite/bloqueado), minutos por dia e horários proibidos.

| Rota | O quê |
|---|---|
| `GET /api/saude/consumo/config` | regras, apps e domínios próprios, pendências, categorias |
| `PUT …/regras/{categoria}` | define modo/limite/horários (afrouxar vira pendência de 24 h) |
| `PUT …/apps` · `DELETE …/apps/{pacote}` | vigiar um app numa categoria; parar de vigiar |
| `POST …/dominios/{cat}` · `DELETE …/dominios/{cat}/{dom}` | domínio extra para bloquear; remover |
| `PUT …/protecao` · `DELETE …/pendencias/{id}` | liga/desliga a blindagem; cancela uma pendência |
| `POST …/sincronizar` | o aparelho manda uso/eventos e recebe as regras montadas para aplicar |
| `GET …/dispositivos` · `GET …/resumo?de=&ate=` | aparelhos e seu estado; uso por categoria/app/hora |
| `GET/POST …/analises` | leituras do "vigia" guardadas (20); pede uma nova (`dias`, `pergunta`) |

App: seção **Consumo** no submenu lateral de Saúde (`telas/consumo_tela.dart`), com as regras, os
aparelhos, o uso e o "vigia". No Android só **lê o uso** pelo plugin nativo (`android/.../consumo/`,
canal `agent/saude/consumo`, `app/lib/src/consumo_nativo.dart`): **UsageStats**
(`PACKAGE_USAGE_STATS`) dá tempo por app, aberturas e minutos por hora. Não há bloqueio no aparelho:
acessibilidade, VPN local de DNS e administrador do aparelho foram removidos porque o app do banco
passou a acusar o agent como suspeito. A única permissão é a leitura de uso (`permissoes`/`pedir`).
O código nativo não é coberto por `infra/scripts/verificar` (só
ruff/pytest/flutter analyze): exige build no aparelho.
