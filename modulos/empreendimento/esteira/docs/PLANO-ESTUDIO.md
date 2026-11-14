# Plano · Estúdio de vídeos (rede de canais)

> **Correção de rumo (01/11/2026):** template por canal → acervo de peças com ficha e direção por metadados.
> Ver `docs/PLANO-ACERVO.md`; onde os dois divergem, vale o PLANO-ACERVO.

Objetivo: produzir vídeos verticais (Reels/Shorts) e horizontais (longos e cursos), dark ou com apresentador,
com muito motion graphics e som coerente, rodando ≥ 80% na IA local. O Claude cria e refina os estilos (uma vez)
e socorre quando um portão reprova duas vezes.

## Requisito: tudo pela ferramenta

Toda operação (criar canal, identidade e estilo, produzir, aprovar portões, exportar, checar e instalar
dependências, trocar modelo local) roda pela aba **Estúdio** do app, com o backend/worker publicados. O terminal
é só para desenvolvimento; nenhuma etapa do uso diário depende de pedir algo ao Claude Code.

## Princípio

**Clareza antes de enfeite.** Cada frase do áudio tem uma intenção (número, comparação, processo, lista,
conceito, citação, emoção). O estilo define o tratamento de cada intenção:
- só motion graphics, quando a animação explica melhor que qualquer imagem;
- imagem/vídeo + motion por cima, quando há material real;
- apresentador + peça, quando a pessoa aparece.

A IA local não inventa o visual: classifica a frase e escolhe no cardápio do estilo.

## Dois fluxos

- **A · Identidade e estilo** (Claude, uma vez por canal/estilo): referências → Claude analisa e propõe o guia →
  piloto → correções viram regra → estilo travado e versionado.
- **B · Produção** (IA local, cada vídeo): vídeo + estilo → corte → portão 1 → diretor → render → portão final.

Hierarquia: **Canal** → **Identidade visual** → **Estilos** (vertical/horizontal × dark/apresentador/curso) →
**Vídeo**. A rede é aberta: botão **Adicionar canal** na aba Estúdio cria o canal (aproveitando o cadastro da aba
Canais) e abre o Fluxo A para a estrutura personalizada dele.

## Componentes

| Componente | O que é |
|---|---|
| Guia de estilo | dado (JSON + exemplos): identidade, catálogo de cenas, regras das 6 etapas, portões |
| Biblioteca de cenas | motion graphics parametrizados, vertical e horizontal, com a pele do canal |
| Motor de corte | corte pelo som (skill) + pelo texto (esteira) + conferência |
| Diretor local | frase → intenção → tratamento → cena + campos, sempre JSON com esquema |
| Compilador | JSON do diretor → HyperFrames (render) e → FilmCraft (exportação opcional) |
| Portões | validadores automáticos + aprovações (corte sempre; mapa opcional; final sempre) |
| Bancada de LLM | gabarito das nossas tarefas para escolher e acompanhar modelos |
| Base de aprovações | cada aprovação/correção gravada; vira gabarito e, depois, fine-tune |

## Fases

0. **Fundação**: skill → `skill-vertical-main`; Node + HyperFrames; licença da skill. Pronto: exemplo VSL
   remontado idêntico.
1. **Bancada de LLM**: gabarito (tomada, intenção, mapa de cenas, legenda, checagem visual); testar candidatos
   de texto e visão nos 16 GB. Pronto: modelo escolhido por papel, com nota medida.
2. **Corte unificado + portão 1**: som + texto, tomadas pelo LLM local, tela de aprovação emenda por emenda com
   reversão. Pronto: bruto sem palavra comida, aprovado sem ajuste manual.
3. **Identidade e estilo (Fluxo A)**: esquema do guia, análise de referências pelo Claude, VSL vertical
   convertido como primeiro estilo. Pronto: estilo travado e versionado.
4. **Biblioteca de cenas**: número/contador, comparação, processo/fluxo, lista, linha do tempo, gráfico de
   dados, citação, conceito, mapa, CTA — vertical e horizontal; absorve as peças da skill e os gráficos da
   esteira. Pronto: cada cena passa no portão visual isolada.
5. **Diretor local**: intenção → tratamento → cena; mídia do acervo e do enviado; validadores devolvem o erro;
   2ª reprovação vai ao Claude. Pronto: piloto com ≤ 20% de chamadas ao Claude.
6. **Legenda, som e acabamento**: legenda palavra a palavra; SFX ligados a eventos de motion com teto por
   segundo (sem trilha); −14 LUFS; relatório dos portões.
7. **Aba Estúdio**: canais (com Adicionar canal), identidades, estilos, produção, portões, progresso,
   exportação FilmCraft.
8. **Rede**: estilos horizontal, dark e curso; piloto aprovado por canal (benehistory, cosmoatomico,
   embarcados, thiagobenevide e os que entrarem).
9. **Fine-tune**: QLoRA 7–14B com a base de aprovações; nova rodada na bancada.

## Andamento

**Fase 0 · concluída (29/10/2026)**
- Skill movida para `modulos/empreendimento/skill-vertical-main` (`name: vertical`).
- Node 22.23.4 em `~/development/node` (fora do PATH, como o Flutter); Chromium do Playwright em
  `~/.cache/ms-playwright/chromium-*/chrome-linux64/chrome` (variável `CHROME`); telemetria do HyperFrames
  desligada (`HYPERFRAMES_NO_TELEMETRY=1`).
- Exemplo VSL remontado em `$AGENT_DATA/empreendimento/estudio/teste-fase0/`: lint 0 erros, render de 38,8 s em
  ~53 s (6 workers), peças no mesmo instante da referência. Cena 16:9 (1920×1080) renderizada: 4 s em 6 s.
- Falta para a ferramenta: checagem/instalação dessas dependências por botão na aba Estúdio; `opencv` (rastreio
  da boca) só quando entrar o apresentador.

**Fase 1 · bancada (29/10/2026)**: `esteira/bancada.py` + gabarito (64 intenções/cenas rotuladas, 120 cortes revisados,
18 legendas, 16 quadros de visão). Resultado (nota 0–1 / ms; corte = acurácia balanceada):

| modelo | intenção | cena | legenda | corte | visão |
|---|---|---|---|---|---|
| qwen3-14b (antigo) | 0,72 | 0,83 | 0,64 | 0,64 | — |
| qwen2.5vl-7b (antigo) | 0,61 | 0,75 | 0,58 | 0,64 | 0,81 |
| **gemma-4-12b** | 0,73 | 0,83 | 0,64 | **0,74** | **0,95** |
| gpt-oss-20b | 0,75 | 0,73 | 0,64 | 0,70 | — |
| **qwen3.8-27b** (parte na RAM) | **0,89** | **0,89** | **0,72** | 0,62 | 0,92 |
| gemma-4-26b-a4b | 0,69 | 0,77 | 0,69 | **0,75** | 0,89 |

Decisão: padrão de texto e visão = Gemma 4 12B (um modelo só na VRAM); diretor do Estúdio (`estudio_cena`) =
Qwen3.8-27B pelas Opções (~7,5 s por cena). `--fit on` no llama-server (modelos grandes com parte na RAM).

**Fases 3–7 · primeira versão (29–30/10/2026)**: pacote `esteira/estudio/` (estilo como dado, kit de 13 cenas 16:9/9:16,
diretor local com validação e escalação, compilar/render NVENC/áudio/verificar), API `/api/v1/estudio`, aba Estúdio no
app (canais + Adicionar canal, estilos + referências + proposta do Claude, produções com portões, motor e bancada).
Teste de ponta a ponta no episódio de teste `finlumia-990` (1º minuto do 004): 19 trechos, 17 decididos pela IA local,
2 pela regra; −14,03 LUFS / −1,01 dBTP nos dois formatos; render de 60 s em ~45 s (NVENC).
Pendente: fase 9 (fine-tune).

**Fase 2 · corte unificado (30/10/2026)**: `esteira/estudio/corte.py` = motor da skill (`3-corte.py`) sobre a
narração editada pela esteira (as tomadas continuam escolhidas pelo texto em `cortes.aplicar`). Fala pelo som (volume +
inclinação espectral), vícios pelo faster-whisper com o prompt de vícios (não precisou do whisper.cpp), palavra comida
protegida (só a audível: o Whisper estica a 1ª palavra da frase por cima do silêncio), respiro de 0,15 s em fim de frase,
conferência (texto da narração × do corte, ignorando grafia "oito"/"8"; repetições; pausas > 0,45 s). Cada buraco tirado
é uma emenda no app (antes/depois e reversão; reverter reabre o portão e refaz o corte na fila). O resto do Estúdio
lê os tempos remapeados (`corte.palavras/frases/novo/audio`). Portão 1 só aprova com o corte pelo som feito e
atualizado. CLI `./dark estudio-corte <ep>`; API `GET/POST /producoes/{ep}/corte`, `PUT .../corte/emenda`; app
`estudio/corte_tela.dart`. Teste no 990: 60,0 s → 54,6 s, 17 emendas, 0 trechos a conferir, texto 97% igual.

**Modo apresentador (30/10/2026)**: `esteira/estudio/camera.py`. A câmera do episódio (importada em modo
apresentador, sincronizada com o WAV em `camera.json`) segue os dois cortes (tomadas da esteira + corte pelo som):
cada quadro de saída aponta para o quadro certo da câmera (sem deriva) → `estudio/corte/camera.mp4` (NVENC). Rosto
pelo OpenCV 4 (Haar, mediana de 24 quadros) → `object-position` e origem do punch-in. Layouts por trecho
(`layouts`): FULL (punch 1,06; 1,16 em frase de impacto, corte seco), SPLIT (cena de motion na área livre + câmera
num card: embaixo no 9:16, à direita no 16:9; troca animada 0,45 s), `tela` (só capítulo, ≤ 7%) e B-roll (mídia
curada, um item sim um não, ≤ 30%). Regras em `regras.apresentador` do estilo; semente `finlumia-apresentador`.
Teste no 990 com o vídeo de referência da skill como câmera: FULL 65% · SPLIT 15% · B-roll 20%, 1692 quadros =
56,4 s exatos, −14,04 LUFS nos dois formatos.

**Controles do template (30/10/2026)**: o estilo é o template. Fontes por papel (títulos, texto, rótulos, legenda),
escolhidas num catálogo OFL do kit (`estudio/fontes.py`: 16 famílias) ou enviadas pelo app (.ttf/.otf em
`$AGENT_DATA/.../estudio/fontes/`); o compilador copia só as usadas e gera `assets/fontes.css`; fonte fora do
catálogo vira aviso. Legenda (`regras.legenda` por formato + `regras.legenda_visual`: tamanho, posição
baixo/meio/abaixo do rosto, 1–3 palavras, caixa alta, sombra/contorno/fundo, palavras-chave em destaque).
Intensidade baixa/média/alta em três eixos (`regras.niveis`; tabela `estilo.NIVEIS`): som (volume, teto por
segundo, quais cenas soam), motion (tempo em motion, frequência de peças, B-roll do apresentador) e efeitos
(`regras.efeitos`: flash, zoom/movimento/socos/punch, brilho, grade). Ajuste fino no "Avançado" deixa o eixo
"personalizado". A produção pode trocar o nível só daquele vídeo (`--intensidade`, portão 2). "Duplicar" cria
template novo (`estilo.duplicar`, `POST /estilos/{id}/duplicar`).

**Cenas no padrão das peças da esteira + apontamento (30/10/2026)**: o kit (`kit/estudio.js`/`.css`) tinha 13 cenas
num molde só (pílulas pequenas) e ficou abaixo das peças do EffectCraft. As cenas foram refeitas com a linguagem dos
`graficos/modelos/*.html` (de onde vieram as peças do EffectCraft): rótulo mono espaçado com traço, número gigante
contando com unidade na cor de destaque, capítulo em serifa itálica letra a letra, "vs" em serifa, etiquetas de terço
inferior com faixa, cartões numerados, véu que escurece e desfoca a mídia, entradas com desfoque. Papel de fonte novo
`fonte_editorial` (Playfair Display, com itálico). Prova: página com as 12 cenas nos dois formatos.
Apontamento (`estudio/apontamento.py`): depois do corte, a pessoa marca por trecho a cena (ou "auto"/"nenhuma");
confirmar libera o diretor e põe a produção na fila (`GET/PUT /producoes/{ep}/apontamento`, app
`estudio/apontamento_tela.dart`). Na cena marcada a IA local só preenche âncora/título/valores (`por: "voce"`), e
variedade/orçamento não a trocam. 

**Custo: Claude só na referência (30/10/2026)**: o Claude entra só no Fluxo A, uma vez por estilo, e devolve dados
(pele com fontes do catálogo, `regras.visual`, guia, exemplos); não escreve código. Na produção, o socorro do diretor
ao Claude fica desligado por padrão (Opções → "Socorro do Claude no Estúdio", `opcoes.socorro_claude`): a 2ª falha
da IA local cai na regra fixa; o apontamento cobre os trechos difíceis. Variedade visual = `regras.visual` (dado):
entradas que alternam por cena (desfoque, deslizar, revelar, escala), fundo das cenas de motion (véu, sólido,
gradiente), alinhamento, cartões (vidro, contorno, sólido) e cantos; editável na aba Cenas do estilo.

## Piloto

**Finlumia** (finanças pessoais; perfil `perfis/finlumia.toml`: sóbrio, dourado `#f5c518`, números em
destaque) até o fim das fases 0–7, depois os demais canais na fase 8.

## Decisões

- Finlumia: os primeiros 50 vídeos são **dark** (narração + motion + mídia); depois entra o apresentador. O
  piloto exercita o estilo dark primeiro; os layouts com rosto (FULL/SPLIT da skill) ficam para a fase 8.
- **Sem trilha musical** em nenhum formato: o som é voz + SFX coerentes com o motion.
- Licença da skill-reel: autorizada pelo usuário para incorporar.
- Piloto Finlumia nos **dois formatos**: horizontal longo e vertical (Shorts), com as mesmas cenas em duas
  composições (a biblioteca da fase 4 nasce com as duas versões de cada cena).
