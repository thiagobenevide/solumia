import pytest

from esteira.dataset import index
from esteira.dataset import registry as R


@pytest.fixture(autouse=True)
def temporary_dataset(tmp_path, monkeypatch):
    """Nenhum teste grava no dataset real: registro, artefatos, eventos e índice vão para o tmp."""
    base = tmp_path / "dataset"
    for name, value in {"FOLDER": base, "RECORD": base / "registro", "ARTIFACTS": base / "artefatos",
                        "EVENTS": base / "registro" / "_eventos"}.items():
        monkeypatch.setattr(R, name, value)
    monkeypatch.setattr(index, "FILE", base / "indice.db")
    from esteira.ai import claude
    monkeypatch.setattr(claude, "quota_limit", lambda: claude.QUOTA_LIMIT)  # as Opções reais não entram nos testes
    return base
