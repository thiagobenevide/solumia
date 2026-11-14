from __future__ import annotations

from pathlib import Path

import pytest

from solumia_configurador.cofre import Cofre, FonteChave


class ChaveFixa(FonteChave):
    """Chave em memória: os testes nunca tocam no chaveiro real da pessoa."""

    def __init__(self, chave: bytes = b"k" * 32) -> None:
        self.chave = chave

    def obter(self, criar: bool) -> bytes:
        return self.chave


@pytest.fixture(autouse=True)
def _isolar_pastas(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    for var in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME"):
        monkeypatch.setenv(var, str(tmp_path / var.lower()))


@pytest.fixture
def cofre(tmp_path: Path) -> Cofre:
    return Cofre(tmp_path / "teste.cofre", ChaveFixa()).abrir()
