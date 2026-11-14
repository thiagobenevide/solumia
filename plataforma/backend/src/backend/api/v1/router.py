from fastapi import APIRouter, Depends

from backend.api.deps import require_client_api_key
from backend.api.v1.chat import router as chat_router
from backend.api.v1.models import router as models_router

# Agrega os endpoints OpenAI-compatible (GET /v1/models, POST /v1/chat/completions,
# POST /v1/responses, POST /v1/embeddings, ...), added from Stage 2 on.
# `dependencies=[Depends(require_client_api_key)]` protege TODO endpoint /v1/*
# with Authorization: Bearer <key> — /health stays out on purpose (used by the
# Docker healthcheck, without auth headers).
router = APIRouter(prefix="/v1", dependencies=[Depends(require_client_api_key)])
router.include_router(models_router)
router.include_router(chat_router)
