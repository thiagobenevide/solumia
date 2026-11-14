from datetime import date
from typing import Any

from concursos.vagas import Vagas


async def test_pesquisa_junta_vagas_e_mantem_estado(tmp_path):
    vagas = Vagas(tmp_path, hoje=lambda: date(2026, 11, 3))
    pedidos: list[dict[str, Any]] = []
    vaga = {
        "titulo": "Dev Python",
        "empresa": "Acme",
        "modalidade": "remoto",
        "url": "https://acme.com/vaga/1",
        "resumo": "FastAPI",
    }

    async def executar(pedido: dict[str, Any]) -> dict[str, Any]:
        pedidos.append(pedido)
        return {"vagas": [vaga, {"titulo": ""}]}

    await vagas.pesquisar_claude(executar)
    # 2 áreas × 4 grupos de fontes; a mesma vaga achada em várias rodadas vira uma só
    assert len(pedidos) == 8
    assert "2026-11-03" in pedidos[0]["prompt"] and "LinkedIn" in pedidos[0]["prompt"]
    [v] = vagas.listar()["vagas"]
    assert v["estado"] == "nova" and v["area"] == "Desenvolvimento de software"

    vagas.marcar(v["id"], "candidatei")
    await vagas.pesquisar_claude(executar)
    assert vagas.listar()["vagas"][0]["estado"] == "candidatei"
    assert vagas.remover(v["id"]) and vagas.listar()["vagas"] == []


async def test_empresas_acompanhadas_ganham_rodada_e_falha_nao_perde_as_outras(tmp_path):
    vagas = Vagas(tmp_path)
    vagas.salvar_perfil({"areas": ["Engenharia de dados"], "empresas": ["Nubank"]})
    prompts: list[str] = []

    async def executar(pedido: dict[str, Any]) -> dict[str, Any]:
        prompts.append(pedido["prompt"])
        if len(prompts) == 1:
            raise RuntimeError("tempo esgotado")
        return {"vagas": [{"titulo": f"Data engineer {len(prompts)}", "empresa": "X"}]}

    r = await vagas.pesquisar_claude(executar)
    assert len(prompts) == 5 and "Nubank" in prompts[-1]
    assert r == {"achadas": 4} and "tempo esgotado" in vagas.listar()["claude"]["erro"]


def test_perfil_salvo_completa_com_padrao(tmp_path):
    vagas = Vagas(tmp_path)
    perfil = vagas.salvar_perfil({"cargos": "Dados"})
    assert perfil["cargos"] == "Dados" and perfil["local"]
    assert vagas.listar()["perfil"]["cargos"] == "Dados"


async def test_cidade_vazia_tira_o_limite_de_distancia(tmp_path):
    vagas = Vagas(tmp_path)
    vagas.salvar_perfil({"local": "", "areas": ["Dados"]})
    prompts: list[str] = []

    async def executar(pedido: dict[str, Any]) -> dict[str, Any]:
        prompts.append(pedido["prompt"])
        return {"vagas": []}

    await vagas.pesquisar_claude(executar)
    assert all("Brasil todo" in p and "300 km" not in p for p in prompts)


def test_raiz_com_til_e_expandida(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    Vagas("~/dados").salvar_perfil({})
    assert (tmp_path / "dados" / "vagas" / "vagas.json").exists()


class GeoFalso:
    async def municipio(self, cidade: str, uf: str) -> dict[str, Any] | None:
        if cidade == "Recife":
            return {"cidade": "Recife", "uf": uf, "lat": -8.05, "lon": -34.9, "aproximado": False}
        return {"cidade": "Capital", "uf": uf, "lat": -1.0, "lon": -1.0, "aproximado": True}


async def test_vagas_ganham_contrato_e_lugar_no_mapa(tmp_path):
    vagas = Vagas(tmp_path, geo=GeoFalso())  # type: ignore[arg-type]

    async def executar(pedido: dict[str, Any]) -> dict[str, Any]:
        return {
            "vagas": [
                {"titulo": "Dev", "empresa": "A", "local": "Recife/PE", "contrato": "pj"},
                {"titulo": "Dados", "empresa": "B", "cidade": "", "uf": "sp", "contrato": "clt"},
                {"titulo": "Remota", "empresa": "C", "local": "Remoto (Brasil)"},
            ]
        }

    await vagas.pesquisar_claude(executar)
    por_titulo = {v["titulo"]: v for v in vagas.listar()["vagas"]}
    assert por_titulo["Dev"]["contrato"] == "pj" and por_titulo["Dev"]["geo"]["cidade"] == "Recife"
    assert por_titulo["Dados"]["geo"]["aproximado"] and por_titulo["Dados"]["geo"]["uf"] == "SP"
    assert por_titulo["Remota"]["geo"] == {}


def test_curriculos_comecam_pelo_modelo_e_tem_um_padrao(tmp_path):
    vagas = Vagas(tmp_path)
    [modelo] = vagas.curriculos.listar()["curriculos"]
    assert modelo["padrao"] and "Thiago" in vagas.curriculos.ler(modelo["id"])["conteudo"]

    novo = vagas.curriculos.salvar(None, "Currículo de dados", "# Dados")
    assert not novo["padrao"] and vagas.curriculos.definir_padrao(novo["id"])
    assert vagas.curriculos.listar()["curriculos"][0]["id"] == novo["id"]
    assert vagas.curriculos.remover(novo["id"])
    assert vagas.curriculos.padrao()["id"] == modelo["id"]
    assert vagas.curriculos.ler("../vagas") is None


async def test_curriculo_gerado_para_a_vaga_parte_do_padrao(tmp_path):
    vagas = Vagas(tmp_path)
    pedidos: list[dict[str, Any]] = []

    async def pesquisa(pedido: dict[str, Any]) -> dict[str, Any]:
        return {"vagas": [{"titulo": "Dev Python", "empresa": "Acme", "url": "https://a/1"}]}

    async def gerar(pedido: dict[str, Any]) -> dict[str, Any]:
        pedidos.append(pedido)
        return {"markdown": "# Thiago para Acme"}

    await vagas.pesquisar_claude(pesquisa)
    [v] = vagas.listar()["vagas"]
    c = await vagas.gerar_curriculo(v["id"], gerar)
    assert "Currículo base" in pedidos[0]["prompt"] and "Dev Python" in pedidos[0]["prompt"]
    assert vagas.listar()["vagas"][0]["curriculo"] == c["id"] == f"vaga-{v['id']}"
    assert vagas.curriculos.ler(c["id"])["vaga"] == v["id"] and not vagas.gerando
