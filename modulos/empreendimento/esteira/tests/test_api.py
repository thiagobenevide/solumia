"""API JSON do app Flutter: validações que não dependem dos episódios da máquina."""
from esteira.web.app import app
from fastapi.testclient import TestClient

c = TestClient(app, base_url="http://localhost")


def test_episodio_inexistente_da_404():
    assert c.get("/api/v1/episodios/canal-que-nao-existe-999").status_code == 404
    assert c.post("/api/v1/episodios/canal-que-nao-existe-999/rodar/all").status_code == 404


def test_produzir_recusa_roteiro_fora_do_vault():
    r = c.post("/api/v1/produzir", json={"roteiros": ["/etc/passwd"]})
    assert r.status_code == 400


def test_cors_libera_o_app_local():
    r = c.options("/api/v1/canais", headers={"Origin": "http://localhost:51234",
                                             "Access-Control-Request-Method": "GET"})
    assert r.headers["access-control-allow-origin"] == "http://localhost:51234"
    r = c.options("/api/v1/canais", headers={"Origin": "https://site-qualquer.com",
                                             "Access-Control-Request-Method": "GET"})
    assert "access-control-allow-origin" not in r.headers


def test_validacoes_das_acoes():
    assert c.post("/api/v1/roteiros/gerar", json={"alvo": "sem-numero"}).status_code == 400
    assert c.post("/api/v1/opcoes", json={"engine": "gpt"}).status_code == 400
    assert c.post("/api/v1/opcoes/baixar", json={"nome": "rm -rf /"}).status_code == 400
    assert c.post("/api/v1/processos/nao-existe/parar").status_code == 404
    for rota in ("roteiro", "cortes", "cenas", "graficos", "thumbs", "editor/grafico/0", "editor/thumb"):
        assert c.get(f"/api/v1/episodios/canal-que-nao-existe-999/{rota}").status_code == 404, rota


def test_leituras_do_sistema_respondem():
    for rota in ("meta", "monitor", "grafo", "processos?limite=1", "custos", "acervo?limite=1", "opcoes/baixando"):
        assert c.get(f"/api/v1/{rota}").status_code == 200, rota


def test_episodio_do_estudio_usa_o_final_do_estudio(tmp_path, monkeypatch):
    import os

    from esteira.web import api
    from esteira.web import app as painel
    pasta = tmp_path / "canal" / "001"
    (pasta / "estudio" / "16x9").mkdir(parents=True)
    monkeypatch.setattr(painel, "pasta_ep", lambda ep: pasta)
    monkeypatch.setattr(api, "pasta_ep", lambda ep: pasta)
    monkeypatch.setattr(painel, "Projeto", lambda p: type("P", (), {"cfg": {"video": {"formato": "16:9"}}}))
    antigo, novo = pasta / "final.mp4", pasta / "estudio" / "16x9" / "final.mp4"
    plano = pasta / "plano.json"
    for n, a in enumerate((antigo, plano, novo, novo.with_name("previa.mp4"))):
        a.write_text("x")
        os.utime(a, (n + 1, n + 1))
    r = painel._resumo_ep("canal-001")
    assert r["final"] and not r["desatualizado"] and r["feitas"] == 2  # graficos e montar: o Estúdio os substitui
    assert api._video_leve("canal-001", painel.final_do_ep(pasta)).startswith("/arq/canal-001/estudio/16x9/previa.mp4")
    os.utime(plano, (9, 9))
    assert painel._resumo_ep("canal-001")["desatualizado"]


def test_recusa_host_de_fora_e_post_de_outro_site():
    # DNS rebinding: o navegador manda o Host do domínio do atacante.
    assert c.get("/api/sistema", headers={"host": "atacante.com"}).status_code == 403
    # CSRF: formulário de outro site para a esteira local.
    r = c.post("/fila/limpar", headers={"origin": "https://atacante.com"})
    assert r.status_code == 403
    assert c.post("/fila/limpar", headers={"origin": "null"}).status_code == 403


def test_aceita_origem_local_e_dominio():
    for origem in ("http://127.0.0.1:8765", "https://agent.thiagobenevide.com"):
        # Rota inexistente: 404 mostra que a trava deixou passar sem mexer na fila real.
        assert c.post("/nao-existe", headers={"origin": origem}).status_code == 404
