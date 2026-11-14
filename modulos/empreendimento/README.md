# Empreendimento e Escala de Conteúdo

Gestão dos cinco canais do YouTube (meta: um vídeo por canal por dia): ideação, roteiros com artigos científicos, curadoria e validação por LLM local, busca de mídia em bancos abertos, edição, efeitos e thumbnails pelas Craft Apps, publicação.

- `esteira/`: pipeline de vídeos dark (ex-`llm/esteira-dark`), com CLI `./dark` e painel próprios; dados em `$AGENT_DATA/empreendimento/`.
- Canais: `finlumia`, `benehistory`, `cosmoatomico`, `embarcados`, `thiagobenevide` (`esteira/perfis/`).

## Estrutura

```
empreendimento/
├── backend/   pacote Python: API FastAPI, modelos e regras (roda na VPS)
├── worker/    jobs pesados de LLM/GPU (roda no PC com a GPU)
└── app/       pacote Flutter com as telas do módulo
```

Cada parte só existe quando houver código para ela. A plataforma (`plataforma/`) registra o
router do backend, despacha os jobs do worker e monta as telas do app.
