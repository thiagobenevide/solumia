# Guia de escrita de peças · motor EffectCraft

Mesma ficha, mesmos encaixes e o mesmo portão das peças HTML (`GUIA.md`, seções Ficha, Texto máximo e Lições valem
aqui); muda o código. O script é o modelo de objetos do After Effects do EffectCraft (comps, camadas, propriedades,
keyframes, expressões, efeitos) mais `app.run(<comando>, {...})` para comandos da engine (ex.: `layer.setText`).

## Pasta

```
estudio/pecas/<id>/
  peca.jsx       o script da peça                      [portão]
  ficha.json     motor "effectcraft"                   [portão]
  prova/         gerada pelo portão
```

## Contrato do `peca.jsx`

O Python monta `var DADOS = {...}` + `_ec/nucleo.jsx` + `peca.jsx` + `_ec/fim.jsx`. A peça só desenha na comp
`CONTEUDO` (já criada) a partir de `T0`; o fim cria a comp "Peça", faz a saída em `FIM` e mede o texto.

- Variáveis prontas: `E` (encaixes), `B` (botões), `BAT` (batidas: instante em s de cada encaixe listado em
  `batidas`), `W`, `H`, `U` (1% do lado menor), `VERT`, `T0`, `FIM`, `DUR`, `DADOS.tela_cheia`.
- Utilitários do núcleo (use em vez de reinventar): `fundoTela()` (tela cheia) ou `veuBaixo(opac)` (por cima da
  mídia); `bloco(nome, texto, x, y, largura, {papel, peso, tam, cor, alinhar, entrelinha, caps, tracking, italico})`
  (parágrafo; `*palavra*` vai em destaque); `linha(nome, texto, x, linhaDeBase, {papel, peso, tam, cor, justify})`;
  `retangulo(nome, x, y, w, h, papel, opacidade, raio, ancoraEsq)`; `elipse(nome, cx, cy, d, papel, contorno)`;
  `entrar(camada, "baixo"|"esq"|"dir"|"aparecer"|"escala", t, dur)`; `traco(camada, t, dur)`; `chaves(prop, [[t, v]])`;
  `desfoque(camada, [[t, v]])`; `filho(camada, pai)`; `contagem(camadaTexto, alvo, casas, ini, dura, antes, depois)`;
  `numero(texto)` → `{antes, n, depois, casas}`; `largura(camada)`; `tr(camada, "Position")`.
- Nomes das camadas em português e descritivos ("Número (conta até o valor)", "Traço"): a pessoa edita à mão no
  EffectCraft.
- Determinística: nada de `Math.random`, `Date`; não crie comps (`addComp`) nem escreva saída (`writeLn`).

## Pele: só por papel  [portão]

Cores: `cor("destaque")` (hex, para texto), `corRGB("fundo")` (para formas/sólidos), `mistura("texto", "fundo", 0.8)`;
papéis `fundo`, `fundo2`, `texto`, `destaque`, `apoio`, `acento`. Fontes: o `papel` dos utilitários (`"fD"` destaque,
`"fT"` texto, `"fM"` técnica, `"fE"` editorial, `"fL"` legenda); o núcleo acha o estilo mais próximo do peso pedido.
Hex, `[r, g, b]` ou `font: "..."` no código reprova.

## Referência

`pecas/numero_impacto_ec/`: o mesmo número de impacto de `numero_impacto` (HTML), para comparar os dois motores.

## Lições

(entram aqui os motivos de reprovação e os ajustes pedidos na revisão das peças EffectCraft)
