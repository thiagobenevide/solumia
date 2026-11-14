# Conta de serviço Google

Pasta para a chave JSON da conta de serviço usada para acessar planilhas (Google Sheets) e documentos (Google Docs).

> Nenhuma chave desta pasta vai para o Git (`google/*.json` está no `.gitignore`), nem com o repositório privado. Se precisar dela na VPS, copie direto (`scp`), com permissão 600.

## 1. Colocar a chave

Salve o arquivo baixado do Google Cloud aqui com o nome:

```
.credenciais/google/service-account.json
```

E restrinja a permissão de leitura:

```bash
chmod 600 .credenciais/google/service-account.json
```

## 2. Pré-requisitos no Google Cloud

No projeto onde a conta de serviço foi criada, ative as APIs:

- Google Sheets API
- Google Docs API
- Google Drive API (para listar/encontrar arquivos)

## 3. Dar acesso aos arquivos

A conta de serviço **não** enxerga seus arquivos automaticamente. Para cada planilha ou documento (ou pasta do Drive):

1. Abra o JSON e copie o campo `client_email` (algo como `nome@projeto.iam.gserviceaccount.com`).
2. No Google Drive, clique em **Compartilhar** no arquivo/pasta.
3. Cole o e-mail da conta de serviço e dê permissão de **Leitor** (ou **Editor**, se precisar escrever).

Compartilhar uma **pasta** dá acesso a tudo que estiver dentro dela.

## 4. Testar a conexão

```bash
python3 -m venv .credenciais/google/.venv
.credenciais/google/.venv/bin/pip install google-auth google-api-python-client
.credenciais/google/.venv/bin/python .credenciais/google/testar_conexao.py
```

O script lista os arquivos que a conta de serviço consegue ver.

## Se a chave vazar

1. Google Cloud Console > IAM > Contas de serviço > a conta > **Chaves** > excluir a chave.
2. Gerar uma nova chave e substituir o arquivo aqui.
