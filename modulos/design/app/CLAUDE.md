# App Flutter de design (quadro branco)

Galeria de quadros + quadro infinito vetorial. Fala com `/api/design` (ver `../README.md`).

## Mapa

- `lib/src/api_design.dart`: um método por rota; `salvar` manda `versao` (409 = outro aparelho gravou).
- `lib/src/modelos.dart`: `Elemento` selado (`Traco` com `Ponto(x, y, pressão)`, `Forma`, `Texto`, `NoFluxo` e
  `Ligacao` do fluxograma; `religar` refaz as pontas das setas pelos blocos, chamado em todo `_trocar`) em coordenadas
  do mundo, `toca` (borracha), `dentroDoLaco`/`transformar` (seleção: mover, escalar, duplicar, recolorir),
  `Quadro`/`ResumoQuadro`, `mesclar`. Teste em `test/modelos_test.dart`.
- `lib/src/cache.dart`: cópia offline por quadro (SharedPreferences; localStorage na web) com `pendente`/`apagados`.
- `lib/src/telas/galeria_tela.dart`: grade com miniaturas (novo, renomear, duplicar, excluir); sem rede, lista o cache.
- `lib/src/quadro/`: `quadro_tela.dart` (Listener cru: caneta/mouse/dedo/trackpad, pinça, laser, projeção,
  atalhos de teclado), `entrada.dart` (`classificar` decide desenhar/apagar/navegar por aparelho; `pressao`;
  `Camera` tela↔mundo), `menu_caneta.dart` (`CliqueDoBotao`: clique rápido no botão da caneta pairando, lido nos
  eventos de hover → `MenuRadialCaneta` com ferramentas, desfazer/refazer, cores e espessura; segurar + encostar segue
  borracha; teste `test/menu_caneta_test.dart`), `estojo.dart` (ferramentas, cor/espessura, dedo desenha?), `pintura.dart` (pincéis,
  fundo, pintor vivo), `editor.dart` (desfazer/refazer, autosalvar 1,2 s, cache antes do envio, nova tentativa em 15 s offline,
  mescla no 409, envia a miniatura), `exportar.dart` (PNG/PDF do quadro ou da seleção → `FilePicker.saveFile`).
  Seletor de cor completo: `escolherCor` do `agent_core`. `fluxo.dart`: diálogo "Fluxo com IA" (descrever, código,
  ajustar), fluxo do servidor → elementos (`elementosDoFluxo`, ids `<fluxo>.<nó>`), texto com `**negrito**`, `*itálico*`,
  `__sublinhado__`, `==marcador==` (`editarTextoFormatado`; desenho em `pintura.textoFormatado`). Teste: `test/fluxo_test.dart`.
  `paineis.dart`: layout do draw.io — `PainelFormas` (busca, categorias, arrastar para o quadro), `PainelEstilo` (forma,
  borda/fundo/texto, alinhamento, seta reta/ortogonal/tracejada) e `BarraPaginas` (abas). Fixos a partir de 1100 px; abaixo,
  gavetas. Páginas no `editor.dart` (`paginaAtual`, `irPara`, `novaPagina`…; `elementos` = só a página aberta).
  Testes: `test/paginas_test.dart`, `test/fluxo_tela_test.dart`. `tabela.dart`: diálogo da `Tabela` (linhas, colunas,
  cores/negrito/alinhamento por célula). `imagens.dart`: `PainelImagens` (busca no Google
  Imagens, botão na barra) e `CacheImagens` (elemento `Imagem`, arquivo em `/api/design/imagens/<id>`). `Elemento.grupo` (Ctrl+G/Ctrl+Shift+G): seleção pega o grupo inteiro; Ctrl+clique soma.
- `lib/src/telas/design_tela.dart`: seções do submenu lateral (`ModuloDesign.secoes`/`secaoAtual`, como Estudos):
  Cadernos = `GaleriaTela(api.cadernos)`, Fluxogramas = `GaleriaTela(api)`, Wireframes.
- `lib/src/caderno/`: o mesmo `QuadroTela` (ganchos: `acoes` na barra, `editor.papel` no `PintorQuadro`), com
  `/api/design/cadernos` (`ApiDesign.cadernos`, cache `design.caderno.`). `caderno_tela.dart` (`AbrirCaderno` liga
  `editor.papelPadrao` e `editor.ajustarTraco`; cartão de referência = `NoFluxo` nota), `papel_dialogo.dart` (`Papel` da
  folha em `Pagina.papel`: pauta, espaço, tamanho, cor, margem; uma folha ou todas; desenho em `pintura.pintarPapel`),
  `caneta.dart` (`reconhecer`: reta alinhada 0°/45°/90°/paralela, retângulo/quadrado/triângulo/elipse/círculo; só traço
  maior que ~2 linhas da pauta, escrita fica), `referencias.dart` (destaques de `/api/arquivos/destaques` e `/api/notas`).
  Teste: `test/caneta_test.dart`.
- `lib/src/wireframe/`: `modelo.dart` (`TelaWf`, `Nota`, `Componente` com `props` livres, `catalogo` igual ao
  `COMPONENTES` do backend, `ajustarTamanho`), `pintura.dart` (`PintorWireframe`: cabeçalho, janela, componentes e
  painel de notas como `docs/wireframes-nd/_gerador/lib.py`; `Prancha` = medidas), `wireframe_tela.dart` (editor:
  paleta, arrastar/redimensionar com grade 4 px, props por tipo, listas em JSON, notas, desfazer, autosalvar 1,2 s,
  menu IA exportar/importar; a exportação manda antes o PNG de cada tela via `renderizarTela`), `galeria.dart`. Teste: `test/wireframe_test.dart`.

Validar: `infra/scripts/verificar modulos/design`.
