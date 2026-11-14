"""Etapa 6 do acervo: direção por bloco (blocos → tratamento → 5 candidatas → escolha → preenchimento), com a IA local
simulada e sem o modelo de embeddings (plano B por palavras)."""
import json
import re

from esteira.studio import direction as D
from esteira.studio import style as E
from esteira.studio import piece as P
from esteira.studio import rhythm as R

LONGO, CURTO = R.load("longo"), R.load("curto")


def _t(texto, ini, fim):
    return {"texto": texto, "ini": ini, "fim": fim}


def test_numeros_falados_por_extenso():
    assert D.spoken("Oito em cada dez famílias") == {"8", "10"}
    assert D.spoken("vinte e cinco por cento") == {"25"}
    assert D.spoken("um dia ele disse") == set() and D.spoken("um mil e duzentos") == {"1200"}
    assert D.spoken("81,7% em 2024") == {"817", "2024"}


def test_blocos_pelo_roteiro_e_sem_roteiro():
    tr = [_t("Primeira frase do bloco um.", 0, 3), _t("Segunda frase do bloco um.", 3, 6), _t("Outro parágrafo aqui.", 7, 9)]
    bl = D.blocks(tr, ["Primeira frase do bloco um. Segunda frase do bloco um.", "Outro parágrafo aqui."], LONGO)
    assert [b["trechos"] for b in bl] == [[0, 1], [2]]
    sem = D.blocks([_t("a b c", 0, 2), _t("d e f", 2.2, 4), _t("g h i", 6, 8)], [], LONGO)  # pausa de 2 s separa
    assert [b["trechos"] for b in sem] == [[0, 1], [2]]


def test_momentos_pela_virada_e_numero_proprio():
    tr = [_t(f"frase {chr(97 + k)}", k * 2.0, k * 2.0 + 1.8) for k in range(6)]
    b = {"i": 0, "trechos": list(range(6))}
    assert len(D.moments(b, tr, CURTO)) >= 2                     # curto: algo novo a cada 2–4 s
    assert len(D.moments(b, tr, LONGO)) == 1                     # longo: 12 s cabem num momento
    tr2 = [_t("são 81% das famílias", 0, 2), _t("e 30% dos jovens", 2, 4)]
    assert len(D.moments({"i": 0, "trechos": [0, 1]}, tr2, LONGO)) == 2   # dois números → dois momentos


def test_tratamento_respeita_o_modo_e_varia():
    lt = [D.ReadingMoment(intencao="numero", tratamento=t) for t in ("camera_peca", "midia_motion", "midia_motion", "midia_motion")]
    assert D.treat(lt, "dark") == ["voz_motion", "midia_motion", "midia_motion", "voz_motion"]
    assert D.treat(lt[:1], "apresentador") == ["camera_peca"]


def test_candidatas_filtram_pontuam_e_penalizam_repeticao():
    fichas = P.list_all("aprovada")
    m = {"ini": 30.0, "fim": 36.0, "texto": "81% das famílias brasileiras estão endividadas"}
    lt = D.ReadingMoment(intencao="numero")
    cs = D.candidates(m, lt, "voz_motion", fichas, None, None, {}, ["16:9"], LONGO, [])
    assert len(cs) == 5 and all(f.tela_cheia for _, f in cs)
    assert cs[0][1].id in ("contador", "anel_percentual", "grade_proporcao")
    usado = cs[0][1].id
    cs2 = D.candidates(m, lt, "voz_motion", fichas, None, None, {usado: 10.0}, ["16:9"], LONGO, [])
    pontos2 = dict((f.id, p) for p, f in cs2)
    assert usado not in pontos2 or pontos2[usado] < cs[0][0]  # usada há pouco: perde pontos (ou sai das 5)
    sobre = D.candidates(m, lt, "midia_motion", fichas, None, None, {}, ["16:9"], LONGO, [])
    assert not any(f.tela_cheia for _, f in sobre)


def test_preenchimento_recusa_numero_inventado_e_peca_de_numero_vazia():
    f = P.load("contador")
    assert D.problems(f, {"titulo": "Endividadas", "valores": [{"rotulo": "famílias", "valor": "90%"}]},
                       {}, "oito em cada dez famílias")[-1].startswith("números que não foram ditos")
    assert any("sem o número" in e for e in D.problems(f, {"titulo": "Endividadas"}, {}, "oito em cada dez"))
    assert any("nenhum número" in e for e in D.problems(f, {"titulo": "Oi"}, {}, "vamos entender isso"))
    assert D.problems(f, {"titulo": "Endividadas", "valores": [{"rotulo": "famílias", "valor": "8 em 10"}]},
                       {}, "oito em cada dez famílias") == []


class _Proj:
    def __init__(self, pasta):
        self.pasta, self.vertical, self.cfg = pasta, False, {}


def _ia_falsa(monkeypatch, vistos):
    def falsa(texto, esquema, **kw):
        vistos.append(esquema.__name__)
        if esquema is D.ReadingBlock:
            n = int(re.search(r"exatamente (\d+) itens", texto).group(1))
            return D.ReadingBlock(momentos=[D.ReadingMoment(intencao="destaque", tratamento="voz_motion")] * n)
        if esquema is D.Escolha:
            return D.Escolha(escolha=re.search(r"^- (\w+):", texto, re.M).group(1), motivo="a primeira")
        if esquema is D.Verification:
            return D.Verification(fiel=True)
        momento = re.search(r'Momento \(o que está sendo dito\): "(.*?)"', texto).group(1)
        num = re.search(r"\d[\d,.]*%?", momento)
        enc = {"titulo": " ".join(momento.split()[:4])[:20]}
        if num:
            enc["valores"] = [{"rotulo": "dado", "valor": num.group(0)}]
        return D.Filling(encaixes=enc)
    monkeypatch.setattr(D.local, "ask", falsa)


def test_dirigir_monta_o_mapa_do_kit(tmp_path, monkeypatch):
    from esteira.ai import embeddings
    monkeypatch.setattr(embeddings, "vectors", lambda textos, prefixo="": None)
    vistos = []
    _ia_falsa(monkeypatch, vistos)
    frases = [{"texto": "Hoje 81% das famílias estão endividadas.", "ini": 0.2, "fim": 3.0, "destaques": []},
              {"texto": "Mas isso não é falta de caráter.", "ini": 3.5, "fim": 6.0, "destaques": []},
              {"texto": "O problema é o juro do cartão.", "ini": 40.0, "fim": 43.0, "destaques": []},
              {"texto": "E ele passa de 400% ao ano.", "ini": 43.5, "fim": 46.0, "destaques": []}]
    (tmp_path / "frases.json").write_text(json.dumps(frases, ensure_ascii=False))
    palavras = [{"p": w, "ini": f["ini"] + k * 0.3, "fim": f["ini"] + k * 0.3 + 0.25}
                for f in frases for k, w in enumerate(f["texto"].split())]
    (tmp_path / "transcricao.json").write_text(json.dumps({"palavras": palavras}, ensure_ascii=False))
    est = E.Style(id="t-dark", nome="T", canal="t")
    mapa = D.direct(_Proj(tmp_path), est, LONGO, ["16:9"])
    assert mapa["direcao"] == "blocos" and mapa["embeddings"] is False and mapa["cenas"]
    for c in mapa["cenas"]:
        assert c["encaixes"] and 1 <= len(c["candidatas"]) <= 5 and c["cena"] in c["candidatas"]
        assert "takeover" in c and c["ate"] > c["t"]
        assert D.spoken(json.dumps(c["encaixes"], ensure_ascii=False)) <= D.spoken(c["frase"])
    assert "ReadingBlock" in vistos and "Filling" in vistos
    assert json.loads((tmp_path / "estudio" / "mapa.json").read_text())["ritmo"]["perfil"] == "longo"
    # aprovar o mapa ensina a bancada (tarefa bloco_peca)
    from esteira import bench
    monkeypatch.setattr(bench, "ANSWER_KEY", tmp_path / "gabarito")
    esperados = [c for c in mapa["cenas"] if c["por"] in ("local", "regra")]   # gatilho/pessoa não entram
    assert D.approve_map("t-001", mapa) == len(esperados)
    if esperados:
        caso = json.loads((tmp_path / "gabarito" / "bloco_peca.jsonl").read_text().splitlines()[0])
        assert caso["aceitas"] == [esperados[0]["cena"]] and esperados[0]["cena"] in caso["candidatas"]


def test_tarefa_da_bancada():
    from esteira import bench
    montar, nota = bench.TASKS["bloco_peca"]
    caso = {"texto": "81% estão endividadas", "candidatas": "- contador: número\n- cta: chamada", "aceitas": ["contador"]}
    texto, esquema, _ = montar(caso)
    assert "contador" in texto and esquema is bench.ChoicePiece
    assert nota(caso, bench.ChoicePiece(escolha="contador")) == 1.0 and nota(caso, bench.ChoicePiece(escolha="cta")) == 0.0


def test_citacao_vem_do_roteiro_e_sem_citacao_a_peca_nao_entra():
    f = P.load("estudo_folha_25d")
    cit = {"en": "subjects complete these parts faster", "pt": "terminam mais rápido", "autores": "Brown e Lahey",
           "ano": "2014", "revista": "NBER", "palavras": set(D._words_norm("as pessoas terminavam a tarefa mais rápido"))}
    enc, _ = D.fill(f, {"texto": "as pessoas terminavam a tarefa mais rápido"}, None, [cit])
    assert enc["trecho_en"] == cit["en"] and enc["autor"] == "Brown e Lahey"
    assert D.fill(f, {"texto": "parece que a bola de neve é só um erro"}, None, [cit]) is None


def test_recusa_lista_sem_itens_marcador_vazio_e_comparacao_igual():
    lista = P.load("lista_itens")
    assert D.problems(lista, {"titulo": "A *realidade*"}, {}, "fala")
    assert D.problems(lista, {"titulo": "x", "valores": [{"rotulo": "Estudo de"}, {"rotulo": "e"}]}, {}, "fala")
    folha = P.load("estudo_folha_25d")
    assert D.problems(folha, {"trecho_en": "a", "traducao": "b", "autor": "Unknown"}, {}, "fala")
    pilares = P.load("comparacao_pilares_25d")
    assert any("iguais" in e for e in D.problems(pilares, {"valor_a": "100", "valor_b": "100"}, {}, "100 e 100"))


def test_recusa_cta_sem_chamada_e_barras_sem_numero():
    cta = P.load("cta")
    assert any("chama" in e for e in D.problems(cta, {"titulo": "Você tem *aversão*?"}, {}, "ganhavam dinheiro de verdade"))
    assert not any("chama" in e for e in D.problems(cta, {"titulo": "Comenta *aí*"}, {}, "me conta nos comentários"))
    barras = P.load("barras_comparacao")
    vs = [{"rotulo": "Avalanche", "valor": "Menor"}, {"rotulo": "Outras", "valor": "Maior"}]
    assert any("barras" in e for e in D.problems(barras, {"titulo": "x", "valores": vs}, {}, "fala"))


def test_conferencia_da_llm_devolve_o_problema(monkeypatch):
    f = P.load("conceito_icone")
    monkeypatch.setattr(D.local, "ask", lambda *a, **k: D.Verification(fiel=False, problema="custo trocado"))
    assert "custo trocado" in D.cross_check(f, {"titulo": "Custo da *avalanche*"}, {"texto": "espalhar custa caro"}, "")[0]
