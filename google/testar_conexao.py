"""Testa a conta de serviço Google listando os arquivos que ela consegue acessar."""

import json
import sys
from pathlib import Path

CHAVE = Path(__file__).with_name("service-account.json")
ESCOPOS = [
    "https://www.googleapis.com/auth/drive.readonly",
    "https://www.googleapis.com/auth/spreadsheets.readonly",
    "https://www.googleapis.com/auth/documents.readonly",
]

if not CHAVE.exists():
    sys.exit(f"Chave não encontrada: {CHAVE}")

try:
    from google.oauth2 import service_account
    from googleapiclient.discovery import build
except ImportError:
    sys.exit("Instale as dependências no venv: veja o README desta pasta")

credenciais = service_account.Credentials.from_service_account_file(CHAVE, scopes=ESCOPOS)
print("Conta de serviço:", json.loads(CHAVE.read_text())["client_email"])

drive = build("drive", "v3", credentials=credenciais)
resposta = drive.files().list(
    pageSize=50,
    fields="files(id, name, mimeType)",
    includeItemsFromAllDrives=True,
    supportsAllDrives=True,
).execute()

arquivos = resposta.get("files", [])
if not arquivos:
    print("Nenhum arquivo visível. Compartilhe planilhas/documentos com o e-mail acima.")
for arquivo in arquivos:
    tipo = arquivo["mimeType"].rsplit(".", 1)[-1]
    print(f"- [{tipo}] {arquivo['name']} ({arquivo['id']})")
