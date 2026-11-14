# Plano: plataforma de produção dark

Objetivo: do roteiro no Obsidian + WAV exportado até o vídeo final, com o mínimo de aprovação humana e o
mínimo de tokens. Decidido em 26/10/2026.

## Quem decide o quê

| Nível | Quem | Usar para |
|---|---|---|
| 1 Código | Python | vault → roteiro, Whisper, cortes óbvios, cenas, download/normalização, CLIP, gráficos, FilmCraft |
| 2 LLM local | llama.cpp (roteador, `~/agent-data/modelos`): `qwen3-14b` texto, `qwen2.5vl-7b` visão | cortes ambíguos, busca/tipo/clima por cena, destaques, escolha de gráficos, nota de mídia |
| 3 Claude | `claude -p` automático, com teto de custo por episódio/dia | só escalonamento: nível 2 com confiança baixa após nova tentativa, erro desconhecido |

Toda decisão do nível 2/3 sai em JSON validado (pydantic) com `confianca`, e é gravada no estado com quem
decidiu e por quê. O Claude recebe um dossiê compacto gerado pelo código, nunca arquivos inteiros.

## Entradas

- Roteiros: `~/Documents/github/obsidian/Notas/Empreendimento/YouTube/<canal>/Roteiros/*.md` (frontmatter
  `video`, `status`, seções `## Parte N`, `## Leitura antes de gravar`, `## Notas de produção`, fontes).
- Áudio: WAV exportado em `~/Music/Youtube/<Canal>/Roteiros/<NNN - título>/`, casado pelo número NNN.
- Artigos: PDFs em `obsidian/Referências/Artigos/` ou baixados pelo DOI (Unpaywall/acesso aberto).

## Gráficos (`esteira/graphics/`)

Modelos HTML/CSS (Jinja2) renderizados quadro a quadro pelo Chromium (Playwright) → ProRes 4444 com alfa,
colocados na V2 do FilmCraft. Determinístico (`seek(t)` congela as animações). ~2–3x tempo real.

- `citacao`: página do PDF, câmera aproxima do trecho, marca-texto linha a linha, ficha do estudo + tradução.
  O trecho é achado pelo PyMuPDF (tolera hifenização/quebras).
- `numero`: valor contando, rótulo, legenda com destaque, fonte.
- `frase`: texto cinético palavra a palavra.
- `fonte`: terço inferior com a origem do dado.
- A fazer: `comparacao` (A vs B / barras), `passos` (lista numerada), `linha_do_tempo`, `mapa`, `grafico`
  (dados → barras/linhas animadas), `titulo` de abertura e de capítulo (`## Parte N`).

O LLM local lê o roteiro com tempos e propõe um "plano gráfico" (que peça, quando, com quais dados); o código
valida (trecho existe no PDF? número está na fala?) e renderiza.

## Thumbnail agressiva (`esteira/etapas/thumb/`)

Meta: parar o polegar no feed e não sair da cabeça. Hoje é só fundo da 1ª cena + texto; passa a ser uma
etapa de criação com variantes e avaliação.

1. **Conceitos** (LLM local, ~10): a partir do roteiro, cada um com emoção-alvo (medo, agonia, choque,
   urgência, injustiça), gatilho (lacuna de curiosidade, perda iminente, ameaça pessoal, número chocante,
   "você está fazendo errado", antes/depois), elemento central e texto de 2–4 palavras que NÃO repete o
   título (título e thumb se completam). A promessa tem de ser cumprida pelo vídeo (retenção e política
   do YouTube contra thumb enganosa).
2. **Composição** (código): um ponto focal só; rosto com expressão extrema (banco de fotos + recorte com
   rembg, contorno/brilho), fundo escuro dramático, alto contraste vermelho/amarelo × preto, setas/círculos,
   número gigante quando houver. Modelos HTML renderizados como imagem única pelo mesmo motor dos gráficos;
   PSD na PhotoCraft para ajuste manual. Opcional: geração local de imagem (FLUX/SDXL na GPU) para cenas que
   não existem em banco de fotos.
3. **Avaliação** (código + VLM local): legibilidade a 168×94 px (tamanho do celular), contraste do texto,
   saliência do ponto focal, área ocupada pelo rosto; o VLM dá nota de "impacto em 1 s". Variantes fracas
   são refeitas automaticamente.
4. **Escolha final** (Claude, 1 imagem): folha com as ~6 melhores; o Claude escolhe 3 e justifica. Vale o
   custo: a thumb é a peça de maior retorno do vídeo.
5. **Entrega**: 3 variantes para o "Testar e comparar" do YouTube (teste A/B nativo) + PSDs.

## Estrutura alvo

```
esteira/nucleo/    eventos (jsonl + SSE), estado (SQLite), cache, fila (worker único)
esteira/sources/    obsidian (md → roteiro + fontes), gravacoes (NNN → WAV)
esteira/ia/        local (Ollama), visao (CLIP/VLM), claude (escalonamento + teto), prompts/
esteira/etapas/    cortes, cenas, curadoria, midia, graficos, efeitos, montagem, thumb
esteira/craft/     filmcraft, effectcraft, photocraft, soundcraft
esteira/web/       FastAPI + HTMX + Tailwind: biblioteca (checkbox → fila), produção ao vivo,
                   cortes, linha do tempo, escalonamentos/custos
perfis/<canal>.toml  cor, fontes, LUT, música, ritmo, efeitos por clima
projetos/<canal>/<NNN>/  episódios (id na CLI: canal-NNN)
tests/             casos dourados (cortes do ep003)
```

## Fases

1. Núcleo: eventos, estado, `./dark status`, progresso (montagem deixa de ser caixa-preta).
2. Fontes: vault → `roteiro.txt` + lista de fontes automática; WAV encontrado pelo NNN.
3. Cortes novos (blocos de fala, palavras/radicais, recomeços) + testes dourados.
4. LLM local: cortes ambíguos, curadoria de cenas, plano gráfico.
5. Gráficos integrados à montagem (V2) + citações de PDF; CLIP/VLM avaliando mídia; downloads paralelos.
6. Painel web.
7. Perfis por canal, efeitos por clima, SoundCraft na voz, EffectCraft.
8. Escalonamento automático ao Claude com teto.
9. Thumbnail agressiva: conceitos, composição, avaliação, 3 variantes para teste A/B.

## Estado (26/10/2026)

- [x] 1 Núcleo: `esteira/nucleo/` (eventos.jsonl, `./dark status`, `./dark log`, progresso com previsão,
      FilmCraft instrumentado, batimento na exportação)
- [x] 2 Fontes: `./dark roteiros`, `./dark importar canal:NNN` (vault → roteiro.txt, roteiro.json com
      capítulos/notas/fontes; WAV achado pelo número da sessão)
- [x] 3 Cortes: `esteira/cuts.py` (alinhamento local, último recomeço, retakes partidos, duplicados,
      reformulações, continuações, 2ª passada para retakes ocultos) + `tests/test_cuts.py`
- [x] 4 LLM local: cortes ambíguos e pares, curadoria (`./dark curar`), plano gráfico; cache em `cache/llm.jsonl`
- [x] 5 Gráficos integrados (V4) + citações com PDF (vault/OpenAlex); avaliação visual (`./dark avaliar`);
      downloads paralelos
- [x] 6 Painel web (`./dark painel`): biblioteca com seleção, fila, etapas ao vivo, cortes, linha do tempo, custos
- [x] 7 Perfis por canal (`perfis/*.toml`), transições e zoom por clima
- [x] 8 Claude automático com teto: cortes incertos, mídia fraca (folha), escolha de thumbs, diagnóstico de erro
- [x] 9 Thumbs: conceitos (LLM) → RealVisXL → HTML → nota de impacto (visão) → Claude escolhe 3
- [ ] FLUX.1-schnell (melhor que SDXL em rostos): exige `huggingface-cli login` + aceitar a licença no site
- [ ] SoundCraft na voz (redução de ruído/EQ) antes dos cortes; EffectCraft
- [ ] Gráficos: `grafico` (barras/linhas com dados), `mapa`, `linha_do_tempo`; ProRes ocupa ~75 MB/s
      de gráfico (avaliar codec mais leve)
- [x] Limpeza (26/10/2026): removidos `novo`, `limpar.py` antigo, `thumb.py` (PhotoCraft), overlay de textura
      (V3, flocos/poeira), projetos `ep003`/`exemplo`; episódios em `projetos/<canal>/<NNN>/`

## Roteiro como fonte da verdade (26/10/2026)

- Vault: `.claude/scripts/artigo` (baixar PDF por DOI/URL/arXiv via OpenAlex, Semantic Scholar e
  `citation_pdf_url` → `Referências/Artigos/` + `indice.json`; `trechos`; `citar` gera o bloco `[!cite]` com o
  trecho exatamente como está na página; `checar` confere o roteiro). Skill `roteiro` e agente `roteirista`
  (um vídeo por subagente, lotes de até 4) para "faça os 10 roteiros".
- Esteira: `obsidian.convert` lê os `[!cite]` → `roteiro.json["citacoes"]` (conferidos no `importar`);
  `graficos` usa a citação marcada (sem LLM) e só tenta adivinhar as fontes que o roteiro não marcou.
- Formato 9:16: `[video] formato`, sobrescritas `[vertical.*]` (cenas mais curtas, legenda queimada, sem
  cartelas de capítulo nem thumbs), mídia em retrato, layout vertical em todos os modelos gráficos.
  Shorts em `<canal>/Shorts/Short NNNx — Título.md`, projeto `projetos/<canal>/NNNx/`.
- Edição manual: `./dark abrir`, `./dark exportar`; o `montar` preserva `.fcproj` editado (assinatura em
  `log/fcproj.sha1`).

## Modos de produção e acervo de mídia (26/10/2026)

- `esteira/production.py`: `dark` (narração + bancos de imagens) e `apresentador` (câmera na V1 com os mesmos
  cortes da narração via `timeline.place sourceIn/duration`, sem recodificar; WAV sincronizado com o som da
  câmera por correlação cruzada de envelopes; B-roll na V2 em `[producao] broll` do tempo; regras: nota de
  cena pedindo câmera → câmera, nota visual → B-roll, abertura de cada Parte → câmera). Cenas de câmera não
  buscam mídia. Câmera escalada para preencher o quadro (4K, 720p, 9:16).
- `esteira/library.py`: originais guardados em `acervo/<provedor>/<id>`, metadados (crédito, licença, tags e
  título do banco, dimensões, orientação, duração, termos que acharam, descrição/tags do VLM local, notas por
  termo, usos por episódio/canal) em SQLite + FTS5. Busca: acervo → Pexels/Pixabay/Openverse. Filtros: tipo,
  orientação, duração, `max_usos_canal`, nota ≤ 2 para o mesmo termo. Avaliação visual reaproveita notas.
  Painel: aba Acervo. `cortes.json` passa a guardar os intervalos mantidos (tempo da gravação bruta).
