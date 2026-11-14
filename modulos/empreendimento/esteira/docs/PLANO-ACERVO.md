# Plano · Acervo de motion e direção por metadados

Correção de rumo do Estúdio (`docs/PLANO-ESTUDIO.md`), decidida em conversa em 01/11/2026. Ainda não
implementado. Este arquivo é a referência para começar a codificar em outro chat.

## O que estava errado

O Estúdio nasceu com **um template por canal**: o estilo (`studio/style.py`) traz a lista fixa de cenas
(`regras.cenas`) e o modo (`modo: apresentador`) vale para o estilo inteiro. O cardápio é pequeno (17 cenas em
`bancada.CENAS`, cada uma descrita por uma frase só) e mora num arquivo único (`kit/estudio.js`, ~700 linhas).
Consequência: a IA local tende a repetir as mesmas peças, o vídeo fica com a mesma cara do começo ao fim e uma
animação feita para um canal não serve a outro.

## O que fica (já funciona e continua)

- Corte pelo som + portão do corte (`studio/cut.py`), câmera cortada igual ao áudio (`studio/camera.py`).
- Compilação HyperFrames + render NVENC + −14 LUFS + conferência (`compilar.py`, `motor.py`, `verificar`).
- Fontes por papel e catálogo OFL (`fontes.py`), legenda e intensidade (`estilo.NIVEIS`), gatilhos (`gatilhos.py`).
- Bancada de LLM (`esteira/bench.py`), apontamento manual (`apontamento.py`), versões do estilo, prévia leve.
- Claude só cria (Fluxo A); a produção de cada vídeo é IA local + código.

## Decisões

1. **Acervo de animações em código, compartilhado entre canais.** Toda animação criada com o Claude entra num
   acervo único. Uma animação feita para o Cosmoatomico (marrom/preto, espaço) pode ser usada no Finlumia
   (finanças, dourado): a IA local adapta conteúdo e pele e mantém a estrutura.
2. **Ninguém escolhe cena a cena.** A IA local decide pelos metadados; a pessoa só corrige quando quiser
   (o apontamento continua como ajuste opcional, não como passo obrigatório).
3. **Adaptação em três camadas** (a animação já nasce preparada para isso):
   - **Pele, por código, sem IA:** nenhuma cor/fonte fixa no código da animação, tudo por variáveis
     (`--cor-principal`, `--cor-destaque`, `--fundo`, `--fonte-titulo`, `--fonte-texto`…). Trocar de canal =
     aplicar a identidade do canal.
   - **Conteúdo, pela IA:** encaixes declarados (textos, números, itens, ícone, imagem). Elemento temático
     (o foguete do Cosmoatomico) também é encaixe: no Finlumia vira um gráfico subindo.
   - **Estrutura, pela IA via botões declarados:** as "pequenas modificações" são parâmetros com valores
     permitidos (quantidade de itens, direção, velocidade, ênfase, fundo, posição). Reescrita livre do
     código só como último recurso, com validação automática e volta à original se falhar.
     *(Recomendação aceita como padrão; confirmar no início da implementação.)*
4. **Configuração do canal ≠ repertório.** O "template" deixa de existir como template e vira a
   **configuração geral do canal**, que já existe hoje no estilo (`studio/style.py`): paleta, fontes por papel,
   legenda, nível de motion/som/efeitos (padrão do usuário: **alto**), tom e o que o canal **não** usa (filtro).
   Não carrega lista de cenas. É **padrão fixo**: a IA local (e o Claude ao criar peças) sempre respeita e
   **nunca altera** a configuração; as peças é que se adaptam a ela. Mudança só pela pessoa, na tela do canal,
   gerando nova versão (`id@N`, como hoje). Isso evita conflito entre peça e canal.
5. **Modo por vídeo, marcado no roteiro.** Ao escrever o roteiro (pessoa + IA) já se define se o vídeo é
   **dark** (entra áudio) ou **apresentador** (entra MP4 da câmera). O mesmo canal pode ter os dois. A esteira já
   lê `modo:` do roteiro (`[producao] modo`, `esteira/production.py`); o Estúdio passa a usar esse mesmo campo em
   vez de `estilo.modo`.
6. **Direção por bloco (parágrafo), não por frase.** O bloco é a unidade de decisão; dentro dele a peça pode
   ter batidas sincronizadas às palavras.
7. **Longo e curto com perfis de ritmo diferentes** (dado, não código separado):
   - **Longo (15–45 min):** blocos de 20–60 s, motion moderado, capítulos, uma "virada" visual a cada
     20–40 s; anti-repetição olhando uma janela de vários minutos.
   - **Curto (30–60 s; Shorts, Reels, TikTok):** gancho nos 2 primeiros segundos, troca visual a cada
     2–4 s, legenda forte, peças rápidas.
   - Os curtos têm **roteiro próprio** (regra). Corte de vídeo longo é exceção e manual.
8. **2D e 3D, em níveis de peso:**
   - **2D:** texto, caixas, tabelas, formas, caminhos/trilhas, gráficos. A maior parte do acervo.
   - **2,5D (CSS 3D no Chromium do HyperFrames):** `perspective` + `rotateX/Y`, profundidade em camadas,
     paralaxe. Cobre o "vídeo do monitor em perspectiva durante a fala", cartões inclinados e câmera
     passando por planos. Custo de render quase igual ao 2D. **Começar por aqui.**
   - **3D real (Three.js dentro da composição):** objetos 3D (globo, moedas, modelos, partículas). Render
     mais pesado; peças marcadas como `peso: 3d`, com cota por vídeo. Entra depois do 2,5D estar sólido.

## Corte do áudio: palavra nunca é comida (prioridade máxima)

Problema relatado: a fala é cortada no meio da palavra ("casa" vira "ca"). A causa é o **código** das bordas
dos cortes, não a IA local: a IA decide quais trechos ficam (tomada, retake, vício), mas onde a tesoura entra
é decidido por limiares de energia e pelos tempos de palavra do Whisper. Revisão do código em 01/11/2026:

### Como o corte funciona hoje (dois cortes em série)
1. **Esteira** (`esteira/cuts.py`): escolhe as tomadas pelo texto e corta a gravação bruta; cada borda procura
   silêncio no envelope de energia (`envelope`, `_silencio`, `_borda_ini/_borda_fim`, `_vale`).
2. **Estúdio** (`esteira/studio/cut.py`): sobre a narração já editada, corta de novo pelo som (`fala` →
   máscara de fala, `vicios`, `segmentos`), com outro detector e outros limiares.

### Falhas encontradas
| # | Onde | Falha | Efeito |
|---|---|---|---|
| 1 | `studio/cut.py:67` (`fala`) | Só conta como fala quadro com `tilt > 0` (mais energia nos graves que nos agudos). Consoantes surdas (**s, x, f, ch, t, k, p**) têm energia nos agudos (tilt negativo) e saem da máscara. | "mais", "isso", "fez", "dois" perdem o fim; "s" final em português é muito comum. |
| 2 | `studio/cut.py:124` (`segmentos`) | A proteção só devolve a palavra se **menos de 10%** dela ficou na máscara. Palavra cortada pela metade (50% dentro) não é protegida. | É exatamente o "casa" → "ca". |
| 3 | `studio/cut.py:67` e `cortes.py:574` | Limiar de fala/silêncio é **global** (percentil do arquivo inteiro). Em vídeo de 15–45 min o volume varia (distância do microfone, cansaço). | Nos trechos mais baixos, finais de palavra fracos viram "silêncio". |
| 4 | `cortes.py:582` (`_silencio`) + `SILENCIO_MIN = 0.12` | "Silêncio" = 120 ms abaixo de p60 − 28 dB, só por energia. Final átono ("casa", "muito") e fricativa final ficam abaixo disso. | A busca acha um falso silêncio **dentro** do fim da palavra e a borda cai nele (`:611`). |
| 5 | `cortes.py:614-617` (`_borda_ini`) | A busca para trás começa **40 ms dentro** da palavra (`ini_w + 0.04`); um "s"/"f" inicial fraco é lido como silêncio. | Some o começo: "sempre" → "empre". |
| 6 | `cortes.py:611/617` e `:646` (`_vale`) | Sem silêncio à vista, corta no ponto de **menor energia** da janela, que muitas vezes é o fecho de um "p/t/k" **dentro** da palavra. As exclusões de retake (`:646`) usam janela de 350 ms em volta de um tempo do Whisper. | Corte no meio da palavra vizinha ao retake. |
| 7 | `studio/cut.py:98` (`vicios`) | "e", "a", "um", "o" com 0,45–1,6 s viram vício e são cortados de `ini + 0,14` até o fim **pelo tempo do Whisper**, que erra 0,1–0,3 s e costuma esticar a palavra por cima da seguinte. | Leva junto o começo da próxima palavra. |
| 8 | `studio/cut.py:142` (`ISLAND`) | Trechos de fala < 70 ms isolados são descartados. | O estouro final de "t/k/p" ("fiz**t**", "pac**to**") separado por um vale curto some. |
| 9 | os dois | **Nenhuma regra impede borda dentro de uma palavra**: as bordas nunca são conferidas contra os intervalos das palavras. | Todas as falhas acima passam sem alarme. |
| 10 | `studio/cut.py:246` (`conferir`) | A conferência compara só o **texto**. O Whisper "completa" palavra truncada pelo contexto ("ca…" transcrito como "casa"). | Palavra comida passa como certa. |
| 11 | arquitetura | Dois cortadores em série, com detectores diferentes; o segundo corta áudio que o primeiro já cortou. | Erros se somam; difícil saber qual etapa comeu a palavra. |
| — | `studio/cut.py:165-166` | `return` duplicado (código morto). | Só limpeza. |

### Correção (implementar antes da fábrica)

**Feito em 01/11/2026** (itens 1–7): `esteira/edges.py`, `esteira/alignment.py` + `ia/alinhar_ctc.py`,
`tests/test_edges.py`. Pendente: WAVs reais gravados pela pessoa nos testes (item 7) e corte único (item 4: os dois
cortadores já usam o mesmo validador e detector, mas o Estúdio ainda corta pausas e vícios por conta própria).
1. **Tempos de palavra precisos por alinhamento forçado.** O texto é conhecido (roteiro + transcrição), então
   alinhar fonema a fonema (CTC, ex.: `torchaudio` MMS_FA, que cobre português) dá início/fim de palavra com
   erro de ~20–30 ms, contra 100–300 ms do Whisper. O Whisper continua para *o que* foi dito; o alinhamento
   decide *onde*.
2. **Regra de ouro em código:** nenhuma borda pode cair dentro de `[ini − 30 ms, fim + 40 ms]` de uma palavra
   mantida. Toda borda passa por um validador; se cair dentro, empurra para o vão mais próximo entre palavras;
   se não houver vão, **não corta** (melhor sobrar uma pausa que comer uma sílaba).
3. **Detector de fala que enxerga consoante surda:** fala = voz (graves) **ou** fricção (energia em 3–8 kHz
   acima do ruído de fundo), com ruído de fundo medido localmente (janela móvel de ~10 s), não por percentil
   global.
4. **Um corte só, em duas decisões:** a esteira decide *o que* sai (tomadas, retakes, vícios, gaguejos) e um
   único módulo de bordas decide *onde* cortar, com o mesmo detector e o validador do item 2. O corte pelo som
   do Estúdio passa a só encurtar pausas, sem cortar palavra.
5. **Vícios cortados só no vão alinhado**, nunca por "início + 0,14 s".
6. **Conferência que mede, não só lê:** para cada palavra mantida, comparar a duração dela no áudio final com
   a do alinhamento original; encurtou > 25% ou perdeu o fim com energia → alerta "palavra cortada" com o
   trecho para ouvir no app. O portão do corte não aprova com alerta aberto.
7. **Testes de regressão** (`tests/`): WAVs curtos gravados pela pessoa com finais difíceis ("casas", "mais",
   "fez", "muito", "pacto", "sempre") e as falhas já encontradas; o teste garante que nenhuma borda cai em
   palavra e que a duração de cada palavra se mantém.
8. A IA local continua só decidindo trechos (tomada × retake); receber tempos certos já tira a maior parte da
   "confusão" dela.

As falhas que a pessoa já tinha encontrado devem ser conferidas contra esta lista no início da implementação
e virar casos de teste.

## Peça do acervo (unidade)

Uma pasta por peça em `esteira/studio/pecas/<id>/` (o nome `acervo/` já é do acervo de mídia, `esteira/library.py`):
- `peca.js` / `peca.css`: a animação, lendo só variáveis de pele e os encaixes/botões recebidos.
- `ficha.json`: os metadados (abaixo). É o que a IA lê; tem de ser tão cuidada quanto o código.
- `prova/`: quadros renderizados com **duas peles diferentes** × **9:16 e 16:9** (portão de entrada).

### Ficha (`ficha.json`)

| Campo | Para quê |
|---|---|
| `id`, `versao`, `origem` (canal onde nasceu), `motor` (`html` · `effectcraft`) | rastreio e render |
| `comunica` | o que a peça explica, em uma frase ("mostra crescimento ao longo do tempo") |
| `intencoes` | número, comparação, processo, lista, narrativa do passado, conceito, citação, chamada… |
| `exemplos_sim` (5–10 frases) / `exemplos_nao` (3–5) | o que mais ajuda o modelo local a casar frase × peça |
| `temas` + `neutra` (bool) | neutra serve a qualquer canal; temática exige trocar o encaixe temático |
| `tom`, `energia` | calma, dramática, didática; baixa/média/alta |
| `peso` | `texto` · `2d` · `2_5d` · `3d` · `midia` (mídia + motion por cima) |
| `formatos`, `duracao_min`/`max` | 9:16, 16:9; segundos |
| `rosto` | `nao_usa` · `precisa_area_livre` · `sobre_camera` (ex.: monitor em perspectiva) |
| `encaixes` | nome, tipo, limites (título ≤ 40 car.; 3–6 itens; número com unidade; ícone; imagem) |
| `botoes` | parâmetro, valores permitidos, padrão |
| `batidas` | quais encaixes entram sincronizados a palavras do bloco |
| `sfx` | eventos que soam (entrada, contagem, impacto) → categoria do pacote de SFX |

## Direção (produção de cada vídeo)

1. **Leitura do roteiro (IA local):** divide em blocos (os parágrafos do roteiro) e classifica cada um
   (intenção, tom, entidades: números, datas, nomes). Saída em JSON com esquema.
2. **Tratamento do bloco (regra + IA):** só voz com motion, mídia com motion, câmera cheia, câmera + peça,
   2,5D sobre a câmera, 3D. Respeita o modo do vídeo e o perfil de ritmo.
3. **Busca de candidatas (código):** filtra por formato, duração, rosto, filtro do canal; ordena pela
   semelhança entre o bloco e os `exemplos_sim` (modelo local de embeddings no llama.cpp); penaliza peças
   usadas recentemente e tratamentos repetidos; aplica cotas (3D, mídia, só texto). Saem **5 candidatas**.
4. **Escolha (IA local):** escolhe 1 das 5 com justificativa curta.
5. **Preenchimento (IA local):** encaixes + botões dentro dos limites; o código valida e devolve o erro;
   2ª falha → próxima candidata (sem Claude por padrão).
6. **Pele (código):** aplica a identidade do canal → compila → render → conferência.

A anti-repetição é sempre código: a IA tende a repetir o que funcionou.

## Fábrica de peças (Claude gerando de forma contínua)

Hoje o acervo de peças está **vazio**: o que existe são as cenas do kit e os gráficos do fluxo anterior. A
fábrica é o fluxo, dentro do Estúdio, em que o Claude gera peças sem parar e a pessoa revisa. É o único lugar
em que o Claude trabalha; depois, a produção de cada vídeo usa só a IA local.

**Como funciona (tudo pela aba Estúdio → Fábrica, nada pelo terminal):**
1. **Pedido:** a pessoa liga a fábrica e diz o quê e quanto: um pedido livre ("3 animações de linha do tempo
   com fotos de época"), uma referência (vídeo/imagem enviada) ou "preencher lacunas". Nas lacunas, o código
   conta o acervo por intenção × peso (2D/2,5D/3D) × formato e sugere o que falta.
2. **Geração:** cada peça é uma tarefa na fila da esteira (vaga "claude", `claude -p` com teto de custo,
   `esteira/ia/claude.py`). O Claude escreve peça + ficha seguindo o esquema e o guia de escrita de peças
   (variáveis de pele, encaixes, botões). Recebe como contexto as fichas parecidas que já existem, para não
   duplicar.
3. **Portão automático:** lint, render nas duas peles × dois formatos, encaixes no limite (texto máximo
   cabe), checagem visual local. Reprovou → volta ao Claude uma vez com o erro; reprovou de novo → descartada
   com o motivo.
4. **Revisão da pessoa (fila de revisão no app):** prévia animada nas peles dos canais e a ficha legível.
   Ações: **aprovar** (entra no acervo), **pedir ajuste** (comentário vira nova rodada do Claude na mesma
   peça), **variação** (gera irmã com outro visual), **reprovar** (motivo guardado e enviado como regra nas
   próximas gerações).
5. **Modo contínuo:** a fábrica segue gerando até atingir a quantidade pedida aprovada ou o teto de custo do
   dia; a pessoa revisa quando puder (notificação no app).

O que a revisão ensina (motivos de reprovação, ajustes pedidos) vira **guia de escrita de peças**, um arquivo de
regras lido em toda geração, para o Claude errar menos a cada lote.

**Base inicial:** as 17 cenas atuais (`kit/estudio.js` + `bancada.CENAS`) e os gráficos do fluxo anterior
(`graficos/modelos/*.html`, `graficos/effectcraft.jsx`) viram as primeiras peças, cada uma com ficha completa.
O kit fica só com o núcleo comum (legenda, câmera, transições, utilitários). Junto com as peças entram o pacote
de SFX por categoria de evento, transições e fundos, também como peças com ficha.

## Dois motores de geração, para comparar

As peças podem ser escritas de duas formas. As duas são testadas e comparadas antes de escolher:

| | **Motor HTML** (código direto) | **Motor EffectCraft** (fluxo anterior) |
|---|---|---|
| O que o Claude escreve | HTML/CSS/JS + GSAP para o HyperFrames | script `.jsx` no modelo de objetos do EffectCraft (`graficos/effectcraft.jsx`) |
| Saída | composição renderizada no Chromium (NVENC) | `.ecproj` com camadas nomeadas → `effectcraft-cli render` (ProRes 4444 com alfa) |
| Edição à mão | no código | no EffectCraft, camada a camada |
| Pontos fortes esperados | rápido, 2,5D por CSS, Three.js, tudo no mesmo render | efeitos de pós (desfoque, brilho, máscaras) e acabamento de motion |

- **Mesma ficha** nos dois (campo `motor: html | effectcraft`); a direção não muda conforme o motor.
- **Ordem:** primeiro o motor HTML (é o atual do Estúdio). Funcionando, o mesmo lote de pedidos é gerado também
  no EffectCraft.
- **Comparação**, com o mesmo conjunto de pedidos nos dois: nota da pessoa na revisão, taxa de aprovação no
  portão, tempo e custo de geração, tempo de render, acerto da IA local ao preencher, fidelidade da troca de pele
  e facilidade de ajuste à mão. Resultado: usar um só, ou cada motor para o tipo de peça em que ganha. Se o
  motor HTML ficar complexo demais, voltar ao EffectCraft é uma saída aceita.

## Peça de referência: a citação de PDF

A citação do fluxo anterior é a régua de qualidade: a página do artigo em tela, zoom no trecho, grifo nas
palavras da frase citada e a tradução (`graphics/pdf.py` acha o trecho e gera a página com os retângulos; peça
de citação em `graficos/modelos/citacao.html` e em `graficos/effectcraft.jsx`). É a **primeira peça da
fábrica**, refeita nos dois motores e com mais efeitos: página em perspectiva 2,5D, câmera que percorre a
página, grifo que acompanha a fala palavra a palavra, desfoque no resto da página e tradução entrando em
sincronia. Ela serve de modelo do padrão visual esperado de todas as peças.

## Aprendizado

Cada escolha e cada correção da pessoa (troca de peça, ajuste de encaixe) vira registro na base de aprovações
→ alimenta a bancada (nova tarefa: "bloco → peça certa entre 5") e, depois, o fine-tune (fase 9 do plano antigo).

## App (aba Empreendimento)

**Ficam como estão** (só ganham as funções novas, nunca são removidas): Acompanhamento (**Monitor**,
**Processos**, **Custos**) e Configuração (**Acervo**, **Opções**). Novos fluxos (fábrica, motores, alertas de
corte, custos do Claude da fábrica) entram nelas: processos da fábrica no Monitor/Processos, gasto da fábrica em
Custos, opções da fábrica e do corte em Opções.

**Mudam** as etapas do início da esteira (Canais → Estúdio → Roteiros → Fila → Produção) para o fluxo novo:
configuração do canal, fábrica/acervo, roteiro com modo, direção por bloco e revisão.

Na aba Estúdio:

- **Acervo:** galeria das peças animadas, com filtro pela ficha e prévia na pele de qualquer canal.
- **Produção:** linha do tempo por bloco (peça escolhida, as outras 4 candidatas, trocar com um clique) e
  render só do bloco alterado.
- **Configuração do canal:** a tela de estilo atual, sem a lista de cenas e sem o modo, com o filtro do que o
  canal não usa.
- **Fábrica:** pedido (livre, referência ou lacunas), quantidade, motor, teto de custo; fila de revisão com
  aprovar / pedir ajuste / variação / reprovar; comparação entre os motores.

## Mudanças no código atual

| Hoje | Passa a ser |
|---|---|
| estilo como template (`studio/style.py`) | configuração geral do canal, padrão fixo |
| `estilo.regras.cenas` (cardápio por estilo) | filtro do canal sobre o acervo |
| Fluxo A: Claude propõe só dados do estilo (`identidade.py`) | fábrica: Claude gera peças + fichas, pessoa revisa |
| `estilo.modo` (apresentador/dark) | `modo:` do roteiro (já existe na esteira) |
| `bancada.CENAS` (descrição de uma frase) | `estudio/pecas/*/ficha.json` |
| `kit/estudio.js` monolítico | núcleo comum + uma pasta por peça |
| diretor frase/trecho → cena do cardápio | blocos → tratamento → 5 candidatas → escolha → preenchimento |
| apontamento obrigatório antes do diretor | ajuste opcional depois da direção |
| ritmo implícito | perfis `longo` e `curto` (dado) |

## Ordem sugerida

0. **Corte do áudio** (seção acima): alinhamento forçado, validador de bordas, detector com consoante surda,
   corte único, conferência por duração e testes. Vem antes de tudo: sem isso nenhum vídeo sai bom.
1. Configuração do canal (estilo atual sem lista de cenas e sem modo; nível padrão alto) + esquema da ficha +
   formato da peça (variáveis de pele, encaixes, botões) + portão de entrada.
   **Feito em 01/11/2026:** `regras.filtro` no lugar de `regras.cenas` (migração automática), níveis padrão alto,
   produção com o `modo:` do episódio (`estilo.com_modo`), `studio/piece.py` (ficha, `validar_dados`, portão: código +
   prova no Chromium em 2 peles × formatos com texto máximo e área segura), `ESTUDIO.peca` no kit, `pecas/GUIA.md`,
   peça de referência `pecas/numero_impacto`, API `/estudio/pecas`. O campo `modo` do estilo ficou só para amostra/teste
   (as telas de layout do app ainda dependem dele; sai junto com as telas, na etapa 8).
2. Fábrica de peças no motor HTML: fila de geração do Claude, portão, fila de revisão no app, modo contínuo e
   guia de escrita de peças. Primeira peça: citação de PDF.
   **Feito em 01/11/2026:** `studio/factory.py` (pedidos livre/referência/lacunas, `./dark estudio-fabrica` na vaga
   "claude", correção única pelo portão + visão local, revisão com aprovar/ajuste/variação/reprovar e lições no
   `GUIA.md`, teto do dia), encaixe `pagina`, prévia animada (`./dark estudio-peca-previa`), tela Fábrica no app e
   pedido pronto da citação de PDF (anexa `graficos/modelos/citacao.html`). A citação ainda não foi gerada: é o
   primeiro pedido a disparar pelo app.
3. Migrar as 17 cenas e os gráficos antigos para o acervo com fichas completas; provar a troca de pele entre
   Finlumia e Cosmoatomico.
   **Feito em 01/11/2026:** as 22 cenas do kit viraram peças aprovadas (`origem: kit`, encaixes `titulo`/`valores`,
   `compilar` traduz o mapa do diretor atual por `peca.legado`); o kit ficou só com o núcleo (mídia, câmera, legenda,
   fundo, véu, utilitários; `estudio.js` 755 → 392 linhas, `estudio.css` 345 → 139). Dos gráficos antigos, `comparacao`
   e `fonte` viraram `comparacao_atributos` e `fonte_dado` (em revisão); `numero`, `lista`, `capitulo` e `frase` já
   estão cobertos pelas cenas migradas, `citacao` é o pedido pronto da fábrica e `caixas` é ferramenta do editor
   manual. Estilo semente `cosmoatomico-dark`; `peca.prova_canais` (aba Fábrica → Troca de pele) passou as 22 peças
   nas duas peles × dois formatos sem problema. Pendente: transições, fundos e pacote de SFX como peças com ficha
   (hoje o SFX já vai por categoria na ficha, mas fundo e transições continuam no núcleo do kit).
4. Fábrica também no motor EffectCraft; comparação com o mesmo lote de pedidos e decisão de motor por tipo de peça.
   **Feito em 01/11/2026:** peça EffectCraft = `peca.jsx` + a mesma ficha; script = DADOS + `pecas/_ec/nucleo.jsx`
   (pele por papel, utilitários) + peça + `_ec/fim.jsx` (saída e medição da área segura); `studio/ec.py` (fontes da
   pele copiadas para `~/.local/share/fonts`, portão com prova nas 2 peles × formatos, prévia MP4, WebM VP9 com alfa
   por cena na compilação, escrito no HTML na camada `#ec` porque o HyperFrames só extrai quadros dos vídeos que
   estão no HTML estático); referência `numero_impacto_ec`; `GUIA_EC.md`. Fábrica: motor por pedido (html,
   effectcraft, ambos = o mesmo pedido nos dois, auto = decisão por intenção), nota 1–5 na revisão,
   `fabrica.comparacao()` (portão, rodadas, custo, tempo, render, aprovação, nota, troca de pele; geral e por
   intenção) e sugestão aplicável na tela da Fábrica. Pendente: rodar o lote real nos dois motores e decidir; o
   critério "acerto da IA local ao preencher" entra com a direção nova (etapa 6).
5. Perfis de ritmo longo/curto; o Estúdio passa a ler o `modo:` do roteiro.
   **Feito em 01/11/2026:** `estudio/ritmos/{longo,curto}.json` (dado; cópia editável em `$AGENT_DATA`, API
   `/estudio/ritmos`) e `studio/rhythm.py`. Perfil = `ritmo:` do roteiro, senão curto para o Short (9:16) e longo
   para o resto; na produção ajusta o estilo (regras de ritmo, teto de motion do longo, presença, legenda forte do
   curto) e o diretor aplica sem capítulos (curto), anti-repetição (troca pela peça parecida; só tira quando repete
   colada e sem dado), gancho nos 2 s do curto e conferência (sem virada, gancho, peça longa, repetição, duração)
   no mapa e no relatório; o app mostra ritmo, modo e avisos no portão do mapa. O `modo:` já vinha da etapa 1.
   Blocos de 20–60 s (`bloco_s`) ficam no perfil para a direção por bloco (etapa 6).
6. Direção nova (blocos → candidatas por embeddings → escolha → preenchimento) + anti-repetição; nova tarefa
   na bancada.
   **Feito em 01/11/2026:** `studio/direction.py` (padrão; Opções → `direcao = "frases"` volta ao diretor antigo):
   blocos = falas do roteiro, momentos do tamanho da virada do perfil (número dito abre momento), leitura por bloco
   (IA local), tratamento corrigido pelo modo, 5 candidatas por embeddings (EmbeddingGemma 300M num llama-server
   próprio na CPU, porta 8082, `ia/embeddings.py`; sem ele, palavras em comum) + intenção − repetição + cotas,
   escolha e preenchimento pela IA local com validação (limites, número não dito, inclusive por extenso; peça de
   número exige número) e queda para a próxima candidata. Apontamento e gatilhos fixam a peça. Tarefa `bloco_peca`
   na bancada, alimentada pelo mapa aprovado e pelas trocas de peça no app (as candidatas aparecem primeiro).
   Testado no `finlumia-990` (3 momentos → 3 peças com motivo).
7. Peças 2,5D (monitor em perspectiva, cartões em profundidade) e ampliação contínua do acervo pela fábrica.
   **Feito em 01/11/2026:** peças 2,5D de referência em CSS 3D (`monitor_perspectiva`, `cartoes_profundidade`,
   `planos_camera`; em revisão na Fábrica) e a seção 2,5D do `GUIA.md`. Ampliação contínua (`fabrica.ampliar`,
   relógio de 15 min no worker da fila): com a opção ligada no app, um pedido de lacunas por dia (inclui 2,5D),
   dentro do teto e pausado quando a fila de revisão passa do limite; a pessoa continua aprovando cada peça.
8. Telas: acervo, linha do tempo por bloco, render do bloco.
   **Feito em 02/11/2026:** aba Estúdio → Acervo de peças (galeria com filtro por estado, peso, motor, intenção e
   busca; ao abrir, ficha, quadros, prévia na pele de qualquer canal e ações); linha do tempo por bloco no portão do
   mapa (peça escolhida + candidatas, troca em um clique: `direcao.refazer_cena` preenche a nova pela IA local e a
   troca vira caso do gabarito); render só do bloco (`./dark estudio-bloco`: `compilar` numa janela [de, ate] com
   narração, mídia e câmera cortadas por `data-media-start` → `emendar` no `render/bruto.mp4` → loudness e prévia);
   modo do template vira "modo da prévia" (no vídeo vale o do roteiro). Testado no `finlumia-990`: trecho de 9,5 s
   renderizado em 33 s e emendado sem mudar o resto.
9. 3D real (Three.js) com cota; base de aprovações → fine-tune.
   **Feito em 02/11/2026:** `kit/three.min.js` vai para os assets só quando a composição tem peça `peso: "3d"`
   (`peca.juntar`, `__THREE__` no template); `k.cena3d` no kit (canvas na caixa da peça, desenhado pela timeline, nunca
   por requestAnimationFrame: determinístico no HyperFrames) e `k.cor3d` (cor da pele por papel); peça de referência
   `barras_3d` (em revisão). Cota: `cota_3d_s` no perfil de ritmo (no máximo uma 3D por janela; a direção pune a
   segunda). Fine-tune: `studio/training.py` transforma o gabarito da bancada (`bloco_peca`, `preencher`, `corte`,
   `legenda`) em conversas de chat 90/10 em `$AGENT_DATA/.../treino/<data>/`, com mínimo por tarefa;
   `ia/treinar_lora.py` (unsloth no `.venv-treino`) treina só nas respostas e exporta GGUF para o roteador
   (`agente-<data>.gguf`, escolhido em Opções). CLI `./dark treino <alvo> exportar|treinar`, API `/estudio/treino`, app
   em Estúdio → Dependências → Base de treino (progresso por tarefa, exportar, treinar na fila). Primeira exportação:
   corte 109+11, legenda 18+0; nenhuma tarefa no mínimo ainda. Pendente: criar o `.venv-treino` e o primeiro treino
   quando alguma tarefa chegar ao mínimo.

## Ponto a confirmar ao começar

- Se as modificações de estrutura pela IA ficam só por botões declarados (recomendado) ou se a reescrita
  livre do código entra já no início.
