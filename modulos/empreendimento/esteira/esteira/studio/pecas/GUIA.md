# Guia de escrita de peças

Lido em toda geração de peça (fábrica, `docs/PLANO-ACERVO.md`). O portão de entrada (`studio/piece.py`, `portao`)
confere as regras marcadas com **[portão]**; as outras são de qualidade e aparecem na revisão da pessoa. Os motivos de
reprovação e os ajustes pedidos na revisão entram no fim deste arquivo, em "Lições".

## Pasta

```
estudio/pecas/<id>/        id: minúsculas, números e _ (3–40)
  peca.js                  a animação                           [portão]
  peca.css                 opcional; só seletores dentro de .p-<id>   [portão]
  ficha.json               metadados (esquema `Ficha`)           [portão]
  prova/                   gerada pelo portão (não editar, fora do git)
```

## Contrato do `peca.js`

```js
ESTUDIO.peca("<id>", (k, c, box) => {
  const e = c.encaixes, b = c.botoes;      // conteúdo (IA local) e estrutura (botões da ficha)
  // ... anima dentro de `box` usando k.tl a partir de c.t ...
});
```

- `box`: `div.peca.p-<id>` criada pelo kit na camada certa (tela cheia ou por cima da mídia/câmera). A **saída é do
  kit** (`sai(box, fim(c))`); a peça só anima entradas e o que acontece durante.
- `c.t` / `c.ate`: começo e fim da peça (s). `c.batidas.<encaixe>`: instante em que a palavra daquele encaixe é dita
  (só para os encaixes listados em `batidas` da ficha); use-o para sincronizar a entrada.
- `c.takeover`: true quando a peça ocupa a tela (chame `k.fundo(c)` para o fundo padrão); false = por cima da mídia
  (use `k.veu(c, "baixo")` para escurecer a faixa do texto).
- `k`: `tl` (timeline GSAP), `U` (1% do lado menor, em px), `V` (vertical?), `W`, `H`, `$` (cria elemento:
  `k.$("div", "classe", pai, html)`), `esc` (escapa texto), `svg`, `rico` (`*palavra*` → destaque),
  `entra(el, t, {de, ate})`, `sai`, `traco(el, t, dur)`, `palavras(el, texto, t, passo)`, `letras(el, texto, t)`,
  `contar(el, numero, t, dur, inteiro)`, `numero(texto)` → `{antes, n, depois, casas}`, `fmt`, `icone(texto)`,
  `kicker(pai, texto, t)`, `flash(t)`, `fim(c)`, `SUAVE` (curva do canal), `fundo(c)`, `veu(c, cls)`, `camada(c)`,
  `ajuste(c)` (ajuste da peça no estilo: `contagem_s`, `tamanho`, `fonte`), `valorHtml`, `numeroGrande(pai, num, t, dur)`,
  `auraFinal(el, t)`, `proporcao(c)`, `numeros(c)`, `fonteDe(c)`, `rnd(i)` (aleatório determinístico), `MOV`, `PROIB`
  (o que o canal proíbe: `k.PROIB.has("flash")`), `EF` (intensidade dos efeitos), `inativos`, `midia` (camada da mídia)
  e `outra(id, c, raiz)` (cair noutra peça quando o conteúdo não serve).
- Tudo medido em `U` (ou `var(--U)` no CSS): a mesma peça vale em 16:9 e 9:16 (`.vertical` no CSS para ajustar).
- Determinística: nada de `Math.random()`, `Date`, `setTimeout` ou `requestAnimationFrame`; tudo na `k.tl`.
- Leia encaixes e botões só de `c.encaixes` / `c.botoes` (direto, por apelido ou desestruturação). Usar um nome que
  a ficha não declara reprova **[portão]**; declarar e não usar é aviso.

## Pele: nenhuma cor nem fonte fixa  [portão]

Cores: `var(--fundo)`, `var(--fundo2)`, `var(--texto)`, `var(--destaque)`, `var(--apoio)`, `var(--acento)` e misturas
(`color-mix(in srgb, var(--destaque) 40%, transparent)`). Sombra preta (`rgba(0,0,0,.5)`) é a única exceção.
Fontes: `var(--fD)` destaque, `var(--fT)` texto, `var(--fM)` técnica, `var(--fE)` editorial (serifa), `var(--fL)`
legenda. Outras: `var(--esc)` (escala da peça no canal), `var(--inativo)` (opacidade de itens inativos), `var(--R)`
(cantos). O portão prova a peça em duas peles bem diferentes (escura/amarela sem serifa e clara/verde com serifa).

## Classes  [portão]

O CSS do kit é global: use classes com o prefixo da peça (`ni-titulo` em `numero_impacto`). Reaproveitar de
propósito só as do núcleo: `kicker`, `traco`, `veu` (`baixo`, `cheio`), `pw`, `pl`, `l`, `d`, `centro` (caixa
centralizada), `titulo`, `tag` / `tx` / `tk` (etiqueta do terço inferior), `ngr` / `nn` (número grande), `ctx`,
`kick2`. Outra classe do kit reprova (o estilo dela vaza).

## Texto máximo cabe  [portão]

O portão preenche cada encaixe no limite (`max_car`, `max_itens`) e mede, em três instantes, se algum texto sai da
área segura (3% do lado menor em cada borda) nas duas peles × formatos da ficha. Dimensione as fontes para o pior
caso, ou quebre linha; nunca reduza `max_car` abaixo do que a frase típica precisa.

## Peças 2,5D (CSS 3D)

Profundidade sem 3D real: render quase igual ao 2D. Referências: `monitor_perspectiva` (tela inclinada com
conteúdo e reflexo), `cartoes_profundidade` (cartões que chegam do fundo e se arrumam em camadas),
`planos_camera` (câmera atravessando planos de texto).
- Um contêiner de cena com `perspective` (≈ 110–160 × `--U`) e, dentro, o palco com `transform-style: preserve-3d`.
- Anime pelo GSAP: `rotationY`, `rotationX`, `z` (e `x`/`y`); ângulos moderados (10–30°): texto em ângulo forte
  fica ilegível.
- Movimento contínuo durante a fala (a câmera "respira": o palco gira alguns graus até o fim) dá vida sem distrair.
- Nada pode ficar na frente do texto principal no fim: o que a câmera atravessa some ao passar.
- Ficha com `peso: "2_5d"`; a direção usa essas peças no tratamento "2,5D sobre a câmera" e na tela cheia.

## Ficha (o que a IA local lê)

- `comunica`: uma frase concreta sobre o que a peça explica.
- `exemplos_sim` (5–10) e `exemplos_nao` (3–5): frases reais de roteiro; é o que mais ajuda o modelo local.
- `encaixes`: limites honestos (o código recusa o que passar). `exemplo` é usado na prova e no prompt. Tipos:
  `texto`, `numero`, `itens` (lista de textos), `pares` (lista de `{rotulo, valor}`, com `max_car` no rótulo e
  `max_valor` no valor), `icone`, `imagem`, `tematico`, `pagina` (página com grifos).
- `botoes`: só variações que a peça realmente implementa, cada valor visivelmente diferente.
- `neutra: false` exige um encaixe `tematico` (o elemento que muda de canal: foguete → gráfico subindo).
- `peso`: `texto` · `2d` · `2_5d` (CSS 3D: `perspective`, `rotateX/Y`) · `3d` (Three.js, cota por vídeo) · `midia`.

## Referência

Peças do motor EffectCraft (`peca.jsx`) seguem também `GUIA_EC.md`.


`pecas/numero_impacto/`: número grande contando, rótulo e contexto; mostra encaixes, botões, batida e o tratamento
de tela cheia × por cima da mídia. As peças com `origem: kit` são as cenas antigas migradas (encaixes `titulo` e
`valores` no formato do diretor atual); `comparacao_atributos` e `fonte_dado` vieram dos gráficos antigos.

## Lições
- 02/11/2026: ajuste pedido: Ficou complementamente vazio e sem dos dados corrija (peça linha_do_tempo_25d)
- 02/11/2026: ajuste pedido: Não gerou nada do que seria na solicitação, realize as correções (peça linha_do_tempo_3d_2)
- 02/11/2026: ajuste pedido: Refaça pois ele está  completamente bugado responsividade e textos incorretos e precisa ser reconstruido (peça comparacao_25d)
- 02/11/2026: Texto secundário (metadados, rótulos, fonte técnica, pílulas) nunca menor que calc(2.4 * var(--U)) e com contraste forte (texto claro sobre pílula escura ou o inverso, nunca cinza sobre cinza); em card pequeno, aumente o card em vez de encolher o texto — a visão reprova texto miúdo no 16:9.
- 08/11/2026: reprovada: Ficou incorreta (peça linha_do_tempo_25d)
- 08/11/2026: reprovada: Ficou incorreta (peça linha_do_tempo_profundidade_2)
- 08/11/2026: reprovada: por que ela ficou muito ruim a visualização (peça transicao_formas)
