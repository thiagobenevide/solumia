from fastapi import APIRouter
from pydantic import BaseModel

from backend.api.deps import WorkerRegistryDep

router = APIRouter(tags=["models"])

# Mock list (roadmap Stage 2): used only as a fallback while no worker is
# connected. The IDs mirror the models currently served through LM Studio,
# so extensions (VSCode, Continue.dev etc.) can already list and select
# models even before there is a real worker.
_MOCK_MODEL_IDS = [
    "openai/gpt-oss-20b",
    "deepseek-v4-flash-0731",
    "google/gemma-4-12b-qat",
    "qwen/qwen3.5-9b",
    "text-embedding-nomic-embed-text-v1.5",
]


class Model(BaseModel):
    id: str
    object: str = "model"
    owned_by: str = "organization_owner"


class ModelList(BaseModel):
    object: str = "list"
    data: list[Model]


@router.get("/models", response_model=ModelList)
async def list_models(registry: WorkerRegistryDep) -> ModelList:
    model_ids = registry.all_models() or _MOCK_MODEL_IDS
    return ModelList(data=[Model(id=model_id) for model_id in model_ids])
