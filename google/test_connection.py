"""Tests the Google service account by listing the files it can access."""

import json
import sys
from pathlib import Path

KEY = Path(__file__).with_name("service-account.json")
SCOPES = [
    "https://www.googleapis.com/auth/drive.readonly",
    "https://www.googleapis.com/auth/spreadsheets.readonly",
    "https://www.googleapis.com/auth/documents.readonly",
]

if not KEY.exists():
    sys.exit(f"Key not found: {KEY}")

try:
    from google.oauth2 import service_account
    from googleapiclient.discovery import build
except ImportError:
    sys.exit("Install the dependencies in the venv: see this folder's README")

credentials = service_account.Credentials.from_service_account_file(KEY, scopes=SCOPES)
print("Service account:", json.loads(KEY.read_text())["client_email"])

drive = build("drive", "v3", credentials=credentials)
response = drive.files().list(
    pageSize=50,
    fields="files(id, name, mimeType)",
    includeItemsFromAllDrives=True,
    supportsAllDrives=True,
).execute()

files = response.get("files", [])
if not files:
    print("No visible file. Share spreadsheets/documents with the e-mail above.")
for file in files:
    kind = file["mimeType"].rsplit(".", 1)[-1]
    print(f"- [{kind}] {file['name']} ({file['id']})")
