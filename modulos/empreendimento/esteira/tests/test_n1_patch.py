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
    assert box["filhos"][1]["h"] == N1P.LINE_H[0] and box["filhos"][1]["w"] == N1P.LINE_W[0]
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
        {"op": "style", "nome": "titulo", "caps": True}]))
    assert refused == []
    assert doc["elementos"][0]["filhos"][1]["se"] == {"botao": "enfase", "igual": "traco"}
    assert "se" not in doc["elementos"][0]["filhos"][0]  # content of the base is never hidden by a button


def test_added_shapes_are_small_accents_and_few():
    ops = []
    for k in range(4):
        ops.append({"op": "add", "caixa": "palco", "elemento": {"tipo": "elipse", "nome": f"p{k}", "d": 0.5}})
    doc, refused = N1P.apply(BASE, _patch(ops))
    kids = doc["elementos"][0]["filhos"]
    assert len(kids) == 1 + N1P.MAX_ADDS and len(refused) == 1 and "_added" not in doc
    assert kids[1]["d"] == N1P.DOT_D[1]


def test_added_accent_gets_a_small_cell_and_weights_can_be_set():
    doc, refused = N1P.apply(BASE, _patch([
        {"op": "add", "caixa": "palco", "elemento": {"tipo": "retangulo", "nome": "linha"}},
        {"op": "weights", "caixa": "palco", "pesos": [3, 1, 1]},
        {"op": "weights", "caixa": "palco", "pesos": [2, 0.5]}]))
    assert doc["elementos"][0]["pesos"] == [2, 0.5] and len(refused) == 1 and "2 children" in refused[0]
    doc, _ = N1P.apply(BASE, _patch([{"op": "add", "caixa": "palco", "elemento": {"tipo": "retangulo", "nome": "l"}}]))
    assert doc["elementos"][0]["pesos"] == [1.0, N1P.ACCENT_WEIGHT]


def test_entrance_settles_early_and_count_follows_it():
    base = {"elementos": BASE["elementos"], "animacoes": [
        {"anim": "entrar", "alvo": "titulo", "t": 0.1}, {"anim": "contar", "alvo": "titulo", "t": 0.1}]}
    doc, refused = N1P.apply(base, _patch([{"op": "motion", "alvo": "titulo", "t": 3.1, "dur": "0.4v"}]))
    assert refused == []
    assert doc["animacoes"][0] == {"anim": "entrar", "alvo": "titulo", "t": N1P.T_MAX, "dur": "0.4v"}
    assert doc["animacoes"][1]["t"] == N1P.T_MAX


def test_hero_number_keeps_its_level():
    base = {"elementos": [{"tipo": "caixa", "nome": "palco", "filhos": [
        {"tipo": "texto", "nome": "valor", "conteudo": "{{valor}}", "nivel": "numero"},
        {"tipo": "texto", "nome": "rotulo", "conteudo": "{{rotulo}}", "nivel": "corpo"}]}]}
    doc, refused = N1P.apply(base, _patch([
        {"op": "style", "nome": "valor", "nivel": "titulo"},
        {"op": "style", "nome": "rotulo", "nivel": "numero"},
        {"op": "style", "nome": "rotulo", "nivel": "rotulo", "caps": True}]))
    kids = doc["elementos"][0]["filhos"]
    assert len(refused) == 2 and kids[0]["nivel"] == "numero" and kids[1]["nivel"] == "rotulo"


def test_text_size_only_on_texts():
    doc, refused = N1P.apply(BASE, _patch([
        {"op": "style", "nome": "titulo", "tam": 0.3},
        {"op": "style", "nome": "palco", "tam": 0.3}]))
    assert doc["elementos"][0]["filhos"][0]["tam"] == 0.3 and len(refused) == 1


def test_weights_on_repeat_set_item_weights():
    base = {"elementos": [{"tipo": "caixa", "nome": "lista", "filhos": [
        {"tipo": "repetir", "nome": "itens", "encaixe": "itens", "elementos": [
            {"tipo": "retangulo", "nome": "marca"}, {"tipo": "texto", "nome": "item", "conteudo": "{{item}}"}]}]}]}
    doc, refused = N1P.apply(base, _patch([{"op": "weights", "caixa": "itens", "pesos": [0.2, 3]}]))
    assert refused == [] and doc["elementos"][0]["filhos"][0]["pesos_item"] == [0.2, 3]
