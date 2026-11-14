"""Bancada de LLM: as notas comparam a resposta com o gabarito sem depender do modelo."""
from esteira import bancada as B


def test_numeros_e_normalizar():
    assert B.numeros("Eram 81,7% em 2026, R$ 1.200") == {"817", "2026", "1200"}
    assert B.normalizar("Avalanche: é o MÉTODO!") == "avalanche e o metodo"


def test_wer():
    assert B.wer("qual você paga primeiro", "Qual você paga primeiro?") == 0
    assert B.wer("um consignato", "um consignado") == 0.5


def test_so_trocas():
    assert B.so_trocas("Um consignato ou crédito", "Um consignado ou crédito")
    assert B.so_trocas("eram 81 , 7 %", "eram 81,7%")
    assert not B.so_trocas("Imagina aqui que você tem", "Imagina que você tem")  # o narrador acrescentou
    assert not B.so_trocas("igual", "igual")


def test_nota_cena():
    caso = {"frase": "Em setembro de 2026, eram 81,7%.", "aceitas": ["contador"]}
    certa = B.Cena(cena="contador", ancora="eram 81,7%", titulo="Endividadas",
                   valores=[B.Valor(rotulo="famílias", valor="81,7%")])
    assert B.nota_cena(caso, certa) == 1
    inventada = certa.model_copy(update={"valores": [B.Valor(rotulo="x", valor="90%")]})
    assert B.nota_cena(caso, inventada) == 0.75
    errada = B.Cena(cena="midia", ancora="não está na frase", titulo="", valores=[])
    assert B.nota_cena(caso, errada) == 0.25  # só "não inventou número"


def test_nota_legenda_e_visao():
    caso = {"whisper": "um consignato", "certo": "um consignado"}
    assert B.nota_legenda(caso, B.Legenda(texto="um consignado")) == 1
    assert B.nota_legenda(caso, B.Legenda(texto="um consignato")) == 0.5
    assert B.nota_legenda(caso, B.Legenda(texto="outra coisa")) == 0
    v = {"certo": {"texto_cortado": True, "sobreposicao": False, "ilegivel": False, "rosto_coberto": False}}
    assert B.nota_visao(v, B.Visao(texto_cortado=True, sobreposicao=True, ilegivel=False, rosto_coberto=False)) == 0.75
