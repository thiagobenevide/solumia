from __future__ import annotations

from pathlib import Path

import pytest

from solumia_configurador.vault import KeySource, Vault


class ChaveFixa(KeySource):
    """In-memory key: the tests never touch the person's real keyring."""

    def __init__(self, chave: bytes = b"k" * 32) -> None:
        self.key = chave

    def obter(self, criar: bool) -> bytes:
        return self.key


@pytest.fixture(autouse=True)
def _isolate_folders(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    for var in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME"):
        monkeypatch.setenv(var, str(tmp_path / var.lower()))


@pytest.fixture
def vault(tmp_path: Path) -> Vault:
    return Vault(tmp_path / "teste.cofre", ChaveFixa()).open_file()
