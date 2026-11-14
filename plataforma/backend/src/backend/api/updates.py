"""Atualização do app: versão publicada e os pacotes (APK e Linux) que o botão "Atualizar app"
baixa.

`infra/scripts/publicar_app` grava em `atualizacoes_dir` o `versao.json` (`build`, `versao`,
`publicado`) e os arquivos `agent.apk`, `agent-linux.tar.gz` e `relogio.apk` (app do relógio, mesmo
`build`).
"""

import json
from pathlib import Path

from fastapi import APIRouter, Depends
from fastapi.responses import FileResponse

from backend.api.deps import SettingsDep, require_client_api_key
from backend.core.errors import openai_error

router = APIRouter(
    prefix="/api/atualizacoes",
    tags=["atualizacoes"],
    dependencies=[Depends(require_client_api_key)],
)

PACOTES = {"android": "agent.apk", "linux": "agent-linux.tar.gz", "relogio": "relogio.apk"}


def _pasta(settings) -> Path:
    return Path(settings.atualizacoes_dir).expanduser()


@router.get("")
def versao(settings: SettingsDep) -> dict:
    """Última versão publicada; `build` 0 = nada publicado ainda."""
    arq = _pasta(settings) / "versao.json"
    dados = json.loads(arq.read_text()) if arq.is_file() else {"build": 0}
    dados["plataformas"] = [p for p, nome in PACOTES.items() if (_pasta(settings) / nome).is_file()]
    return dados


@router.get("/{plataforma}")
def baixar(plataforma: str, settings: SettingsDep) -> FileResponse:
    nome = PACOTES.get(plataforma)
    if not nome or not (_pasta(settings) / nome).is_file():
        raise openai_error(404, f"Sem pacote publicado para {plataforma}.", "not_found")
    return FileResponse(
        _pasta(settings) / nome, filename=nome, media_type="application/octet-stream"
    )
