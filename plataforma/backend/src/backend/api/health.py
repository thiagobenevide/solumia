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
    """Infrastructure health check (used by Docker/monitoring).

    Not part of the OpenAI-compatible API — must not be exposed under /v1.
    """
    return HealthResponse(
        status="ok",
        app_name=settings.app_name,
        version=__version__,
        environment=settings.environment,
    )
