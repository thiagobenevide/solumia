# Guia do N1 do EffectCraft (peça como dados)

A peça do motor EffectCraft é um documento JSON (`peca.n1.json`), não código. O compilador
(`esteira/n1/effectcraft.py`) resolve encaixes, botões, batidas e formato e gera o script da app com os
auxiliares do núcleo. Esquema completo: `Peca` (o portão valida; campo desconhecido reprova).

## Layout por caixas (obrigatório)

Você não posiciona nada: descreve a ESTRUTURA e o compilador calcula posição e tamanho nos dois formatos.
- No nível de cima só há `caixa`s. Cada uma tem `regiao`: `topo` (título), `centro`, `base` (fonte, contexto),
  `esquerda` e `direita` (lado a lado no 16:9; no 9:16 viram cima e baixo sozinhas) ou `tela` (tudo).
- `disposicao` divide a caixa entre os `filhos`: `coluna` (de cima para baixo), `linha` (lado a lado), `fluxo`
  (linha no 16:9 e coluna no 9:16), `grade` (`colunas` × linhas) e `camadas` (todos no mesmo lugar: formas atrás,
  texto na frente; texto sobre anel/círculo cabe no furo). `pesos` dá o tamanho relativo dos filhos ([1, 3]).
  `alinhar`: `inicio | centro | fim`. Caixas podem ter caixas dentro.
- Texto: `nivel` (`titulo | destaque | numero | corpo | rotulo`) no lugar de tam; quebra na largura da célula
  e encolhe para caber nela. Nunca escreva x, y, largura ou tam.
- Formas: `retangulo` sem w/h preenche a célula (com `h` pequeno vira linha fina centrada); `elipse` sem `d`
  ocupa a célula (anel: `contorno`; fatias: `fatia: true` num `repetir` dentro de `camadas`).
- `repetir` dentro de caixa: cada item ganha a sua célula (sem `passo`); `disposicao_item` arruma os elementos
  de UM item (`linha`: rótulo e valor lado a lado). Uma grade 10 × 10: caixa `grade` com `colunas` 10 e um
  `repetir` com `quantidade` 100 e `ativos`.
- Barras e pilares que comparam valores: `retangulo` com `proporcional: true` num `repetir` de pares dentro de
  caixa `linha` (barras em pé) ou `coluna` (barras deitadas), com o texto do valor no mesmo item.
- Todo encaixe-lista (itens/pares) da ficha precisa de um `repetir` com esse `encaixe` (sem ele aparece 1, 2, 3).
- Em `camadas`, vários textos ficam um embaixo do outro dentro da forma (número em `numero`, legenda em `rotulo`).
- Animações continuam pelo `nome` do elemento (os itens do repetir ganham " 1", " 2"…).

## Regras

- **Área segura**: mantenha o texto entre 0,06 e 0,94 da tela (x e y). O texto máximo dos encaixes é longo: prefira
  parágrafo (`largura`) a uma linha comprida; o compilador encolhe a fonte do que ainda passar da borda.
- **Unidades** (só em peças antigas, fora de caixa; a fábrica não usa): `x` em fração da largura, `y` em fração da altura; `tam`, `w`, `h`, `d`, `contorno` e `folga`
  em fração do lado menor (0,024 ≈ 2,4% do lado menor). Nunca pixels.
- **Texto**: com `largura` é parágrafo (`y` = topo); sem `largura` é uma linha (`y` = linha de base).
  `{{encaixe}}` traz o valor; `*palavra*` pinta de destaque. `numero: true` formata o número dito em pt-BR e
  permite `contar`; `unidade_de` mostra só a unidade do número indicado; `apos` encosta um texto no fim de outro.
- **Cor e fonte só por papel**: cores `fundo | fundo2 | texto | destaque | apoio | acento`; fontes `fD`
  (display), `fT` (texto), `fM` (mono), `fE`, `fL`.
- **Tempo**: número = segundos depois de T0; `"@numero"` = instante em que a batida é dita (declare o padrão em
  `batidas_padrao`); `"T0+0.2"`; o sufixo `v` multiplica pela velocidade do botão `botao_velocidade`
  (`"@numero+0.5v"`; durações `"0.8v"`). Vários termos somam: `"@numero+0.2+0.6v"`.
- **Condições** (`se`): `{"botao": "enfase", "igual": "traco"}`, `{"encaixe": "contexto"}` (preenchido) ou lista
  (todas valendo). Variantes exclusivas podem ter o mesmo `nome`; a animação vale para a que estiver ativa.
- **Formato vertical**: `vertical` sobrescreve campos no 9:16 (posições, tamanhos, `apos`).
- **Listas** (encaixes `itens`/`pares`): `repetir` com um molde de `elementos` e `animacoes`, `passo` [dx, dy]
  por item e `intervalo` (s) de atraso por item; no molde, `{{item}}`, `{{item.rotulo}}`, `{{item.valor}}`.
  Grade: `colunas` (o item i vai à coluna i % colunas, linha i // colunas; `passo` = [entre colunas, entre linhas]);
  sem `encaixe`, `quantidade` repete N vezes (grade 10 × 10 = `quantidade` 100, `colunas` 10); `ativos` (encaixe com
  número ou %) pinta os primeiros N itens com `cor_ativa` ("34%" numa grade de 100 = 34 acesos). O `repetir` aceita
  `vertical` (passo, colunas, posição no 9:16); o `vertical` do molde vale para cada item antes do passo.
  Rosca/pizza: `elipse` com `fatia: true` dentro de um `repetir` de pares (cada item vira um arco proporcional ao
  valor, com cor própria; `contorno` = espessura do anel); arco avulso: `inicio`/`fim` em fração da volta.
  `{{item}}` fora de um `repetir` reprova; fora dele, `{{pares.valor}}` é o valor do primeiro item. Exemplo (lista vertical):
  `{"tipo": "repetir", "nome": "Lista", "encaixe": "itens", "maximo": 5, "passo": [0, 0.09], "intervalo": 0.15,
  "elementos": [{"tipo": "texto", "nome": "Item", "conteudo": "{{item}}", "x": 0.12, "y": 0.3, "tam": 0.045}],
  "animacoes": [{"anim": "entrar", "alvo": "Item", "de": "esq", "t": "T0+0.2", "dur": "0.6v"}]}`
- **Animações**: `entrar` (de `baixo | esq | dir | aparecer | escala`), `tracar` (traço que cresce),
  `contar` (só em texto com `numero`), `chaves` (`escala | opacidade | posicao | rotacao`, pares [tempo, valor]),
  `desfocar` (pares [tempo, raio]). A saída da peça é do sistema: não anime o fim.
  Valores das `chaves`: `escala` em % ([100, 100] = original), `opacidade` de 0 a 100, `posicao` [x, y] em
  frações da tela, `rotacao` em graus.
- **Fundo**: `fundo` (sobre a mídia: `veu` ou `nenhum`) e `fundo_tela_cheia` (`tela`) quando a cena é tela cheia.

## Exemplo

`numero_impacto_ec/peca.n1.json` (número grande contando, rótulo, traço ou anel e linha de contexto, nas
variantes centro/esquerda e 16:9/9:16).

## Lições (erros já vistos; não repita)
- Todo botão da ficha muda algo visível: crie as variantes com `se` no valor do botão; nunca declare botão sem uso
- Elementos de um item (forma, rótulo, valor, bolinha de cor) ficam no MESMO `repetir`; `maximo` = `max_itens` da ficha
- Rótulo e valor de um item são dois textos (`disposicao_item: "linha"`), nunca concatenados num só
- Para destacar um item por um encaixe (ex.: `foco`), use `se` comparando com o valor do encaixe
- Toda batida `@nome` usada em `t` tem padrão em `batidas_padrao`
- Rosca/pizza: `elipse` com `fatia: true` num `repetir` dentro de caixa `camadas`, com o total como texto na mesma camada
- Antes/depois (de X para Y): os dois valores visíveis ao mesmo tempo, em células diferentes (`fluxo`), o inicial em `apoio`
- Curva ou onda não é elipse: use `repetir` de retângulos finos (barras) numa caixa `linha`
- Legenda com cor: uma elipse pequena da cor do item no mesmo `repetir` do texto (`disposicao_item: "linha"`, `pesos`)
- Em cartão de passo ou etapa, ponha a região `centro` direto como o cartão (sem caixa `camadas` extra com `pesos`/`espaco`), com margem interna. Dê ao marcador uma célula estreita (peso até 0,1) e um número do passo em `numero` dentro dele, com a frase em nível `titulo` ocupando o resto, para o cartão preencher a região nos dois formatos (peça passo_a_passo_ec)
- Em cartão de passo, a região `centro` é uma `camadas` com dois filhos: o retângulo de fundo e uma `linha` por cima, com `pesos` [0.1, 0.9] e `alinhar: centro`. A célula estreita leva uma elipse com o número do passo em `numero`, e a frase em `titulo` fica na célula larga. Nunca deixe o texto como irmão solto do cartão (peça passo_a_passo_ec)
- Em marcador numérico dentro de elipse, o texto do número recebe só o dígito do passo (valor curto), nunca o encaixe da frase; se a ficha não tem encaixe de número, deixe a elipse sem texto (peça passo_a_passo_ec)
- Em peça de pergunta ou frase com palavra-chave em destaque, ponha frase, destaque e marca (?) como filhos de uma única caixa `coluna` com `pesos` explícitos e `alinhar: centro`, dentro de um cartão `camadas`. Nunca ponha os textos como irmãos numa `camadas`, nem repita o encaixe de destaque na região `base` (peça pergunta_canto_ec)
- Em peça de pergunta ou frase com palavra-chave, dê hierarquia na coluna: a frase em nível `corpo` ou `destaque`, a palavra-chave em `titulo` com a maior célula, e o '?' em `numero` com peso próprio. Nunca ponha os três textos no mesmo nível e com pesos iguais ou omitidos (peça pergunta_canto_ec)
- Em peça de pergunta ou frase longa em que o texto é o herói, ponha o texto em nível `titulo` numa única caixa de região `tela` ou `centro`, com `alinhar: centro` e sem `linha` de ornamento ao lado. Qualquer barra ou filete decorativo vai em `camadas` atrás do texto, nunca como célula irmã. O bloco precisa preencher a largura nos dois formatos (peça pergunta_destaque_ec)
- Em peça de texto único sobre cartão, deixe a região `centro` ser o próprio cartão (`camadas` com o retângulo de fundo e o texto como filhos diretos, ambos na mesma célula), com texto em `titulo` e margem interna. Nunca aninhe uma caixa de região dentro da outra nem use `pesos` ou `espaco` em `camadas` (peça pergunta_destaque_ec)
- Todo elemento visual que a ficha cita em `comunica` (como o '?' desenhado ou o pulso) precisa existir na peça como elemento próprio com animação; confira cada item da descrição antes de entregar (peça pergunta_gancho_ec)
- Quando a ficha cita um elemento gráfico gigante ao fundo (como '?'), ponha esse texto em nível `numero` numa `camadas` da região `centro`, atrás da coluna de texto, com cor `fundo2` ou `apoio`, e nunca omita nem reduza esse elemento (peça pergunta_palavras_25d_ec)
- Em ranking ou barras que comparam valores, cada item do `repetir` deve ter um `retangulo` com `proporcional: true` numa célula larga (peso dominante) e o valor e o rótulo em células de texto ao lado; nunca dê ao retângulo da barra um peso pequeno nem o omita (peça ranking_ec)
- Em ranking com rótulo longo, cada item do `repetir` deve ter duas linhas na célula: rótulo e valor lado a lado numa linha em cima, e a barra proporcional em largura total embaixo. Nunca ponha barra, valor e rótulo numa só `linha` com `pesos_item`, pois o rótulo encolhe e quebra em várias linhas no 9:16 (peça ranking_ec)
- Em peça de lista riscada (o que deixar de fazer), faça cada item uma célula de `camadas` com o texto do rótulo em nível `titulo` e um `retangulo` fino (`h` pequeno) por cima, com `tracar`. Empilhe os itens numa caixa `coluna` na região `centro`. Não use barra `proporcional` quando os pares não têm valor (peça riscado_ec)
- Em peça de cartão de dicionário ou definição, ponha termo e definição como filhos de UMA única caixa 'coluna' da região 'centro' (pesos explícitos, termo em 'titulo' com peso maior, definição em 'corpo' com peso suficiente para ocupar o cartão), sobre um retângulo de fundo numa 'camadas' externa, com alinhar 'centro'. Nunca separe termo e definição em dois cartões em regiões diferentes, e nunca deixe a definição como um rodapé pequeno (peça termo_tecnico_ec)
- Em peça de título de capítulo ou transição, o texto é o herói: use uma única caixa 'coluna' na região 'centro' ou 'tela', com alinhar 'centro' e pesos explícitos. O rótulo 'Parte N' fica em nível 'numero' ou 'destaque' acima do título em nível 'titulo' (maior célula). Não use barra proporcional nem caixa 'topo' separada; qualquer filete decorativo vai em 'camadas' atrás do texto (peça titulo_capitulo_ec)
- Em peça de comparação A × B, faça cada lado uma célula de `camadas` (cartão de fundo atrás) com uma única `coluna` por cima: valor em `numero` (maior peso), rótulo em `titulo` e, se couber, barra `proporcional` em célula própria; deixe a `linha` de lados em `fluxo`, com pesos iguais e sem retângulo solto como irmão. Dê um peso em `pesos_item` para cada elemento do item, nunca menos pesos que elementos (peça versus_ec)
