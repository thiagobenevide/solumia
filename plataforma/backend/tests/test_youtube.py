from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from youtube.importer import importar, normalizar

R = "/api/youtube"


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, notas_dir=str(tmp_path / "notas"))
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def _canal(api: TestClient) -> None:
    r = api.post(
        f"{R}/canais",
        json={"slug": "finlumia", "titulo": "Canal 1 — Finanças", "nome": "Finlumia"},
    )
    assert r.status_code == 201, r.text


def test_exige_chave(tmp_path: Path) -> None:
    s = Settings(client_api_keys=CLIENT_API_KEY, notas_dir=str(tmp_path))
    assert TestClient(create_app(settings=s)).get(f"{R}/canais").status_code == 401


def test_canal_crud(api: TestClient, tmp_path: Path) -> None:
    _canal(api)
    assert api.post(f"{R}/canais", json={"slug": "finlumia", "titulo": "X"}).status_code == 409
    assert api.post(f"{R}/canais", json={"slug": "Com Espaço", "titulo": "Y"}).status_code == 409
    [c] = api.get(f"{R}/canais").json()
    assert (c["slug"], c["nome"], c["status"]) == ("finlumia", "Finlumia", "ideia")
    arq = tmp_path / "notas/Notas/Empreendimento/YouTube/finlumia/Canal 1 — Finanças.md"
    assert "tipo: canal" in arq.read_text()

    r = api.patch(f"{R}/canais/finlumia", json={"status": "ativo", "nome": "Finlumia BR"})
    assert (r.json()["status"], r.json()["nome"]) == ("ativo", "Finlumia BR")
    assert api.get(f"{R}/canais/nada").status_code == 404
    assert api.delete(f"{R}/canais/finlumia").status_code == 204
    assert api.get(f"{R}/canais").json() == []


def test_temas_derivar_e_gerencia(api: TestClient, tmp_path: Path) -> None:
    _canal(api)
    base = f"{R}/canais/finlumia"
    r = api.post(
        f"{base}/temas",
        json={"titulo": "001 — Juros compostos", "propriedades": {"numero": "1", "fio": "DO"}},
    )
    assert r.status_code == 201, r.text
    tema = r.json()
    assert tema["titulo"] == "Tema — 001 — Juros compostos"
    assert tema["propriedades"]["canal"] == "[[Canal 1 — Finanças]]"
    assert "## Títulos" in tema["corpo"]
    assert (
        api.post(f"{base}/temas", json={"titulo": "x", "propriedades": {"numero": "a"}}).status_code
        == 409
    )
    assert (
        api.post(f"{base}/temas", json={"titulo": "x", "propriedades": {"status": "?"}}).status_code
        == 409
    )

    rot = api.post(f"{base}/temas/{tema['id']}/derivar", json={"colecao": "roteiros"}).json()
    assert rot["titulo"] == "Roteiro — 001 — Juros compostos"
    assert rot["propriedades"]["video"] == 1
    assert rot["ligacoes"]["tema"] == tema["titulo"]
    assert (
        api.post(f"{base}/temas/{tema['id']}/derivar", json={"colecao": "roteiros"}).status_code
        == 409
    )
    hist = api.post(f"{base}/temas/{tema['id']}/derivar", json={"colecao": "historias"}).json()
    assert hist["ligacoes"] == {"tema": tema["titulo"], "roteiro": rot["titulo"]}

    [t] = api.get(f"{base}/temas").json()
    assert t["ligacoes"] == {"roteiro": rot["titulo"], "historia": hist["titulo"]}
    assert api.get(f"{base}/temas?status=publicado").json() == []

    r = api.patch(
        f"{base}/roteiros/{rot['id']}",
        json={"propriedades": {"status": "gravado", "formato": "L", "fio": ""}},
    )
    assert r.json()["status"] == "gravado" and "fio" not in r.json()["propriedades"]
    # a nota do tema também aparece no app de notas, com o mesmo id
    assert api.get(f"/api/notas/{tema['id']}").json()["tipo"] == "tema"
    assert api.get(f"{base}/historias/{tema['id']}").status_code == 404

    col = api.get(f"{R}/canais").json()[0]["colecoes"]
    assert col["temas"]["total"] == 1 and col["roteiros"]["status"] == {"gravado": 1}
    assert api.delete(f"{R}/canais/finlumia").status_code == 409
    assert api.delete(f"{base}/roteiros/{rot['id']}").status_code == 204
    assert api.get(f"{base}/roteiros").json() == []


def test_normalizar_padrao_das_notas() -> None:
    ids: set[str] = set()
    texto = (
        '---\nid: "1"\ntipo: tema\ncriado: "2026-10-20"\natualizado: 2026-10-25\n'
        "status: rascunho\n---\n\n# T\n"
    )
    saida = normalizar(texto, ids)
    assert "criada: '2026-10-20'" in saida and "atualizada: '2026-10-25'" in saida
    assert "criado:" not in saida and saida.endswith("# T\n")
    assert "id: 1-2" in normalizar(texto, ids).replace("'", "")


def test_importar_do_vault(tmp_path: Path) -> None:
    pasta = tmp_path / "vault/Notas/Empreendimento/YouTube/finlumia"
    (pasta / "Temas").mkdir(parents=True)
    (pasta / ".gerador").mkdir()
    (pasta / "Canal 1.md").write_text("---\nid: '10'\ntipo: canal\n---\n\n# Canal 1\n")
    (pasta / "Temas/Tema — A.md").write_text("---\nid: '10'\ntipo: tema\n---\n\n# A\n")
    (pasta / ".gerador/x.md").write_text("ignorar")
    destino = tmp_path / "notas"
    assert importar(tmp_path / "vault", destino)["importadas"] == 2
    assert importar(tmp_path / "vault", destino)["puladas"] == 2

    s = Settings(
        client_api_keys=CLIENT_API_KEY,
        notas_dir=str(destino),
        youtube_vault=str(tmp_path / "vault"),
    )
    api = TestClient(create_app(settings=s), headers=AUTH_HEADERS)
    assert api.post(f"{R}/importar", json={"substituir": True}).json()["importadas"] == 2
    [c] = api.get(f"{R}/canais").json()
    assert c["colecoes"]["temas"]["total"] == 1
