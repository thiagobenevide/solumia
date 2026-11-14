import io
import json
import zipfile

import pytest
from esteira import package


@pytest.fixture
def ep(tmp_path):
    pasta = tmp_path / "finlumia" / "003"
    (pasta / "midia").mkdir(parents=True)
    (pasta / "graficos").mkdir()
    (pasta / "midia" / "c1.mp4").write_bytes(b"video")
    (pasta / "graficos" / "pag.png").write_bytes(b"png")
    png = str(pasta / "graficos" / "pag.png")
    fc = {"format": "filmcraft.project",
          "itens": [{"path": str(pasta / "midia" / "c1.mp4")}, {"x": [{"path": png}]}]}
    (pasta / "projeto.fcproj").write_text(json.dumps(fc))
    ec = {"kind": {"path": str(pasta / "graficos" / "pag.png")}}
    (pasta / "graficos" / "g.ecproj").write_text(json.dumps(ec))
    return pasta


def _zip(pasta, arquivo, nome="pct"):
    return zipfile.ZipFile(io.BytesIO(b"".join(package.empacotar(arquivo, pasta, nome))))


def test_pacote_leva_midia_e_caminhos_relativos(ep):
    z = _zip(ep, ep / "projeto.fcproj")
    assert sorted(z.namelist()) == [
        "pct/graficos/pag.png", "pct/midia/c1.mp4", "pct/projeto.fcproj"]
    dados = json.loads(z.read("pct/projeto.fcproj"))
    caminhos = [n["path"] for n in package._nos_com_caminho(dados)]
    assert caminhos == ["midia/c1.mp4", "graficos/pag.png"]
    assert z.read("pct/midia/c1.mp4") == b"video"
    g = json.loads(_zip(ep, ep / "graficos" / "g.ecproj").read("pct/graficos/g.ecproj"))
    assert g["kind"]["path"] == "pag.png"


def test_receber_religa_caminhos_de_outra_maquina_e_guarda_anterior(ep):
    anterior = (ep / "projeto.fcproj").read_text()
    editado = {"format": "filmcraft.project", "itens": [
        {"path": "/home/outro/Downloads/x/finlumia/003/midia/c1.mp4"},  # trecho <canal>/<NNN>/
        {"path": "C:\\Users\\eu\\pct\\graficos\\pag.png"},              # só pelo nome
        {"path": "midia/sumiu.mp4"},
    ]}
    r = package.receber(json.dumps(editado).encode(), ep / "projeto.fcproj", ep)
    assert r == {"ok": True, "midia_faltando": 1}
    gravado = json.loads((ep / "projeto.fcproj").read_text())
    caminhos = [n["path"] for n in package._nos_com_caminho(gravado)]
    assert caminhos[:2] == [str(ep / "midia" / "c1.mp4"), str(ep / "graficos" / "pag.png")]
    guardados = list((ep / "log" / "envios").glob("projeto.*.fcproj"))
    assert len(guardados) == 1 and guardados[0].read_text() == anterior


def test_receber_aceita_o_zip_baixado_e_recusa_lixo(ep):
    zipado = b"".join(package.empacotar(ep / "graficos" / "g.ecproj", ep, "pct"))
    package.receber(zipado, ep / "graficos" / "g.ecproj", ep)
    g = json.loads((ep / "graficos" / "g.ecproj").read_text())
    assert g["kind"]["path"] == str((ep / "graficos" / "pag.png").resolve())
    with pytest.raises(ValueError):
        package.receber(b"isto nao e json", ep / "projeto.fcproj", ep)
    with pytest.raises(ValueError):
        package.receber(b"PK\x03\x04", ep / "thumbs.pcraft", ep)
