import shutil
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app

# PDF mínimo de uma página em branco.
PDF = (
    b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
    b"2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
    b"3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\n"
    b"trailer<</Root 1 0 R>>\n%%EOF\n"
)


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(
        client_api_keys=CLIENT_API_KEY, arquivos_dir=str(tmp_path), notas_dir=str(tmp_path)
    )
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def _enviar(api: TestClient, nome: str, conteudo: bytes = PDF, pasta: str = "") -> dict:
    r = api.post("/api/arquivos", files={"arquivo": (nome, conteudo)}, data={"pasta": pasta})
    assert r.status_code == 201, r.text
    return r.json()


def test_exige_chave(tmp_path: Path) -> None:
    s = Settings(client_api_keys=CLIENT_API_KEY, arquivos_dir=str(tmp_path))
    assert TestClient(create_app(settings=s)).get("/api/arquivos").status_code == 401


def test_envio_listagem_edicao_e_exclusao(api: TestClient) -> None:
    meta = _enviar(api, "Artigo Ótimo.pdf", pasta="Biologia")
    assert meta["status"] == "pronto" and meta["titulo"] == "Artigo Ótimo"
    assert _enviar(api, "copia.pdf")["duplicado"] is True
    assert [m["id"] for m in api.get("/api/arquivos?q=otimo").json()] == [meta["id"]]
    assert api.get("/api/arquivos/pastas").json() == ["Biologia"]
    assert api.get(f"/api/arquivos/{meta['id']}/pdf").content == PDF

    edited = api.patch(f"/api/arquivos/{meta['id']}", json={"titulo": "Novo", "tags": ["a"]})
    assert edited.json()["titulo"] == "Novo"

    assert api.delete(f"/api/arquivos/{meta['id']}").status_code == 204
    assert api.get(f"/api/arquivos/{meta['id']}").status_code == 404
    actions = [m["acao"] for m in api.get("/api/arquivos/mudancas").json()["mudancas"]]
    assert actions == ["criado", "editado", "excluido"]
    assert len(api.get("/api/arquivos/mudancas?desde=2").json()["mudancas"]) == 1


def test_duplicar(api: TestClient) -> None:
    meta = _enviar(api, "Artigo.pdf", pasta="Biologia")
    r = api.post(f"/api/arquivos/{meta['id']}/duplicar")
    assert r.status_code == 201
    copy = r.json()
    assert copy["id"] != meta["id"] and copy["titulo"] == "Artigo (cópia)"
    assert copy["pasta"] == "Biologia"
    assert api.get(f"/api/arquivos/{copy['id']}/pdf").content == PDF
    assert len(api.get("/api/arquivos").json()) == 2
    assert api.post("/api/arquivos/000000000000/duplicar").status_code == 404


def test_formato_recusado(api: TestClient) -> None:
    # planilhas e extratos (csv, xlsx, ofx…) entram desde o Finanças; executável não
    r = api.post("/api/arquivos", files={"arquivo": ("programa.exe", b"x")})
    assert r.status_code == 415


def test_xml_fica_pronto_sem_pdf(api: TestClient) -> None:
    meta = _enviar(api, "nfe.xml", b"<nota><valor>10</valor></nota>")
    assert meta["tipo"] == "xml" and meta["status"] == "pronto"
    assert api.get(f"/api/arquivos/{meta['id']}/original").content.startswith(b"<nota>")

    new = b"<nota><valor>20</valor></nota>"
    r = api.put(f"/api/arquivos/{meta['id']}/original", files={"arquivo": ("nfe.xml", new)})
    assert r.status_code == 200 and r.json()["status"] == "pronto"
    assert api.get(f"/api/arquivos/{meta['id']}/original").content == new


@pytest.mark.skipif(shutil.which("soffice") is None, reason="LibreOffice não instalado")
def test_converte_documento(api: TestClient, tmp_path: Path) -> None:
    meta = _enviar(api, "notas.rtf", rb"{\rtf1\ansi Ola mundo\par}")
    final = api.get(f"/api/arquivos/{meta['id']}").json()
    assert final["status"] == "pronto", final["erro"]
    assert api.get(f"/api/arquivos/{meta['id']}/pdf").content.startswith(b"%PDF")


def test_exporta_documento(api: TestClient) -> None:
    meta = _enviar(api, "notas.rtf", rb"{\rtf1\ansi Ola mundo\par}")
    r = api.get(f"/api/arquivos/{meta['id']}/exportar", params={"formato": "txt"})
    assert r.status_code == 200, r.text
    assert "Ola mundo" in r.content.decode("utf-8-sig")
    assert "notas.txt" in r.headers["content-disposition"]
    r = api.get(f"/api/arquivos/{meta['id']}/exportar", params={"formato": "xlsx"})
    assert r.status_code == 422


@pytest.mark.parametrize(
    ("tipo", "ext"), [("documento", "docx"), ("planilha", "xlsx"), ("apresentacao", "pptx")]
)
def test_cria_em_branco(api: TestClient, tipo: str, ext: str) -> None:
    r = api.post("/api/arquivos/novo", json={"tipo": tipo, "titulo": "Capítulo 1", "pasta": "TCC"})
    assert r.status_code == 201, r.text
    meta = r.json()
    assert meta["nome_original"] == f"Capítulo 1.{ext}"
    assert meta["pasta"] == "TCC"
    assert api.get(f"/api/arquivos/{meta['id']}/original").content.startswith(b"PK")


def test_anotacoes_com_conflito_e_destaques(api: TestClient) -> None:
    meta = _enviar(api, "Fotossintese.pdf")
    url = f"/api/arquivos/{meta['id']}/anotacoes"
    highlight = {"id": "d1", "pagina": 2, "texto": "A clorofila absorve luz", "cor": 4294961979}
    salvo = api.put(url, json={"versao_base": 0, "destaques": [highlight], "tracos": [{"id": "t"}]})
    assert salvo.json()["versao"] == 1

    conflict = api.put(url, json={"versao_base": 0})
    assert conflict.status_code == 409
    assert conflict.json()["atuais"]["destaques"][0]["id"] == "d1"

    found = api.get("/api/arquivos/destaques?q=clorofila").json()
    assert found[0]["arquivo_titulo"] == "Fotossintese"
    assert found[0]["referencia"] == "> A clorofila absorve luz\n— [[Fotossintese]], p. 3"
    assert api.get(f"/api/arquivos/{meta['id']}").json()["destaques"] == 1
