"""Edições à mão → N1: diferença da montagem no .fcproj e dos textos no .pcraft."""
import json

from esteira.dataset import edits as E
from esteira.filmcraft import TICKS


def _fcproj(tmp_path, clips):
    items = {"1": {"kind": {"Media": {"media": {"File": {"path": "/x/midia/a.jpg"}}}}},
             "2": {"kind": {"Media": {"media": {"File": {"path": "/x/midia/b.jpg"}}}}},
             "3": {"kind": {"Media": {"media": {"File": {"path": "/x/midia/c.jpg"}}}}}}
    track = {"name": "Video 1", "items": [{"item": i, "name": n, "start": int(at * TICKS), "duration": int(d * TICKS),
                                            "source_in": int(o * TICKS), "speed": v}
                                           for i, n, at, d, o, v in clips]}
    items["9"] = {"kind": {"Sequence": {"video_tracks": [track], "audio_tracks": []}}}
    file = tmp_path / "e.fcproj"
    file.write_text(json.dumps({"project": {"items": items}}))
    return file


def test_lift_fc_remove_move_trim_speed_and_place(tmp_path):
    doc = {"ops": [{"op": "colocar", "id": "c1", "midia": "cena:1", "trilha": "base", "em": 0, "dur": 4},
                   {"op": "colocar", "id": "c2", "midia": "cena:2", "trilha": "base", "em": 4, "dur": 4},
                   {"op": "colocar", "id": "c3", "midia": "cena:3", "trilha": "base", "em": 8, "dur": 4}]}
    medias = {"cena:1": "a.jpg", "cena:2": "b.jpg", "cena:3": "c.jpg"}
    # c1 encurtado no fim, c2 apagado, c3 aparado no início (1 s) e movido, mais rápido; um clipe novo de a.jpg
    file = _fcproj(tmp_path, [(1, "a", 0, 3, 0, 1.0), (3, "c", 5, 3, 1, 1.5), (1, "a", 20, 2, 0, 1.0)])
    ops, raw = E.lift_fc(doc, medias, file)
    kinds = [(o["op"], o.get("alvo") or o.get("id")) for o in ops]
    assert ("aparar", "c1") in kinds and ("remover", "c2") in kinds and ("velocidade", "c3") in kinds
    c3 = [o for o in ops if o.get("alvo") == "c3"]
    assert {"op": "aparar", "alvo": "c3", "borda": "entrada", "delta": -1.0} in c3
    assert any(o["op"] == "mover" and o["para"] == 5 for o in c3)
    new = next(o for o in ops if o["op"] == "colocar")
    assert new["midia"] == "arquivo:a.jpg" and new["em"] == 20 and not raw


def test_lift_pc_brings_edited_text_and_marks_new_layer():
    doc = {"elementos": [{"tipo": "titulo", "conteudo": "O *ERRO*", "tamanho": 0.2},
                         {"tipo": "caixa", "conteudo": "abc", "pos": [0, 0], "largura": 0.3, "tamanho": 0.05}]}
    info = {"height": 720, "layers": [{"name": "Título", "text": {"text": "O GRANDE ERRO", "sizePt": 144.0}},
                                      {"name": "Caixa 1", "text": {"text": "abc", "sizePt": 36.0}},
                                      {"name": "Emoji", "kind": "Pixel"}]}
    new, raw = E.lift_pc(doc, info)
    assert new["elementos"][0]["conteudo"] == "O GRANDE ERRO" and new["elementos"][0]["tamanho"] == 0.2
    assert new["elementos"][1]["conteudo"] == "abc" and raw == [{"camada_nova": "Emoji"}]
