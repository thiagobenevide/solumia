"""Etapa 9 do acervo: 3D real (Three.js) com cota por vídeo e a base de aprovações para o fine-tune."""
import json

from esteira.studio import direction as D
from esteira.studio import piece as P
from esteira.studio import rhythm as R
from esteira.studio import training as T


def test_peca_3d_usa_three_e_passa_no_portao_estatico():
    f = P.load("barras_3d")
    assert f.peso == "3d" and P.check_code("barras_3d", f) == ([], [])
    assert "k.cena3d(" in (P.folder("barras_3d") / "peca.js").read_text()   # cena do kit, desenhada pela timeline


def test_three_so_vai_para_os_assets_com_peca_3d(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    a.mkdir(), b.mkdir()
    assert P.join(a, ["numero_impacto"]) is False and not (a / "three.min.js").exists()
    assert P.join(b, ["numero_impacto", "barras_3d"]) is True and (b / "three.min.js").exists()


def test_cota_3d_derruba_a_segunda_peca_3d_na_janela():
    f3 = P.load("barras_3d").model_copy(update={"estado": "aprovada"})
    cards = [f3] + P.list_all("aprovada")
    profile = R.load("longo")
    m = {"ini": 60.0, "fim": 66.0, "texto": "A poupança rendeu 6%, o CDB 11% e o Tesouro 12%."}
    lei = D.ReadingMoment(intencao="comparacao")
    free = D.candidates(m, lei, "3d", cards, None, None, {}, ["16:9"], profile, [])
    preso = D.candidates(m, lei, "3d", cards, None, None, {}, ["16:9"], profile, [(f3, 10.0)])
    points = lambda cs: next(p for p, f in cs if f.id == "barras_3d")  # noqa: E731
    assert free[0][1].id == "barras_3d"
    assert points(preso) <= points(free) - 1.0


def test_exportar_base_de_treino(tmp_path, monkeypatch):
    cases = {"corte": [{"id": f"c{i}", "manter": i % 2 == 0} for i in range(40)],
             "legenda": [{"id": "l1", "certo": "texto certo"}, {"id": "l1", "certo": "corrigido de novo"}]}
    monkeypatch.setattr(T, "FOLDER", tmp_path)
    monkeypatch.setattr(T, "_cases", lambda t: cases.get(t, []))
    monkeypatch.setattr(T, "_prompt_bench", lambda t, c: f"prompt {t} {c['id']}")
    r = T.export(("corte", "legenda"))
    assert r["tarefas"]["corte"]["treino"] + r["tarefas"]["corte"]["validacao"] == 40
    assert r["tarefas"]["legenda"]["treino"] + r["tarefas"]["legenda"]["validacao"] == 1   # repetido: vale o último
    assert not r["pronta"]                                                                 # abaixo do mínimo
    lines = [json.loads(x) for p in tmp_path.glob("*/legenda.*.jsonl") for x in p.read_text().splitlines()]
    assert json.loads(lines[0]["messages"][1]["content"]) == {"texto": "corrigido de novo"}
    assert T.status()["ultima"]["pasta"] == r["pasta"]
