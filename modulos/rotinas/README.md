# Gerenciamento de Processos e Rotinas

Kanban (pendente, em execução, concluído), temporizador por tarefa e respostas rápidas por LLM em linguagem natural.

## Estrutura

```
rotinas/
├── backend/   pacote Python: API FastAPI, modelos e regras (roda na VPS)
├── worker/    jobs pesados de LLM/GPU (roda no PC com a GPU)
└── app/       pacote Flutter com as telas do módulo
```

Cada parte só existe quando houver código para ela. A plataforma (`plataforma/`) registra o
router do backend, despacha os jobs do worker e monta as telas do app.
