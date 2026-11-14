from esteira.studio import triggers
from esteira.studio.style import Estilo

G = triggers.padrao()


def _id(frase, **ctx):
    d = triggers.detectar(frase, G, ctx)
    return d["gatilho"].id if d else None


def test_estudo_vence_porcentagem():
    d = triggers.detectar("Segundo a CNC, 81,7% das famílias brasileiras estão endividadas.", G)
    assert d["gatilho"].id == "estudo_citado"
    assert "porcentagem" in d["perdeu"]


def test_porcentagem_e_proporcao():
    assert _id("81,7% das famílias estão endividadas") == "porcentagem"
    assert _id("8 em cada 10 brasileiros não têm reserva") == "porcentagem"


def test_comparacao_bloqueia_porcentagem():
    frase = "Os juros do rotativo passam de 400% ao ano, contra 12% da poupança."
    assert _id(frase) == "comparacao"


def test_numero_recente_nao_dispara():
    assert _id("São 77 milhões de pessoas", numero_recente=True) is None


def test_pergunta_e_cta():
    assert _id("E sabe qual é o maior vilão?") == "pergunta"
    assert _id("Comenta RESERVA que eu te mando a planilha") == "cta"


def test_palavra_inteira():
    assert _id("Ele indica outro caminho para a conversa") is None


def test_cor_pelo_sentido():
    d = triggers.detectar("81,7% das famílias estão endividadas", G)
    assert d["cor"] == "acento"


def test_testar_roteiro():
    e = Estilo(id="teste-ap", nome="t", canal="t", modo="apresentador")
    texto = ("Segundo a CNC, 81,7% das famílias brasileiras estão endividadas. "
             "E sabe qual é o maior vilão? "
             "O cartão de crédito. Sem nenhum gatilho por aqui hoje não.")
    r = triggers.testar(triggers.frases_do_texto(texto), e)
    ids = [c["gatilho"] for c in r["cenas"]]
    assert ids[:3] == ["estudo_citado", "pergunta", "termo"]
    assert any(a["tipo"] == "sem_gatilho" for a in r["avisos"])
    assert abs(sum(r["ritmo"].values()) - 1) < 0.1
