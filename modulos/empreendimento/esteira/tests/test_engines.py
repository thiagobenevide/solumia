"""Etapa 4 do acervo: motor EffectCraft (mesma ficha, peca.jsx, portão próprio, WebM com alfa na produção) e a
fábrica nos dois motores com a comparação (Claude simulado; EffectCraft real quando a CLI existe)."""
import json
import shutil

import pytest

from esteira.studio import ec
from esteira.studio import factory as F
from esteira.studio import piece as P

REF, REF_EC = P.folder("numero_impacto"), P.folder("numero_impacto_ec")
sem_ec = pytest.mark.skipif(not ec.available(), reason="sem effectcraft-cli")


@pytest.fixture
def environment(tmp_path, monkeypatch):
    pieces = tmp_path / "pecas"
    pieces.mkdir()
    for d in (REF, REF_EC, P.FOLDER / "_ec"):
        shutil.copytree(d, pieces / d.name, ignore=shutil.ignore_patterns("prova"))
    for g in ("GUIA.md", "GUIA_EC.md"):
        shutil.copy(P.FOLDER / g, pieces / g)
    data = tmp_path / "fabrica"
    monkeypatch.setattr(P, "FOLDER", pieces)
    monkeypatch.setattr(ec, "PIECES", pieces)
    for name, value in {"FOLDER": data, "REQUESTS": data / "pedidos.json", "RECORD": data / "registro.jsonl",
                        "REFS": data / "referencias", "REJECTED": data / "reprovadas", "GUIDE": pieces / "GUIA.md",
                        "GUIDE_EC": pieces / "GUIA_EC.md", "ENGINES": data / "motores.json"}.items():
        monkeypatch.setattr(F, name, value)
    monkeypatch.setattr(F, "enqueue", lambda pid: {"id": 1})
    monkeypatch.setattr(F, "spent_today", lambda: 0.0)
    monkeypatch.setattr(F, "check_visual", lambda id_: [])
    monkeypatch.setattr(P, "prove", lambda id_, card: ([], []))
    monkeypatch.setattr(ec, "prove", lambda id_, card: ([], [], 0.5))
    return pieces


def _answer(engine, id_="linha_tempo", **mudar):
    card = json.loads((REF / "ficha.json").read_text())
    card.update(id="x", comunica="uma linha do tempo com marcos e datas", intencoes=["dado_temporal"])
    if engine == "effectcraft":
        g = {"id": id_, "peca_jsx": (REF_EC / "peca.jsx").read_text(), "ficha": card, "resumo": "linha do tempo ec"}
    else:
        js = (REF / "peca.js").read_text().replace("numero_impacto", "x").replace("ni-", "lt-")
        css = (REF / "peca.css").read_text().replace("numero_impacto", "x").replace("ni-", "lt-")
        g = {"id": id_, "peca_js": js, "peca_css": css, "ficha": card, "resumo": "linha do tempo"}
    g.update(mudar)
    return F.PieceGenerated.model_validate(g)


def _claude(monkeypatch):
    """Responde no motor que o dossiê pede; guarda os dossiês."""
    seen = []

    def falso(p, text, image=None):
        seen.append(text)
        return _answer("effectcraft" if "EffectCraft engine" in text[:400] else "html"), 0.2
    monkeypatch.setattr(F, "_query", falso)
    return seen


def test_reference_ec_code_passes_and_rules_reject(environment):
    f = P.load("numero_impacto_ec")
    assert ec.check_code("numero_impacto_ec", f) == ([], [])  # pelo N1
    (environment / "numero_impacto_ec" / "peca.n1.json").unlink()  # sem N1, vale o peca.jsx e as regras de script
    assert ec.check_code("numero_impacto_ec", f) == ([], [])
    base = (environment / "numero_impacto_ec" / "peca.jsx").read_text()
    for span, msg in (('var z = "#ff0000";', "cor fixa"), ("var z = [1, 0, 0];", "cor fixa"),
                        ('var z = {font: "Arial"};', "fonte fixa"), ("var z = Math.random();", "Math.random"),
                        ("var z = E.inexistente;", "não declara")):
        (environment / "numero_impacto_ec" / "peca.jsx").write_text(base + "\n" + span)
        errors, _ = ec.check_code("numero_impacto_ec", f)
        assert any(msg in e for e in errors), (span, errors)


def test_videos_ec_entram_no_html_estatico():
    html = P.videos_ec([{"t": 1.0, "ate": 3.5, "ec_src": "assets/ec_000.webm"}, {"t": 4, "ate": 5}])
    assert html.count("<video") == 1 and 'data-start="1.000"' in html and 'data-duration="2.500"' in html


def test_pair_in_both_engines_with_same_task(environment, monkeypatch):
    seen = _claude(monkeypatch)
    p = F.new_request("livre", "linhas do tempo com fotos de época", quantidade=1, engine="ambos")
    r = F.run(p.id, visual=False)
    assert r.pares == [["linha_tempo", "linha_tempo_2"]] and r.situacao == "aguardando sua revisão"
    assert P.load("linha_tempo").motor == "html" and P.load("linha_tempo_2").motor == "effectcraft"
    assert (environment / "linha_tempo_2" / "peca.jsx").exists() and not (environment / "linha_tempo_2" / "peca.js").exists()
    assert "EFFECTCRAFT N1 GUIDE" in seen[1] and "peca_n1" in seen[1] and "linhas do tempo com fotos" in seen[0] and "linhas do tempo com fotos" in seen[1]
    queue = {x["id"]: x for x in F.queue_review()}
    assert queue["linha_tempo"]["par"] == "linha_tempo_2" and queue["linha_tempo_2"]["motor"] == "effectcraft"


def test_adjustment_stays_in_piece_engine_and_lesson_goes_to_its_guide(environment, monkeypatch):
    seen = _claude(monkeypatch)
    p = F.new_request("livre", "x", quantidade=1, engine="effectcraft")
    F.run(p.id, visual=False)
    F.review("linha_tempo", "ajuste", "camadas com nomes mais claros")
    F.run(p.id, visual=False)
    assert "EffectCraft engine" in seen[-1][:400] and P.load("linha_tempo").versao == 2
    assert "nomes mais claros" in F.GUIDE_EC.read_text() and "nomes mais claros" not in F.GUIDE.read_text()


def test_comparison_and_decision_by_intent(environment, monkeypatch):
    _claude(monkeypatch)
    monkeypatch.setattr(F, "SAMPLE_MIN", 1)
    p = F.new_request("livre", "x", quantidade=2, engine="ambos")
    F.run(p.id, visual=False)
    pieces = F.request(p.id).pecas
    html = [i for i in pieces if P.load(i).motor == "html"]
    ecs = [i for i in pieces if P.load(i).motor == "effectcraft"]
    for i in ecs:
        F.review(i, "aprovar", note=5)
    F.review(html[0], "aprovar", note=2)
    F.review(html[1], "reprovar", "pouco movimento", note=1)
    c = F.comparison()
    assert c["geral"]["effectcraft"]["taxa_aprovacao"] == 1.0 and c["geral"]["html"]["taxa_aprovacao"] == 0.5
    assert c["geral"]["effectcraft"]["nota_media"] == 5 and c["geral"]["html"]["geradas"] == 2
    assert c["sugestao"]["dado_temporal"]["motor"] == "effectcraft"
    F.apply_engines({"dado_temporal": "effectcraft", "invalida": "html"})
    assert F.engines()["por_intencao"] == {"dado_temporal": "effectcraft"}
    auto = F.new_request("lacunas", quantidade=1, engine="auto")
    assert F.engine_of_request(auto) in ("html", "effectcraft")
    with pytest.raises(ValueError):
        F.review(ecs[0], "aprovar", note=9)


@sem_ec
def test_real_ec_gate_on_reference_and_overflow(tmp_path, monkeypatch):
    pieces = tmp_path / "pecas"
    for d in (REF_EC, P.FOLDER / "_ec"):
        shutil.copytree(d, pieces / d.name, ignore=shutil.ignore_patterns("prova"))
    monkeypatch.setattr(P, "FOLDER", pieces)
    monkeypatch.setattr(ec, "PIECES", pieces)
    r = P.gate("numero_impacto_ec")
    assert r["ok"], r["erros"]
    assert r["motor"] == "effectcraft" and len(r["quadros"]) == 4 and r["render_s"] is not None
    d = json.loads((pieces / "numero_impacto_ec" / "ficha.json").read_text())
    # número de uma linha muito maior que a tela: encolher esconderia o erro (caber só até 55%) e o portão reprova
    num = next(e for e in d["encaixes"] if e["nome"] == "numero")
    num.update(max_car=24, exemplo="1.234.567.890.123,45%")
    (pieces / "numero_impacto_ec" / "ficha.json").write_text(json.dumps(d, ensure_ascii=False))
    assert any("área segura" in e for e in P.gate("numero_impacto_ec")["erros"])


@sem_ec
def test_ec_production_generates_webm_with_alpha(tmp_path):
    from esteira.studio import style as E
    f = P.load("numero_impacto_ec")
    scene = {"cena": f.id, "t": 1.0, "ate": 3.0, "encaixes": P.examples(f), "botoes": {}, "batidas": {}}
    destination = tmp_path / "ec_000.webm"
    ec.to_production(f.id, scene, E.Style(id="t-dark", nome="T", canal="t"), "9:16", destination)
    assert destination.exists() and destination.with_suffix(".ecproj").exists()
    import subprocess
    tags = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream_tags=alpha_mode:format=duration", "-of",
                           "json", str(destination)], capture_output=True, text=True).stdout
    assert '"alpha_mode": "1"' in tags and abs(float(json.loads(tags)["format"]["duration"]) - 2.0) < 0.15


def test_port_of_html_pieces_to_n1(environment, monkeypatch):
    n1 = json.loads((REF_EC / "peca.n1.json").read_text())
    card_ec = json.loads((REF_EC / "ficha.json").read_text())
    seen = []

    def falso(p, text, image=None):
        seen.append(text)
        return F.PieceGenerated.model_validate({"id": "qualquer", "peca_n1": n1, "ficha": card_ec, "resumo": "porte"}), 0.3
    monkeypatch.setattr(F, "_query", falso)
    shutil.copytree(environment / "numero_impacto", environment / "barras")  # outra HTML, sem irmã EffectCraft
    f = json.loads((environment / "barras" / "ficha.json").read_text())
    (environment / "barras" / "ficha.json").write_text(json.dumps({**f, "id": "barras"}))
    p = F.request_size()
    assert set(p.alvos) == {"numero_impacto", "barras"} and p.motor == "effectcraft"
    r = F.run(p.id, visual=False)
    # numero_impacto já tem a irmã numero_impacto_ec: fica fora; barras vira barras_ec em N1
    assert r.estado == "concluido" and r.pecas == ["barras_ec"] and len(seen) == 1
    assert (environment / "barras_ec" / "peca.n1.json").exists() and not (environment / "barras_ec" / "peca.jsx").exists()
    assert "NEW PATTERNS" in seen[0] and "numero_impacto" in seen[0] and "N1 GUIDE" in seen[0]


def _barras(environment):
    shutil.copytree(environment / "numero_impacto", environment / "barras")
    f = json.loads((environment / "barras" / "ficha.json").read_text())
    (environment / "barras" / "ficha.json").write_text(json.dumps({**f, "id": "barras"}))


def _in_box(n1):
    """A LLM local só entrega peça por caixas: o N1 de referência dentro de uma caixa que ocupa a tela."""
    return {**n1, "elementos": [{"tipo": "caixa", "nome": "Tudo", "disposicao": "camadas", "filhos": n1["elementos"]}]}


def test_hybrid_port_by_local_llm_without_spending_claude(environment, monkeypatch):
    _barras(environment)
    n1 = _in_box(json.loads((REF_EC / "peca.n1.json").read_text()))
    local_names = []
    monkeypatch.setattr(F, "_query_n1_local", lambda text: local_names.append(text) or F.PieceN1Local(peca_n1=n1))
    monkeypatch.setattr(F, "_query", lambda *a, **k: pytest.fail("o Claude não devia ser chamado"))
    p = F.request_hybrid("porte")
    r = F.run(p.id, visual=False)
    assert r.pecas == ["barras_ec"] and r.locais == 1 and r.socorros == 0 and r.gasto_usd == 0
    assert "STARTING HTML PIECE" in local_names[0] and P.load("barras_ec").motor == "effectcraft"


def test_hybrid_port_without_fallback_and_idea_with_fallback(environment, monkeypatch):
    _barras(environment)
    n1 = json.loads((REF_EC / "peca.n1.json").read_text())
    card_ec = json.loads((REF_EC / "ficha.json").read_text())
    monkeypatch.setattr(F, "_query_n1_local", lambda text: None)  # o local não responde em nenhuma rodada
    monkeypatch.setattr(F, "_query", lambda p, text, image=None: (
        F.PieceGenerated.model_validate({"id": "x", "peca_n1": n1, "ficha": card_ec, "resumo": "socorro"}), 0.3))
    r = F.run(F.request_hybrid("porte").id, visual=False)  # a última rodada é o rascunho do molde: a peça sai
    assert r.socorros == 0 and r.pecas == ["barras_ec"] and r.descartadas == 0 and r.gasto_usd == 0
    from esteira.studio import molds as M
    monkeypatch.setattr(M, "draft", lambda card: ("quebrado", {"elementos": [
        {"tipo": "caixa", "nome": "Vazia", "regiao": "centro", "filhos": []}]}))
    r = F.run(F.request_hybrid("porte").id, visual=False)  # rascunho reprovado na estrutura: a triagem barra antes
    assert r.socorros == 0 and r.descartadas == 0 and r.pecas == [] and r.gasto_usd == 0
    monkeypatch.setattr(F, "FALLBACK_IDEAS", True)  # o socorro existe, desligado por padrão
    monkeypatch.setattr(F, "_query_ideas", lambda p, n: ([{"ficha": {**card_ec, "id": "ideia_x"},
                                                                 "conceito": "c"}], 0.1))
    r = F.run(F.request_hybrid("ideias", quantidade=1).id, visual=False)  # ideia: o Claude socorre
    assert r.socorros == 1 and len(r.pecas) == 1 and r.gasto_usd == 0.4


def test_hybrid_batch_ideas_from_claude_expanded_by_local_llm(environment, monkeypatch):
    n1 = _in_box(json.loads((REF_EC / "peca.n1.json").read_text()))
    card = json.loads((REF_EC / "ficha.json").read_text())
    ideas = [{"ficha": {**card, "id": f"ideia_{k}"}, "conceito": f"conceito {k}"} for k in range(3)]
    calls = []
    monkeypatch.setattr(F, "_query_ideas", lambda p, n: calls.append(n) or (ideas[:n], 0.4))
    monkeypatch.setattr(F, "_query_n1_local", lambda text: F.PieceN1Local(peca_n1=n1))
    p = F.request_hybrid("ideias", quantidade=3)
    r = F.run(p.id, visual=False)
    assert calls == [3] and r.estado == "concluido" and r.locais == 3 and r.gasto_usd == 0.4
    assert sorted(r.pecas) == ["ideia_0", "ideia_1", "ideia_2"]
