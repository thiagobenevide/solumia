# Estudos e Gestão do Conhecimento

Leitura, anotação e síntese de artigos e livros; notas com backlinks (vault Obsidian) e grafo de conhecimento. Áreas: Tecnologia, Finanças, Linguagens e Saúde. Idiomas (inglês, francês, espanhol, português) do A1 ao C2, com cronogramas diários e semanais gerados automaticamente.

## Estrutura

```
estudos/
├── backend/   pacote Python: API FastAPI, modelos e regras (roda na VPS)
├── worker/    jobs pesados de LLM/GPU (roda no PC com a GPU)
└── app/       pacote Flutter com as telas do módulo
```

Implementado:
- `backend/` (`agent-estudos`, pacote `estudos`) em `/api/estudos`; dados em `$AGENT_DATA/estudos/`.
  `leituras` (livro/artigo, área, status, páginas, `nota_id` da síntese) e `idiomas` (trilhas A1–C2:
  `cronograma?de=&ate=` gerado por regra em `idiomas.py`, `sessoes` registra minutos, `marcos` com
  previsão por nível pelas horas guiadas do Quadro Europeu).
- Projetos de leitura (`projetos.py`, `/api/estudos/projetos`): pré-TCC, vídeo… Destaques, textos e traços à
  mão dos Arquivos levam `projetos: [id]` (projeto ativo no leitor ou chips do destaque); `…/matriz` junta tudo
  com a ficha da leitura de mesmo `arquivo_id` (T001, `[Autor Ano]`, `Autor (Ano)`), `PATCH …/itens/{id}`
  classifica no projeto (seção, tipo de citação/conteúdo, status de uso, paráfrase) e `…/exportar` gera o
  `.xlsx` (Trabalhos, Trechos, Painel, Referências) no molde de `docs/Mapeamento de Conteúdo.xlsx`.
- Mapeamento reverso (`plataforma/backend/src/backend/files/mapping.py`): `POST …/{id}/documento` guarda o
  `.docx` pronto nos Arquivos e o Claude (`claude_json` no worker) lista referências e citações, liga cada uma a
  um PDF da biblioteca e marca o trecho (destaque no projeto, já classificado); sem PDF → pendência + tarefa no
  Quadro. `POST …/{id}/mapeamento` refaz (só acrescenta). Painel em `app/lib/src/telas/mapeamento_painel.dart`.
- Trilhas de conhecimento (`conhecimento.py`, `/api/estudos/conhecimento`): catálogo em
  `catalogo_tecnologia.py` (estante de livros e a trilha Arquiteto de Software em fases → etapas, cada uma com
  frentes, conceitos, capítulos indicados, prática e entregável); progresso em `conhecimento.json`. `?frente=`
  filtra a trilha por área (Back-end, Dados, DevOps, IA…), `proxima` é a leitura dinâmica (primeiro capítulo
  não lido de livro que você tem), `POST …/livros/{id}/leitura` liga o livro à aba Leituras (PDF e grifos).
- Linguagem (`linguagem.py` + `api_linguagem.py`, `/api/estudos/linguagem`; dados em `$AGENT_DATA/estudos/linguagem/`):
  tudo pela LLM local (`_chat_llm` sem raciocínio) e pela voz do worker, nunca pelo Claude.
  `POST fala` (Kokoro por idioma + tempo de cada palavra pelo Whisper, cache por frase) e `POST traduzir` (trecho no
  contexto: tradução, classe, IPA, frase traduzida) servem a leitura guiada do leitor dos Arquivos. `vocabulario`
  (caderno; "Criar tarefas" gera frases A2–C1 e exercícios lacuna/tradução/produção em segundo plano; `responder`
  corrige e `revisar` agenda pelo FSRS-4.5), `escritas` (3 perguntas sobre o PDF da leitura ou um texto colado;
  `responder` dá nota por critério, CEFR, texto corrigido e correções), `leituras-voz` (gravação × texto:
  `shared/linguagem.py` marca certas/trocadas/puladas, ppm e pausas; o worker soma a pronúncia por fonema),
  `atividades` (minutos entram na trilha do idioma) e `progresso`.
  Worker: `falar_marcado` e `avaliar_leitura` em `worker/voice.py`; pronúncia em `worker/pronunciation.py` +
  `worker/pronuncia/servidor.py` (wav2vec2 `facebook/wav2vec2-lv-60-espeak-cv-ft` no venv do XTTS, que já tem torch;
  sem ele, avalia só as palavras). Fala em `.m4a` se houver `ffmpeg`.
- `app/` (`agent_estudos`): abas Leituras (com a vista Projetos: matriz em cartões, filtros, cobertura), Trilhas (etapas por fase, estante, nota da etapa no cofre) (nota de síntese aberta no editor de Notas, com link
  `[[Área]]`), Grafo (`/api/notas/grafo`, força dirigida, filtro por área/tag), Idiomas e Linguagem
  (`telas/linguagem_tela.dart`: Revisar, Vocabulário, Escrita, Leitura em voz, Progresso).

Cada parte só existe quando houver código para ela. A plataforma (`plataforma/`) registra o
router do backend, despacha os jobs do worker e monta as telas do app.
