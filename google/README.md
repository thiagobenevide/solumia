# Google service account

Folder for the JSON key of the service account used to access spreadsheets (Google Sheets) and documents (Google Docs).

> No key in this folder goes to Git (`google/*.json` is in `.gitignore`), not even with the private repository. If you need it on the VPS, copy it directly (`scp`), with permission 600.

## 1. Place the key

Save the file downloaded from Google Cloud here with the name:

```
google/service-account.json
```

And restrict read permission:

```bash
chmod 600 google/service-account.json
```

## 2. Google Cloud prerequisites

In the project where the service account was created, enable the APIs:

- Google Sheets API
- Google Docs API
- Google Drive API (to list/find files)

## 3. Grant access to the files

The service account does **not** see your files automatically. For each spreadsheet or document (or Drive folder):

1. Open the JSON and copy the `client_email` field (something like `name@project.iam.gserviceaccount.com`).
2. In Google Drive, click **Share** on the file/folder.
3. Paste the service account e-mail and grant **Viewer** permission (or **Editor**, if it needs to write).

Sharing a **folder** grants access to everything inside it.

## 4. Test the connection

```bash
python3 -m venv google/.venv
google/.venv/bin/pip install google-auth google-api-python-client
google/.venv/bin/python google/test_connection.py
```

The script lists the files the service account can see.

## If the key leaks

1. Google Cloud Console > IAM > Service accounts > the account > **Keys** > delete the key.
2. Generate a new key and replace the file here.
