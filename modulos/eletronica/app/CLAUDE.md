# App Flutter de eletrônica (CAD de circuitos)

Lista de projetos + tela de CAD do esquemático. Fala com `/api/eletronica` (ver `../README.md`).

## Mapa

- `lib/src/modelos.dart`: `P` (ponto inteiro em µm, grade 1270), `transformar` (espelho + giro horário, igual a
  `posicao_pino` do backend), `Simbolo`/`Pino`/`Biblioteca`, itens selados `Componente`/`Fio`/`Rotulo`/`TextoCad`,
  `Projeto` (`esquematicoJson`, `restaurar`), geometria (`rotaOrtogonal`, `simplificar`, `juncoes`, `proximaRef`).
- `lib/src/cad/editor.dart`: `Editor` (ChangeNotifier): ferramenta, seleção, camadas ocultas/travadas, folhas,
  desfazer/refazer por fotos JSON (`alterar`; arrastes com `iniciarLote`/`mexer`/`terminarLote`), fio em andamento,
  mover com pontas de fio presas aos pinos, gravação 1,5 s após mudar (409 → `conflito`).
- `lib/src/cad/pintura.dart`: `Camera` (px/µm), `Paleta` (escura na tela, papel na exportação), `pintarSimbolo`,
  `pintarFolha`, `pintarGrade`, `PintorCad`.
- `lib/src/cad/cad_tela.dart`: Listener cru (mouse, caneta, dedo, pinça, trackpad), atalhos de teclado, layout
  (biblioteca à esquerda e propriedades à direita a partir de 1100 px; abaixo, gavetas).
- `lib/src/cad/paineis.dart`: `PainelBiblioteca` (abas Base, busca local, e KiCad, busca no servidor com espera de
  300 ms; o escolhido entra em `Biblioteca.adicionar`), `BarraFerramentas`, `BarraFolhas`, `PainelPropriedades`, diálogos.
- `lib/src/telas/bibliotecas_tela.dart`: baixar oficiais do KiCad, importar `.kicad_sym`, remover. Ao abrir o projeto,
  `projetos_tela.dart` pede ao servidor os símbolos importados que ele usa; os que sumiram viram `Simbolo.faltando`.
- `lib/src/simulacao.dart`: `Analise`, `Spice`, `Resultado` (`PontoOperacao`/`Curvas`), `ApiSimulacao` (extensão de
  `ApiEletronica`: `spice`, `simular` que consulta a tarefa a cada 1 s). Contrato das rotas: ver `../README.md`.
- `lib/src/telas/simulacao_tela.dart` (botão "Simular" no CAD): parâmetros por análise, multímetro (op), osciloscópio
  (tran/dc/AC em dB ou V/V) com legenda que liga/desliga sinais (cor fixa por sinal, até 8), tabela e netlist.
  `telas/grafico.dart`: `GraficoCurvas` (uma grandeza por gráfico, eixo x linear ou log, cruz + valores ao apontar).
- `lib/src/cad/exportar.dart`: PNG/PDF da folha. `lib/src/telas/`: `projetos_tela.dart`, `bom_tela.dart`.
- `lib/src/calculos.dart`: contas puras das calculadoras (`lerValor` "4k7", `formatar`, Ohm, divisor, E24, LED, RC,
  código de cores, crossover, dissipador, LM317); testes em `test/calculos_test.dart`.
- `lib/src/telas/calculadoras_tela.dart`: `mostrarCalculadoras` (abas), aberto pelo botão 'Calculadoras' do CAD.
- `bom_tela.dart` tem a 3ª aba "Verificação (ERC)" (`ApiEletronica.erc`; erro vermelho, aviso âmbar).

Testes: `test/modelos_test.dart`, `test/cad_tela_test.dart` (usa `test/simbolos.json`, cópia de símbolos do backend).
Validar: `infra/scripts/verificar modulos/eletronica`.
