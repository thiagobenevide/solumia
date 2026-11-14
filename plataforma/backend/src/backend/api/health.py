from fastapi import APIRouter
from pydantic import BaseModel

from backend import __version__
from backend.api.deps import SettingsDep

router = APIRouter(tags=["health"])


class HealthResponse(BaseModel):
    status: str
    app_name: str
    version: str
    environment: str


@router.get("/health", response_model=HealthResponse)
async def health(settings: SettingsDep) -> HealthResponse:
    """Health check de infraestrutura (usado por Docker/monitoramento).

    Não faz parte da API OpenAI-compatible — não deve ser exposto sob /v1.
    """
    return HealthResponse(
        status="ok",
        app_name=settings.app_name,
        version=__version__,
        environment=settings.environment,
    )
