import pytest

from worker import pc


@pytest.fixture
def lancados(monkeypatch: pytest.MonkeyPatch) -> list[tuple[str, ...]]:
    feitos: list[tuple[str, ...]] = []
    monkeypatch.setattr(pc, "_lancar", lambda *a: feitos.append(a))
    monkeypatch.setattr(pc.shutil, "which", lambda exe: f"/usr/bin/{exe}")
    return feitos


async def test_abre_site_e_pesquisa(lancados: list[tuple[str, ...]]) -> None:
    await pc.executar({"acao": "abrir_site", "url": "youtube.com/@ThiagoBenevide"})
    await pc.executar({"acao": "pesquisar", "consulta": "Flamengo hoje", "onde": "youtube"})
    assert lancados == [
        ("brave-browser", "https://youtube.com/@ThiagoBenevide"),
        ("brave-browser", "https://www.youtube.com/results?search_query=Flamengo+hoje"),
    ]


async def test_recusa_fora_da_lista(lancados: list[tuple[str, ...]]) -> None:
    for pedido in (
        {"acao": "shell", "comando": "rm -rf ~"},
        {"acao": "abrir_programa", "nome": "bash"},
        {"acao": "abrir_site", "url": "file:///etc/passwd"},
    ):
        with pytest.raises(pc.ComandoInvalido):
            await pc.executar(pedido)
    assert lancados == []
