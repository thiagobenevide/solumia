"""Etapa 7 do acervo: peças 2,5D (CSS 3D) e a ampliação contínua do acervo pelas lacunas."""
import shutil

import pytest

from esteira.studio import direction as D
from esteira.studio import factory as F
from esteira.studio import piece as P
from esteira.studio import rhythm as R

PECAS_25D = ("monitor_perspectiva", "cartoes_profundidade", "planos_camera")


@pytest.mark.parametrize("id_", PECAS_25D)
def test_pecas_25d_usam_css_3d_e_passam_no_portao_estatico(id_):
    f = P.carregar(id_)
    assert f.peso == "2_5d" and P.checar_codigo(id_, f) == ([], [])
    css = (P.pasta(id_) / "peca.css").read_text()
    js = (P.pasta(id_) / "peca.js").read_text()
    assert "perspective" in css and ("rotationY" in js or " z:" in js)


def test_direcao_usa_25d_no_tratamento_sobre_a_camera():
    fichas = ([P.carregar(i).model_copy(update={"estado": "aprovada"}) for i in PECAS_25D]
              # só as 2D do acervo: outras 2,5D aprovadas depois mudariam o pódio sem a direção errar
              + [f for f in P.listar("aprovada") if f.id not in PECAS_25D and f.peso != "2_5d"])
    m = {"ini": 10.0, "fim": 18.0, "texto": "Olha o que aparece quando você abre o aplicativo do banco"}
    cs = D.candidatas(m, D.LeituraMomento(intencao="conceito"), "camera_2_5d", fichas, None, None, {}, ["16:9"],
                      R.carregar("longo"), [])
    assert {f.id for _, f in cs[:3]} == set(PECAS_25D)
    assert cs[0][1].id == "monitor_perspectiva"   # o exemplo da ficha é o mais parecido com a fala


def test_preenchimento_maximo_nao_deixa_destaque_solto():
    assert P._encher("Simulação do *empréstimo*", 30).count("*") % 2 == 0


@pytest.fixture
def ambiente(tmp_path, monkeypatch):
    pecas = tmp_path / "pecas"
    pecas.mkdir()
    shutil.copytree(P.pasta("numero_impacto"), pecas / "numero_impacto", ignore=shutil.ignore_patterns("prova"))
    dados = tmp_path / "fabrica"
    monkeypatch.setattr(P, "PASTA", pecas)
    for nome, valor in {"PASTA": dados, "PEDIDOS": dados / "pedidos.json", "REGISTRO": dados / "registro.jsonl",
                        "AMPLIACAO": dados / "ampliacao.json", "MOTORES": dados / "motores.json"}.items():
        monkeypatch.setattr(F, nome, valor)
    filas = []
    monkeypatch.setattr(F, "enfileirar", lambda pid: filas.append(pid) or {"id": 1})
    monkeypatch.setattr(F, "gasto_hoje", lambda: 0.0)
    return filas


def test_ampliacao_cria_um_pedido_por_dia_e_respeita_os_freios(ambiente, monkeypatch):
    filas = ambiente
    assert F.ampliar() == (None, "desligada")
    F.salvar_ampliacao(ativo=True, pecas_por_dia=2, teto_dia_usd=1.5, motor="auto")
    p, motivo = F.ampliar()
    assert motivo == "pedido criado" and p.tipo == "lacunas" and p.quantidade == 2 and p.motor == "auto"
    assert filas == [p.id]
    p2, motivo2 = F.ampliar()
    assert p2.id == p.id and motivo2 == "pedido do dia" and len(F.pedidos()) == 1
    monkeypatch.setattr(F.claude, "quota", lambda: 0.95)
    assert F.ampliar() == (None, "cota do Claude em 95%")
    monkeypatch.setattr(F.claude, "quota", lambda: 0.1)
    monkeypatch.setattr(F, "fila_revisao", lambda: [{}] * 8)
    assert F.ampliar()[1].startswith("8+ peças esperando")
    with pytest.raises(ValueError):
        F.salvar_ampliacao(pecas_por_dia=0)


def test_lacunas_incluem_25d(monkeypatch):
    monkeypatch.setattr(F, "_no_acervo", lambda: [])  # acervo vazio: o acervo real já cobre as 2,5D
    assert any(x["peso"] == "2_5d" for x in F.lacunas())
