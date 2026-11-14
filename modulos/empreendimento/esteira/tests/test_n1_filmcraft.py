"""N1 do FilmCraft: esquema fechado e executor N1 → comandos (FilmCraft simulado)."""
import itertools

import pytest
from pydantic import ValidationError

from esteira.filmcraft import ticks
from esteira.n1 import filmcraft as N1

ESTILO = {"fonte": "Inter", "fonte_estilo": "Bold", "cores": {"texto": "#ffffff", "destaque": "#ff0", "acento": "#0ff"}}


class FC:
    def __init__(self):
        self.chamadas, self.n = [], itertools.count(1)

    def run(self, cmd, **p):
        self.chamadas.append((cmd, p))
        if cmd == "file.import":
            return {"items": [f"i{next(self.n)}" for _ in p["paths"]], "errors": []}
        if cmd == "timeline.place":
            return {"clips": [f"c{next(self.n)}"]}
        if cmd == "graphics.newText":
            return {"clip": f"c{next(self.n)}"}
        if cmd == "file.newAdjustmentLayer":
            return {"item": f"i{next(self.n)}"}
        return {}


def _executar(ops, midias=None):
    fc = FC()
    midias = midias or {"narracao": {"caminho": "/n.wav"}, "cena:1": {"caminho": "/a.mp4"},
                        "musica": {"caminho": "/m.mp3", "dur": 40}}
    ex = N1.Executor(fc, midias, ESTILO)
    ex.executar({"ops": ops})
    return fc.chamadas


def test_montagem_basica_resolve_nomes_trilhas_e_ticks():
    cmds = _executar([
        {"op": "sequencia", "nome": "ep", "formato": "9:16"},
        {"op": "colocar", "id": "narracao", "midia": "narracao", "trilha": "narracao", "em": 0},
        {"op": "colocar", "id": "c1", "midia": "cena:1", "trilha": "base", "em": 2, "dur": 3},
        {"op": "ken_burns", "alvo": "c1", "movimento": "pan_dir", "zoom": 10},
        {"op": "transicao", "alvo": "c1", "tipo": "glitch", "borda": "saida"},
        {"op": "musica", "ate": 100, "ganho_db": -18},
    ])
    names = [c for c, _ in cmds]
    assert names[0] == "file.import" and len(cmds[0][1]["paths"]) == 3
    assert cmds[1] == ("file.newSequence", {"name": "ep", "width": 1080, "height": 1920, "fps": 30, "video": 4,
                                            "audio": 2})
    scene = cmds[3][1]
    assert scene["track"] == "V1" and scene["duration"] == ticks(3) and scene["audio"] is False
    pos = [p for c, p in cmds if c == "effects.setParam" and p["param"] == "position"]
    assert len(pos) == 2 and pos[0]["value"][0] > 540 > pos[1]["value"][0]  # pan para a direita
    trans = next(p for c, p in cmds if c == "sequence.applyVideoTransition")
    assert trans["edge"] == "out" and trans["effect"] == "glitch"
    assert sum(1 for c, p in cmds if c == "timeline.place" and p["track"] == "A2") == 3  # 100 s em loops de 40
    assert ("essentialSound.generateDucking" in names)


def test_texto_pop_e_correcoes():
    cmds = _executar([
        {"op": "sequencia", "nome": "ep"},
        {"op": "texto", "id": "k", "conteudo": "JUROS", "em": 1, "dur": 1.5, "tamanho": 0.1, "pos": [0.5, 0.8],
         "cor": "acento", "estilo": "pop"},
        {"op": "mover", "alvo": "k", "para": 4},
        {"op": "marcar", "em": 2, "nome": "revisar", "cor": "vermelho"},
    ])
    props = next(p for c, p in cmds if c == "graphics.set")["props"]
    assert props["fill_color"] == "#0ff" and props["size"] == 108 and props["position"] == [960, 864]
    assert next(p for c, p in cmds if c == "timeline.move")["moves"][0]["time"] == {"seconds": 4}
    assert next(p for c, p in cmds if c == "markers.add")["color"] == "Red"


def test_esquema_fechado_e_erros():
    with pytest.raises(ValidationError):  # transição fora do catálogo
        N1.Assembly.model_validate({"ops": [{"op": "transicao", "alvo": "x", "tipo": "explosao"}]})
    with pytest.raises(ValidationError):  # campo desconhecido
        N1.Assembly.model_validate({"ops": [{"op": "cortar", "em": 1, "pixels": 3}]})
    with pytest.raises(N1.ErrorN1):
        _executar([{"op": "sequencia", "nome": "e"}, {"op": "remover", "alvo": "fantasma"}])
    with pytest.raises(N1.ErrorN1):
        _executar([{"op": "colocar", "id": "x", "midia": "cena:999", "trilha": "base", "em": 0}])
    schema = N1.esquema_json(N1.Assembly) if hasattr(N1, "esquema_json") else N1.Assembly.model_json_schema()
    assert "ops" in schema["properties"]
