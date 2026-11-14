"""Etapa 7 do acervo: peças 2,5D (CSS 3D) e a ampliação contínua do acervo pelas lacunas."""
import shutil

import pytest

from esteira.studio import direction as D
from esteira.studio import factory as F
from esteira.studio import piece as P
from esteira.studio import rhythm as R

PIECES_25D = ("monitor_perspectiva", "cartoes_profundidade", "planos_camera")


@pytest.mark.parametrize("id_", PIECES_25D)
def test_25d_pieces_use_css_3d_and_pass_static_gate(id_):
    f = P.load(id_)
    assert f.peso == "2_5d" and P.check_code(id_, f) == ([], [])
    css = (P.folder(id_) / "peca.css").read_text()
    js = (P.folder(id_) / "peca.js").read_text()
    assert "perspective" in css and ("rotationY" in js or " z:" in js)


def test_direction_uses_25d_in_camera_overlay_treatment():
    cards = ([P.load(i).model_copy(update={"estado": "aprovada"}) for i in PIECES_25D]
              # só as 2D do acervo: outras 2,5D aprovadas depois mudariam o pódio sem a direção errar
              + [f for f in P.list_all("aprovada") if f.id not in PIECES_25D and f.peso != "2_5d"])
    m = {"ini": 10.0, "fim": 18.0, "texto": "Olha o que aparece quando você abre o aplicativo do banco"}
    cs = D.candidates(m, D.ReadingMoment(intencao="conceito"), "camera_2_5d", cards, None, None, {}, ["16:9"],
                      R.load("longo"), [])
    assert {f.id for _, f in cs[:3]} == set(PIECES_25D)
    assert cs[0][1].id == "monitor_perspectiva"   # o exemplo da ficha é o mais parecido com a fala


def test_maximum_fill_leaves_no_loose_highlight():
    assert P._fill("Simulação do *empréstimo*", 30).count("*") % 2 == 0


@pytest.fixture
def environment(tmp_path, monkeypatch):
    pieces = tmp_path / "pecas"
    pieces.mkdir()
    shutil.copytree(P.folder("numero_impacto"), pieces / "numero_impacto", ignore=shutil.ignore_patterns("prova"))
    data = tmp_path / "fabrica"
    monkeypatch.setattr(P, "FOLDER", pieces)
    for name, value in {"FOLDER": data, "REQUESTS": data / "pedidos.json", "RECORD": data / "registro.jsonl",
                        "EXPANSION": data / "ampliacao.json", "ENGINES": data / "motores.json"}.items():
        monkeypatch.setattr(F, name, value)
    queues = []
    monkeypatch.setattr(F, "enqueue", lambda pid: queues.append(pid) or {"id": 1})
    monkeypatch.setattr(F, "spent_today", lambda: 0.0)
    return queues


def test_expansion_creates_one_request_per_day_and_respects_brakes(environment, monkeypatch):
    queues = environment
    assert F.expand() == (None, "desligada")
    F.save_expansion(ativo=True, pecas_por_dia=2, teto_dia_usd=1.5, motor="auto")
    p, reason = F.expand()
    assert reason == "pedido criado" and p.tipo == "lacunas" and p.quantidade == 2 and p.motor == "auto"
    assert queues == [p.id]
    p2, reason2 = F.expand()
    assert p2.id == p.id and reason2 == "pedido do dia" and len(F.requests()) == 1
    monkeypatch.setattr(F.claude, "quota", lambda: 0.95)
    assert F.expand() == (None, "cota do Claude em 95%")
    monkeypatch.setattr(F.claude, "quota", lambda: 0.1)
    monkeypatch.setattr(F, "queue_review", lambda: [{}] * 8)
    assert F.expand()[1].startswith("8+ peças esperando")
    with pytest.raises(ValueError):
        F.save_expansion(pecas_por_dia=0)


def test_gaps_include_25d(monkeypatch):
    monkeypatch.setattr(F, "_in_library", lambda: [])  # acervo vazio: o acervo real já cobre as 2,5D
    assert any(x["peso"] == "2_5d" for x in F.gaps())
