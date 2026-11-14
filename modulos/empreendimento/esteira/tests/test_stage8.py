"""Etapa 8 do acervo: trecho de um bloco (janela de tempo), emenda no vídeo já renderizado e troca de peça na linha
do tempo (IA local simulada)."""
import json
import subprocess

import pytest

from esteira import studio
from esteira.studio import compiler
from esteira.studio import direction as D
from esteira.studio import piece as P


def test_window_shifts_cuts_and_filters_beats():
    items = [{"t": 1.0, "ate": 4.0}, {"t": 5.0, "ate": 9.0, "batidas": {"numero": 6.0, "x": 12.0}}, {"t": 12.0, "ate": 13.0}]
    j = compiler._window(items, 3.0, 10.0)
    assert [(x["t"], x["ate"]) for x in j] == [(0.0, 1.0), (2.0, 6.0)]
    assert j[0]["corte"] == 2.0 and "corte" not in j[1] and j[1]["batidas"] == {"numero": 3.0}
    m = compiler._window([{"ini": 0.0, "fim": 8.0, "src": "a.mp4"}], 3.0, 6.0, "ini", "fim")
    assert m == [{"ini": 0.0, "fim": 3.0, "src": "a.mp4", "corte": 3.0}]   # o vídeo da mídia entra no meio


def test_block_window_falls_on_pauses():
    mapping = {"duracao": 60.0, "blocos": [{"i": 0, "ini": 0.2, "fim": 20.0}, {"i": 1, "ini": 21.0, "fim": 40.0},
                                        {"i": 2, "ini": 42.0, "fim": 59.0}]}
    assert studio.window_of_block(mapping, 1) == (20.5, 41.0)
    assert studio.window_of_block(mapping, 0) == (0.0, 20.5) and studio.window_of_block(mapping, 2) == (41.0, 60.0)
    with pytest.raises(ValueError):
        studio.window_of_block(mapping, 9)


class _Proj:
    def __init__(self, folder):
        self.folder_path = folder


def _video(destination, color, seconds, freq):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"color=c={color}:s=320x180:r=30:d={seconds}",
                    "-f", "lavfi", "-i", f"sine=frequency={freq}:duration={seconds}", "-shortest", "-c:v", "libx264",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", str(destination)], check=True)


def _color(video, t):
    out = subprocess.run(["ffmpeg", "-v", "error", "-ss", str(t), "-i", str(video), "-frames:v", "1", "-vf", "scale=1:1",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True).stdout
    return tuple(out[:3])


def test_splice_swaps_only_segment(tmp_path):
    pr = _Proj(tmp_path)
    render = compiler.folder(pr, "16:9") / "render"
    render.mkdir(parents=True)
    _video(render / "bruto.mp4", "red", 10, 440)
    _video(tmp_path / "trecho.mp4", "blue", 3, 880)
    compiler.splice(pr, "16:9", 4.0, 7.0, tmp_path / "trecho.mp4")
    new = render / "bruto.mp4"
    duration = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(new)],
                               capture_output=True, text=True).stdout)
    assert abs(duration - 10.0) < 0.15 and (render / "bruto.anterior.mp4").exists()
    r, _, b = _color(new, 5.5)
    assert b > 150 and r < 80                                   # dentro do trecho: o novo (azul)
    r, _, b = _color(new, 2.0)
    assert r > 150 and b < 80                                   # fora: o de antes (vermelho)
    assert _color(new, 8.5)[0] > 150


def test_swap_piece_fills_new_or_reuses_existing(monkeypatch):
    scene = {"t": 10.0, "ate": 16.0, "cena": "frase_destaque", "frase": "Hoje 81% das famílias estão endividadas",
            "titulo": "Endividadas", "valores": [{"rotulo": "famílias", "valor": "81%"}], "intencao": "numero"}
    monkeypatch.setattr(D, "fill", lambda f, m, lt: ({"titulo": "Endividadas", "valores": [{"rotulo": "famílias", "valor": "81%"}]}, {}))
    c = D.redo_scene(dict(scene), P.load("contador"))
    assert c["cena"] == "contador" and c["takeover"] is True and c["manual"] and c["encaixes"]["valores"][0]["valor"] == "81%"
    monkeypatch.setattr(D, "fill", lambda f, m, lt: None)   # a IA falhou: usa título/valores da cena
    c2 = D.redo_scene(dict(scene), P.load("contador"))
    assert c2["encaixes"] == {"titulo": "Endividadas", "valores": [{"rotulo": "famílias", "valor": "81%"}]}
    with pytest.raises(ValueError):                              # nada serve: recusa (a cena fica como estava)
        D.redo_scene({**scene, "frase": "vamos entender isso", "valores": []}, P.load("contador"))


def test_template_has_narration_start():
    assert 'data-media-start="__DE__"' in (compiler.KIT / "index.template.html").read_text()
    assert json.loads(json.dumps({"ok": 1}))
