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

PACKAGES = {"android": "agent.apk", "linux": "agent-linux.tar.gz", "relogio": "relogio.apk"}


def _folder(settings) -> Path:
    return Path(settings.atualizacoes_dir).expanduser()


@router.get("")
def version(settings: SettingsDep) -> dict:
    """Última versão publicada; `build` 0 = nada publicado ainda."""
    file = _folder(settings) / "versao.json"
    data = json.loads(file.read_text()) if file.is_file() else {"build": 0}
    data["plataformas"] = [p for p, name in PACKAGES.items() if (_folder(settings) / name).is_file()]
    return data


@router.get("/{plataforma}")
def download(plataforma: str, settings: SettingsDep) -> FileResponse:
    name = PACKAGES.get(plataforma)
    if not name or not (_folder(settings) / name).is_file():
        raise openai_error(404, f"Sem pacote publicado para {plataforma}.", "not_found")
    return FileResponse(
        _folder(settings) / name, filename=name, media_type="application/octet-stream"
    )
