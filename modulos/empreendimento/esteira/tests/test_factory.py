"""Etapa 2 do acervo: fábrica de peças com o Claude simulado (nenhuma chamada real ao `claude -p`)."""
import json
import shutil

import pytest
from esteira.dataset import registry as R
from esteira.studio import factory as F
from esteira.studio import piece as P

REF = P.folder("numero_impacto")


@pytest.fixture
def environment(tmp_path, monkeypatch):
    """Acervo e dados da fábrica em pastas temporárias, só com a peça de referência e o guia."""
    pieces = tmp_path / "pecas"
    pieces.mkdir()
    shutil.copytree(REF, pieces / "numero_impacto", ignore=shutil.ignore_patterns("prova"))
    shutil.copy(P.FOLDER / "GUIA.md", pieces / "GUIA.md")
    data = tmp_path / "fabrica"
    monkeypatch.setattr(P, "FOLDER", pieces)
    for name, value in {"FOLDER": data, "REQUESTS": data / "pedidos.json", "RECORD": data / "registro.jsonl",
                        "REFS": data / "referencias", "REJECTED": data / "reprovadas",
                        "GUIDE": pieces / "GUIA.md"}.items():
        monkeypatch.setattr(F, name, value)
    monkeypatch.setattr(F, "enqueue", lambda pid: {"id": 1})
    monkeypatch.setattr(F, "spent_today", lambda: 0.0)
    monkeypatch.setattr(F, "check_visual", lambda id_: [])
    monkeypatch.setattr(P, "prove", lambda id_, card: ([], []))  # prova no Chromium tem teste próprio
    return pieces


def _answer(id_="linha_tempo", **mudar):
    """Peça válida (derivada da referência) como o Claude devolveria."""
    js = (REF / "peca.js").read_text().replace("numero_impacto", "qualquer").replace("ni-", "lt-")
    css = (REF / "peca.css").read_text().replace("numero_impacto", "qualquer").replace("ni-", "lt-")
    card = json.loads((REF / "ficha.json").read_text())
    card.update(id="qualquer", comunica="uma linha do tempo com marcos e datas", intencoes=["dado_temporal"])
    g = {"id": id_, "peca_js": js, "peca_css": css, "ficha": card, "resumo": "linha do tempo"}
    g.update(mudar)
    return F.PieceGenerated.model_validate(g)


def _claude(monkeypatch, answers):
    requests_seen = []

    def falso(p, text, image=None):
        requests_seen.append(text)
        return (answers.pop(0) if answers else None), 0.25
    monkeypatch.setattr(F, "_query", falso)
    return requests_seen


def test_free_request_generates_up_to_quantity_and_awaits_review(environment, monkeypatch):
    seen = _claude(monkeypatch, [_answer("linha_tempo"), _answer("linha_tempo")])
    p = F.new_request("livre", "linhas do tempo com fotos de época", quantidade=2)
    r = F.run(p.id, visual=False)
    assert r.pecas == ["linha_tempo", "linha_tempo_2"] and r.situacao == "aguardando sua revisão"
    assert P.load("linha_tempo").estado == "revisao" and r.gasto_usd == 0.5
    assert 'ESTUDIO.peca("linha_tempo_2"' in (environment / "linha_tempo_2" / "peca.js").read_text()
    assert ".p-linha_tempo_2" in (environment / "linha_tempo_2" / "peca.css").read_text()
    assert "PIECE WRITING GUIDE" in seen[0] and "linhas do tempo com fotos" in seen[0]
    assert "linha_tempo:" in seen[1]  # o acervo atual entra no dossiê para não duplicar


def test_rejected_at_gate_returns_to_claude_once(environment, monkeypatch):
    bad = _answer(peca_css=".p-qualquer .lt-n { color: #ff0000; }")
    seen = _claude(monkeypatch, [bad, _answer()])
    p = F.new_request("livre", "x", quantidade=1)
    r = F.run(p.id, visual=False)
    assert r.pecas == ["linha_tempo"] and "REJECTED by the automatic gate" in seen[1] and "cor fixa" in seen[1]


def test_rejected_twice_is_discarded_with_reason(environment, monkeypatch):
    bad = _answer(peca_css=".p-qualquer .lt-n { color: #ff0000; }")
    _claude(monkeypatch, [bad, bad])
    p = F.new_request("livre", "x", quantidade=1)
    r = F.generate(F.request(p.id), visual=False)
    assert not r["ok"] and "cor fixa" in r["motivo"] and not (environment / "linha_tempo").exists()
    assert any((F.REJECTED).glob("linha_tempo-*/motivo.txt"))
    regs = list(R.records("peca_html"))  # as duas rodadas no dataset; a 2ª é filha da 1ª e fica descartada
    assert len(regs) == 2 and regs[1]["pai"] == regs[0]["id"] and regs[1]["humano"]["veredito"] == "descartada"


def test_review_approve_adjust_variation_reject(environment, monkeypatch):
    _claude(monkeypatch, [_answer(), _answer(), _answer(comunica="x")])
    p = F.new_request("livre", "x", quantidade=1)
    F.run(p.id, visual=False)
    # ajuste: nova versão da mesma peça, comentário vira lição
    F.review("linha_tempo", "ajuste", "deixe a entrada mais lenta")
    assert F.request(p.id).tarefas[0].tipo == "ajuste"
    F.run(p.id, visual=False)
    assert P.load("linha_tempo").versao == 2 and P.load("linha_tempo").estado == "revisao"
    assert "deixe a entrada mais lenta" in F.GUIDE.read_text()
    # variação: irmã com id novo, entra no pedido
    F.review("linha_tempo", "variacao")
    F.run(p.id, visual=False)
    assert "linha_tempo_2" in F.request(p.id).pecas
    # aprovar a original fecha o pedido (quantidade 1); reprovar a irmã guarda o motivo no guia
    F.review("linha_tempo", "aprovar")
    assert P.load("linha_tempo").estado == "aprovada" and F.request(p.id).estado == "concluido"
    F.review("linha_tempo_2", "reprovar", "movimento rápido demais para o tom didático")
    assert not (environment / "linha_tempo_2").exists() and "rápido demais" in F.GUIDE.read_text()
    with pytest.raises(ValueError):
        F.review("linha_tempo", "reprovar", "")
    vered = {(r["extra"]["peca"], (r["humano"] or {}).get("veredito")) for r in R.records("peca_html")}
    assert ("linha_tempo", "aprovada") in vered and ("linha_tempo_2", "reprovada") in vered
    assert {r["grupo"] for r in R.records("peca_html")} == {"peca:linha_tempo"}  # irmã no grupo da mãe


def test_adjustment_that_fails_returns_previous_version(environment, monkeypatch):
    bad = _answer(peca_css=".p-qualquer .lt-n { color: #ff0000; }")
    _claude(monkeypatch, [_answer(), bad, bad])
    p = F.new_request("livre", "x", quantidade=1)
    F.run(p.id, visual=False)
    before = (environment / "linha_tempo" / "peca.css").read_text()
    F.review("linha_tempo", "ajuste", "mais contraste")
    F.run(p.id, visual=False)
    f = P.load("linha_tempo")
    assert f.versao == 1 and f.estado == "revisao" and "ajuste reprovado" in f.notas
    assert (environment / "linha_tempo" / "peca.css").read_text() == before


def test_subscription_quota_stops_factory(environment, monkeypatch):
    _claude(monkeypatch, [_answer()])
    monkeypatch.setattr(F.claude, "quota", lambda: 0.92)
    p = F.new_request("livre", "x", quantidade=1)
    assert "cota do Claude em 92%" in F.run(p.id, visual=False).situacao and not F.request(p.id).pecas


def test_gaps_and_gap_request(environment, monkeypatch):
    assert F.gaps()[0]["tem"] == 0
    assert not any(x["intencao"] == "numero" and x["peso"] == "2d" and x["tem"] == 0 for x in F.gaps())
    seen = _claude(monkeypatch, [_answer()])
    p = F.new_request("lacunas", quantidade=1)
    F.run(p.id, visual=False)
    assert "Library gap" in seen[0]


def test_quote_attaches_old_template(environment, monkeypatch):
    seen = _claude(monkeypatch, [None])
    p = F.request_quote()
    r = F.run(p.id, visual=False)
    assert "CITAÇÃO DE ESTUDO" in seen[0] and "ATTACHMENT esteira/graphics/modelos/citacao.html" in seen[0]
    assert "não respondeu" in r.situacao


def test_page_validates_highlights_inside():
    e = P.Fit(nome="pagina", tipo="pagina", max_itens=4)
    f = P.load("numero_impacto").model_copy(update={"encaixes": [e], "batidas": []})
    a = P.sample_page()
    ok = {"src": "x.png", "w": a["w"], "h": a["h"], "grifos": a["grifos"]}
    assert P.validate_data(f, {"pagina": ok}) == []
    assert P.validate_data(f, {"pagina": {**ok, "grifos": [[0, 0, a["w"] + 10, 5]]}})
    assert P.validate_data(f, {"pagina": "x.png"})


def test_brake_pauses_request_after_consecutive_discards(environment, monkeypatch):
    bad = _answer(peca_css=".p-qualquer .lt-n { color: #ff0000; }")
    _claude(monkeypatch, [bad] * 6)
    monkeypatch.setattr(F, "_discard", lambda id_, reason: shutil.rmtree(P.folder(id_), ignore_errors=True))
    p = F.new_request("livre", "x", quantidade=5)
    r = F.run(p.id, visual=False)
    assert r.estado == "pausado" and r.situacao.startswith("freio: 3 descartes seguidos") and r.descartadas == 3
    F.pause(p.id, False)  # a retomada zera a contagem: volta a tentar
    _claude(monkeypatch, [_answer()])
    assert F.run(p.id, visual=False).pecas == ["linha_tempo"]


def test_resume_returns_to_queue_when_quota_frees(environment, monkeypatch):
    a = F.new_request("livre", "a", quantidade=1)
    b = F.new_request("livre", "b", quantidade=1)
    F._change(a.id, situacao="cota do Claude em 90%: volta quando a janela virar")
    F.pause(b.id)
    monkeypatch.setattr(F.claude, "quota", lambda: 0.95)
    assert F.resume() == []
    monkeypatch.setattr(F.claude, "quota", lambda: 0.10)
    assert F.resume() == [a.id]  # o pausado fica parado


def test_panel_shows_stage_who_did_it_and_categories(environment, monkeypatch, tmp_path):
    from esteira.core import trace
    from esteira.ai import claude
    from esteira.web import queue
    monkeypatch.setattr(F, "GUIDE_N1_EC", environment / "GUIA_N1_EC.md")
    (environment / "GUIA_N1_EC.md").write_text("# guia\n\n## Lições\n- não empilhe itens (peça x)\n")
    monkeypatch.setattr(trace, "DIR", tmp_path / "live")
    monkeypatch.setattr(claude, "_records", lambda: [])
    p = F.request_hybrid("ideias", 8, "finanças")
    F._change(p.id, conceitos=[{"ficha": {"id": "ideia_a", "descricao": "uma ideia"}, "conceito": "c"}],
             etapa=F._stage("n1", "ideia_a", 2))
    monkeypatch.setattr(queue, "list_all", lambda: [{"ep": f"fabrica:{p.id}", "estado": "rodando", "comando": "studio-factory"}])
    F._register("descartada", pedido=p.id, peca="ideia_a", motor="effectcraft", ia="local", custo=0.0,
                 motivo="escura 16:9: sai da área segura com o texto máximo: ['T']")
    F._register("revisao", peca="ideia_b", aprovada=False, problemas=["itens empilhados"], custo=0.05)
    d = F.panel()
    assert d["agora"][0]["etapa"]["nome"] == "n1" and d["agora"][0]["etapa"]["rodada"] == 2
    assert d["ideias_na_fila"][0]["id"] == "ideia_a" and d["licoes"]["total"] == 1
    assert d["hoje"]["motion"]["motivos"] == [{"motivo": "texto fora da área segura", "n": 1}]
    assert [e["quem"] for e in d["eventos"][:2]] == ["claude", "local"]


def test_lessons_have_cap_and_go_to_file(monkeypatch, tmp_path):
    guide, file = tmp_path / "g.md", tmp_path / "arq.md"
    monkeypatch.setattr(F, "GUIDE_N1_EC", guide)
    monkeypatch.setattr(F, "LESSONS_FILE", file)
    monkeypatch.setattr(F, "LESSONS_MAX_CAR", 300)
    guide.write_text("# Guia\n\n## Lições (erros já vistos; não repita)\n- regra de base\n")
    for i in range(20):  # palavras distintas: parecidas seriam barradas como repetidas
        F.lesson_n1([f"regra{i}a regra{i}b regra{i}c numero {i} " + "x" * 20], f"p{i}")
    t = guide.read_text()
    assert len(t.split("## Lições", 1)[1].partition("\n")[2]) <= 300 and "regra de base" in t and "numero 19" in t
    assert "numero 0 " in file.read_text() and "numero 0 " not in t


def test_one_lesson_per_review_without_repeating(monkeypatch, tmp_path):
    guide = tmp_path / "g.md"
    monkeypatch.setattr(F, "GUIDE_N1_EC", guide)
    monkeypatch.setattr(F, "LESSONS_FILE", tmp_path / "arq.md")
    guide.write_text("# Guia\n\n## Lições\n- Ponha o traço decorativo numa célula de peso mínimo (peça a)\n")
    assert F.lesson_n1(["Ponha sempre o traço decorativo numa célula de peso mínimo", "Regra bem diferente sobre "
                       "títulos longos", "Outra regra distinta qualquer"], "b") == ["Regra bem diferente sobre títulos longos"]


def test_pruned_lesson_does_not_return_and_piece_has_cap(monkeypatch, tmp_path):
    guide, file = tmp_path / "g.md", tmp_path / "arq.md"
    monkeypatch.setattr(F, "GUIDE_N1_EC", guide)
    monkeypatch.setattr(F, "LESSONS_FILE", file)
    guide.write_text("# Guia\n\n## Lições\n")
    file.write_text("- Fundo de ondas: monte várias caixas linha com barras finas (peça ondas)\n")
    assert F.lesson_n1(["Fundo de ondas: monte várias caixas linha com barras finas e pesos"], "ondas2") == []
    for i in range(F.LESSONS_PER_PIECE):
        assert F.lesson_n1([f"regra{i}a regra{i}b regra{i}c distinta"], "p")
    assert F.lesson_n1(["regra nova totalmente diferente das outras"], "p") == []


def test_screen_gate_names_box_without_region():
    from esteira.studio import ec as EC
    from esteira.n1 import effectcraft as N1
    doc = N1.Piece.model_validate({"elementos": [
        {"tipo": "caixa", "nome": "Cena", "filhos": [{"tipo": "texto", "nome": "T", "conteudo": "x"}]},
        {"tipo": "caixa", "nome": "Base", "regiao": "base", "filhos": [{"tipo": "texto", "nome": "B", "conteudo": "y"}]}]})
    error = next(e for e in EC.check_structure(doc, P.load("numero_impacto"))
                if "junto de outras" in e)
    assert "['Cena']" in error and "sem `regiao`" in error


def test_gate_catches_stroke_block_contrast_and_unweighted_column():
    from esteira.studio import ec as EC
    from esteira.n1 import effectcraft as N1
    doc = N1.Piece.model_validate({"elementos": [
        {"tipo": "caixa", "nome": "C", "regiao": "centro", "disposicao": "linha", "pesos": [0.3, 1], "filhos": [
            {"tipo": "caixa", "nome": "B", "disposicao": "camadas", "filhos": [
                {"tipo": "retangulo", "nome": "F", "cor": "destaque"},
                {"tipo": "texto", "nome": "N", "conteudo": "{{numero}}", "nivel": "numero", "cor": "texto"}]},
            {"tipo": "caixa", "nome": "T", "disposicao": "coluna", "filhos": [
                {"tipo": "texto", "nome": "K", "conteudo": "x", "nivel": "rotulo"},
                {"tipo": "texto", "nome": "Ti", "conteudo": "{{rotulo}}", "nivel": "titulo"},
                {"tipo": "retangulo", "nome": "Tr", "cor": "destaque"}]}]},
        {"tipo": "caixa", "nome": "S", "regiao": "tela", "filhos": [{"tipo": "texto", "nome": "Z", "conteudo": "z"}]}]})
    errors = " | ".join(EC.check_structure(doc, P.load("numero_impacto")))
    assert "'F' sem `w` e `h`" in errors and "texto 'N' em cor `texto`" in errors
    assert "'Tr' sem `h`" in errors and "coluna 'T'" in errors and "caixa 'S' só de texto" in errors


def test_next_round_fixes_previous_version_with_cause():
    t = F._dossier_local("ideia", {"id": "x"}, idea={"conceito": "c"}, errors=["causa no N1: Traco: falta h"],
                        draft={"molde": 1}, previous={"elementos": [{"nome": "Traco", "h": None, "se": None}]},
                        already_seen=["erro velho"])
    assert "YOUR PREVIOUS VERSION" in t and '{"nome": "Traco"}' in t and '"molde"' not in t
    assert "Traco: falta h" in t and "erro velho" in t


def test_chapter_uses_own_mold():
    from esteira.studio import molds as M
    assert M.draft(P.load("capitulo_faixa").model_dump(mode="json"))[0] == "capitulo"


def test_molds_fit_library_cards_and_pass_structural_gate():
    """Toda ficha viável vira rascunho N1 válido, que compila e passa no portão estrutural (é a última rodada)."""
    from esteira.studio import ec as EC
    from esteira.studio import molds as M
    from esteira.n1 import effectcraft as N1
    used = set()
    for f in P.list_all():
        fi = f.model_dump(mode="json")
        if M.unfeasible(fi):
            continue
        mid, n1 = M.draft(fi)
        used.add(mid)
        doc = N1.Piece.model_validate(n1)
        assert EC.check_structure(doc, f) == [], (f.id, mid)
        enc = {e.nome: {"numero": "34%", "pares": [{"rotulo": "A", "valor": "8%"}] * 3, "itens": ["A"] * 3}
               .get(e.tipo, "A") for e in f.encaixes}
        N1.build(doc, {"encaixes": enc, "botoes": {b.nome: b.padrao for b in f.botoes}, "batidas": {}, "t0": 0.3,
                          "dur": 6, "w": 1920, "h": 1080, "fps": 30, "tela_cheia": True})
    assert {"numero", "frase", "barras", "lista"} <= used


def test_structural_gate_catches_what_compiles_but_breaks():
    from esteira.studio import ec as EC
    from esteira.n1 import effectcraft as N1
    card = P.load("numero_impacto")
    doc = N1.Piece.model_validate({"elementos": [
        {"tipo": "caixa", "nome": "A", "regiao": "centro", "filhos": []},
        {"tipo": "caixa", "nome": "B", "regiao": "esquerda", "filhos": [
            {"tipo": "texto", "nome": "T", "conteudo": "{{rotulo}}", "se": {"botao": "enfase", "igual": "brilho"}},
            {"tipo": "texto", "nome": "U", "conteudo": "x", "se": {"botao": "anel"}},
            {"tipo": "repetir", "nome": "Bolas", "quantidade": 8, "elementos": [{"tipo": "elipse", "nome": "Bola"}]}]}]})
    errors = " | ".join(EC.check_structure(doc, card))
    assert "caixa 'A' sem filhos" in errors and "'numero' não aparece" in errors
    assert "igual a 'brilho'" in errors and "'anel' é valor do botão 'enfase'" in errors
    assert "fileira" in errors and "esquerda/direita" in errors


def test_screening_skips_what_n1_cannot_draw():
    from esteira.studio import molds as M
    base = P.load("numero_impacto").model_dump(mode="json")
    assert M.unfeasible(base) == ""
    assert "curva" in M.unfeasible({**base, "comunica": "duas curvas de juros que se afastam"})
    assert "imagem" in M.unfeasible({**base, "encaixes": [*base["encaixes"], {"nome": "foto", "tipo": "imagem"}]})
    assert "fundo" in M.unfeasible({**base, "intencoes": ["fundo"]})


def test_local_llm_orphans_removed_on_start(environment, monkeypatch):
    f = P.load("numero_impacto")
    destination = P.folder("orfa_teste")
    shutil.copytree(P.folder("numero_impacto"), destination)
    P.save(f.model_copy(update={"id": "orfa_teste", "origem": "fabrica_local", "estado": "rascunho"}))
    assert F.clean_orphans() == ["orfa_teste"] and not destination.exists()


def test_lock_restores_what_llm_deleted_from_mold():
    mold = {"elementos": [{"tipo": "caixa", "nome": "C", "pesos": [0.36, 1], "vertical": {"disposicao": "coluna"},
                            "filhos": [{"tipo": "retangulo", "nome": "F", "w": 0.39, "h": 0.39}]}]}
    llm = {"elementos": [{"tipo": "caixa", "nome": "C", "pesos": None, "vertical": {"pesos": [1, 2]}, "filhos": [
        {"tipo": "retangulo", "nome": "F", "w": 0.5, "h": None, "cor": "acento"}]}]}
    d = F.lock_mold(llm, mold)
    c, f = d["elementos"][0], d["elementos"][0]["filhos"][0]
    assert c["pesos"] == [0.36, 1] and c["vertical"] == {"disposicao": "coluna", "pesos": [1, 2]}
    assert f == {"tipo": "retangulo", "nome": "F", "w": 0.5, "h": 0.39, "cor": "acento"}  # muda, mas não apaga
    assert llm["elementos"][0]["pesos"] is None


def test_field_llm_did_not_write_comes_from_mold_not_default():
    from esteira.n1 import effectcraft as N1
    mold = {"fundo_tela_cheia": "tela", "elementos": [{"tipo": "caixa", "nome": "C", "filhos": [
        {"tipo": "texto", "nome": "N", "conteudo": "{{numero}}", "peso": 800, "cor": "fundo", "caps": True}]}]}
    answer = N1.Piece.model_validate({"elementos": [{"tipo": "caixa", "nome": "C", "filhos": [
        {"tipo": "texto", "nome": "N", "conteudo": "{{numero}}", "cor": "texto"}]}]})
    d = F.lock_mold(answer.model_dump(mode="json", exclude_unset=True), mold)
    n = d["elementos"][0]["filhos"][0]
    assert n["peso"] == 800 and n["caps"] is True and n["cor"] == "texto"  # o que ela escreveu fica
    assert d["fundo_tela_cheia"] == "tela"


def test_lock_restores_slot_element_llm_deleted():
    mold = {"elementos": [{"tipo": "caixa", "nome": "Base", "filhos": [
        {"tipo": "repetir", "nome": "Itens", "encaixe": "valores", "elementos": [
            {"tipo": "texto", "nome": "Item", "conteudo": "{{item}}"}]}]}],
        "animacoes": [{"anim": "entrar", "alvo": "Item", "t": 0}]}
    d = F.lock_mold({"elementos": [{"tipo": "caixa", "nome": "Base", "filhos": [
        {"tipo": "texto", "nome": "T", "conteudo": "x"}]}], "animacoes": []}, mold)
    assert [x["nome"] for x in d["elementos"][0]["filhos"]] == ["T", "Itens"]
    assert [a["alvo"] for a in d["animacoes"]] == ["Item"]


def test_base_returns_to_mold_when_stuck_or_names_drift():
    mold = {"elementos": [{"nome": "A"}, {"nome": "B"}]}
    v = {"elementos": [{"nome": "A"}, {"nome": "B"}, {"nome": "C"}]}
    assert F._base_next(v, None, mold) == (v, "")
    assert F._base_next(v, v, mold)[0] is None  # devolveu igual
    fugiu = {"elementos": [{"nome": "Cena"}, {"nome": "Outro"}]}
    assert F._base_next(fugiu, None, mold)[0] is None and "nome" in F._base_next(fugiu, None, mold)[1]


def test_screening_skips_card_the_mold_squeezes():
    from esteira.studio import molds as M
    assert "não comporta" in M.unfeasible(P.load("comparacao_atributos").model_dump(mode="json"))


def test_same_error_twice_returns_to_mold():
    mold = {"elementos": [{"nome": "A"}]}
    v1, v2 = {"elementos": [{"nome": "A", "x": 1}]}, {"elementos": [{"nome": "A", "x": 2}]}
    assert F._base_next(v2, v1, mold, ["erro x"], ["erro x", "outro"])[0] is None
    assert F._base_next(v2, v1, mold, ["erro novo"], ["erro x"])[0] == v2


def test_lock_removes_lone_color_block_and_keeps_background_panel():
    d = F.lock_mold({"elementos": [
        {"tipo": "caixa", "nome": "Fundo", "filhos": [{"tipo": "retangulo", "nome": "BG", "cor": "destaque"}]},
        {"tipo": "caixa", "nome": "Painel", "filhos": [{"tipo": "retangulo", "nome": "P", "cor": "fundo2"}]}],
        "animacoes": [{"anim": "entrar", "alvo": "BG", "t": 0}]}, {"elementos": []})
    assert [e["nome"] for e in d["elementos"]] == ["Painel"] and d["animacoes"] == []


def test_lock_restores_items_of_emptied_repeat():
    mold = {"elementos": [{"tipo": "repetir", "nome": "Barras", "encaixe": "valores", "elementos": [
        {"tipo": "retangulo", "nome": "Barra", "proporcional": True},
        {"tipo": "texto", "nome": "Valor", "conteudo": "{{item.valor}}"}]}]}
    d = F.lock_mold({"elementos": [{"tipo": "repetir", "nome": "Barras", "encaixe": "valores", "elementos": []}]},
                       mold)
    assert [x["nome"] for x in d["elementos"][0]["elementos"]] == ["Barra", "Valor"]


def test_lock_restores_item_label_even_with_value_present():
    mold = {"elementos": [{"tipo": "repetir", "nome": "Barras", "encaixe": "valores", "elementos": [
        {"tipo": "texto", "nome": "Valor", "conteudo": "{{item.valor}}"},
        {"tipo": "texto", "nome": "Rotulo", "conteudo": "{{item.rotulo}}"}]}]}
    d = F.lock_mold({"elementos": [{"tipo": "repetir", "nome": "Barras", "encaixe": "valores", "elementos": [
        {"tipo": "texto", "nome": "V", "conteudo": "{{item.valor}}"}]}]}, mold)
    assert [x["nome"] for x in d["elementos"][0]["elementos"]] == ["V", "Rotulo"]


def test_lock_removes_animation_of_missing_element():
    d = F.lock_mold({"elementos": [{"tipo": "texto", "nome": "T", "conteudo": "x"}],
                        "animacoes": [{"anim": "entrar", "alvo": "Barra", "t": 0}, {"anim": "entrar", "alvo": "T", "t": 0}]},
                       {"elementos": []})
    assert [a["alvo"] for a in d["animacoes"]] == ["T"]


def test_kit_port_with_real_slots_and_own_mold():
    """Peça do kit (titulo + valores) sai pelo mapa: molde certo e rascunho que passa no portão; sem mapa, triagem."""
    from esteira.studio import ec as EC
    from esteira.studio import molds as M
    from esteira.n1 import effectcraft as N1
    mapping = json.loads(M.KIT.read_text())
    for kid, k in mapping.items():
        fp = M.card_size(json.loads((P.folder(kid) / "ficha.json").read_text()))
        assert not M.unfeasible(fp), kid
        mid, n1 = M.draft(fp)
        assert mid == k["molde"], kid
        assert EC.check_structure(N1.Piece.model_validate(n1), P.Card.model_validate({**fp, "id": f"{kid}_ec"})) == [], kid
    assert "kit sem molde" in M.unfeasible(json.loads((P.folder("lettering") / "ficha.json").read_text()))
