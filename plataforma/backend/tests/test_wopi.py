import time
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.files import wopi
from backend.files.library import Collection
from backend.main import create_app

DISCOVERY = """<?xml version="1.0" encoding="utf-8"?>
<wopi-discovery><net-zone name="external-http">
<app name="writer">
  <action name="view" ext="docx" urlsrc="http://collabora:9980/browser/abc/cool.html?"/>
  <action name="edit" ext="docx" urlsrc="http://collabora:9980/browser/abc/cool.html?&lt;ui=UI_LLCC&amp;&gt;"/>
</app>
<app name="Capabilities"><action name="getinfo" urlsrc="http://collabora:9980/hosting/capabilities"/></app>
</net-zone></wopi-discovery>"""

DOCX = b"PK\x03\x04 docx de mentira"


@pytest.fixture
def api(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> TestClient:
    # No LibreOffice in tests: the reconversion scheduled by PutFile does nothing.
    monkeypatch.setattr(Collection, "convert", lambda self, id_: {})
    monkeypatch.setitem(
        wopi._discovery, "http://collabora:9980", (time.time(), wopi._read_discovery(DISCOVERY))
    )
    s = Settings(
        client_api_keys=CLIENT_API_KEY,
        arquivos_dir=str(tmp_path),
        notas_dir=str(tmp_path),
        collabora_url="https://escritorio.exemplo.com",
        collabora_interno_url="http://collabora:9980",
        wopi_base_url="http://gateway:48080",
        wopi_secret="segredo-de-teste",
    )
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def _session(api: TestClient) -> tuple[str, dict]:
    r = api.post("/api/arquivos", files={"arquivo": ("Relatório.docx", DOCX)})
    assert r.status_code == 201, r.text
    id_ = r.json()["id"]
    s = api.post(f"/api/arquivos/{id_}/collabora")
    assert s.status_code == 200, s.text
    return id_, s.json()


def test_session_builds_action_url(api: TestClient) -> None:
    id_, s = _session(api)
    url = urlsplit(s["url"])
    assert (url.scheme, url.netloc, url.path) == (
        "https",
        "escritorio.exemplo.com",
        "/browser/abc/cool.html",
    )
    assert "<" not in s["url"]
    assert parse_qs(url.query)["WOPISrc"] == [f"http://gateway:48080/wopi/files/{id_}"]
    assert s["access_token_ttl"] > time.time() * 1000
    # without the app key no session opens
    without_key = TestClient(api.app).post(f"/api/arquivos/{id_}/collabora")
    assert without_key.status_code == 401


def test_check_get_put(api: TestClient) -> None:
    id_, s = _session(api)
    wopi_cli = TestClient(api.app)  # Collabora does not have the app key
    q = {"access_token": s["access_token"]}
    info = wopi_cli.get(f"/wopi/files/{id_}", params=q).json()
    assert info["BaseFileName"] == "Relatório.docx" and info["Size"] == len(DOCX)
    assert info["UserCanWrite"] and info["SupportsLocks"] and info["SupportsUpdate"]
    assert wopi_cli.get(f"/wopi/files/{id_}/contents", params=q).content == DOCX

    new = b"PK\x03\x04 editado no collabora"
    r = wopi_cli.post(
        f"/wopi/files/{id_}/contents", params=q, content=new, headers={"X-WOPI-Override": "PUT"}
    )
    assert r.status_code == 200, r.text
    assert r.headers["X-WOPI-ItemVersion"] != info["Version"]
    assert api.get(f"/api/arquivos/{id_}/original").content == new
    assert api.get(f"/api/arquivos/{id_}").json()["status"] == "convertendo"


def test_invalid_or_expired_token(api: TestClient) -> None:
    id_, s = _session(api)
    cli = TestClient(api.app)
    assert cli.get(f"/wopi/files/{id_}").status_code == 401
    assert (
        cli.get(f"/wopi/files/{id_}", params={"access_token": s["access_token"] + "x"}).status_code
        == 401
    )
    vencido, _ = wopi.generate_token(b"segredo-de-teste", id_, -10)
    assert cli.get(f"/wopi/files/{id_}", params={"access_token": vencido}).status_code == 401
    outro, _ = wopi.generate_token(b"segredo-de-teste", "aaaaaaaaaaaa", 60)
    assert cli.get(f"/wopi/files/{id_}/contents", params={"access_token": outro}).status_code == 401
    # the app key does not work as a WOPI token
    assert cli.get(f"/wopi/files/{id_}", params={"access_token": CLIENT_API_KEY}).status_code == 401


def test_locks(api: TestClient) -> None:
    id_, s = _session(api)
    cli = TestClient(api.app)
    q = {"access_token": s["access_token"]}
    url = f"/wopi/files/{id_}"

    def op(override: str, trava: str = "", antiga: str = ""):
        h = {"X-WOPI-Override": override, "X-WOPI-Lock": trava}
        if antiga:
            h["X-WOPI-OldLock"] = antiga
        return cli.post(url, params=q, headers=h)

    assert op("GET_LOCK").headers["X-WOPI-Lock"] == ""
    assert op("LOCK", "A").status_code == 200
    assert op("LOCK", "A").status_code == 200  # the same lock renews
    r = op("LOCK", "B")
    assert r.status_code == 409 and r.headers["X-WOPI-Lock"] == "A"
    assert op("GET_LOCK").headers["X-WOPI-Lock"] == "A"
    assert op("REFRESH_LOCK", "A").status_code == 200
    assert op("REFRESH_LOCK", "B").status_code == 409

    # PutFile with another lock is refused
    put = cli.post(
        f"{url}/contents",
        params=q,
        content=b"x",
        headers={"X-WOPI-Override": "PUT", "X-WOPI-Lock": "B"},
    )
    assert put.status_code == 409 and put.headers["X-WOPI-Lock"] == "A"

    assert op("LOCK", "C", antiga="A").status_code == 200  # UnlockAndRelock
    assert op("UNLOCK", "A").status_code == 409
    assert op("UNLOCK", "C").status_code == 200
    assert op("GET_LOCK").headers["X-WOPI-Lock"] == ""


def test_open_page(api: TestClient) -> None:
    id_, s = _session(api)
    r = TestClient(api.app).get(f"/wopi/abrir/{id_}", params={"t": s["access_token"]})
    assert r.status_code == 200
    assert (
        "access_token" in r.text
        and "https://escritorio.exemplo.com/browser/abc/cool.html" in r.text
    )
    assert "form-action https://escritorio.exemplo.com" in r.headers["Content-Security-Policy"]
    assert TestClient(api.app).get(f"/wopi/abrir/{id_}", params={"t": "x"}).status_code == 401


def test_without_collabora_configured(tmp_path: Path) -> None:
    s = Settings(
        client_api_keys=CLIENT_API_KEY, arquivos_dir=str(tmp_path), notas_dir=str(tmp_path)
    )
    api = TestClient(create_app(settings=s), headers=AUTH_HEADERS)
    id_ = api.post("/api/arquivos", files={"arquivo": ("a.xml", b"<a/>")}).json()["id"]
    assert api.post(f"/api/arquivos/{id_}/collabora").status_code == 503
