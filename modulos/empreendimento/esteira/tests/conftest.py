import pytest

from esteira.dataset import indice
from esteira.dataset import registro as R


@pytest.fixture(autouse=True)
def dataset_temporario(tmp_path, monkeypatch):
    """Nenhum teste grava no dataset real: registro, artefatos, eventos e índice vão para o tmp."""
    base = tmp_path / "dataset"
    for nome, valor in {"PASTA": base, "REGISTRO": base / "registro", "ARTEFATOS": base / "artefatos",
                        "EVENTOS": base / "registro" / "_eventos"}.items():
        monkeypatch.setattr(R, nome, valor)
    monkeypatch.setattr(indice, "ARQUIVO", base / "indice.db")
    from esteira.ia import claude
    monkeypatch.setattr(claude, "limite_cota", lambda: claude.LIMITE_COTA)  # as Opções reais não entram nos testes
    return base
