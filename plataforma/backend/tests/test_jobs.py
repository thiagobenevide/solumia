from datetime import date
from typing import Any

from exams.jobs import Slots


async def test_search_merges_jobs_and_keeps_state(tmp_path):
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

    await slots.search_claude(executar)
    # 2 areas × 4 source groups; the same opening found in several rounds becomes one
    assert len(requests) == 8
    assert "2026-11-03" in requests[0]["prompt"] and "LinkedIn" in requests[0]["prompt"]
    [v] = slots.list_all()["vagas"]
    assert v["estado"] == "nova" and v["area"] == "Desenvolvimento de software"

    slots.marcar(v["id"], "candidatei")
    await slots.search_claude(executar)
    assert slots.list_all()["vagas"][0]["estado"] == "candidatei"
    assert slots.remover(v["id"]) and slots.list_all()["vagas"] == []


async def test_followed_companies_get_round_and_failure_keeps_others(tmp_path):
    slots = Slots(tmp_path)
    slots.save_profile({"areas": ["Engenharia de dados"], "empresas": ["Nubank"]})
    prompts: list[str] = []

    async def executar(pedido: dict[str, Any]) -> dict[str, Any]:
        prompts.append(pedido["prompt"])
        if len(prompts) == 1:
            raise RuntimeError("tempo esgotado")
        return {"vagas": [{"titulo": f"Data engineer {len(prompts)}", "empresa": "X"}]}

    r = await slots.search_claude(executar)
    assert len(prompts) == 5 and "Nubank" in prompts[-1]
    assert r == {"achadas": 4} and "tempo esgotado" in slots.list_all()["claude"]["erro"]


def test_saved_profile_filled_with_default(tmp_path):
    slots = Slots(tmp_path)
    profile = slots.save_profile({"cargos": "Dados"})
    assert profile["cargos"] == "Dados" and profile["local"]
    assert slots.list_all()["perfil"]["cargos"] == "Dados"


async def test_empty_city_removes_distance_limit(tmp_path):
    slots = Slots(tmp_path)
    slots.save_profile({"local": "", "areas": ["Dados"]})
    prompts: list[str] = []

    async def executar(pedido: dict[str, Any]) -> dict[str, Any]:
        prompts.append(pedido["prompt"])
        return {"vagas": []}

    await slots.search_claude(executar)
    assert all("all of Brazil" in p and "300 km" not in p for p in prompts)


def test_root_with_tilde_is_expanded(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    Slots("~/dados").save_profile({})
    assert (tmp_path / "dados" / "vagas" / "vagas.json").exists()


class GeoFalso:
    async def municipio(self, cidade: str, uf: str) -> dict[str, Any] | None:
        if cidade == "Recife":
            return {"cidade": "Recife", "uf": uf, "lat": -8.05, "lon": -34.9, "aproximado": False}
        return {"cidade": "Capital", "uf": uf, "lat": -1.0, "lon": -1.0, "aproximado": True}


async def test_jobs_get_contract_and_map_place(tmp_path):
    slots = Slots(tmp_path, geo=GeoFalso())  # type: ignore[arg-type]

    async def executar(pedido: dict[str, Any]) -> dict[str, Any]:
        return {
            "vagas": [
                {"titulo": "Dev", "empresa": "A", "local": "Recife/PE", "contrato": "pj"},
                {"titulo": "Dados", "empresa": "B", "cidade": "", "uf": "sp", "contrato": "clt"},
                {"titulo": "Remota", "empresa": "C", "local": "Remoto (Brasil)"},
            ]
        }

    await slots.search_claude(executar)
    by_title = {v["titulo"]: v for v in slots.list_all()["vagas"]}
    assert by_title["Dev"]["contrato"] == "pj" and by_title["Dev"]["geo"]["cidade"] == "Recife"
    assert by_title["Dados"]["geo"]["aproximado"] and by_title["Dados"]["geo"]["uf"] == "SP"
    assert by_title["Remota"]["geo"] == {}


def test_resumes_start_from_template_and_have_default(tmp_path):
    slots = Slots(tmp_path)
    [model] = slots.resumes.list_all()["curriculos"]
    assert model["padrao"] and "Thiago" in slots.resumes.ler(model["id"])["conteudo"]

    new = slots.resumes.salvar(None, "Currículo de dados", "# Dados")
    assert not new["padrao"] and slots.resumes.definir_default(new["id"])
    assert slots.resumes.list_all()["curriculos"][0]["id"] == new["id"]
    assert slots.resumes.remover(new["id"])
    assert slots.resumes.default()["id"] == model["id"]
    assert slots.resumes.ler("../vagas") is None


async def test_resume_generated_for_job_starts_from_default(tmp_path):
    slots = Slots(tmp_path)
    requests: list[dict[str, Any]] = []

    async def pesquisa(pedido: dict[str, Any]) -> dict[str, Any]:
        return {"vagas": [{"titulo": "Dev Python", "empresa": "Acme", "url": "https://a/1"}]}

    async def gerar(pedido: dict[str, Any]) -> dict[str, Any]:
        requests.append(pedido)
        return {"markdown": "# Thiago para Acme"}

    await slots.search_claude(pesquisa)
    [v] = slots.list_all()["vagas"]
    c = await slots.generate_resume(v["id"], gerar)
    assert "Base résumé" in requests[0]["prompt"] and "Dev Python" in requests[0]["prompt"]
    assert slots.list_all()["vagas"][0]["curriculo"] == c["id"] == f"vaga-{v['id']}"
    assert slots.resumes.ler(c["id"])["vaga"] == v["id"] and not slots.generating
