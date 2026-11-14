import pytest

from worker import pc


@pytest.fixture
def lancados(monkeypatch: pytest.MonkeyPatch) -> list[tuple[str, ...]]:
    done: list[tuple[str, ...]] = []
    monkeypatch.setattr(pc, "_post", lambda *a: done.append(a))
    monkeypatch.setattr(pc.shutil, "which", lambda exe: f"/usr/bin/{exe}")
    return done


async def test_abre_site_e_pesquisa(lancados: list[tuple[str, ...]]) -> None:
    await pc.execute({"acao": "abrir_site", "url": "youtube.com/@ThiagoBenevide"})
    await pc.execute({"acao": "pesquisar", "consulta": "Flamengo hoje", "onde": "youtube"})
    assert lancados == [
        ("brave-browser", "https://youtube.com/@ThiagoBenevide"),
        ("brave-browser", "https://www.youtube.com/results?search_query=Flamengo+hoje"),
    ]


async def test_recusa_fora_da_lista(lancados: list[tuple[str, ...]]) -> None:
    for request in (
        {"acao": "shell", "comando": "rm -rf ~"},
        {"acao": "abrir_programa", "nome": "bash"},
        {"acao": "abrir_site", "url": "file:///etc/passwd"},
    ):
        with pytest.raises(pc.CommandInvalid):
            await pc.execute(request)
    assert lancados == []
