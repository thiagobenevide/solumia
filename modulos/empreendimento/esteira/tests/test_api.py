"""API JSON do app Flutter: validações que não dependem dos episódios da máquina."""
from esteira.web.app import app
from fastapi.testclient import TestClient

c = TestClient(app, base_url="http://localhost")


def test_missing_episode_returns_404():
    assert c.get("/api/v1/episodios/canal-que-nao-existe-999").status_code == 404
    assert c.post("/api/v1/episodios/canal-que-nao-existe-999/rodar/all").status_code == 404


def test_produce_rejects_script_outside_vault():
    r = c.post("/api/v1/produzir", json={"roteiros": ["/etc/passwd"]})
    assert r.status_code == 400


def test_cors_libera_o_app_local():
    r = c.options("/api/v1/canais", headers={"Origin": "http://localhost:51234",
                                             "Access-Control-Request-Method": "GET"})
    assert r.headers["access-control-allow-origin"] == "http://localhost:51234"
    r = c.options("/api/v1/canais", headers={"Origin": "https://site-qualquer.com",
                                             "Access-Control-Request-Method": "GET"})
    assert "access-control-allow-origin" not in r.headers


def test_action_validations():
    assert c.post("/api/v1/roteiros/gerar", json={"alvo": "sem-numero"}).status_code == 400
    assert c.post("/api/v1/opcoes", json={"engine": "gpt"}).status_code == 400
    assert c.post("/api/v1/opcoes/baixar", json={"nome": "rm -rf /"}).status_code == 400
    assert c.post("/api/v1/processos/nao-existe/parar").status_code == 404
    for route in ("roteiro", "cortes", "cenas", "graficos", "thumbs", "editor/grafico/0", "editor/thumb"):
        assert c.get(f"/api/v1/episodios/canal-que-nao-existe-999/{route}").status_code == 404, route


def test_system_readings_respond():
    for route in ("meta", "monitor", "grafo", "processos?limite=1", "custos", "acervo?limite=1", "opcoes/baixando"):
        assert c.get(f"/api/v1/{route}").status_code == 200, route


def test_studio_episode_uses_studio_final(tmp_path, monkeypatch):
    import os

    from esteira.web import api
    from esteira.web import app as painel
    folder = tmp_path / "canal" / "001"
    (folder / "estudio" / "16x9").mkdir(parents=True)
    monkeypatch.setattr(painel, "folder_ep", lambda ep: folder)
    monkeypatch.setattr(api, "folder_ep", lambda ep: folder)
    monkeypatch.setattr(painel, "Project", lambda p: type("P", (), {"cfg": {"video": {"formato": "16:9"}}}))
    old, new = folder / "final.mp4", folder / "estudio" / "16x9" / "final.mp4"
    plan = folder / "plano.json"
    for n, a in enumerate((old, plan, new, new.with_name("previa.mp4"))):
        a.write_text("x")
        os.utime(a, (n + 1, n + 1))
    r = painel._summary_ep("canal-001")
    assert r["final"] and not r["desatualizado"] and r["feitas"] == 2  # graficos e montar: o Estúdio os substitui
    assert api._video_light("canal-001", painel.final_of_ep(folder)).startswith("/arq/canal-001/estudio/16x9/previa.mp4")
    os.utime(plan, (9, 9))
    assert painel._summary_ep("canal-001")["desatualizado"]


def test_rejects_foreign_host_and_post_from_other_site():
    # DNS rebinding: o navegador manda o Host do domínio do atacante.
    assert c.get("/api/sistema", headers={"host": "atacante.com"}).status_code == 403
    # CSRF: formulário de outro site para a esteira local.
    r = c.post("/fila/limpar", headers={"origin": "https://atacante.com"})
    assert r.status_code == 403
    assert c.post("/fila/limpar", headers={"origin": "null"}).status_code == 403


def test_accepts_local_origin_and_domain():
    for origin in ("http://127.0.0.1:8765", "https://solumialocal.thiagobenevide.com"):
        # Rota inexistente: 404 mostra que a trava deixou passar sem mexer na fila real.
        assert c.post("/nao-existe", headers={"origin": origin}).status_code == 404
