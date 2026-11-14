"""Estúdio: regras do diretor (validação, tempo, orçamento), trechos, densidade de SFX e estilo como dado."""
from esteira.bench import Scene, Value
from esteira.studio import compiler, director
from esteira.studio import style as E


def _p(texto, t0=0.0, passo=0.4):
    return [{"p": w, "ini": round(t0 + k * passo, 3), "fim": round(t0 + k * passo + 0.3, 3)}
            for k, w in enumerate(texto.split())]


def _estilo(**regras):
    return E.Style(id="teste-dark", nome="Teste", canal="teste", regras=E.Rules(**regras))


def test_problemas_recusa_ancora_fora_e_numero_inventado():
    sentence = "Em setembro, eram 81,7% das famílias."
    ok = Scene(cena="contador", ancora="eram 81,7%", titulo="Endividadas", valores=[Value(rotulo="famílias", valor="81,7%")])
    assert director.problems(sentence, ok, list(E.SCENES)) == []
    bad = ok.model_copy(update={"ancora": "noventa", "valores": [Value(rotulo="x", valor="90%")]})
    errors = director.problems(sentence, bad, list(E.SCENES))
    assert any("âncora" in e for e in errors) and any("90" in e for e in errors)
    assert director.problems(sentence, ok, ["midia"])  # fora do cardápio do estilo


def test_regra_sem_llm():
    assert director.rule("A taxa chegou a 132% ao ano.", list(E.SCENES)).cena == "contador"
    assert director.rule("E você, faz isso?", list(E.SCENES)).cena == "pergunta_destaque"
    assert director.rule("Pensa nisso com calma.", list(E.SCENES)).cena == "midia"


def test_trechos_divide_frase_longa_nas_virgulas():
    text = "Hoje eu vou te mostrar os três números que importam, qual deles preocupa de verdade, e o que dizem as pesquisas."
    pal = _p(text)
    f = [{"texto": text, "ini": 0.0, "fim": pal[-1]["fim"]}]
    t = director.spans(f, pal, 3.0)
    assert len(t) == 3
    assert t[1]["texto"].startswith("qual deles") and t[1]["ini"] == pal[10]["ini"]
    assert director.spans(f, pal, 60.0) == [{"texto": text, "ini": 0.0, "fim": pal[-1]["fim"]}]


def test_cronometrar_ancora_teto_e_orcamento():
    sentences = [{"texto": "A taxa chegou a 132% ao ano no cheque especial.", "ini": 0.0, "fim": 4.0},
              {"texto": "E por que isso acontece com tanta gente?", "ini": 4.2, "fim": 7.0},
              {"texto": "Porque o crédito fácil parece a única saída quando aperta.", "ini": 7.2, "fim": 20.0}]
    pal = _p(sentences[0]["texto"]) + _p(sentences[1]["texto"], 4.2) + _p(sentences[2]["texto"], 7.2)
    esc = [(0, Scene(cena="contador", ancora="132% ao ano", titulo="Cheque especial", valores=[Value(rotulo="", valor="132%")]), "local"),
           (1, Scene(cena="pergunta_destaque", ancora="E por que", titulo="Por quê?", valores=[]), "local"),
           (2, Scene(cena="conceito_icone", ancora="crédito fácil", titulo="Crédito fácil", valores=[]), "local")]
    scenes = director.time(sentences, esc, pal, _estilo(), 21.0)
    c0 = scenes[0]
    assert abs(c0["t"] - (pal[4]["ini"] - 0.08)) < 1e-6  # entra na palavra "132%"
    assert c0["ate"] <= scenes[1]["t"] and c0["takeover"]
    assert scenes[2]["ate"] - scenes[2]["t"] <= 5.0  # teto da cena sobre a mídia
    # orçamento apertado: a pergunta (takeover) vira frase de impacto sobre a mídia
    apertado = director.time(sentences, esc, pal, _estilo(takeover_max=0.15), 21.0)
    assert [c["cena"] for c in apertado][:2] == ["contador", "frase_destaque"]


def test_sfx_respeita_teto_por_segundo():
    scenes = [{"cena": "contador", "t": t} for t in (1.0, 1.5, 2.0, 3.0, 4.5)]
    sounds = compiler._sfx(scenes, _estilo(sfx={"contador": "whoosh"}, sfx_por_s=0.8))
    assert [round(s["t"] + 0.05, 2) for s in sounds] == [1.0, 3.0, 4.5]


def test_estilo_semente_e_trava(tmp_path, monkeypatch):
    monkeypatch.setattr(E, "FOLDER", tmp_path)
    fin = E.load("finlumia-dark")
    assert fin.pele.destaque == "#f5c518" and "contador" in fin.regras.cardapio()
    new = E.new_channel("canal-novo", "Canal Novo", "tecnologia", "#22c55e")
    assert new.id == "canal-novo-dark" and new.pele.destaque == "#22c55e"
    assert "canal-novo" in E.channels()
    new.travado = True
    E.save(new, forcar=True)
    try:
        E.save(E.load("canal-novo-dark"))
        raise AssertionError("estilo travado não pode mudar sem forcar")
    except PermissionError:
        pass


def test_corte_pelo_som_vicio_respiro_reversao_e_palavra_protegida():
    import numpy as np
    from esteira.studio import cut as C
    sp = np.zeros(600, bool)          # 6 s; fala em 0–1 s, "éé" em 1,5–2,0 s, fala em 2,3–3,0 s e 4,0–5,0 s
    for a, b in ((0, 100), (150, 200), (230, 300), (400, 500)):
        sp[a:b] = True
    ws = [[0.0, 1.0, "Oi"], [1.5, 2.0, "éé"], [2.3, 3.0, "tudo."], [3.3, 3.6, "bem"], [4.0, 5.0, "agora"]]
    cuts = C.fillers(ws)
    assert [c[2] for c in cuts] == ["éé"]
    segs, emendas, prot = C.segments(sp, ws, cuts, dur=6.0)
    assert [p[2] for p in prot] == ["bem"]  # o detector comeu "bem": volta inteira
    assert any(e["tipo"] == "vicio" and e["texto"] == "éé" for e in emendas)
    mapping, total = C._map(segs)
    assert C._new(mapping, 1.7) == C._new(mapping, 2.3) - C.LEAD  # dentro do vício → começo do trecho seguinte
    assert total < 6.0
    filler = next(e for e in emendas if e["tipo"] == "vicio")
    segs2, emendas2, _ = C.segments(sp, ws, cuts, [[filler["de"], filler["ate"]]], dur=6.0)
    assert len(segs2) == len(segs) - 1 and any(e["revertida"] for e in emendas2)


def test_conferencia_acha_palavra_sumida_e_repeticao():
    from esteira.studio import cut as C
    origin = [[0, 0.3, "o"], [0.3, 0.6, "juro"], [0.6, 0.9, "composto"], [0.9, 1.2, "cresce"]]
    cut = [[0, 0.3, "o"], [0.3, 0.6, "juro"], [0.6, 0.9, "cresce"], [0.9, 1.2, "cresce"]]
    conf = C.cross_check(origin, cut, [], [], [])
    assert conf["sumidas"][0]["texto"] == "composto" and conf["repeticoes"]


def test_camera_layouts_split_tela_broll_e_punch():
    from esteira.studio import camera as K
    scenes = [{"cena": "contador", "t": 2.0, "ate": 5.0, "takeover": True},
             {"cena": "titulo_capitulo", "t": 6.0, "ate": 7.0, "takeover": True},
             {"cena": "frase_destaque", "t": 8.0, "ate": 10.0, "takeover": False}]
    media = [{"ini": 0.0, "fim": 2.0}, {"ini": 10.0, "fim": 14.0}, {"ini": 14.0, "fim": 18.0}]
    segs = K.layouts(scenes, media, _estilo().regras, 20.0)
    assert [c["layout"] for c in scenes] == ["split", "tela", "full"]
    assert any(s["layout"] == "full" and s["punch"] and s["t"] == 8.0 for s in segs)
    assert any(s["layout"] == "broll" and s["t"] == 10.0 for s in segs)
    assert segs[0]["t"] == 0.0 and segs[-1]["ate"] == 20.0
    assert all(a["ate"] == b["t"] for a, b in zip(segs, segs[1:], strict=False))


def test_camera_layouts_rodizio_lateral_flutuante_e_solido_no_teto():
    from esteira.studio import camera as K
    scenes = [{"cena": "contador", "t": t, "ate": t + 3.0, "takeover": True} for t in (2.0, 6.0, 10.0, 14.0)]
    scenes.append({"cena": "ranking", "t": 18.0, "ate": 23.0, "takeover": True, "layout_pedido": "solido"})
    segs = K.layouts(scenes, [], _estilo().regras, 100.0, ["lateral", "flutuante", "solido"])
    # o sólido tira o apresentador: o 1º cabe no teto (7% de 100 s), o pedido depois dele já não cabe e flutua
    assert [c["layout"] for c in scenes] == ["lateral", "flutuante", "solido", "lateral", "flutuante"]
    assert {s["layout"] for s in segs} >= {"full", "lateral", "flutuante", "solido"}


def test_dark_rodizio_das_pecas_cheias():
    from esteira.studio import compiler as Cp
    scenes = [{"cena": "contador", "t": 0, "ate": 2, "takeover": True},
             {"cena": "ranking", "t": 3, "ate": 5, "takeover": True},
             {"cena": "titulo_capitulo", "t": 6, "ate": 8, "takeover": True},
             {"cena": "versus", "t": 9, "ate": 11, "takeover": True, "layout_pedido": "solido"},
             {"cena": "frase_destaque", "t": 12, "ate": 14, "takeover": False}]
    Cp._layouts_dark(scenes, ["tela", "flutuante"])
    assert [c.get("layout") for c in scenes] == [None, "flutuante", None, "solido", None]


def test_camera_segue_os_dois_cortes_sem_deriva():
    from esteira.studio import camera as K
    spans = [(0.0, 10.0, 2.0), (2.0, 20.0, 3.0)]   # narração editada → câmera (tomadas da esteira + offset)
    segs = [[0.5, 1.5, 0.0], [2.5, 4.0, 0.0]]        # corte pelo som
    assert K._in_camera(spans, 2.5) == 20.5
    assert K._edited(segs, 1.2) == 2.7 and abs(K._edited(segs, 3.0) - 4.5) < 1e-9


def test_niveis_preenchem_regras_e_personalizado_fica():
    r = E.aplicar_levels(E.Rules(), {"sfx": "baixa", "motion": "alta", "efeitos": "baixa"})
    assert r.sfx_por_s == 0.35 and r.takeover_max == 0.7 and r.efeitos["flash"] == 0 and r.apresentador["broll"] == 0.35
    mao = E.Rules(sfx_por_s=1.7, niveis={"sfx": "personalizado", "motion": "media", "efeitos": "media"})
    assert E.aplicar_levels(mao).sfx_por_s == 1.7


def test_sfx_baixa_so_entradas_principais_e_alta_toda_cena():
    from esteira.studio import compiler
    scenes = [{"cena": "lista_itens", "t": 1.0}, {"cena": "contador", "t": 4.0}]
    base = _estilo(sfx={"contador": "whoosh"})
    baixa = base.model_copy(update={"regras": E.aplicar_levels(base.regras, {"sfx": "baixa"})})
    alta = base.model_copy(update={"regras": E.aplicar_levels(base.regras, {"sfx": "alta"})})
    assert len(compiler._sfx(scenes, baixa)) == 1 and len(compiler._sfx(scenes, alta)) == 2


def test_fontes_catalogo_resolve_e_avisa(tmp_path, monkeypatch):
    from esteira.studio import fonts as F
    monkeypatch.setattr(F, "UPLOADED", tmp_path / "enviadas")
    assert F.resolve("Bebas Neue") == "Bebas Neue" and F.resolve("Comic Inexistente") == F.DEFAULT
    css = F.css(["Bebas Neue", "Inter", "Comic Inexistente"], tmp_path)
    assert '"Bebas Neue"' in css and '"Inter"' in css and (tmp_path / "fonts" / "BebasNeue.ttf").exists()
    assert F.send("Minha.ttf", b"\x00\x01\x00\x00resto") == "Minha" and F.resolve("Minha") == "Minha"


def test_versoes_guardadas_e_template_novo(tmp_path, monkeypatch):
    monkeypatch.setattr(E, "FOLDER", tmp_path)
    fin = E.load("finlumia-dark")
    v1 = fin.versao
    fin.pele.destaque = "#ff0000"
    fin.rotulo = "vermelho"
    E.save(fin)
    assert E.load("finlumia-dark").versao == v1 + 1
    assert E.load(f"finlumia-dark@{v1}").pele.destaque == "#f5c518"  # a anterior não foi sobrescrita
    assert [e.versao for e in E.versions("finlumia-dark")] == [v1 + 1, v1]
    assert E.label(E.load("finlumia-dark")) == f"v{v1 + 1} - vermelho"
    E.save(E.load("finlumia-dark").model_copy(update={"travado": True}), forcar=True, nova_versao=False)
    assert E.load("finlumia-dark").versao == v1 + 1  # travar não cria versão
    a = E.new("finlumia", "apresentador", ["9:16"])
    b = E.new("finlumia", "apresentador", ["9:16"])
    assert a.id != b.id and b.formatos == ["9:16"] and b.versao == 1


def test_duplicar_estilo(tmp_path, monkeypatch):
    monkeypatch.setattr(E, "FOLDER", tmp_path)
    new = E.duplicate("finlumia-dark", "finlumia-curso", "Finlumia · curso")
    assert new.versao == 1 and not new.travado and E.load("finlumia-curso").pele.destaque == "#f5c518"


def test_apontamento_marca_por_texto_e_diretor_respeita(tmp_path, monkeypatch):
    from types import SimpleNamespace

    from esteira.studio import marking
    from esteira.ai import local
    project = SimpleNamespace(pasta=tmp_path)
    sentences = [{"texto": "A taxa chegou a 132% ao ano.", "ini": 0.0, "fim": 3.0},
              {"texto": "Pensa nisso com calma.", "ini": 3.2, "fim": 5.0},
              {"texto": "E isso acontece com muita gente.", "ini": 5.2, "fim": 8.0}]
    marking.save(project, [{"texto": "a taxa chegou a 132% ao ano", "cena": "versus"},
                                 {"texto": sentences[1]["texto"], "cena": "nenhuma"},
                                 {"texto": sentences[2]["texto"], "cena": "auto"}], confirmar=True)
    assert marking.confirmed(project)
    marks = marking.marks(project, sentences)
    assert marks == {0: "versus", 1: "nenhuma"}
    # a IA local erra a cena marcada e escolhe outra na livre: a marcada fica, a livre segue a IA
    resp = Scene(cena="frase_destaque", ancora="acontece com", titulo="Muita gente", valores=[])
    monkeypatch.setattr(local, "ask", lambda *a, **k: resp)
    monkeypatch.setattr(local, "prompt", lambda nome, **k: local.Prompt(k["frase"]))
    esc = director.choose(sentences, _estilo(cenas=["frase_destaque", "contador"]), marks)
    assert esc[0][1].cena == "versus" and esc[0][2] == "voce"
    assert esc[1][1].cena == "midia" and esc[1][2] == "voce"
    assert esc[2][1].cena == "frase_destaque" and esc[2][2] == "local"
    # orçamento apertado não troca a cena marcada
    scenes = director.time(sentences, esc, _p(sentences[0]["texto"]) + _p(sentences[2]["texto"], 5.2),
                                _estilo(takeover_max=0.01), 9.0)
    assert scenes[0]["cena"] == "versus" and scenes[0]["por"] == "voce"
    try:
        marking.save(project, [{"texto": "x", "cena": "inventada"}])
        raise AssertionError("aceitou cena inválida")
    except ValueError:
        pass


def test_sem_socorro_do_claude_falha_cai_na_regra(monkeypatch):
    from esteira.core import options
    from esteira.ai import local
    sentences = [{"texto": "A taxa chegou a 132% ao ano.", "ini": 0.0, "fim": 3.0}]
    monkeypatch.setattr(local, "ask", lambda *a, **k: None)
    monkeypatch.setattr(local, "prompt", lambda nome, **k: local.Prompt(k["frase"]))
    monkeypatch.setattr(options, "read", lambda: {**options.DEFAULT})
    monkeypatch.setattr(director, "_escalate", lambda *a: (_ for _ in ()).throw(AssertionError("chamou o Claude")))
    esc = director.choose(sentences, _estilo())
    assert esc[0][1].cena == "contador" and esc[0][2] == "regra"
    assert E.Rules().visual.entradas == ["desfoque", "deslizar"]
