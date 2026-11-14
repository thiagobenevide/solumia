# Design e Quadro Branco

Desenho livre e esquemas visuais com caneta (S-Pen) em tablets e celulares; quadro branco para projeção e explicações.

## Estrutura

```
design/
├── backend/   pacote Python: API FastAPI, modelos e regras (roda na VPS)
├── worker/    jobs pesados de LLM/GPU (roda no PC com a GPU)
└── app/       pacote Flutter com as telas do módulo
```

Cada parte só existe quando houver código para ela. A plataforma (`plataforma/`) registra o
router do backend, despacha os jobs do worker e monta as telas do app.

## Hoje

- `backend/` (`agent-design`, montado em `/api/design`): quadros em `$AGENT_DATA/design/quadros/<id>.json`
  (`GATEWAY_DESIGN_DIR`). Rotas: listar/criar/obter/editar (`titulo`, `fundo`, `pasta`), `PUT …/elementos`
  com `versao` (409 + quadro atual quando outro aparelho gravou antes), duplicar, excluir, miniatura PNG (`GET/POST …/miniatura`, gerada pelo app).
  Testes: `plataforma/backend/tests/test_design.py`.
  Fluxogramas com IA (`design/flows.py`): `POST /fluxos/gerar` (descrição, código ou fluxo atual + `provedor`) cria
  uma tarefa, `GET /fluxos/tarefas/{id}` devolve o fluxo já posicionado em camadas; LLMs em `app.state.design_llms`.
  Testes: `plataforma/backend/tests/test_design_fluxos.py`.
  draw.io (`design/drawio.py`): `POST /quadros/importar-drawio` (`.drawio`/`.xml`, páginas comprimidas ou não → abas
  `paginas`, raias/contêineres, cores, setas presas aos blocos, tracejadas, texto à esquerda) e `GET /quadros/{id}/drawio`
  (exporta de volta). Cada elemento leva `pagina`. Testes: `plataforma/backend/tests/test_design_drawio.py`
  (com `modulo-verbas-atual.drawio` da raiz, quando existe).
- Wireframes (`design/ai_wireframe.py`, guarda `Quadros` em `wireframes/`): telas = `paginas` (código, breadcrumb,
  tamanho, `notas` do painel lateral) e componentes = `elementos` (`x/y/w/h`, `estado` existe/proposto/divergencia,
  `props`), no estilo de `docs/wireframes-nd/`. Rotas `/wireframes` (CRUD, `PUT …/elementos` com `versao`, duplicar).
  Troca com outras IAs: `GET /wireframes/{id}/ia` (ZIP com `AGENTS.md` + `wireframe.schema.json` JSON Schema 2020-12
  + `wireframe.json` no formato `agent-wireframe` v1 + `telas/<id>.png`, render que o app manda em
  `POST /wireframes/{id}/telas/{tela}/png` antes de baixar, guardado em `<id>.anexos/`; `?formato=json` só o JSON), `POST /wireframes/importar-ia`
  (novo) e `POST /wireframes/{id}/importar-ia` (substitui; aceita ZIP, JSON ou texto com bloco ```json). O catálogo
  `COMPONENTES` gera schema, `AGENTS.md` e validação. Testes: `plataforma/backend/tests/test_design_wireframes.py`.
- Cadernos (`design/notebooks.py`, guarda `Quadros` em `cadernos/`): as mesmas rotas dos quadros em `/cadernos`
  (CRUD, `PUT …/elementos` com `versao`, miniatura, duplicar, draw.io); o papel de cada folha vai em `paginas[].papel`.
  Testes: `plataforma/backend/tests/test_design_cadernos.py`.
- `app/` (`agent_design`): seções Cadernos, Fluxogramas e Wireframes no submenu lateral. Ver `app/CLAUDE.md`.

## Entrada por aparelho

| Aparelho | Desenha | Move / zoom | Apaga |
|---|---|---|---|
| Tablet/celular com S-Pen | caneta (pressão) | dedo (1 move, pinça dá zoom) | ponta de borracha ou botão lateral |
| PC com mesa digitalizadora | caneta (pressão) | botão do meio/direito, espaço, roda | ponta de borracha ou botão da caneta |
| PC/notebook com mouse | botão esquerdo | botão do meio/direito, espaço+arrastar, roda (Ctrl = zoom), trackpad | ferramenta Borracha (E) |
| Celular sem caneta | dedo | dois dedos | ferramenta Borracha |

O dedo desenha até aparecer uma caneta; daí só move (sem risco da palma). O botão da mão na barra troca isso.
Seleção (V): laço ou toque; arrastar move, cantos redimensionam; duplicar (Ctrl+D), recolorir, exportar,
excluir (Delete). Exportar PNG/PDF no menu. Sem rede o quadro abre do aparelho e sincroniza quando voltar.
Projeção (F): esconde a barra superior, barra reduzida (caneta, marcador, laser, borracha) e quadro escuro opcional.
