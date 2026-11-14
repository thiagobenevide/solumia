"""Bancada de LLM: as notas comparam a resposta com o gabarito sem depender do modelo."""
from esteira import bench as B


def test_numeros_e_normalizar():
    assert B.numbers("Eram 81,7% em 2026, R$ 1.200") == {"817", "2026", "1200"}
    assert B.normalize("Avalanche: é o MÉTODO!") == "avalanche e o metodo"


def test_wer():
    assert B.wer("qual você paga primeiro", "Qual você paga primeiro?") == 0
    assert B.wer("um consignato", "um consignado") == 0.5


def test_so_trocas():
    assert B.only_swaps("Um consignato ou crédito", "Um consignado ou crédito")
    assert B.only_swaps("eram 81 , 7 %", "eram 81,7%")
    assert not B.only_swaps("Imagina aqui que você tem", "Imagina que você tem")  # o narrador acrescentou
    assert not B.only_swaps("igual", "igual")


def test_nota_cena():
    instance = {"frase": "Em setembro de 2026, eram 81,7%.", "aceitas": ["contador"]}
    certa = B.Scene(cena="contador", ancora="eram 81,7%", titulo="Endividadas",
                   valores=[B.Value(rotulo="famílias", valor="81,7%")])
    assert B.score_scene(instance, certa) == 1
    inventada = certa.model_copy(update={"valores": [B.Value(rotulo="x", valor="90%")]})
    assert B.score_scene(instance, inventada) == 0.75
    errada = B.Scene(cena="midia", ancora="não está na frase", titulo="", valores=[])
    assert B.score_scene(instance, errada) == 0.25  # só "não inventou número"


def test_nota_legenda_e_visao():
    instance = {"whisper": "um consignato", "certo": "um consignado"}
    assert B.score_caption(instance, B.Caption(texto="um consignado")) == 1
    assert B.score_caption(instance, B.Caption(texto="um consignato")) == 0.5
    assert B.score_caption(instance, B.Caption(texto="outra coisa")) == 0
    v = {"certo": {"texto_cortado": True, "sobreposicao": False, "ilegivel": False, "rosto_coberto": False}}
    assert B.score_vision(v, B.Vision(texto_cortado=True, sobreposicao=True, ilegivel=False, rosto_coberto=False)) == 0.75
