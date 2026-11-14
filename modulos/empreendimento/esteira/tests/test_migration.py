"""Etapa 3 do acervo: as cenas do kit viraram peças (código, CSS e ficha), o kit ficou só com o núcleo e a mesma peça
funciona na pele de qualquer canal."""
import re

import pytest

from esteira.bench import SCENES
from esteira.studio import compiler
from esteira.studio import piece as P

MIGRADAS = [c for c in SCENES if c != "midia"]


def test_toda_cena_do_kit_virou_peca_aprovada():
    for c in MIGRADAS:
        f = P.load(c)
        assert f.origem == "kit" and f.estado == "aprovada" and len(f.exemplos_sim) >= 5, c
        assert any(e.nome == "titulo" for e in f.encaixes), c


def test_kit_ficou_so_com_o_nucleo():
    js = (compiler.KIT / "estudio.js").read_text()
    css = (compiler.KIT / "estudio.css").read_text()
    assert not [c for c in MIGRADAS if re.search(rf"^\s+{c}\(c\) \{{", js, re.M)]
    assert re.search(r"const CENA = \{\s*midia\(\) \{\},\s*\};", js)
    for classe in (".linhab", ".anelp", ".grade10", ".eqt", ".rk ", ".letreiro", ".carimbo"):
        assert classe not in css, classe
    for nucleo in (".tkfundo", ".kicker", ".centro", ".tag", "#cap .pal", ".peca"):
        assert nucleo in css, nucleo


@pytest.mark.parametrize("id_", [f.id for f in P.list_all()])
def test_portao_estatico_de_todas_as_pecas(id_):
    from esteira.studio import ec
    f = P.load(id_)
    erros, avisos = (ec.check_code if f.motor == "effectcraft" else P.check_code)(id_, f)
    assert erros == [] and avisos == [], (erros, avisos)


def test_mapa_antigo_vira_encaixes_da_peca():
    cena = {"cena": "barras_comparacao", "titulo": "Juros", "valores": [{"rotulo": "A", "valor": "1%"}], "frase": "x"}
    assert P.legacy(cena, P.load("barras_comparacao")) == {"titulo": "Juros", "valores": cena["valores"]}
    assert P.legacy({"cena": "cta", "titulo": "Comenta", "valores": []}, P.load("cta")) == {"titulo": "Comenta"}
    assert P.legacy({"encaixes": {"x": 1}}, P.load("cta")) == {"x": 1}


def test_pares_conferem_limites():
    f = P.load("barras_comparacao")
    assert P.validate_data(f, {"titulo": "Juros", "valores": [{"rotulo": "A", "valor": "1%"}, {"rotulo": "B", "valor": "2%"}]}) == []
    erros = P.validate_data(f, {"titulo": "Juros", "valores": [{"rotulo": "A" * 60, "valor": "1%"}]})
    assert any("pares" in e for e in erros) and any("rotulo" in e for e in erros)


def test_peca_que_cai_em_outra_leva_a_outra_junto():
    assert P._drops(P.load("anel_percentual")) == ["contador"]
    assert P._drops(P.load("grafico_linha")) == ["linha_do_tempo"]


@pytest.mark.skipif(not __import__("esteira.studio.engine", fromlist=["x"])._chromium(), reason="sem Chromium")
def test_troca_de_pele_finlumia_cosmoatomico(tmp_path, monkeypatch):
    from esteira.studio import style as E
    monkeypatch.setattr(E, "FOLDER", tmp_path / "estilos")
    monkeypatch.setattr(P, "previews_dir", lambda id_: tmp_path / "previas" / id_)
    r = P.proof_channels(["finlumia-dark", "cosmoatomico-dark"], formatos=("9:16",),
                       ids=["contador", "anel_percentual", "lista_itens"])
    assert r["problemas"] == [], r["problemas"]
    assert r["folhas"] == ["finlumia-dark_9x16.jpg", "cosmoatomico-dark_9x16.jpg"]
