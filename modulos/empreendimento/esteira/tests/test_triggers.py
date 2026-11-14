from esteira.studio import triggers
from esteira.studio.style import Style

G = triggers.default()


def _id(sentence, **ctx):
    d = triggers.detect(sentence, G, ctx)
    return d["gatilho"].id if d else None


def test_study_beats_percentage():
    d = triggers.detect("Segundo a CNC, 81,7% das famílias brasileiras estão endividadas.", G)
    assert d["gatilho"].id == "estudo_citado"
    assert "porcentagem" in d["perdeu"]


def test_porcentagem_e_proporcao():
    assert _id("81,7% das famílias estão endividadas") == "porcentagem"
    assert _id("8 em cada 10 brasileiros não têm reserva") == "porcentagem"


def test_comparison_blocks_percentage():
    sentence = "Os juros do rotativo passam de 400% ao ano, contra 12% da poupança."
    assert _id(sentence) == "comparacao"


def test_recent_number_does_not_trigger():
    assert _id("São 77 milhões de pessoas", numero_recente=True) is None


def test_question_and_cta():
    assert _id("E sabe qual é o maior vilão?") == "pergunta"
    assert _id("Comenta RESERVA que eu te mando a planilha") == "cta"


def test_whole_word():
    assert _id("Ele indica outro caminho para a conversa") is None


def test_color_by_meaning():
    d = triggers.detect("81,7% das famílias estão endividadas", G)
    assert d["cor"] == "acento"


def test_test_script():
    e = Style(id="teste-ap", nome="t", canal="t", modo="apresentador")
    text = ("Segundo a CNC, 81,7% das famílias brasileiras estão endividadas. "
             "E sabe qual é o maior vilão? "
             "O cartão de crédito. Sem nenhum gatilho por aqui hoje não.")
    r = triggers.test(triggers.sentences_of_text(text), e)
    ids = [c["gatilho"] for c in r["cenas"]]
    assert ids[:3] == ["estudo_citado", "pergunta", "termo"]
    assert any(a["tipo"] == "sem_gatilho" for a in r["avisos"])
    assert abs(sum(r["ritmo"].values()) - 1) < 0.1
