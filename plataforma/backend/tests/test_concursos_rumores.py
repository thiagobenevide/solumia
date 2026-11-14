import asyncio
from datetime import date
from pathlib import Path
from typing import Any

from concursos.rumors import Rumores

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


def test_busca_acompanha_e_novidade_vira_alerta(tmp_path: Path) -> None:
    rumores = Rumores(tmp_path, hoje=lambda: date.today())
    pedidos: list[dict[str, Any]] = []

    async def executar(p: dict[str, Any]) -> dict[str, Any]:
        pedidos.append(p)
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

    assert asyncio.run(rumores.pesquisar(executar, "TRF5")) == {"achados": 1}
    assert '"TRF5"' in pedidos[0]["prompt"]
    assert len(pedidos) == 1  # sem acompanhados não reverifica
    [item] = rumores.listar()["itens"]
    assert item["id"] == "trf-5-regi-o-pe" and item["fontes"][0]["url"] == RUMOR["fonte_url"]
    assert rumores.alertas() == []

    rumores.acompanhar(item["id"], True)
    asyncio.run(rumores.pesquisar(executar))
    item = rumores.listar()["itens"][0]
    assert item["fase"] == "autorizado"
    assert [n["texto"] for n in item["novidades"]] == ["Concurso autorizado"]
    [alerta] = rumores.alertas()
    assert alerta["texto"] == "Rumor TRF 5ª Região: Concurso autorizado"
    assert alerta["concurso"] == "TRF 5ª Região"
    # a mesma novidade não entra de novo
    asyncio.run(rumores.pesquisar(executar))
    assert len(rumores.listar()["itens"][0]["novidades"]) == 1
