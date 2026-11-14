"""Etapa 9 do acervo: 3D real (Three.js) com cota por vídeo e a base de aprovações para o fine-tune."""
import json

from esteira.estudio import direcao as D
from esteira.estudio import peca as P
from esteira.estudio import ritmo as R
from esteira.estudio import treino as T


def test_peca_3d_usa_three_e_passa_no_portao_estatico():
    f = P.carregar("barras_3d")
    assert f.peso == "3d" and P.checar_codigo("barras_3d", f) == ([], [])
    assert "k.cena3d(" in (P.pasta("barras_3d") / "peca.js").read_text()   # cena do kit, desenhada pela timeline


def test_three_so_vai_para_os_assets_com_peca_3d(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    a.mkdir(), b.mkdir()
    assert P.juntar(a, ["numero_impacto"]) is False and not (a / "three.min.js").exists()
    assert P.juntar(b, ["numero_impacto", "barras_3d"]) is True and (b / "three.min.js").exists()


def test_cota_3d_derruba_a_segunda_peca_3d_na_janela():
    f3 = P.carregar("barras_3d").model_copy(update={"estado": "aprovada"})
    fichas = [f3] + P.listar("aprovada")
    perfil = R.carregar("longo")
    m = {"ini": 60.0, "fim": 66.0, "texto": "A poupança rendeu 6%, o CDB 11% e o Tesouro 12%."}
    lei = D.LeituraMomento(intencao="comparacao")
    livre = D.candidatas(m, lei, "3d", fichas, None, None, {}, ["16:9"], perfil, [])
    preso = D.candidatas(m, lei, "3d", fichas, None, None, {}, ["16:9"], perfil, [(f3, 10.0)])
    pontos = lambda cs: next(p for p, f in cs if f.id == "barras_3d")  # noqa: E731
    assert livre[0][1].id == "barras_3d"
    assert pontos(preso) <= pontos(livre) - 1.0


def test_exportar_base_de_treino(tmp_path, monkeypatch):
    casos = {"corte": [{"id": f"c{i}", "manter": i % 2 == 0} for i in range(40)],
             "legenda": [{"id": "l1", "certo": "texto certo"}, {"id": "l1", "certo": "corrigido de novo"}]}
    monkeypatch.setattr(T, "PASTA", tmp_path)
    monkeypatch.setattr(T, "_casos", lambda t: casos.get(t, []))
    monkeypatch.setattr(T, "_prompt_bancada", lambda t, c: f"prompt {t} {c['id']}")
    r = T.exportar(("corte", "legenda"))
    assert r["tarefas"]["corte"]["treino"] + r["tarefas"]["corte"]["validacao"] == 40
    assert r["tarefas"]["legenda"]["treino"] + r["tarefas"]["legenda"]["validacao"] == 1   # repetido: vale o último
    assert not r["pronta"]                                                                 # abaixo do mínimo
    linhas = [json.loads(x) for p in tmp_path.glob("*/legenda.*.jsonl") for x in p.read_text().splitlines()]
    assert json.loads(linhas[0]["messages"][1]["content"]) == {"texto": "corrigido de novo"}
    assert T.situacao()["ultima"]["pasta"] == r["pasta"]
