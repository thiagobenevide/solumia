from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from saude.sessions import Sessoes, meta, sugestao
from saude.workouts import Invalido, Treinos


class Relogio:
    def __init__(self) -> None:
        self.t = datetime(2026, 11, 10, 18, 0, tzinfo=UTC)

    def __call__(self) -> datetime:
        return self.t

    def andar(self, s: int) -> None:
        self.t += timedelta(seconds=s)


@pytest.fixture
def base(tmp_path: Path) -> tuple[Treinos, Sessoes, Relogio]:
    t = Treinos(tmp_path, baixar_imagens=False)
    r = Relogio()
    t.marcar({"data": "2026-11-10", "exercicio_id": "flexao", "series": 2, "repeticoes": "8-12"})
    t.marcar({"data": "2026-11-10", "exercicio_id": "supino-barra", "series": 1, "carga_kg": 40})
    return t, Sessoes(t, r), r


def test_meta() -> None:
    assert meta("8-12") == {"tempo_s": None, "min": 8, "max": 12}
    assert meta("10 cada lado") == {"tempo_s": None, "min": 10, "max": 10}
    assert meta("2 min")["tempo_s"] == 120 and meta("20 s")["tempo_s"] == 20


def test_sugestao_progressao() -> None:
    plano = {"series": 2, "repeticoes": "8-10", "carga_kg": 40}
    bateu = [{"series": [{"repeticoes": 10, "carga_kg": 40}] * 2}]
    assert sugestao(plano, bateu)["carga_kg"] == 42.5
    falhou = [{"series": [{"repeticoes": 6, "carga_kg": 40}] * 2}]
    assert sugestao(plano, falhou)["carga_kg"] == 40
    assert sugestao(plano, falhou * 2)["carga_kg"] == 36
    assert sugestao(plano, []) is None


def test_fluxo_com_descanso_pausa_e_conclusao(base: tuple[Treinos, Sessoes, Relogio]) -> None:
    t, ss, r = base
    s = ss.iniciar("2026-11-10")
    assert ss.iniciar("2026-11-10")["id"] == s["id"]  # só uma em andamento
    c = ss.comando(s["id"], "concluir_serie", {"repeticoes": 12})["controle"]
    assert c["fase"] == "descanso" and c["indice"] == 0
    r.andar(20)
    c = ss.comando(s["id"], "pausar", {})["controle"]
    assert c["descanso_restante_s"] == 40 and c["descanso_ate"] is None
    r.andar(300)  # pausado não corre
    c = ss.comando(s["id"], "continuar", {})["controle"]
    assert c["descanso_ate"] == "2026-11-10T18:06:00Z" and c["pausa_total_s"] == 300
    r.andar(41)
    assert ss.sessao(s["id"])["controle"]["fase"] == "exercicio"  # descanso venceu
    c = ss.comando(s["id"], "concluir_serie", {"repeticoes": 11})["controle"]
    assert c["indice"] == 1 and c["fase"] == "descanso"
    ss.comando(s["id"], "pular_descanso", {})
    c = ss.comando(s["id"], "concluir_serie", {})["controle"]
    assert c["fase"] == "fim"
    fim = ss.concluir(s["id"], {"esforco": 8})
    assert fim["resumo"]["series_feitas"] == 3 and fim["resumo"]["volume_kg"] == 400
    assert all(i["feito"] for i in t.agenda("2026-11-10", "2026-11-10"))
    with pytest.raises(Invalido):
        ss.comando(s["id"], "pausar", {})

    # próxima vez: anterior e sugestão vêm da sessão concluída
    t.marcar({"data": "2026-11-12", "exercicio_id": "supino-barra", "series": 1, "carga_kg": 40})
    nova = ss.iniciar("2026-11-12")
    e = nova["exercicios"][0]
    assert e["anterior"]["data"] == "2026-11-10" and e["sugestao"]["carga_kg"] == 42.5


def test_desfazer_e_pular(base: tuple[Treinos, Sessoes, Relogio]) -> None:
    _, ss, _ = base
    s = ss.iniciar("2026-11-10")
    ss.comando(s["id"], "concluir_serie", {"repeticoes": 9})
    x = ss.comando(s["id"], "desfazer_serie", {})
    assert x["exercicios"][0]["series"] == [] and x["controle"]["fase"] == "exercicio"
    x = ss.comando(s["id"], "pular_exercicio", {})
    assert x["controle"]["indice"] == 1 and x["exercicios"][0]["pulado"]


def test_rotas(tmp_path: Path) -> None:
    s = Settings(
        client_api_keys=CLIENT_API_KEY, saude_dir=str(tmp_path), saude_baixar_imagens=False
    )
    api = TestClient(create_app(settings=s), headers=AUTH_HEADERS)
    assert api.post("/api/saude/sessoes", json={"data": "2026-11-10"}).status_code == 422
    api.post("/api/saude/agenda", json={"data": "2026-11-10", "exercicio_id": "flexao"})
    sid = api.post("/api/saude/sessoes", json={"data": "2026-11-10"}).json()["id"]
    assert api.get("/api/saude/sessoes/ativa").json()["id"] == sid
    url = f"/api/saude/sessoes/{sid}/comando"
    r = api.post(url, json={"acao": "concluir_serie", "repeticoes": 10})
    assert r.json()["controle"]["fase"] == "descanso"
    assert api.post(url, json={"acao": "voar"}).status_code == 422
    api.post(f"/api/saude/sessoes/{sid}/concluir", json={})
    r = api.patch(f"/api/saude/sessoes/{sid}", json={"frequencia": {"media": 120, "maxima": 160}})
    assert r.json()["frequencia"]["maxima"] == 160
    assert api.get("/api/saude/sessoes/ativa").json() is None
    assert len(api.get("/api/saude/sessoes?de=2026-11-01&ate=2026-11-30").json()) == 1


def test_frequencia_ao_vivo(base: tuple[Treinos, Sessoes, Relogio]) -> None:
    _, ss, r = base
    s = ss.iniciar("2026-11-10")
    lote = [{"em": f"2026-11-10T18:00:{n:02d}Z", "bpm": 100 + n} for n in range(0, 30, 2)]
    lote.append({"em": "2026-11-10T17:59:00Z", "bpm": 90})  # antes da sessão: fora
    x = ss.registrar_fc(s["id"], lote)
    assert x["fc_atual"] == {"bpm": 128, "em": "2026-11-10T18:00:28Z"}
    assert x["frequencia"]["origem"] == "relogio" and x["frequencia"]["amostras"] == 6
    assert x["atual"] == "Flexão de braço 1/2" and x["controle"]["fase"] == "exercicio"
    assert ss.registrar_fc(s["id"], [])["estado"] == "andamento"  # lote vazio = sinal de vida
    r.andar(40)
    ss.comando(s["id"], "concluir_serie", {"repeticoes": 10})
    fim = ss.concluir(s["id"], {"frequencia": {"media": 70, "maxima": 80}})
    assert fim["frequencia"]["origem"] == "relogio"  # Health Connect não sobrescreve
    assert fim["exercicios"][0]["series"][0]["fc_max"] == 128
