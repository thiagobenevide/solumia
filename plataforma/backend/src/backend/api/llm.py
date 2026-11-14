from typing import Any
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from backend.api.deps import require_client_api_key
from backend.core.llm_model import ModeloLLM
from backend.core.worker_registry import (
    WorkerDisconnected,
    WorkerRegistry,
    WorkerRespondedWithError,
)

router = APIRouter(
    prefix="/api/llm", tags=["llm"], dependencies=[Depends(require_client_api_key)]
)

# Carregar um .gguf na GPU pode levar minutos.
_TEMPO_CARGA_S = 330.0


class Troca(BaseModel):
    modelo: str


def _partes(request: Request) -> tuple[WorkerRegistry, ModeloLLM]:
    return request.app.state.worker_registry, request.app.state.modelo_llm


async def _no_worker(registry: WorkerRegistry) -> dict[str, Any]:
    """Pergunta ao worker os modelos (atualiza a lista), os carregados e os que processam."""
    worker = registry.pick_worker(None)
    if worker is None:
        return {}
    try:
        r = await registry.send_chat_request(worker, str(uuid4()), {"task": "listar_modelos"}, 15)
    except (TimeoutError, WorkerDisconnected, WorkerRespondedWithError):
        return {}
    registry.atualizar_modelos(worker.worker_id, list(r.get("modelos") or []))
    return r


def _em_uso(registry: WorkerRegistry, ocupados: list[str]) -> list[dict[str, Any]]:
    """Pedidos deste backend + modelos processando no llama-server sem pedido daqui: uso direto
    (a esteira fala com o llama-server sem passar pelo backend)."""
    nossos = registry.em_uso()
    modelos_nossos = {u["modelo"] for u in nossos}
    diretos = [
        {"origem": "Esteira (empreendimento)", "tarefa": "chat", "modelo": m, "ha_s": None}
        for m in ocupados
        if m not in modelos_nossos
    ]
    # Pedido nosso sem modelo explícito também ocupa o llama-server: não conta em dobro.
    return nossos + ([] if "" in modelos_nossos else diretos)


@router.get("")
async def estado(request: Request) -> dict[str, Any]:
    registry, modelo = _partes(request)
    w = await _no_worker(registry)
    return {
        "modelo": modelo.atual,
        "carregados": w.get("carregados") or [],
        "disponiveis": registry.all_models(),
        "workers": len(registry.descrever()),
        "em_uso": _em_uso(registry, w.get("ocupados") or []),
    }


@router.put("")
async def trocar(t: Troca, request: Request) -> dict[str, Any]:
    registry, modelo = _partes(request)
    em_uso = _em_uso(registry, (await _no_worker(registry)).get("ocupados") or [])
    if em_uso:
        origens = ", ".join(sorted({u["origem"] for u in em_uso}))
        raise HTTPException(
            409,
            {
                "message": f"O LLM está em uso por: {origens}. Espere terminar para trocar.",
                "type": "llm_em_uso",
                "em_uso": em_uso,
            },
        )
    worker = registry.pick_worker(None)
    if worker is None:
        raise HTTPException(503, "Nenhum worker conectado. Ligue o Worker no PC.")
    if t.modelo not in worker.available_models:
        raise HTTPException(422, f"Modelo '{t.modelo}' não existe no worker.")
    try:
        await registry.send_chat_request(
            worker,
            str(uuid4()),
            {"task": "carregar_modelo", "modelo": t.modelo},
            _TEMPO_CARGA_S,
            origem="Troca de modelo",
        )
    except TimeoutError as e:
        raise HTTPException(504, "O worker não terminou de carregar o modelo a tempo.") from e
    except (WorkerDisconnected, WorkerRespondedWithError) as e:
        raise HTTPException(502, str(e)) from e
    modelo.trocar(t.modelo)
    return await estado(request)
