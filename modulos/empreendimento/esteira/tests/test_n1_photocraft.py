"""N1 do PhotoCraft: thumb declarativa com layout relacional, variantes A/B e tratamento pela receita do canal."""
import pytest
from pydantic import ValidationError

from esteira.n1 import photocraft as N1

CORES = {"texto": "#ffffff", "destaque": "#ffd400", "alerta": "#ff2d2d", "preto": "#000000"}


def _executar(doc):
    passadas = []

    def rodar(origem, passos, destino):
        passadas.append(passos)
        return [{"layer": f"L{i}", "bounds": [100, 200, 600, 400], "name": f"n{i}"} for i in range(len(passos))]
    N1.Executor(rodar, {"fundo": "/f.png", "foto": "/p.jpg"}, CORES, lambda a: (2560, 1440)).executar(doc, "/tmp/t.pcraft")
    return passadas


def test_thumb_titulo_centralizado_selo_acima_e_caixa_com_vidro():
    passadas = _executar({"elementos": [
        {"tipo": "imagem", "midia": "fundo"},
        {"tipo": "titulo", "conteudo": "O *ERRO* DOS 30", "tamanho": 0.2, "lado": "direita"},
        {"tipo": "selo", "conteudo": "ESTUDO"},
        {"tipo": "caixa", "conteudo": "texto *livre*", "pos": [0.1, 0.8], "largura": 0.4, "tamanho": 0.06,
         "fundo": "vidro"}]})
    p1, p2 = passadas
    place = p1[0][1]
    assert place["scale"] == 50.0 and place["center"] == [640, 360]  # cobre 1280×720 a partir de 2560×1440
    titulo = next(p for c, p in p1 if c == "type.create" and p["name"] == "Título")
    assert titulo["size"] == 144 and titulo["align"] == "right" and titulo["box"][0] == 1280 - 56 - 640
    assert next(p for c, p in p1 if c == "type.edit")["runs"] == [{"start": 2, "end": 6, "color": "#ffd400"}]
    cmds2 = [c for c, _ in p2]
    assert cmds2[0] == "type.edit" and "edit.transform" in cmds2  # título movido; selo girado
    assert any(c == "shape.create" and p["kind"] == "roundedRect" for c, p in p2)  # vidro atrás da caixa


def test_variantes_viram_layer_comps():
    passadas = _executar({"elementos": [{"tipo": "titulo", "conteudo": "A", "tamanho": 0.2}],
                          "variantes": [{"nome": "B", "titulo": "OUTRO *TEXTO*"}]})
    assert ("layerComp.new", {"name": "A"}) in passadas[0]
    p2 = passadas[1]
    assert ("layerComp.new", {"name": "B"}) in p2 and p2[-1] == ("layerComp.apply", {"comp": "A"})


def test_tratamento_pela_receita_e_decisao():
    receita = {"lut": "tealOrange", "nitidez": 0.25, "grao": 0.1, "desfoque_fundo": 0.4}
    doc = N1.tratamento(receita, N1.FotoDecisao(foco=(0.9, 0.5), separar_planos=True, recortar=False), "9:16",
                        1920, 1080)
    passos = _executar(doc)[0]
    crop = next(p for c, p in passos if c == "image.crop")
    assert crop["width"] == 608 and crop["height"] == 1080 and crop["x"] == 1920 - 608  # foco na borda direita
    nomes = [c for c, _ in passos]
    assert "layer.newAdjustmentLayer.colorLookup" in nomes and "filter.blur.smartBlur" in nomes
    assert "layer.removeBackground" not in nomes


def test_esquema_fechado():
    with pytest.raises(ValidationError):  # cor fora dos papéis e não hex
        N1.Composicao.model_validate({"elementos": [{"tipo": "titulo", "conteudo": "x", "tamanho": 0.2,
                                                     "cor": "vermelho"}]})
    with pytest.raises(ValidationError):  # tamanho em pixels não passa
        N1.Composicao.model_validate({"elementos": [{"tipo": "titulo", "conteudo": "x", "tamanho": 150}]})
