from datetime import date
from typing import Any

from concursos.jobs import Slots


async def test_pesquisa_junta_vagas_e_mantem_estado(tmp_path):
    slots = Slots(tmp_path, hoje=lambda: date(2026, 11, 3))
    requests: list[dict[str, Any]] = []
    slot = {
        "titulo": "Dev Python",
        "empresa": "Acme",
        "modalidade": "remoto",
        "url": "https://acme.com/vaga/1",
        "resumo": "FastAPI",
    }

    async def executar(pedido: dict[str, Any]) -> dict[str, Any]:
        requests.append(pedido)
        return {"vagas": [slot, {"titulo": ""}]}

    await slots.pesquisar_claude(executar)
    # 2 áreas × 4 grupos de fontes; a mesma vaga achada em várias rodadas vira uma só
    assert len(requests) == 8
    assert "2026-11-03" in requests[0]["prompt"] and "LinkedIn" in requests[0]["prompt"]
    [v] = slots.listar()["vagas"]
    assert v["estado"] == "nova" and v["area"] == "Desenvolvimento de software"

    slots.marcar(v["id"], "candidatei")
    await slots.pesquisar_claude(executar)
    assert slots.listar()["vagas"][0]["estado"] == "candidatei"
    assert slots.remover(v["id"]) and slots.listar()["vagas"] == []


async def test_empresas_acompanhadas_ganham_rodada_e_falha_nao_perde_as_outras(tmp_path):
    slots = Slots(tmp_path)
    slots.salvar_perfil({"areas": ["Engenharia de dados"], "empresas": ["Nubank"]})
    prompts: list[str] = []

    async def executar(pedido: dict[str, Any]) -> dict[str, Any]:
        prompts.append(pedido["prompt"])
        if len(prompts) == 1:
            raise RuntimeError("tempo esgotado")
        return {"vagas": [{"titulo": f"Data engineer {len(prompts)}", "empresa": "X"}]}

    r = await slots.pesquisar_claude(executar)
    assert len(prompts) == 5 and "Nubank" in prompts[-1]
    assert r == {"achadas": 4} and "tempo esgotado" in slots.listar()["claude"]["erro"]


def test_perfil_salvo_completa_com_padrao(tmp_path):
    slots = Slots(tmp_path)
    profile = slots.salvar_perfil({"cargos": "Dados"})
    assert profile["cargos"] == "Dados" and profile["local"]
    assert slots.listar()["perfil"]["cargos"] == "Dados"


async def test_cidade_vazia_tira_o_limite_de_distancia(tmp_path):
    slots = Slots(tmp_path)
    slots.salvar_perfil({"local": "", "areas": ["Dados"]})
    prompts: list[str] = []

    async def executar(pedido: dict[str, Any]) -> dict[str, Any]:
        prompts.append(pedido["prompt"])
        return {"vagas": []}

    await slots.pesquisar_claude(executar)
    assert all("Brasil todo" in p and "300 km" not in p for p in prompts)


def test_raiz_com_til_e_expandida(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    Slots("~/dados").salvar_perfil({})
    assert (tmp_path / "dados" / "vagas" / "vagas.json").exists()


class GeoFalso:
    async def municipio(self, cidade: str, uf: str) -> dict[str, Any] | None:
        if cidade == "Recife":
            return {"cidade": "Recife", "uf": uf, "lat": -8.05, "lon": -34.9, "aproximado": False}
        return {"cidade": "Capital", "uf": uf, "lat": -1.0, "lon": -1.0, "aproximado": True}


async def test_vagas_ganham_contrato_e_lugar_no_mapa(tmp_path):
    slots = Slots(tmp_path, geo=GeoFalso())  # type: ignore[arg-type]

    async def executar(pedido: dict[str, Any]) -> dict[str, Any]:
        return {
            "vagas": [
                {"titulo": "Dev", "empresa": "A", "local": "Recife/PE", "contrato": "pj"},
                {"titulo": "Dados", "empresa": "B", "cidade": "", "uf": "sp", "contrato": "clt"},
                {"titulo": "Remota", "empresa": "C", "local": "Remoto (Brasil)"},
            ]
        }

    await slots.pesquisar_claude(executar)
    by_title = {v["titulo"]: v for v in slots.listar()["vagas"]}
    assert by_title["Dev"]["contrato"] == "pj" and by_title["Dev"]["geo"]["cidade"] == "Recife"
    assert by_title["Dados"]["geo"]["aproximado"] and by_title["Dados"]["geo"]["uf"] == "SP"
    assert by_title["Remota"]["geo"] == {}


def test_curriculos_comecam_pelo_modelo_e_tem_um_padrao(tmp_path):
    slots = Slots(tmp_path)
    [model] = slots.curriculos.listar()["curriculos"]
    assert model["padrao"] and "Thiago" in slots.curriculos.ler(model["id"])["conteudo"]

    new = slots.curriculos.salvar(None, "Currículo de dados", "# Dados")
    assert not new["padrao"] and slots.curriculos.definir_padrao(new["id"])
    assert slots.curriculos.listar()["curriculos"][0]["id"] == new["id"]
    assert slots.curriculos.remover(new["id"])
    assert slots.curriculos.padrao()["id"] == model["id"]
    assert slots.curriculos.ler("../vagas") is None


async def test_curriculo_gerado_para_a_vaga_parte_do_padrao(tmp_path):
    slots = Slots(tmp_path)
    requests: list[dict[str, Any]] = []

    async def pesquisa(pedido: dict[str, Any]) -> dict[str, Any]:
        return {"vagas": [{"titulo": "Dev Python", "empresa": "Acme", "url": "https://a/1"}]}

    async def gerar(pedido: dict[str, Any]) -> dict[str, Any]:
        requests.append(pedido)
        return {"markdown": "# Thiago para Acme"}

    await slots.pesquisar_claude(pesquisa)
    [v] = slots.listar()["vagas"]
    c = await slots.gerar_curriculo(v["id"], gerar)
    assert "Currículo base" in requests[0]["prompt"] and "Dev Python" in requests[0]["prompt"]
    assert slots.listar()["vagas"][0]["curriculo"] == c["id"] == f"vaga-{v['id']}"
    assert slots.curriculos.ler(c["id"])["vaga"] == v["id"] and not slots.gerando
