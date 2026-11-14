---
name: produzir-episodio
description: Produz, continua ou corrige um episódio da esteira dark (roteiro do vault Obsidian + WAV → vídeo final com gráficos e thumbs). Usar quando o usuário pedir para produzir, refazer ou continuar um episódio em projetos/<canal>/<NNN>, ou investigar uma etapa que falhou.
---

# Produzir um episódio

A esteira roda sozinha: código + LLM local (llama.cpp) fazem o operacional e o Claude é chamado
automaticamente (`claude -p`, com teto) só nos casos difíceis. **O seu papel é acompanhar e corrigir o que
falhou, não refazer o trabalho das etapas.** Plano completo: `docs/PLANO.md`.

## Rodar
```sh
./dark import finlumia:3          # roteiro do vault → projetos/finlumia/003 (roteiro, fontes, áudio)
./dark all finlumia-003            # limpar → cenas → curar → buscar → avaliar → graficos → montar → thumb
./dark panel                       # o usuário acompanha e revisa em http://localhost:8765
```
Modo apresentador (você na câmera): `modo: apresentador` no roteiro (ou `--modo apresentador --camera X.mp4`
no importar). O vídeo da câmera é achado junto do WAV e sincronizado; o `import` mostra o offset e a
confiança da sincronia (abaixo de 30%: conferir no FilmCraft). Mídia: a busca reaproveita o acervo antes das
APIs; `./dark library` mostra o tamanho e o reuso, `./dark library describe` (visão local, sem tokens) melhora
a busca.
Short (9:16): `./dark import finlumia:5a` (pasta `Shorts/` do vault) já grava `formato = "9:16"` no projeto.
O `import` avisa citações `[!cite]` com PDF ausente ou trecho fora da página: corrigir no vault com
`.claude/scripts/artigo checar "<roteiro>.md"` e importar de novo (não editar `roteiro.json`).
Rodar em segundo plano e esperar a notificação; nunca ficar consultando o progresso.

## Acompanhar (barato)
- `./dark status <ep>`: uma linha por etapa (✓ ✗ ▶ ⚠, tempo, última mensagem, avisos).
- `./dark log <ep> --errors` (traceback resumido) ou `--stage X --n 20`. `--debug` só se precisar das
  chamadas ao FilmCraft/LLM.
- Nunca Read/cat em `plano.json`, `transcricao*.json`, `alinhamento.json`, `cortes.json`, `graficos.json`:
  `./dark summary <ep> [--scenes 3,5] [--no-text]`, `./dark words <ep> --from S --to S`, `cortes.txt`.

## Corrigir
- Cenas: `./dark adjust <ep>` (JSON Lines, um comando para várias cenas), depois
  `./dark fetch <ep> --redo --scenes 3,7 && ./dark evaluate <ep>`. Ver mídia só pela folha:
  `./dark review <ep> --scenes 3,7` → Read em `revisao_01.jpg` (uma vez).
- Cortes: o usuário revisa no painel (aba Cortes) e clica Aplicar; `./dark clean <ep>` reaproveita
  `cortes.json`, `--redo` decide de novo. Casos dourados em `tests/test_cortes.py` (rodar após mexer em
  `esteira/cuts.py`: `.venv/bin/python -m pytest -q tests`).
- Gráficos: `./dark graphics <ep>` replaneja + renderiza (cache por hash; só o que mudou é refeito).
- Conferir o vídeo: `./dark frames <ep>` → Read em `quadros.jpg`. Thumbs: Read em `thumbs/folha_escolha.jpg`.

## Edição manual
Se a revisão achar algo que a esteira não resolve, o usuário edita no FilmCraft: `./dark open <ep>`, salva,
`./dark export <ep>`. Não rode `assemble` depois disso sem avisar: ele guarda a edição manual como
`projeto.manual-*.fcproj` e monta de novo do zero.

## Entregar
`final.mp4`, `thumb_1..3.png` (teste A/B do YouTube), `projeto.fcproj`, `creditos.txt`. Resposta curta:
caminhos + o que ficou fraco (cenas com nota < 3 no `./dark summary`, avisos no `./dark status`).
