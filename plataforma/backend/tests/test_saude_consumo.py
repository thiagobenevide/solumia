from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from saude.api_consumption import assemble_context
from saude.consumption import Consumption, loosens
from saude.workouts import Invalid


class Relogio:
    def __init__(self) -> None:
        self.t = datetime(2026, 11, 10, 12, tzinfo=UTC)

    def __call__(self) -> datetime:
        return self.t


@pytest.fixture
def rel() -> Relogio:
    return Relogio()


@pytest.fixture
def c(tmp_path: Path, rel: Relogio) -> Consumption:
    return Consumption(tmp_path, agora=rel)


def test_afrouxa() -> None:
    limit = {"modo": "limite", "limite_min": 30, "horarios": [{"inicio": "22:00", "fim": "07:00"}]}
    assert loosens(limit, {**limit, "limite_min": 40})
    assert not loosens(limit, {**limit, "limite_min": 10})
    assert loosens(limit, {**limit, "horarios": []})
    almoco = {"inicio": "12:00", "fim": "13:00"}
    assert not loosens(limit, {**limit, "horarios": [*limit["horarios"], almoco]})
    assert loosens(limit, {"modo": "livre", "limite_min": 0, "horarios": limit["horarios"]})
    assert not loosens(limit, {"modo": "bloqueado", "limite_min": 0, "horarios": []})


def test_apertar_na_hora_afrouxar_em_24h(c: Consumption, rel: Relogio) -> None:
    r = c.definir_rule("redes_sociais", {"modo": "limite", "limite_min": 10, "horarios": []})
    assert r["pendencia"] is not None  # tirou o horário noturno: afrouxa
    r = c.definir_rule("compras", {"modo": "bloqueado"})
    assert r["aplicado"]
    assert c.config()["regras"]["compras"]["modo"] == "bloqueado"
    assert c.config()["regras"]["redes_sociais"]["limite_min"] == 30
    rel.t += timedelta(hours=23)
    assert c.config()["regras"]["redes_sociais"]["limite_min"] == 30
    rel.t += timedelta(hours=2)
    cfg = c.config()
    assert cfg["regras"]["redes_sociais"] == {"modo": "limite", "limite_min": 10, "horarios": []}
    assert cfg["pendencias"] == []


def test_cancelar_e_protecao(c: Consumption, rel: Relogio) -> None:
    p = c.definir_protection(False)["pendencia"]
    c.cancel_pendencia(p["id"])
    rel.t += timedelta(days=2)
    assert c.config()["protecao"] is True
    assert c.remove_app("com.instagram.android")["pendencia"]
    assert c.include_domain("redes_sociais", "https://www.bsky.app/x")["aplicado"]
    assert "bsky.app" in c.for_dispositivo()["dominios"]["redes_sociais"]


def test_whatsapp_isento(c: Consumption) -> None:
    with pytest.raises(Invalid):
        c.definir_app("com.whatsapp", "WhatsApp", "redes_sociais")
    with pytest.raises(Invalid):
        c.include_domain("redes_sociais", "web.whatsapp.com")
    assert "com.whatsapp" not in c.for_dispositivo()["apps"]


def test_sincronizar_e_resumo(c: Consumption) -> None:
    hour = [0.0] * 24
    hour[23] = 40
    body = {
        "dispositivo": {"id": "cel", "nome": "Galaxy", "estado": {"vigia": True, "vpn": False}},
        "dias": [
            {
                "data": "2026-11-09",
                "apps": [
                    {
                        "pacote": "com.instagram.android",
                        "nome": "Instagram",
                        "categoria": "redes_sociais",
                        "minutos": 50,
                        "aberturas": 12,
                    },
                    {"pacote": "com.whatsapp", "categoria": "x", "minutos": 99},
                ],
                "outros_min": 20,
                "por_hora": {"redes_sociais": hour},
            }
        ],
        "eventos": [
            {"id": "e1", "quando": "2026-11-09T23:10:00", "tipo": "busca", "categoria": "adulto"}
        ],
    }
    rules = c.sync(body)
    c.sync(body)  # repetir não duplica
    assert rules["protecao"] and "instagram.com" in rules["dominios"]["redes_sociais"]
    r = c.resumo("2026-11-09", "2026-11-09")
    assert r["por_dia"]["2026-11-09"] == {"redes_sociais": 50, "outros": 20}
    assert [a["pacote"] for a in r["apps"]] == ["com.instagram.android"]
    assert r["eventos"] == {"busca:adulto": 1}
    text = assemble_context(c, datetime(2026, 11, 3).date(), datetime(2026, 11, 9).date())
    assert "23h: 40" in text and "DESLIGADO: vpn" in text


def test_rotas(tmp_path: Path) -> None:
    s = Settings(client_api_keys=CLIENT_API_KEY, saude_dir=str(tmp_path))
    api = TestClient(create_app(settings=s), headers=AUTH_HEADERS)
    assert api.get("/api/saude/consumo/config").json()["regras"]["adulto"]["modo"] == "bloqueado"
    r = api.put("/api/saude/consumo/regras/adulto", json={"modo": "livre"})
    assert r.json()["pendencia"]["descricao"] == "Afrouxar Conteúdo adulto"
    assert api.put("/api/saude/consumo/regras/xx", json={"modo": "livre"}).status_code == 422
    r = api.post("/api/saude/consumo/sincronizar", json={"dispositivo": {"id": "tab"}})
    assert r.status_code == 200 and r.json()["dns"] == "1.1.1.3"
    assert api.get("/api/saude/consumo/dispositivos").json()[0]["id"] == "tab"
