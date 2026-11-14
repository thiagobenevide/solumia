# Plano do módulo Eletrônica — "AutoCAD só para eletrônica"

Ferramenta de CAD de precisão para montar circuitos de computador, celular, monitor/TV e som: esquemático,
simulação e desenho da placa no mesmo projeto. Usada com mouse, tablet e caneta digitalizadora.
Catálogo da bancada física: [CATALOGO.md](CATALOGO.md).

## Estrutura

- `backend/` (`agent-eletronica`, `/api/eletronica`, VPS): projetos com `versao` (409 quando outro aparelho
  gravou antes), biblioteca de componentes, netlist, ERC/DRC, exportações (KiCad, Gerber, furação, BOM).
- `worker/` (PC): simulação no ngspice (ponto de operação, transiente, AC, varredura); depois Freerouting.
- `app/` (`agent_eletronica`): tela de CAD com os modos **Esquemático**, **Placa** e **Simulação**.

## Tela de CAD

- Coordenadas inteiras em micrômetros (µm); a tela mostra mm ou mils. Grade padrão de 1,27 mm (50 mil).
- Grade, snap (pino, ponta de fio, grade), fio ortogonal, camadas, rotação 90°, espelhamento, desfazer/refazer.
- Mouse: esquerdo coloca/seleciona, meio/direito arrasta, roda dá zoom, atalhos de CAD (R, C, D, W, L, T…).
- Tablet e caneta: a ponta coloca, pairar mostra a prévia, o dedo arrasta e dá pinça, barra de ferramentas
  e botões grandes no lugar do teclado.

## Biblioteca

Base própria (símbolo, pinos, propriedades, prefixo) com os componentes mais usados; depois, importação
das bibliotecas oficiais do KiCad (`.kicad_sym`, `.kicad_mod`) e modelos SPICE por componente.

## Fases

1. **Núcleo e esquemático**: tela de CAD, biblioteca base, fios, redes nomeadas (rótulos e símbolos de
   alimentação), várias folhas, lista de peças, exportação PNG/PDF.
2. **ERC e calculadoras**: pino solto, saídas em curto, rede sem terra; Ohm, divisor, LED, RC, crossover,
   dissipação.
3. **Simulação**: netlist → ngspice no worker; pontas de prova no esquemático, osciloscópio e multímetro
   virtuais.
4. **Placa**: footprints, linhas guia (ratsnest) do esquemático, trilhas em 2–4 camadas, vias, plano de terra,
   DRC, Gerber + furação + BOM/pick-and-place para JLCPCB.
5. **Extras**: roteamento automático, vista 3D, troca com o KiCad, modelos prontos (fonte ATX, VRM, carga de
   celular, backlight, amplificador classe D).
