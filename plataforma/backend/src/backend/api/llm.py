from typing import Any
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from backend.api.deps import require_client_api_key
from backend.core.llm_model import ModelLLM
from backend.core.worker_registry import (
    WorkerDisconnected,
    WorkerRegistry,
    WorkerRespondedWithError,
)

router = APIRouter(
    prefix="/api/llm", tags=["llm"], dependencies=[Depends(require_client_api_key)]
)

# Carregar um .gguf na GPU pode levar minutos.
_TIME_LOAD_S = 330.0


class Swap(BaseModel):
    modelo: str


def _parts(request: Request) -> tuple[WorkerRegistry, ModelLLM]:
    return request.app.state.worker_registry, request.app.state.modelo_llm


async def _on_worker(registry: WorkerRegistry) -> dict[str, Any]:
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


def _in_use(registry: WorkerRegistry, ocupados: list[str]) -> list[dict[str, Any]]:
    """Pedidos deste backend + modelos processando no llama-server sem pedido daqui: uso direto
    (a esteira fala com o llama-server sem passar pelo backend)."""
    nossos = registry.em_uso()
    models_nossos = {u["modelo"] for u in nossos}
    diretos = [
        {"origem": "Esteira (empreendimento)", "tarefa": "chat", "modelo": m, "ha_s": None}
        for m in ocupados
        if m not in models_nossos
    ]
    # Pedido nosso sem modelo explícito também ocupa o llama-server: não conta em dobro.
    return nossos + ([] if "" in models_nossos else diretos)


@router.get("")
async def state(request: Request) -> dict[str, Any]:
    registry, model = _parts(request)
    w = await _on_worker(registry)
    return {
        "modelo": model.atual,
        "carregados": w.get("carregados") or [],
        "disponiveis": registry.all_models(),
        "workers": len(registry.descrever()),
        "em_uso": _in_use(registry, w.get("ocupados") or []),
    }


@router.put("")
async def swap(t: Swap, request: Request) -> dict[str, Any]:
    registry, model = _parts(request)
    in_usage = _in_use(registry, (await _on_worker(registry)).get("ocupados") or [])
    if in_usage:
        origins = ", ".join(sorted({u["origem"] for u in in_usage}))
        raise HTTPException(
            409,
            {
                "message": f"O LLM está em uso por: {origins}. Espere terminar para trocar.",
                "type": "llm_em_uso",
                "em_uso": in_usage,
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
            _TIME_LOAD_S,
            origem="Troca de modelo",
        )
    except TimeoutError as e:
        raise HTTPException(504, "O worker não terminou de carregar o modelo a tempo.") from e
    except (WorkerDisconnected, WorkerRespondedWithError) as e:
        raise HTTPException(502, str(e)) from e
    model.trocar(t.modelo)
    return await state(request)
