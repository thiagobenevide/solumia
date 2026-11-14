# Arquivos

Biblioteca de estudo: PDF (artigos científicos), DOCX e PPTX (slides). DOCX/PPTX viram PDF no servidor
(LibreOffice headless) e são lidos no mesmo leitor; o original fica guardado para baixar.
Edição dentro do app: DOCX no editor de documentos (formatação, controle de alterações por autor,
comentários, ortografia/reescrita pelo Claude como revisões), XLSX na planilha e PPTX no editor de slides;
"Exportar…" gera ODT/PDF/ODS/ODP/CSV/Markdown ou nota de referência. CSV em grade e XML em texto; no desktop, "Abrir com…" LibreOffice/Craft Apps sobe
sozinho o que for salvo lá (PUT `/original`). CSV abre em tabela e XML em árvore (o app lê o `/original`, ou a cópia baixada no aparelho; XML não vira PDF e já entra `pronto`).

- Backend: `plataforma/backend/src/backend/arquivos/` em `/api/arquivos` (núcleo comum, como as notas,
  porque outros módulos anexam arquivos). Dados em `$AGENT_DATA/arquivos/<id>/`.
- App: `app/` (`agent_arquivos`), montado em `plataforma/app/lib/main.dart` com `API_URL`/`API_TOKEN`.

## Rotas (`Authorization: Bearer <GATEWAY_CLIENT_API_KEYS>`)

| Rota | O quê |
|---|---|
| `GET /api/arquivos?q=&tipo=&pasta=` | lista (mais recente primeiro) |
| `POST /api/arquivos` (multipart `arquivo`, `pasta`) | envia; PDF fica `pronto`, DOCX/PPTX `convertendo` |
| `GET /api/arquivos/pastas` | pastas em uso |
| `GET /api/arquivos/destaques?q=&arquivo_id=` | trechos marcados de todos os arquivos, com `referencia` Markdown |
| `GET /api/arquivos/mudancas?desde=<seq>` | log `criado/editado/excluido/convertido/anotado` para sincronizar aparelhos |
| `GET/PATCH/DELETE /api/arquivos/{id}` | meta; edita `titulo`, `pasta`, `tags`; exclui tudo |
| `GET /api/arquivos/{id}/pdf` · `/original` · `/miniatura` | arquivos |
| `PUT /api/arquivos/{id}/original` (multipart `arquivo`) | troca o original por uma versão editada; reconverte |
| `POST /api/arquivos/{id}/converter` | refaz a conversão |
| `POST /api/arquivos/novo` (`{tipo: documento\|planilha\|apresentacao, titulo, pasta}`) | DOCX/XLSX/PPTX em branco (LibreOffice) |
| `GET /api/arquivos/{id}/exportar?formato=` | original convertido pelo LibreOffice (`EXPORTACOES` em `biblioteca.py`: odt/pdf/rtf/txt/html, ods/csv, odp…) |
| `GET /api/arquivos/reescrita` · `POST /api/arquivos/reescrever` | reescrita de trecho (TCC) pelo Claude Code no worker do PC — nunca a API da Anthropic; `arquivo_id` manda o documento como contexto |
| `GET/POST /api/arquivos/{id}/traducao` | tradução do documento para o português, frase a frase por página (LLM local do worker, sem raciocínio), guardada em `traducao.json`; POST só traduz as páginas cujas frases mudaram (ou `refazer`). O leitor mostra no painel, com a diagramação do PDF, ou sobre a própria página |
| `GET/PUT /api/arquivos/{id}/anotacoes` | traços, destaques e textos; PUT com `versao_base` (409 = outro aparelho salvou antes; o app mescla) |

O mesmo backend roda no PC (`http://localhost:48080`, uso interno) e na VPS atrás do nginx
(`https://…`, uso externo pelo tablet, celular e web). Na VPS a imagem Docker já traz LibreOffice e poppler.

## Edição pelo Collabora (WOPI)

`POST /api/arquivos/{id}/collabora` devolve `{url, access_token, access_token_ttl}`; o Collabora fala com
`/wopi/files/{id}` (CheckFileInfo, contents GET/POST, travas) autenticado pelo token, nunca pela chave do app.
`GET /wopi/abrir/{id}?t=` abre no navegador (Linux/Windows, sem webview). Cada salvamento reconverte o PDF.

Env (`GATEWAY_`): `COLLABORA_URL` (pública; vazio = desligado), `COLLABORA_INTERNO_URL` (discovery),
`WOPI_BASE_URL` (como o Collabora alcança o backend; casa com `aliasgroup1`), `WOPI_SECRET`, `WOPI_TOKEN_MINUTOS`.
VPS: serviço `collabora` no `infra/docker/docker-compose.yml` + blocos do nginx (`/browser`, `/hosting/*`, `/cool/`).
No PC:

```
docker run -d --name collabora -p 127.0.0.1:9980:9980 --cap-add MKNOD --add-host=host.docker.internal:host-gateway \
  -e aliasgroup1=http://host.docker.internal:48080 -e "extra_params=--o:ssl.enable=false" \
  -e "dictionaries=pt_BR en_US" collabora/code
```

com `GATEWAY_COLLABORA_URL=http://localhost:9980`, `GATEWAY_WOPI_BASE_URL=http://host.docker.internal:48080` e o
backend escutando em `0.0.0.0`. Web: acrescentar `--o:net.frame_ancestors=<origem do app>` ao `extra_params`.
