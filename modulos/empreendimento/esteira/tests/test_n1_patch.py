from esteira.n1 import patch as N1P

BASE = {"elementos": [{"tipo": "caixa", "nome": "palco", "filhos": [
    {"tipo": "texto", "nome": "titulo", "conteudo": "{{titulo}}", "nivel": "titulo"}]}],
    "animacoes": [{"anim": "entrar", "alvo": "titulo", "t": 0}]}


def _patch(ops):
    return N1P.Patch.model_validate({"ops": ops})


def test_ops_change_only_what_they_name():
    doc, refused = N1P.apply(BASE, _patch([
        {"op": "style", "nome": "titulo", "peso": 800, "caps": True},
        {"op": "motion", "alvo": "titulo", "de": "escala", "t": 0.3},
        {"op": "add", "caixa": "palco", "de": "esq",
         "elemento": {"tipo": "retangulo", "nome": "linha", "x": 0.2}}]))
    assert refused == []
    box = doc["elementos"][0]
    assert box["filhos"][0]["peso"] == 800 and box["filhos"][0]["nivel"] == "titulo"
    assert box["filhos"][1]["nome"] == "linha" and "x" not in box["filhos"][1]
    assert doc["animacoes"][0]["de"] == "escala" and doc["animacoes"][0]["t"] == 0.3
    assert doc["animacoes"][1] == {"anim": "entrar", "alvo": "linha", "de": "esq"}
    assert "peso" not in BASE["elementos"][0]["filhos"][0]


def test_bad_op_is_refused_and_the_good_ones_stay():
    doc, refused = N1P.apply(BASE, _patch([
        {"op": "style", "nome": "fantasma", "caps": True},
        {"op": "style", "nome": "titulo", "raio": 4},
        {"op": "style", "nome": "titulo", "italico": True}]))
    assert len(refused) == 2 and "fantasma" in refused[0]
    title = BASE["elementos"][0]["filhos"][0]
    assert doc["elementos"][0]["filhos"][0] == {**title, "italico": True}


def test_motion_without_fields_is_refused():
    doc, refused = N1P.apply(BASE, _patch([{"op": "motion", "alvo": "titulo"}]))
    assert len(refused) == 1 and doc == BASE


def test_button_variant_on_added_shape():
    doc, refused = N1P.apply(BASE, _patch([
        {"op": "add", "caixa": "palco",
         "elemento": {"tipo": "retangulo", "nome": "traco",
                      "se": {"botao": "enfase", "igual": "traco"}}},
        {"op": "style", "nome": "traco", "se": {"botao": "enfase", "igual": "forte"}}]))
    assert refused == []
    assert doc["elementos"][0]["filhos"][1]["se"] == {"botao": "enfase", "igual": "forte"}
