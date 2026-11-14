import asyncio
from datetime import date
from pathlib import Path
from typing import Any

from exams.rumors import Rumors

RUMOR = {
    "orgao": "TRF 5ª Região",
    "uf": "PE",
    "esfera": "federal",
    "fase": "solicitado",
    "cargos_ti": ["Analista Judiciário - TI"],
    "fonte_nome": "PCI",
    "fonte_url": "https://exemplo/trf5",
    "resumo": "Pedido enviado ao CJF.",
}


def test_search_follow_and_news_becomes_alert(tmp_path: Path) -> None:
    rumors = Rumors(tmp_path, hoje=lambda: date.today())
    requests: list[dict[str, Any]] = []

    async def executar(p: dict[str, Any]) -> dict[str, Any]:
        requests.append(p)
        if "novidades" in p["esquema"]["properties"]:
            return {
                "novidades": [
                    {
                        "id": "trf-5-regi-o-pe",
                        "fase": "autorizado",
                        "texto": "Concurso autorizado",
                        "fonte_url": "https://exemplo/aut",
                    },
                    {"id": "outro", "texto": "x", "fonte_url": "y"},
                ]
            }
        return {"rumores": [RUMOR, {"orgao": "sem fonte"}]}

    assert asyncio.run(rumors.pesquisar(executar, "TRF5")) == {"achados": 1}
    assert '"TRF5"' in requests[0]["prompt"]
    assert len(requests) == 1  # without followed ones it does not recheck
    [item] = rumors.list_all()["itens"]
    assert item["id"] == "trf-5-regi-o-pe" and item["fontes"][0]["url"] == RUMOR["fonte_url"]
    assert rumors.alerts() == []

    rumors.track(item["id"], True)
    asyncio.run(rumors.pesquisar(executar))
    item = rumors.list_all()["itens"][0]
    assert item["fase"] == "autorizado"
    assert [n["texto"] for n in item["novidades"]] == ["Concurso autorizado"]
    [alerta] = rumors.alerts()
    assert alerta["texto"] == "Rumor TRF 5ª Região: Concurso autorizado"
    assert alerta["concurso"] == "TRF 5ª Região"
    # the same news does not come in again
    asyncio.run(rumors.pesquisar(executar))
    assert len(rumors.list_all()["itens"][0]["novidades"]) == 1
