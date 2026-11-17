# Fábrica de peças: correções para parar de reprocessar

Levantamento de 17/11/2026, depois dos testes do fluxo híbrido (Claude cria a ideia, LLM local executa em N1,
portão técnico, revisão do Claude).

## Diagnóstico

Histórico da fábrica (`$AGENT_DATA/empreendimento/estudio/fabrica/registro.jsonl`):

| Etapa | Resultado |
|---|---|
| Execução pela LLM local | 15 geradas, 126 descartadas, 76 puladas como inviáveis |
| Revisão do Claude | 1 aprovada, 147 reprovadas |

Cada rodada só reprocessa a peça. Nada no processo corrige a causa, então o mesmo erro volta.

## Pontos a corrigir

### 1. A ideia do Claude pede o que o executor não sabe fazer

- As ideias trazem coisas que a LLM local não tem como montar: seta, curva, ícone, número "com 40% da altura",
  segundo número "1,4× maior".
- Hoje o Claude recebe só uma lista de moldes em texto livre (`factory._vocabulary_n1`).
- **Correção:** a ideia sai do Claude já presa a um molde, com só os parâmetros que esse molde aceita. Ideia fora
  do contrato é recusada antes de gastar rodada local ou revisão.

### 2. A revisão do Claude cobra o que o patch não consegue mudar

- O revisor reprova por coisas que a LLM local não tem como alterar, e ela gasta as 4 rodadas tentando.
- Exemplos: "a seta não parece seta"; "o número A deveria ser neutro com opacidade" (texto não tem opacidade no N1).
- **Correção:** o revisor recebe a mesma lista de operações que a LLM local, e cada problema vem com a operação que
  o resolve. O que não tiver operação vira "limite do molde": é registrado para melhorar o molde e não volta para a
  LLM.

### 3. A LLM local erra nomes e campos e repete o erro

- Erros repetidos: operação em elemento que não existe, opacidade em texto, contorno em retângulo, número errado
  de pesos.
- **Correção:** o prompt passa um mapa da base, com cada nome, o tipo, quantos filhos cada caixa tem e os campos
  permitidos por tipo. Operação recusada duas vezes some da lista aceita na rodada seguinte.

### 4. O portão técnico não vê o que o vídeo mostra

Os bugs achados nos testes passaram todos pelo portão e só apareceram na imagem:

- a unidade sumia ("R$ 12 mil" virava "R$ 12");
- o núcleo do EffectCraft (`caber`) encolhia o número para 30% do tamanho;
- um elemento que entrava depois do quadro de prova não aparecia na imagem.

**Correção:** o portão passa a medir o resultado real do render, não a estimativa do compilador:

- tamanho final de cada texto contra o pedido;
- todos os elementos visíveis no último instante;
- texto do encaixe aparecendo inteiro.

### 5. Não existe uma bancada fixa de regressão

- Cada teste é uma ideia nova, então não dá para saber se uma correção melhorou ou piorou o fluxo.
- **Correção:** separar umas 10 ideias reais de `reprovadas/` como bancada fixa. Ela roda só com a LLM local e o
  portão, sem gastar Claude, e mede quantas passam e por quê. A revisão do Claude só entra quando a bancada estiver
  limpa.

### 6. As lições automáticas aprendem gambiarra

- Os testes gravaram sozinhos regras novas no `pecas/GUIA_N1_EC.md` e no `pecas/_ec/licoes_arquivo.md`, como "crie
  variante de NumeroB para cada valor do botão".
- Essa regra é justamente o comportamento que esconde conteúdo e que foi travado no código. As mudanças foram
  desfeitas.
- **Correção:** lição nova entra como proposta e só vira regra depois de passar na bancada.

### 7. Os moldes limitam o herói

- O tamanho do número vem fixo do nível (`numero` = 15% do lado menor).
- O patch já pode mudar `tam` até 40%, mas o melhor é o molde expor isso como parâmetro (por exemplo, "escala do
  herói").

### 8. Descarte sem causa raiz

- Os motivos registrados misturam culpa do executor, do compilador, do revisor e da ideia.
- **Correção:** classificar cada descarte por quem falhou (ideia, executor, compilador, revisor) e por molde. É isso
  que diz o que corrigir primeiro.

## Cortes de áudio (episódio 003)

- Falta decidir se a etapa limpar roda de novo com as regras novas (regrava a `narracao.wav` e obriga a refazer o
  corte do Estúdio e o plano).
- Sobram 2 bordas erradas que pedem regra própria:
  - retake parcial ("muito Muito", 618 s);
  - alinhamento que põe o começo da palavra mantida em cima da palavra cortada ("de todas, de todas", 759 s).

## Já feito (sem commit, pytest da esteira passando)

- **Cortes** (`esteira/cuts.py`, `esteira/edges.py`): fragmento colado à frase mantida não é mais tirado pela LLM;
  a borda pula o resto da palavra cortada antes da mantida; o motivo da LLM volta a aparecer no relatório.
- **Patch N1** (`esteira/n1/patch.py`): o botão não esconde conteúdo da base; acento acrescentado sai pequeno e com
  célula pequena; tempos de entrada limitados; hierarquia do número principal travada; operações de pesos (caixa e
  `repetir`) e de tamanho de texto.
- **Compilador** (`esteira/n1/effectcraft.py`): a unidade do número volta; o texto ganha folga no topo da célula.
- **Prompt e triagem** (`esteira/studio/factory.py`, `esteira/studio/molds.py`): prompt do patch atualizado; "logo"
  (advérbio) não marca mais a ideia como inviável.
- Falha já existente, não causada por essas mudanças: `linha_do_tempo_estrada_ec` tem texto saindo da área segura
  no 9:16.

## Ordem proposta

1. Bancada fixa (ponto 5) e portão medindo o render (ponto 4): sem eles não dá para provar nenhuma correção.
2. Contrato ideia/molde/revisor (pontos 1 e 2).
3. Mapa da base para a LLM local (ponto 3).
4. Lições como proposta (6), parâmetros de herói nos moldes (7) e classificação dos descartes (8).
