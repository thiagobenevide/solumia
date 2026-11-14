# Eletrônica

"AutoCAD só para eletrônica": CAD de precisão para montar circuitos de computador, celular, monitor/TV e som —
esquemático, simulação e placa no mesmo projeto, com mouse, tablet e caneta. Plano em
[docs/PLANO.md](docs/PLANO.md); bancada física em [docs/CATALOGO.md](docs/CATALOGO.md).

## Estrutura

```
eletronica/
├── backend/   pacote Python: API FastAPI, biblioteca, netlist e BOM (roda na VPS)
├── worker/    (fase 3) simulação ngspice no PC
└── app/       pacote Flutter com as telas do módulo
```

## Hoje (fase 1 — esquemático)

- `backend/` (`agent-eletronica`, montado em `/api/eletronica`): projetos em
  `$AGENT_DATA/eletronica/projetos/<id>.json` (`GATEWAY_ELETRONICA_DIR`). Rotas: `GET /biblioteca`,
  listar/criar/obter/editar (`titulo`, `pasta`), `PUT /projetos/{id}/esquematico` com `versao` (409 + projeto atual),
  `GET …/netlist` (redes e pinos soltos), `GET …/bom` e `…/bom.csv`, duplicar, excluir.
  `biblioteca.py`: ~57 símbolos em µm (passivos, semicondutores, CIs, eletromecânicos, fontes, conectores,
  alimentação). `netlist.py`: liga pinos, pontas e T de fio na mesma folha; rótulos e alimentação ligam entre folhas.
  KiCad (`kicad.py` + `bibliotecas.py`): lê `.kicad_sym` (KiCad 6–9; mm/y para cima → µm/y para baixo, uma
  entrada por unidade `<lib>:<nome>:<n>`, `extends`, arcos de 3 pontos, bézier) e guarda em
  `$AGENT_DATA/eletronica/bibliotecas/<lib>.json` + `.indice.json`. Rotas: `GET /bibliotecas`,
  `POST /bibliotecas/importar` (arquivo), `GET|POST /bibliotecas/kicad` (oficiais da tag
  `GATEWAY_ELETRONICA_KICAD_VERSAO`, padrão 9.0.9 — o KiCad 10 trocou para pastas `.kicad_symdir`),
  `DELETE /bibliotecas/{nome}`, `GET /biblioteca/busca?q=&biblioteca=`, `POST /biblioteca/simbolos` {ids}.
  `erc.py` + `GET …/erc` (fase 2): pino solto, saídas em curto, rede só de entradas, alimentação sem fonte,
  rede de um pino com rótulo, ref duplicada (menos unidades do mesmo CI), componentes sobrepostos, fio solto,
  rótulo único; testes em `plataforma/backend/tests/test_eletronica_erc.py`.
  Testes: `plataforma/backend/tests/test_eletronica.py`.
- `app/` (`agent_eletronica`): lista de projetos + tela de CAD. Ver `app/CLAUDE.md`.
- Simulação (fase 3, início): `spice.py` gera a netlist SPICE (GND → nó 0, modelos genéricos embutidos, peças sem
  modelo em `ignorados`) e lê o raw do ngspice; `api_simulacao.py`: `GET …/spice`, `POST …/simular` (op, tran,
  ac, dc → tarefa) e `GET /simulacoes/{id}`. Roda como tarefa `simular_spice` do worker no PC
  (`shared/ngspice.py`); sem worker, usa o ngspice do próprio backend se instalado (senão 503).
  Testes: `plataforma/backend/tests/test_eletronica_simulacao.py`.
