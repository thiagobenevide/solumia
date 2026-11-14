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

# Loading a .gguf onto the GPU can take minutes.
_TIME_LOAD_S = 330.0


class Swap(BaseModel):
    modelo: str


def _parts(request: Request) -> tuple[WorkerRegistry, ModelLLM]:
    return request.app.state.worker_registry, request.app.state.modelo_llm


async def _on_worker(registry: WorkerRegistry) -> dict[str, Any]:
    """Asks the worker for the models (refreshes the list), the loaded ones and the busy ones."""
    worker = registry.pick_worker(None)
    if worker is None:
        return {}
    try:
        r = await registry.send_chat_request(worker, str(uuid4()), {"task": "listar_modelos"}, 15)
    except (TimeoutError, WorkerDisconnected, WorkerRespondedWithError):
        return {}
    registry.update_models(worker.worker_id, list(r.get("modelos") or []))
    return r


def _in_use(registry: WorkerRegistry, ocupados: list[str]) -> list[dict[str, Any]]:
    """Requests of this backend + models processing on llama-server without a request from here:
    direct use (the pipeline talks to llama-server without going through the backend)."""
    nossos = registry.in_usage()
    models_nossos = {u["modelo"] for u in nossos}
    diretos = [
        {"origem": "Esteira (empreendimento)", "tarefa": "chat", "modelo": m, "ha_s": None}
        for m in ocupados
        if m not in models_nossos
    ]
    # Our own request without an explicit model also occupies llama-server: do not count it twice.
    return nossos + ([] if "" in models_nossos else diretos)


@router.get("")
async def state(request: Request) -> dict[str, Any]:
    registry, model = _parts(request)
    w = await _on_worker(registry)
    return {
        "modelo": model.atual,
        "carregados": w.get("carregados") or [],
        "disponiveis": registry.all_models(),
        "workers": len(registry.describe()),
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
    model.swap(t.modelo)
    return await state(request)
