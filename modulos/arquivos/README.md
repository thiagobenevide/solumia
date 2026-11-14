# Files

Study library: PDF (scientific articles), DOCX and PPTX (slides). DOCX/PPTX become PDF on the server
(headless LibreOffice) and are read in the same reader; the original is kept for download.
Editing inside the app: DOCX in the document editor (formatting, track changes per author,
comments, spelling/rewriting by Claude as revisions), XLSX in the spreadsheet and PPTX in the slide editor;
"Exportar…" generates ODT/PDF/ODS/ODP/CSV/Markdown or a reference note. CSV in a grid and XML as text; on desktop, "Abrir com…" LibreOffice/Craft Apps uploads
on its own whatever is saved there (PUT `/original`). CSV opens as a table and XML as a tree (the app reads `/original`, or the copy downloaded on the device; XML does not become PDF and already enters as `pronto`).

- Backend: `plataforma/backend/src/backend/files/` at `/api/arquivos` (shared core, like the notes,
  because other modules attach files). Data in `$AGENT_DATA/arquivos/<id>/`.
- App: `app/` (`agent_arquivos`), mounted in `plataforma/app/lib/main.dart` with `API_URL`/`API_TOKEN`.

## Routes (`Authorization: Bearer <GATEWAY_CLIENT_API_KEYS>`)

| Route | What |
|---|---|
| `GET /api/arquivos?q=&tipo=&pasta=` | list (most recent first) |
| `POST /api/arquivos` (multipart `arquivo`, `pasta`) | upload; PDF becomes `pronto`, DOCX/PPTX `convertendo` |
| `GET /api/arquivos/pastas` | folders in use |
| `GET /api/arquivos/destaques?q=&arquivo_id=` | marked passages from every file, with a Markdown `referencia` |
| `GET /api/arquivos/mudancas?desde=<seq>` | `criado/editado/excluido/convertido/anotado` log to sync devices |
| `GET/PATCH/DELETE /api/arquivos/{id}` | meta; edits `titulo`, `pasta`, `tags`; deletes everything |
| `GET /api/arquivos/{id}/pdf` · `/original` · `/miniatura` | files |
| `PUT /api/arquivos/{id}/original` (multipart `arquivo`) | replaces the original with an edited version; converts again |
| `POST /api/arquivos/{id}/converter` | redoes the conversion |
| `POST /api/arquivos/novo` (`{tipo: documento\|planilha\|apresentacao, titulo, pasta}`) | blank DOCX/XLSX/PPTX (LibreOffice) |
| `GET /api/arquivos/{id}/exportar?formato=` | original converted by LibreOffice (`EXPORTACOES` in `biblioteca.py`: odt/pdf/rtf/txt/html, ods/csv, odp…) |
| `GET /api/arquivos/reescrita` · `POST /api/arquivos/reescrever` | passage rewriting (thesis) by Claude Code on the PC worker — never the Anthropic API; `arquivo_id` sends the document as context |
| `GET/POST /api/arquivos/{id}/traducao` | translation of the document into Portuguese, sentence by sentence per page (worker local LLM, no reasoning), stored in `traducao.json`; POST only translates the pages whose sentences changed (or `refazer`). The reader shows it in the panel, with the PDF layout, or over the page itself |
| `GET/PUT /api/arquivos/{id}/anotacoes` | strokes, highlights and texts; PUT with `versao_base` (409 = another device saved first; the app merges) |

The same backend runs on the PC (`http://localhost:48080`, internal use) and on the VPS behind nginx
(`https://…`, external use from the tablet, phone and web). On the VPS the Docker image already ships LibreOffice and poppler.

## Editing with Collabora (WOPI)

`POST /api/arquivos/{id}/collabora` returns `{url, access_token, access_token_ttl}`; Collabora talks to
`/wopi/files/{id}` (CheckFileInfo, contents GET/POST, locks) authenticated by the token, never by the app key.
`GET /wopi/abrir/{id}?t=` opens it in the browser (Linux/Windows, no webview). Each save converts the PDF again.

Env (`GATEWAY_`): `COLLABORA_URL` (public; empty = off), `COLLABORA_INTERNO_URL` (discovery),
`WOPI_BASE_URL` (how Collabora reaches the backend; matches `aliasgroup1`), `WOPI_SECRET`, `WOPI_TOKEN_MINUTOS`.
VPS: `collabora` service in `infra/docker/docker-compose.yml` + nginx blocks (`/browser`, `/hosting/*`, `/cool/`).
On the PC:

```
docker run -d --name collabora -p 127.0.0.1:9980:9980 --cap-add MKNOD --add-host=host.docker.internal:host-gateway \
  -e aliasgroup1=http://host.docker.internal:48080 -e "extra_params=--o:ssl.enable=false" \
  -e "dictionaries=pt_BR en_US" collabora/code
```

with `GATEWAY_COLLABORA_URL=http://localhost:9980`, `GATEWAY_WOPI_BASE_URL=http://host.docker.internal:48080` and the
backend listening on `0.0.0.0`. Web: add `--o:net.frame_ancestors=<app origin>` to `extra_params`.
