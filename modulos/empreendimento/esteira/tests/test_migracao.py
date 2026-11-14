"""Etapa 3 do acervo: as cenas do kit viraram peças (código, CSS e ficha), o kit ficou só com o núcleo e a mesma peça
funciona na pele de qualquer canal."""
import re

import pytest

from esteira.bancada import CENAS
from esteira.estudio import compilar
from esteira.estudio import peca as P

MIGRADAS = [c for c in CENAS if c != "midia"]


def test_toda_cena_do_kit_virou_peca_aprovada():
    for c in MIGRADAS:
        f = P.carregar(c)
        assert f.origem == "kit" and f.estado == "aprovada" and len(f.exemplos_sim) >= 5, c
        assert any(e.nome == "titulo" for e in f.encaixes), c


def test_kit_ficou_so_com_o_nucleo():
    js = (compilar.KIT / "estudio.js").read_text()
    css = (compilar.KIT / "estudio.css").read_text()
    assert not [c for c in MIGRADAS if re.search(rf"^\s+{c}\(c\) \{{", js, re.M)]
    assert re.search(r"const CENA = \{\s*midia\(\) \{\},\s*\};", js)
    for classe in (".linhab", ".anelp", ".grade10", ".eqt", ".rk ", ".letreiro", ".carimbo"):
        assert classe not in css, classe
    for nucleo in (".tkfundo", ".kicker", ".centro", ".tag", "#cap .pal", ".peca"):
        assert nucleo in css, nucleo


@pytest.mark.parametrize("id_", [f.id for f in P.listar()])
def test_portao_estatico_de_todas_as_pecas(id_):
    from esteira.estudio import ec
    f = P.carregar(id_)
    erros, avisos = (ec.checar_codigo if f.motor == "effectcraft" else P.checar_codigo)(id_, f)
    assert erros == [] and avisos == [], (erros, avisos)


def test_mapa_antigo_vira_encaixes_da_peca():
    cena = {"cena": "barras_comparacao", "titulo": "Juros", "valores": [{"rotulo": "A", "valor": "1%"}], "frase": "x"}
    assert P.legado(cena, P.carregar("barras_comparacao")) == {"titulo": "Juros", "valores": cena["valores"]}
    assert P.legado({"cena": "cta", "titulo": "Comenta", "valores": []}, P.carregar("cta")) == {"titulo": "Comenta"}
    assert P.legado({"encaixes": {"x": 1}}, P.carregar("cta")) == {"x": 1}


def test_pares_conferem_limites():
    f = P.carregar("barras_comparacao")
    assert P.validar_dados(f, {"titulo": "Juros", "valores": [{"rotulo": "A", "valor": "1%"}, {"rotulo": "B", "valor": "2%"}]}) == []
    erros = P.validar_dados(f, {"titulo": "Juros", "valores": [{"rotulo": "A" * 60, "valor": "1%"}]})
    assert any("pares" in e for e in erros) and any("rotulo" in e for e in erros)


def test_peca_que_cai_em_outra_leva_a_outra_junto():
    assert P._quedas(P.carregar("anel_percentual")) == ["contador"]
    assert P._quedas(P.carregar("grafico_linha")) == ["linha_do_tempo"]


@pytest.mark.skipif(not __import__("esteira.estudio.motor", fromlist=["x"])._chromium(), reason="sem Chromium")
def test_troca_de_pele_finlumia_cosmoatomico(tmp_path, monkeypatch):
    from esteira.estudio import estilo as E
    monkeypatch.setattr(E, "PASTA", tmp_path / "estilos")
    monkeypatch.setattr(P, "previas_dir", lambda id_: tmp_path / "previas" / id_)
    r = P.prova_canais(["finlumia-dark", "cosmoatomico-dark"], formatos=("9:16",),
                       ids=["contador", "anel_percentual", "lista_itens"])
    assert r["problemas"] == [], r["problemas"]
    assert r["folhas"] == ["finlumia-dark_9x16.jpg", "cosmoatomico-dark_9x16.jpg"]
