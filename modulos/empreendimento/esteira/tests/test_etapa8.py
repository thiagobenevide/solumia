"""Etapa 8 do acervo: trecho de um bloco (janela de tempo), emenda no vídeo já renderizado e troca de peça na linha
do tempo (IA local simulada)."""
import json
import subprocess

import pytest

from esteira import estudio
from esteira.estudio import compilar
from esteira.estudio import direcao as D
from esteira.estudio import peca as P


def test_janela_desloca_corta_e_filtra_batidas():
    itens = [{"t": 1.0, "ate": 4.0}, {"t": 5.0, "ate": 9.0, "batidas": {"numero": 6.0, "x": 12.0}}, {"t": 12.0, "ate": 13.0}]
    j = compilar._janela(itens, 3.0, 10.0)
    assert [(x["t"], x["ate"]) for x in j] == [(0.0, 1.0), (2.0, 6.0)]
    assert j[0]["corte"] == 2.0 and "corte" not in j[1] and j[1]["batidas"] == {"numero": 3.0}
    m = compilar._janela([{"ini": 0.0, "fim": 8.0, "src": "a.mp4"}], 3.0, 6.0, "ini", "fim")
    assert m == [{"ini": 0.0, "fim": 3.0, "src": "a.mp4", "corte": 3.0}]   # o vídeo da mídia entra no meio


def test_janela_do_bloco_cai_nas_pausas():
    mapa = {"duracao": 60.0, "blocos": [{"i": 0, "ini": 0.2, "fim": 20.0}, {"i": 1, "ini": 21.0, "fim": 40.0},
                                        {"i": 2, "ini": 42.0, "fim": 59.0}]}
    assert estudio.janela_do_bloco(mapa, 1) == (20.5, 41.0)
    assert estudio.janela_do_bloco(mapa, 0) == (0.0, 20.5) and estudio.janela_do_bloco(mapa, 2) == (41.0, 60.0)
    with pytest.raises(ValueError):
        estudio.janela_do_bloco(mapa, 9)


class _Proj:
    def __init__(self, pasta):
        self.pasta = pasta


def _video(destino, cor, segundos, freq):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"color=c={cor}:s=320x180:r=30:d={segundos}",
                    "-f", "lavfi", "-i", f"sine=frequency={freq}:duration={segundos}", "-shortest", "-c:v", "libx264",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", str(destino)], check=True)


def _cor(video, t):
    out = subprocess.run(["ffmpeg", "-v", "error", "-ss", str(t), "-i", str(video), "-frames:v", "1", "-vf", "scale=1:1",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True).stdout
    return tuple(out[:3])


def test_emenda_troca_so_o_trecho(tmp_path):
    pr = _Proj(tmp_path)
    render = compilar.pasta(pr, "16:9") / "render"
    render.mkdir(parents=True)
    _video(render / "bruto.mp4", "red", 10, 440)
    _video(tmp_path / "trecho.mp4", "blue", 3, 880)
    compilar.emendar(pr, "16:9", 4.0, 7.0, tmp_path / "trecho.mp4")
    novo = render / "bruto.mp4"
    dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(novo)],
                               capture_output=True, text=True).stdout)
    assert abs(dur - 10.0) < 0.15 and (render / "bruto.anterior.mp4").exists()
    r, _, b = _cor(novo, 5.5)
    assert b > 150 and r < 80                                   # dentro do trecho: o novo (azul)
    r, _, b = _cor(novo, 2.0)
    assert r > 150 and b < 80                                   # fora: o de antes (vermelho)
    assert _cor(novo, 8.5)[0] > 150


def test_trocar_peca_preenche_a_nova_ou_aproveita_o_que_havia(monkeypatch):
    cena = {"t": 10.0, "ate": 16.0, "cena": "frase_destaque", "frase": "Hoje 81% das famílias estão endividadas",
            "titulo": "Endividadas", "valores": [{"rotulo": "famílias", "valor": "81%"}], "intencao": "numero"}
    monkeypatch.setattr(D, "preencher", lambda f, m, lt: ({"titulo": "Endividadas", "valores": [{"rotulo": "famílias", "valor": "81%"}]}, {}))
    c = D.refazer_cena(dict(cena), P.carregar("contador"))
    assert c["cena"] == "contador" and c["takeover"] is True and c["manual"] and c["encaixes"]["valores"][0]["valor"] == "81%"
    monkeypatch.setattr(D, "preencher", lambda f, m, lt: None)   # a IA falhou: usa título/valores da cena
    c2 = D.refazer_cena(dict(cena), P.carregar("contador"))
    assert c2["encaixes"] == {"titulo": "Endividadas", "valores": [{"rotulo": "famílias", "valor": "81%"}]}
    with pytest.raises(ValueError):                              # nada serve: recusa (a cena fica como estava)
        D.refazer_cena({**cena, "frase": "vamos entender isso", "valores": []}, P.carregar("contador"))


def test_template_tem_o_inicio_da_narracao():
    assert 'data-media-start="__DE__"' in (compilar.KIT / "index.template.html").read_text()
    assert json.loads(json.dumps({"ok": 1}))
