"""N1 do EffectCraft: compilação para o script da app (auxiliares do núcleo), tempos, condições e repetição."""
import json
import re
import subprocess

import pytest
from pydantic import ValidationError

from esteira.studio import ec
from esteira.studio import piece as P
from esteira.n1 import effectcraft as N1

N1_EXAMPLE = P.FOLDER / "_ec" / "exemplo_caixas.n1.json"

DOC = json.loads((P.folder("numero_impacto_ec") / "peca.n1.json").read_text())


def _d(**kw):
    d = {"encaixes": {"numero": "R$ 1.250", "rotulo": "juros", "contexto": "só o *mínimo*"},
         "botoes": {"alinhamento": "centro", "enfase": "traco", "velocidade": "lenta"}, "batidas": {}, "t0": 0.3,
         "dur": 5, "w": 1920, "h": 1080, "fps": 30, "tela_cheia": False}
    return {**d, **kw}


def test_real_piece_compiles_with_conditions_times_and_vertical():
    js = N1.build(DOC, _d())
    assert "veuBaixo(0.85);" in js and "fundoTela" not in js
    assert 'retangulo("Traço"' in js and 'elipse("Anel"' not in js  # ênfase = traço
    assert "contagem(e2, n_e2.n, n_e2.casas, 0.5, 1.44" in js  # @numero (T0+0.15) +0.05; 0.9 × lenta (1.6)
    assert "if (n_e2 && n_e2.depois)" in js  # unidade só se o número tiver
    vert = N1.build(DOC, _d(w=1080, h=1920, botoes={"alinhamento": "esquerda", "enfase": "anel"}))
    assert 'elipse("Anel"' in vert and "108.0" in vert  # x0 = 10% do lado menor no 9:16
    without_region = N1.build(DOC, _d(encaixes={"numero": "7", "rotulo": "", "contexto": ""}, tela_cheia=True))
    assert "fundoTela();" in without_region and '"Contexto"' not in without_region and '"Rótulo"' not in without_region


def test_spoken_beat_has_priority_and_compound_time():
    c = N1.Compiler(DOC, _d(batidas={"numero": 2.0}))
    assert c.time_of("@numero+0.2+0.6v") == pytest.approx(2.0 + 0.2 + 0.6 * 1.6)
    assert c.time_of(0.5) == pytest.approx(0.8) and c.duration_of("0.8v") == pytest.approx(1.28)
    assert N1.Compiler({"elementos": []}, _d()).time_of("@sem_padrao") == pytest.approx(0.45)  # T0 + 0,15


def test_repeat_unfolds_items_with_step_and_interval():
    doc = {"elementos": [{"tipo": "repetir", "nome": "Marcos", "encaixe": "marcos", "passo": [0.2, 0], "intervalo": 0.3,
                          "elementos": [{"tipo": "texto", "nome": "Ano", "conteudo": "{{item.rotulo}}", "x": 0.1, "y": 0.5,
                                         "tam": 0.05}],
                          "animacoes": [{"anim": "entrar", "alvo": "Ano", "t": 0.2}]}]}
    js = N1.build(doc, _d(encaixes={"marcos": [{"rotulo": "1990", "valor": "a"}, {"rotulo": "2008", "valor": "b"}]}))
    assert 'linha("Ano 1", "1990", 192.0' in js and 'linha("Ano 2", "2008", 576.0' in js
    assert "entrar(e0, \"baixo\", 0.5, 0.6)" in js and "entrar(e1, \"baixo\", 0.8, 0.6)" in js


def test_closed_schema_and_errors():
    with pytest.raises(ValidationError):  # cor fixa não passa
        N1.Piece.model_validate({"elementos": [{"tipo": "texto", "nome": "a", "conteudo": "x", "x": 0, "y": 0,
                                               "tam": 0.1, "cor": "#ff0000"}]})
    with pytest.raises(ValidationError):  # tempo fora do formato
        N1.Piece.model_validate({"elementos": [], "animacoes": [{"anim": "entrar", "alvo": "a", "t": "agora"}]})
    js = N1.build({"elementos": [{"tipo": "texto", "nome": "a", "conteudo": "x", "x": 0, "y": 0.5, "tam": 0.1}],
                      "animacoes": [{"anim": "contar", "alvo": "a"}]}, _d())  # contar marca o texto como número
    assert "var n_e0 = numero(" in js


def test_static_gate_of_n1_piece():
    errors, _ = ec.check_code("numero_impacto_ec", P.load("numero_impacto_ec"))
    assert errors == []


def test_generated_script_has_valid_syntax():
    node = P._node()
    if not node:
        pytest.skip("sem node")
    js = ec.CORE.read_text() + "\n" + N1.build(DOC, _d()) + "\n" + ec.END.read_text()
    r = subprocess.run([node, "--check", "-"], input="var DADOS = {};\nvar app = {};\n" + js, capture_output=True,
                       text=True)
    assert r.returncode == 0, r.stderr


def test_after_disabled_or_missing_element_keeps_own_x():
    doc = {"elementos": [
        {"tipo": "texto", "nome": "Número", "conteudo": "{{n}}", "x": 0.5, "y": 0.5, "tam": 0.2,
         "se": {"encaixe": "n"}},
        {"tipo": "texto", "nome": "Unidade", "conteudo": "%", "x": 0.6, "y": 0.5, "tam": 0.1,
         "apos": {"nome": "Número", "folga": 0.01}}]}
    js = N1.build(doc, _d(encaixes={"n": ""}))
    assert 'linha("Unidade", "%", 1152.0' in js and "sourceRectAtTime" not in js
    js = N1.build({"elementos": [{**doc["elementos"][1], "apos": {"nome": "Fantasma"}}]}, _d())
    assert 'linha("Unidade", "%", 1152.0' in js


def test_grid_active_slices_vertical_and_markers():
    grade = {"tipo": "repetir", "nome": "Grade", "quantidade": 100, "colunas": 10, "passo": [0.05, 0.05],
             "ativos": "v", "elementos": [{"tipo": "retangulo", "nome": "C", "x": 0.3, "y": 0.2, "w": 0.04, "h": 0.04,
                                           "cor": "apoio"}]}
    js = N1.build({"elementos": [grade]}, _d(encaixes={"v": [{"rotulo": "a", "valor": "34%"}]}))
    assert js.count('retangulo("C ') == 100 and js.count('"destaque"') == 34
    rosca = {"tipo": "repetir", "nome": "R", "encaixe": "f", "elementos": [
        {"tipo": "elipse", "nome": "F", "x": 0.5, "y": 0.5, "d": 0.5, "fatia": True, "contorno": 0.1}]}
    js = N1.build({"elementos": [rosca]}, _d(encaixes={"f": [{"valor": "50%"}, {"valor": "30%"}, {"valor": "20%"}]}))
    assert ", 0.0, 0.5);" in js and ", 0.5, 0.8);" in js and ", 0.8, 1.0);" in js
    items = {"tipo": "repetir", "nome": "L", "encaixe": "i", "passo": [0, 0.1], "elementos": [
        {"tipo": "texto", "nome": "T", "conteudo": "{{item}}", "x": 0.1, "y": 0.2, "tam": 0.04, "vertical": {"y": 0.6}}]}
    js = N1.build({"elementos": [items]}, _d(w=1080, h=1920, encaixes={"i": ["a", "b"]}))
    assert ", 1152.0, " in js and ", 1344.0, " in js  # o vertical do molde vale antes do passo (não empilha)
    js = N1.build({"elementos": [{"tipo": "texto", "nome": "V", "conteudo": "{{p.valor}}", "x": 0.1, "y": 0.5,
                                     "tam": 0.05}]}, _d(encaixes={"p": [{"rotulo": "x", "valor": "R$ 9"}]}))
    assert '"R$ 9"' in js
    with pytest.raises(N1.ErrorN1):
        N1.build({"elementos": [{"tipo": "texto", "nome": "V", "conteudo": "{{p.a.b}}", "x": 0.1, "y": 0.5,
                                    "tam": 0.05}]}, _d())


def test_boxes_compute_geometry_in_both_formats():
    doc = json.loads((N1_EXAMPLE).read_text())
    enc = {"titulo": "Para onde vai o salário", "total": "R$ 4.000",
           "fatias": [{"rotulo": "Necessidades", "valor": "50%"}, {"rotulo": "Desejos", "valor": "30%"},
                      {"rotulo": "Investir", "valor": "20%"}]}
    h = N1.build(doc, _d(encaixes=enc))
    v = N1.build(doc, _d(w=1080, h=1920, encaixes=enc))
    assert h.count('elipse("Fatia ') == 3 and 'LIMITE[' in h and "caber([" in h
    x_h = float(re.search(r'bloco\("Rótulo 1", "Necessidades", ([\d.]+)', h).group(1))
    y_v = float(re.search(r'bloco\("Rótulo 1", "Necessidades", [\d.]+, ([\d.]+)', v).group(1))
    assert x_h > 960 and y_v > 1000  # legenda à direita no 16:9 e embaixo no 9:16, sem nenhuma coordenada no N1
    assert N1.loose(N1.Piece.model_validate(doc)) == []
    assert N1.loose(N1.Piece.model_validate({"elementos": [{"tipo": "texto", "nome": "t", "conteudo": "x"}]})) == ["t"]
    with pytest.raises(N1.ErrorN1):  # elemento solto sem posição
        N1.build({"elementos": [{"tipo": "texto", "nome": "t", "conteudo": "x"}]}, _d())
    grade = {"elementos": [{"tipo": "caixa", "nome": "G", "regiao": "centro", "disposicao": "grade", "colunas": 10,
                            "filhos": [{"tipo": "repetir", "nome": "R", "quantidade": 100, "ativos": "v",
                                        "elementos": [{"tipo": "retangulo", "nome": "C", "cor": "apoio"}]}]}]}
    js = N1.build(grade, _d(encaixes={"v": "34%"}))
    assert js.count('retangulo("C ') == 100 and js.count('"destaque"') == 34


def test_proportional_bars_and_texts_stacked_in_layers():
    doc = {"elementos": [
        {"tipo": "caixa", "nome": "B", "regiao": "centro", "disposicao": "linha", "filhos": [
            {"tipo": "repetir", "nome": "R", "encaixe": "p", "elementos": [
                {"tipo": "retangulo", "nome": "Barra", "proporcional": True},
                {"tipo": "texto", "nome": "V", "conteudo": "{{item.valor}}", "nivel": "rotulo"}]}]},
        {"tipo": "caixa", "nome": "C", "regiao": "topo", "disposicao": "camadas", "filhos": [
            {"tipo": "elipse", "nome": "A", "contorno": 0.03},
            {"tipo": "texto", "nome": "T1", "conteudo": "x", "nivel": "numero"},
            {"tipo": "texto", "nome": "T2", "conteudo": "y", "nivel": "rotulo"}]}]}
    js = N1.build(doc, _d(encaixes={"p": [{"rotulo": "a", "valor": "5"}, {"rotulo": "b", "valor": "10"}]}))
    alturas = [float(m) for m in re.findall(r'retangulo\("Barra \d", [\d.]+, [\d.]+, [\d.]+, ([\d.]+)', js)]
    assert abs(alturas[1] / alturas[0] - 2) < 0.01  # a barra segue o valor
    y1, y2 = (float(re.search(rf'bloco\("{n}", "[xy]", [\d.]+, ([\d.]+)', js).group(1)) for n in ("T1", "T2"))
    assert y2 > y1  # textos da camada empilhados, não sobrepostos


def test_number_keeps_its_unit_unless_another_text_shows_it():
    doc = {"elementos": [{"tipo": "caixa", "nome": "palco", "filhos": [
        {"tipo": "texto", "nome": "valor", "conteudo": "{{numero}}", "nivel": "numero"}]}],
        "animacoes": [{"anim": "contar", "alvo": "valor", "t": 0.2}]}
    js = N1.build(doc, _d(encaixes={"numero": "R$ 12 mil"}))
    assert ".replace(/\\B(?=(\\d{3})+(?!\\d))/g, \".\") + n_e0.depois :" in js
    assert re.search(r"contagem\(e0, .*n_e0\.antes, n_e0\.depois\);", js)
    assert "contagem(e2, n_e2.n, n_e2.casas, 0.5, 1.44" in N1.build(DOC, _d())
    assert re.search(r"contagem\(e2, .*n_e2\.antes, \"\"\);", N1.build(DOC, _d()))  # unit in its own text
