"""Etapa 1 do acervo (docs/PLANO-ACERVO.md): configuração do canal sem cardápio e sem modo, ficha, formato da peça
e portão de entrada."""
import json

import pytest

from esteira.studio import style as E
from esteira.studio import piece as P


def _ficha(**mudar):
    d = json.loads((P.folder("numero_impacto") / "ficha.json").read_text())
    d.update(mudar)
    return d


def test_cardapio_antigo_vira_filtro_e_nivel_padrao_alto():
    r = E.Rules(cenas=["contador", "frase_destaque"])
    assert "contador" in r.cardapio() and "versus" in r.filtro and "versus" not in r.cardapio()
    assert E.Rules().filtro == [] and set(E.Rules().niveis.values()) == {"alta"}
    assert "cenas" not in E.Rules().model_dump()


def test_modo_vem_do_video_e_nao_muda_o_estilo():
    est = E.Style(id="teste-dark", nome="Teste", canal="teste")
    ap = E.with_mode(est, "apresentador")
    assert ap.modo == "apresentador" and est.modo == "dark" and E.with_mode(est, None) is est


def test_ficha_de_referencia_valida_e_coerencia():
    f = P.Card.model_validate(_ficha())
    assert f.id == "numero_impacto" and f.batidas == ["numero"]
    for bad in ({"batidas": ["inexistente"]}, {"duracao_min": 9.0}, {"neutra": False}, {"exemplos_sim": ["a"]},
                 {"botoes": [{"nome": "x", "valores": ["a", "b"], "padrao": "c"}]}):
        with pytest.raises(ValueError):
            P.Card.model_validate(_ficha(**bad))


def test_validar_dados_confere_limites_e_volta_erro_claro():
    f = P.load("numero_impacto")
    assert P.validate_data(f, {"numero": "81%", "rotulo": "endividadas"}, {"enfase": "anel"}) == []
    errors = P.validate_data(f, {"numero": "oitenta", "rotulo": "x" * 40, "extra": "?"}, {"enfase": "brilho"})
    assert any("número" in e for e in errors) and any("rotulo" in e for e in errors)
    assert any("extra" in e for e in errors) and any("enfase" in e for e in errors)
    assert P.validate_data(f, {"numero": "81"}) == ["numero: número com unidade (%, R$, anos…)"]


def test_maximos_enchem_no_limite():
    f = P.load("numero_impacto")
    m = P.maximums(f)
    assert len(m["rotulo"]) <= 24 and len(m["rotulo"]) >= 20 and P.validate_data(f, m) == []


def test_maximos_itens_objeto():  # porte de linha do tempo: itens {ano, texto} quebravam o portão
    f = P.load("numero_impacto").model_copy(update={"encaixes": [P.Fit(
        nome="marcos", tipo="itens", max_car=20, max_itens=3, exemplo=[{"ano": "1990", "texto": "Plano Real"}])]})
    m = P.maximums(f)["marcos"]
    assert len(m) == 3 and set(m[0]) == {"ano", "texto"} and len(m[0]["texto"]) <= 20


def _peca(tmp_path, monkeypatch, js, css="", **ficha):
    data = _ficha(id="teste_peca", **ficha)
    monkeypatch.setattr(P, "FOLDER", tmp_path)
    d = tmp_path / "teste_peca"
    d.mkdir()
    (d / "peca.js").write_text(js)
    if css:
        (d / "peca.css").write_text(css)
    (d / "ficha.json").write_text(json.dumps(data, ensure_ascii=False))
    return P.check_code("teste_peca", P.load("teste_peca"))


BOM = 'ESTUDIO.peca("teste_peca", (k, c, box) => { const { numero, rotulo, contexto } = c.encaixes;\n' \
      '  const b = c.botoes; k.$("div", "tp-n", box, numero + rotulo + contexto + b.alinhamento + b.enfase + b.velocidade); });'


def test_codigo_bom_passa(tmp_path, monkeypatch):
    errors, warnings = _peca(tmp_path, monkeypatch, BOM, ".p-teste_peca .tp-n { color: var(--destaque); font-family: var(--fD); }"
                          "\n@keyframes tp { from { opacity: 0 } to { opacity: 1 } }")
    assert errors == [] and warnings == []


@pytest.mark.parametrize("js,css,trecho", [
    (BOM.replace("teste_peca\"", "outra\""), "", "não registra"),
    (BOM, ".p-teste_peca .tp-n { color: #ff0000; }", "cor fixa"),
    (BOM, ".p-teste_peca .tp-n { color: white; }", "cor fixa pelo nome"),
    (BOM, ".p-teste_peca .tp-n { font-family: Arial; }", "fonte fixa"),
    (BOM, ".tp-n { opacity: 1; }", "seletor fora"),
    (BOM.replace('"tp-n"', '"grupo"'), "", "classes do kit"),
    (BOM.replace("b.velocidade", "c.botoes.tamanho"), "", "botões que a ficha não declara"),
    (BOM + " box.style.background = 'rgb(10, 20, 30)';", "", "cor fixa"),
])
def test_portao_estatico_reprova(tmp_path, monkeypatch, js, css, trecho):
    errors, _ = _peca(tmp_path, monkeypatch, js, css)
    assert any(trecho in e for e in errors), errors


def test_sombra_preta_e_comentario_nao_reprovam(tmp_path, monkeypatch):
    errors, _ = _peca(tmp_path, monkeypatch, BOM + "\n// cor antiga era #123456",
                     ".p-teste_peca .tp-n { box-shadow: 0 0 4px rgba(0,0,0,.5); } /* white */")
    assert errors == []


def test_filtro_do_canal_tira_peca_por_id_intencao_ou_tema():
    f = P.Card.model_validate(_ficha(estado="aprovada"))
    est = E.Style(id="teste-dark", nome="Teste", canal="teste")
    assert P.in_channel([f], est) == [f]
    for criteria in (["numero_impacto"], ["alerta"]):
        est.regras.filtro = criteria
        assert P.in_channel([f], est) == []
    assert P.in_channel([f.model_copy(update={"estado": "revisao"})], E.Style(id="t-d", nome="T", canal="t")) == []


@pytest.mark.skipif(not __import__("esteira.studio.engine", fromlist=["x"])._chromium(),
                    reason="sem Chromium")
def test_portao_completo_na_peca_de_referencia(tmp_path, monkeypatch):
    import shutil
    shutil.copytree(P.folder("numero_impacto"), tmp_path / "numero_impacto",
                    ignore=shutil.ignore_patterns("prova"))
    monkeypatch.setattr(P, "FOLDER", tmp_path)
    before = P.load("numero_impacto").estado
    r = P.gate("numero_impacto")
    assert r["ok"], r["erros"]
    assert sorted(r["quadros"]) == ["clara_16x9.jpg", "clara_9x16.jpg",
                                    "escura_16x9.jpg", "escura_9x16.jpg"]
    assert P.load("numero_impacto").estado == before  # o portão não muda o estado
    # texto que não cabe reprova: rótulo enorme
    d = json.loads((tmp_path / "numero_impacto" / "ficha.json").read_text())
    next(e for e in d["encaixes"] if e["nome"] == "rotulo")["max_car"] = 120
    (tmp_path / "numero_impacto" / "ficha.json").write_text(json.dumps(d, ensure_ascii=False))
    assert any("sai da tela" in e for e in P.gate("numero_impacto")["erros"])
