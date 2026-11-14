from fastapi import APIRouter
from pydantic import BaseModel

from backend.api.deps import WorkerRegistryDep

router = APIRouter(tags=["models"])

# Lista mock (Etapa 2 do roadmap): usada só como fallback enquanto nenhum
# worker está conectado. Os IDs espelham os modelos atualmente servidos via
# LM Studio, para que extensões (VSCode, Continue.dev etc.) já consigam
# listar e selecionar modelos mesmo antes de haver um worker real.
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
