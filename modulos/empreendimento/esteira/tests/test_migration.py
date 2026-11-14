"""Etapa 3 do acervo: as cenas do kit viraram peças (código, CSS e ficha), o kit ficou só com o núcleo e a mesma peça
funciona na pele de qualquer canal."""
import re

import pytest

from esteira.bench import SCENES
from esteira.studio import compiler
from esteira.studio import piece as P

MIGRADAS = [c for c in SCENES if c != "midia"]


def test_every_kit_scene_became_approved_piece():
    for c in MIGRADAS:
        f = P.load(c)
        assert f.origem == "kit" and f.estado == "aprovada" and len(f.exemplos_sim) >= 5, c
        assert any(e.nome == "titulo" for e in f.encaixes), c


def test_kit_kept_only_core():
    js = (compiler.KIT / "estudio.js").read_text()
    css = (compiler.KIT / "estudio.css").read_text()
    assert not [c for c in MIGRADAS if re.search(rf"^\s+{c}\(c\) \{{", js, re.M)]
    assert re.search(r"const CENA = \{\s*midia\(\) \{\},\s*\};", js)
    for klass in (".linhab", ".anelp", ".grade10", ".eqt", ".rk ", ".letreiro", ".carimbo"):
        assert klass not in css, klass
    for core in (".tkfundo", ".kicker", ".centro", ".tag", "#cap .pal", ".peca"):
        assert core in css, core


@pytest.mark.parametrize("id_", [f.id for f in P.list_all()])
def test_static_gate_of_all_pieces(id_):
    from esteira.studio import ec
    f = P.load(id_)
    errors, warnings = (ec.check_code if f.motor == "effectcraft" else P.check_code)(id_, f)
    assert errors == [] and warnings == [], (errors, warnings)


def test_old_map_becomes_piece_slots():
    scene = {"cena": "barras_comparacao", "titulo": "Juros", "valores": [{"rotulo": "A", "valor": "1%"}], "frase": "x"}
    assert P.legacy(scene, P.load("barras_comparacao")) == {"titulo": "Juros", "valores": scene["valores"]}
    assert P.legacy({"cena": "cta", "titulo": "Comenta", "valores": []}, P.load("cta")) == {"titulo": "Comenta"}
    assert P.legacy({"encaixes": {"x": 1}}, P.load("cta")) == {"x": 1}


def test_pairs_check_limits():
    f = P.load("barras_comparacao")
    assert P.validate_data(f, {"titulo": "Juros", "valores": [{"rotulo": "A", "valor": "1%"}, {"rotulo": "B", "valor": "2%"}]}) == []
    errors = P.validate_data(f, {"titulo": "Juros", "valores": [{"rotulo": "A" * 60, "valor": "1%"}]})
    assert any("pares" in e for e in errors) and any("rotulo" in e for e in errors)


def test_piece_falling_into_another_takes_it_along():
    assert P._drops(P.load("anel_percentual")) == ["contador"]
    assert P._drops(P.load("grafico_linha")) == ["linha_do_tempo"]


@pytest.mark.skipif(not __import__("esteira.studio.engine", fromlist=["x"])._chromium(), reason="sem Chromium")
def test_skin_swap_finlumia_cosmoatomico(tmp_path, monkeypatch):
    from esteira.studio import style as E
    monkeypatch.setattr(E, "FOLDER", tmp_path / "estilos")
    monkeypatch.setattr(P, "previews_dir", lambda id_: tmp_path / "previas" / id_)
    r = P.proof_channels(["finlumia-dark", "cosmoatomico-dark"], formats=("9:16",),
                       ids=["contador", "anel_percentual", "lista_itens"])
    assert r["problemas"] == [], r["problemas"]
    assert r["folhas"] == ["finlumia-dark_9x16.jpg", "cosmoatomico-dark_9x16.jpg"]
