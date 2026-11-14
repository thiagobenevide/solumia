# Plano · Dataset das Craft Apps, armazenamento e backup

Revisão da etapa de configuração (2026-11-08): o que foi decidido para treinar a LLM local que opera o
EffectCraft, o FilmCraft e o PhotoCraft, onde os dados ficam e como são protegidos. Nada do dataset está
implementado ainda; a seção "Feito" lista só a configuração já aplicada.

## 1. Ponto de partida

- **Empreendimento** = `esteira/` (pipeline no PC, painel :8765) + `youtube/` (canais como notas do cofre,
  `/api/youtube` na VPS) + `app/` (telas Flutter). YouTube e esteira não se chamam: o elo é o vault do Obsidian.
- Treino já existe: gabarito da bancada → `estudio/treino.exportar` (chat, 90/10) → `ia/treinar_lora.py`
  (unsloth) → GGUF no llama.cpp. As tarefas atuais são de decisão (`bloco_peca`, `preencher`, `corte`, `legenda`).
- Dados de Craft Apps hoje são poucos: 4 peças EffectCraft (81 HTML), 2 aprovadas na fábrica, 3 `.fcproj`
  editados à mão. A fábrica registra eventos, mas não guarda prompt nem resposta de cada rodada.

## 2. Decisões

| Tema | Decisão |
|---|---|
| Papel do Claude | Gera conteúdo profissional (professor, na fábrica); a produção usa o modelo local |
| Execução | Só pelas Craft Apps (`<app>-cli run` com JSONL de comandos), sem depender de scripts `.jsx` |
| O que o modelo escreve | **N1**: vocabulário de operações de domínio; um compilador determinístico gera o N0 |
| Vocabulário | **Um por app**, cada um com o seu adaptador LoRA (`--lora` no llama.cpp, sem mesclar) |
| Formato da saída | EffectCraft e PhotoCraft: documento declarativo; FilmCraft: lista de operações |
| Tamanho dos modelos treinados | **Até 12B de parâmetros** (base atual `gemma-4-12b-it`); modelos maiores só por inferência, sem fine-tuning |
| Fotos dos vídeos | **Receita fixa por canal** (`perfis/<canal>.toml`, `[foto]`); o modelo só decide foco e recorte |
| Formato do dataset | JSONL canônico (só cresce) + exportações derivadas (SFT, DPO, eval) |
| Banco de dados | **Nenhum novo.** JSONL + índice SQLite reconstruível; PostgreSQL da VPS só para resumos do app |
| Backup | **rclone → Google Drive** (5 TB), por módulo, espelho navegável + `--backup-dir` com versões; sem restic |
| Autenticação do backup | OAuth da conta pessoal com client_id próprio; a conta de serviço não envia (cota 0) |

## 3. Níveis de representação

```
N2  Decisão     qual peça, encaixes, foco da foto            ← já treinável (bancada)
N1  Operações   ~20–25 por app, em português, JSON forçado   ← alvo do treino das Craft Apps
        │  compilador determinístico (código nosso, testável)
N0  Comandos    EffectCraft 760 · FilmCraft 717 · PhotoCraft 993
```

Regras comuns do N1: nomes em vez de índices; tempo em segundos ou âncora (`"@numero"`, `"@frase3+0.2"`);
espaço em frações 0–1 da tela; cor e fonte só por papel da pele; catálogos fechados (curvas, entradas, efeitos)
como `enum`; padrão omitido; layout relacional (o compilador mede o texto); render e exportação fora do N1.
O escape `bruto` (comando N0) fica no registro, nunca no vocabulário do modelo.

### EffectCraft (peça = comp, declarativo)

| Grupo | Operações |
|---|---|
| Composição | `comp`, `encaixe` |
| Elementos | `texto`, `forma`, `imagem`, `numero`, `grupo`, `profundidade` |
| Animação | `entrar`, `sair`, `mover`, `escalar`, `girar`, `opacidade`, `contar`, `tracar`, `destacar`, `escalonar`, `enfatizar` |
| Câmera e acabamento | `camera`, `efeito`, `desfocar`, `mascara` |
| Correção | `ajustar` |

Base existente: auxiliares de `estudio/pecas/_ec/nucleo.jsx` e `graficos/effectcraft.jsx`.

### FilmCraft (sequência, lista de operações)

Trilhas por papel: `base`, `apoio`, `grafismo`, `legenda`, `narracao`, `musica`, `sfx`. Mídia por referência
(`acervo:123`, `peca:<id>#n`, `foto:<id>#sujeito`).

| Grupo | Operações |
|---|---|
| Linha do tempo | `sequencia`, `colocar`, `remover_trecho`, `cortar`, `aparar`, `mover`, `velocidade` |
| Imagem | `enquadrar`, `ken_burns`, `soco`, `cor`, `transicao` |
| Texto | `legendas`, `texto` |
| Áudio | `tipo_audio`, `ganho`, `ducking`, `fade` |
| Revisão | `marcar` |

Cobre os 18 comandos que o `montar.py` usa hoje. Fora por ora: `multicam`, `mixer`, interface.

### PhotoCraft (documento declarativo)

| Grupo | Operações |
|---|---|
| Documento e elementos | `documento`, `imagem`, `texto`, `forma` (inclui seta e selo), `grupo` |
| Layout e estilo | `pos` (âncora ou relação), `contorno`, `sombra`, `brilho` |
| Ajustes | `ajuste` (contraste, saturação, níveis, curvas, LUT, mapa de gradiente), `vinheta` |
| Tratamento (receita) | `recortar_sujeito`, `separar_planos`, `reenquadrar`, `desfocar_fundo`, `nitidez`, `grao`, `look` |
| Variantes e correção | `variante` (A/B via layer comps), `ajustar` |

`contentAwareFill` não pode ser usado para remover marca d'água de banco de imagens.

## 4. Esquema do dataset

```
$AGENT_DATA/empreendimento/dataset/
├── registro/<app>/<tarefa>/AAAA-MM.jsonl   canônico, só cresce
├── artefatos/<sha>/                         N1/N0 grandes, prévias, quadros
├── esquemas/<app>/n1.v<N>.json              JSON Schema (gramática no llama.cpp)
├── ouro/<app>/<tarefa>.jsonl                avaliação fixa, nunca treina
├── exportacoes/<data>/{sft,dpo,eval}/       derivado
└── indice.db                                SQLite, reconstruível a partir dos JSONL
```

Envelope do registro: `id` (ULID), `t`, `app`, `tarefa`, `grupo`, `pai`, `versoes` {n1, compilador, pele, app},
`origem` (claude | local:<modelo>+<lora> | humano | traducao), `contexto` (estruturado, sem prompt pronto),
`saida` {n1 sha, tokens}, `n0` {sha, comandos}, `portao` {ok, erros, render_s, visao, quadros}, `humano`
{veredito, nota, motivo, comentario}, `metricas` (CTR e retenção depois), `uso` (sft | dpo_bom | dpo_ruim | eval | descartar).

| Tarefa | App | Saída | Fonte inicial | Mínimo SFT |
|---|---|---|---|---|
| `peca_animar` | EffectCraft | declarativo | fábrica, porte HTML → EC, edições à mão | 500 |
| `montar` | FilmCraft | operações, por trecho de 30–60 s | tradução do `montar.py` | ~1.500 trechos |
| `corrigir_montagem` | FilmCraft | operações (diferença) | `.fcproj` gerado × editado | 200 |
| `thumb_compor` | PhotoCraft | declarativo + variantes | `photocraft.py`, ranking das 8 candidatas | 300 |
| `foto_tratar` | PhotoCraft | N2 `{foco, recortar, separar_planos}` | episódios | 100 |

Regras: prompt montado na exportação (tags `<ficha>`, `<pele>`, `<ancoras>`, `<exemplos>`; resposta só JSON);
divisão 90/10 por `sha1(grupo)`; mudança de esquema N1 exige migrador `n1_vX_para_vY`, o registro original não muda;
cada exportação e cada LoRA levam manifesto com hash dos dados.

## 5. Fine-tuning

**Necessário, mas em degraus.** Antes de treinar, cada tarefa roda sem fine-tuning: esquema N1 forçado como
gramática + 3–5 exemplos aprovados parecidos (busca no registro) no prompt. A bancada mede contra o `ouro/`;
só se treina a tarefa que ficar abaixo da meta **e** já tiver o mínimo de exemplos. Expectativa: `foto_tratar`,
`thumb_compor` e `montar` por trecho resolvem com poucos exemplos ou LoRA leve; `peca_animar` (criação) é a que
mais precisa de LoRA e pode continuar com o Claude na fábrica se o local não alcançar.

**O que já existe** (nunca rodou: não há `.venv-treino` nem `agente-*.gguf`; houve 2 exportações em 2026-11-02):

- `studio/training.py`: `exportar` (chat, 90/10), `situacao`, `ambiente`, `treinar` (copia o GGUF para o roteador).
- `ia/treinar_lora.py`: QLoRA 4 bits com unsloth + `SFTTrainer` (r=16, treina só a resposta), base
  `unsloth/gemma-4-12b-it`, salva o LoRA e um **GGUF mesclado** `q4_k_m`.

**O que falta para o plano por app:**

| Lacuna | Ajuste |
|---|---|
| Sai um GGUF inteiro (~7 GB) por treino | Exportar só o **adaptador** em GGUF (`convert_lora_to_gguf.py` do llama.cpp) e carregar no roteador com `--lora`; o llama-server escolhe o adaptador por requisição, sobre uma base só |
| Exporta só as tarefas da bancada | Ler o registro canônico; system com o resumo do esquema N1 da versão |
| Só SFT | DPO (`trl.DPOTrainer`) quando houver ~100 pares por tarefa |
| Promoção automática do modelo | Portão: adaptador × base no `ouro/` (JSON válido, portão do render, nota da visão); só promove se ganhar |
| Sem rastreio | Manifesto por adaptador: hash da exportação, base, versão do N1, métricas; nome `ec-vN`, `fc-vN`, `pc-vN` |
| Template de chat fixo do Gemma (`instruction_part`) | Mapear o template por família, para poder trocar a base |
| Treino disputa a GPU | Rodar na vaga pesada (`nucleo/travas.py`), parando o llama-server antes |

Limite decidido: **só se treinam bases de até 12B** (QLoRA 4 bits, contexto de ~4 mil tokens, folga nos 16 GB). O `qwen3.8-27b`
do diretor e os demais modelos maiores seguem só com prompt + exemplos.

## 6. Backup

- Remote `gdrive` (`~/.config/rclone/rclone.conf`, `chmod 600`), raiz = pasta `backup_agent` do Drive.
- Layout: `backup_agent/<modulo>/atual/` (espelho) + `backup_agent/<modulo>/versoes/<data>/` (o que mudou ou saiu).
- Entra: todos os módulos de `~/agent-data`, `modelos/` só com os LoRA, dump da VPS. Fica fora: `cache/`, GGUF base.
  Total estimado: ~38 GB.
- O backup é só leitura no Drive: editar lá é desfeito no envio seguinte. Pasta editável, se precisar, fica à parte
  (`rclone bisync`), e o backup continua copiando a partir do PC.
- Retenção: 7 diários, 4 semanais, 12 mensais; teste de restauração mensal; status no painel.

## 7. Feito nesta etapa

- `.gitignore`: `google/service-account.json` e `*service-account*.json` (a chave nunca foi commitada); `chmod 600`.
- Conta de serviço testada: lê e edita o que é compartilhado; envio recusado (`403 … do not have storage quota`).
- rclone v1.76.0 em `~/.local/bin` (checksum conferido); remote `gdrive` com client_id próprio "agent-backup"
  (projeto GCP `swift-reef-479618-c3`); envio de 1 MB conferido com `rclone check`; pasta de teste apagada.

### Implementação (2026-11-08)

- F1–F8 implementadas (commit `19bee71` e seguintes). Equivalência N1 × código antigo: FilmCraft 0 diferenças em
  2.457 comandos (ep. 005 e 006); PhotoCraft 0 em 62 thumbs; EffectCraft `numero_impacto_ec` igual nas 12 combinações.
- Pendentes: 3 peças EC em `.jsx` (estradas/linhas do tempo) sem tradução; porte das 81 HTML para EC não disparado
  (cota do Claude); `.fcproj` manuais antigos não levantados (sem a montagem de antes da edição); backup da VPS
  depende de `BACKUP_VPS` em `~/.config/agent/backup.env`.
- Bancada sem treino (gemma-4-12b, `n1_montar`, 3 casos): 0,94–0,97, JSON 100%.
- Teste de fumaça do treino: `pc-v1` (6 casos, forçado) gerou o adaptador GGUF e o llama.cpp o carrega sobre a base;
  não promovido. Ambiente: `.venv-treino` com Python gerenciado pelo uv (precisa do `Python.h` para o triton); o
  treino para o `agent-worker` (VRAM) e religa no fim.

## 8. Plano de desenvolvimento

Cada fase fecha com o critério de pronto conferido e `infra/scripts/verificar`. Código novo do dataset em
`esteira/dataset/` (registro, índice, exportação) e `esteira/n1/<app>/` (esquema + compilador + levantador).

```
F0 ─► F1 (backup)
F0 ─► F2 (registro) ─► F3 (N1 + compiladores) ─► F4 (produção grava N1) ─► F5 (edições à mão)
                                                        └──────────────► F6 (bancada sem treino) ─► F7 (fine-tuning)
F8 (app) acompanha F1, F4 e F6
```

### F0 · Pré-requisitos (manual, você)

- Revogar o acesso "rclone" em myaccount.google.com/permissions; manter "agent-backup" e conferir que está
  **publicado** (em teste, o login vence em 7 dias).
- Conferir se a chave da conta de serviço está versionada no repositório do vault (`.credenciais/google/`).

### F1 · Backup

- `infra/scripts/backup`: lista por módulo de `~/agent-data` (exclui `cache/`, GGUF base; de `modelos/` só LoRA),
  `rclone sync … gdrive:<modulo>/atual --backup-dir gdrive:<modulo>/versoes/<data>`, limpeza da retenção,
  `estado.json` com início, fim, bytes e erro por módulo.
- Timer do systemd de usuário (diário, de madrugada, fora da vaga pesada da esteira).
- VPS: não há PostgreSQL no `docker-compose`; copiar só os volumes/dados persistentes dela (levantar quais).
- `infra/scripts/backup --restaurar <modulo> [--data D] --destino <pasta>` para o teste mensal.
- **Pronto:** primeira cópia completa (~38 GB) e uma restauração de módulo conferida com `rclone check`.

### F2 · Registro canônico

- `esteira/dataset/registry.py`: `gravar(app, tarefa, grupo, contexto, saida, …)` → linha JSONL em
  `registro/<app>/<tarefa>/AAAA-MM.jsonl` (ULID, escrita de linha inteira com `fsync`); `artefatos.py` por sha256;
  `atualizar_veredito(id, …)` como nova linha de evento (o registro não é reescrito).
- `esteira/dataset/index.py`: SQLite reconstruível (`./dark dataset reindexar`), consultas por app, tarefa,
  grupo, veredito e versão; `./dark dataset situacao` (contagem × mínimo por tarefa).
- Fábrica (`studio/factory.py`): cada rodada grava contexto + resposta do Claude + portão; a revisão grava o
  veredito; `fabrica/registro.jsonl` passa a citar o `id`.
- Thumbs: `thumbs/ranking.json` (já salvo) vira pares `escolhida`/`preterida` no registro.
- **Pronto:** uma rodada da fábrica e uma geração de thumbs aparecem no índice com contexto, saída e veredito.

### F3 · N1 v1 e compiladores (ordem: FilmCraft → PhotoCraft → EffectCraft)

- Por app, `esteira/n1/<app>/`: `esquema.json` (v1, operações da seção 3), `compilar.py` (N1 → JSONL de comandos
  para `<app>-cli run`, resolvendo âncoras, frações, papéis da pele e medidas de texto), testes de ida até o render.
- FilmCraft primeiro: cobre os 18 comandos do `montar.py`, é determinístico e tem dado em todo episódio.
- PhotoCraft: os 14 comandos de `photocraft.py`, com o layout relacional substituindo as duas passagens; receita
  de foto por canal em `perfis/<canal>.toml` (`[foto]`).
- EffectCraft: auxiliares de `pecas/_ec/nucleo.jsx` como operações; as 4 peças EC refeitas em N1.
- **Pronto:** para um episódio já produzido, `montar` via N1 gera a mesma sequência do caminho atual (comparação
  pelo `inspect sequence`); a thumb e as 4 peças EC renderizam iguais (comparação visual dos quadros).

### F4 · Produção passa a gerar N1

- `montar.py` e `photocraft.py` geram N1 → compilador (o caminho antigo fica atrás de opção até a F3 se provar).
- Fábrica com motor `effectcraft` escreve N1 em vez de `.jsx`; pedido em lote para portar as 81 peças HTML (Claude,
  na vaga "claude", dentro da cota).
- Toda produção grava registro (`origem: traducao` para o que veio do caminho antigo).
- **Pronto:** um episódio inteiro produzido só pelo caminho N1, com os registros de `montar`, `thumb_compor` e `foto_tratar`.

### F5 · Edições à mão viram dados

- Levantadores N0 → N1 por app (`esteira/n1/<app>/levantar.py`): FilmCraft pelo `inspect sequence` (colocar,
  aparar, mover, remover_trecho), PhotoCraft pelo `info` (camadas, posições, textos), EffectCraft pelas `props`
  das camadas (vira `ajustar`). O que não se levanta fica como `bruto` no registro.
- Gatilho: a detecção de arquivo salvo à mão que já existe (`.fcproj` manual, `manual_ec`, `.pcraft` editado)
  grava um registro `editada` com o `pai` apontando o gerado.
- **Pronto:** os 3 `.fcproj` manuais existentes viram registros `corrigir_montagem`.

### F6 · Bancada sem fine-tuning (linha de base)

- `ouro/` por tarefa (separado à mão a partir do registro); exportação `sft/`, `eval/` em `esteira/dataset/export.py`
  (substitui o `treino.exportar` para as tarefas novas; as de decisão continuam).
- Inferência: esquema N1 como gramática no llama-server + 3–5 exemplos aprovados parecidos (embeddings na :8082).
- Tarefas novas na bancada (`bancada.py`): JSON válido, portão do render, nota da visão, diferença para a referência.
- **Pronto:** tabela da bancada com a nota de cada tarefa sem treino; meta por tarefa definida a partir dela.

### F7 · Fine-tuning (bases até 12B)

- Montar `.venv-treino` (unsloth) e teste de fumaça com os 120 casos de `corte`, para validar treino → GGUF →
  llama.cpp na GPU.
- `treinar_lora.py`: salvar só o adaptador e converter com `convert_lora_to_gguf.py`; um adaptador por app
  (`ec-vN`, `fc-vN`, `pc-vN`) carregado com `--lora` no roteador; template de chat por família.
- Portão de promoção: adaptador × base no `ouro/`; só entra em uso se ganhar. Manifesto com hash da exportação,
  base, versão do N1 e métricas; adaptadores entram no backup.
- Treino na vaga pesada (`nucleo/travas.py`), parando o llama-server antes.
- DPO quando houver ~100 pares por tarefa.
- **Pronto:** um adaptador promovido para a primeira tarefa que atingir o mínimo.

### F8 · App (junto das fases)

- Com F1: status do backup no painel (último sucesso, erro, último teste de restauração).
- Com F4: veredito das thumbs e das montagens nas telas que já existem (aba do episódio).
- Com F6/F7: aba de dataset no Estúdio (contagem × mínimo por tarefa, notas da bancada, adaptador em uso).

### Riscos

- **Equivalência na F3:** se o N1 não reproduzir o caminho atual, o vocabulário ainda tem lacunas; ampliar o N1
  antes de seguir, e nunca expor `bruto` ao modelo.
- **Volume do EffectCraft:** depende da cota do Claude na fábrica; se não chegar a 500, `peca_animar` fica com o Claude.
- **Mudança das Craft Apps:** versão da app em cada registro; teste de ida dos compiladores a cada atualização.
