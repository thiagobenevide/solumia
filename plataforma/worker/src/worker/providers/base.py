from abc import ABC, abstractmethod
from typing import Any


class Provider(ABC):
    """Abstraction over the local LLM backend (LM Studio, Ollama, vLLM, ...).

    The WorkerClient never talks to a specific backend directly — only to this
    interface, so new implementations (OllamaProvider, VLLMProvider, ...) can be
    added without changing the rest of the Worker.
    """

    @abstractmethod
    async def list_models(self) -> list[str]:
        """Lists the model ids currently available on the local backend."""

    @abstractmethod
    async def chat_completion(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Runs a chat completion (OpenAI-compatible payload) and returns the raw response."""

    async def estado(self) -> dict[str, Any]:
        """Models available, loaded and busy (processing) right now."""
        return {"modelos": await self.list_models(), "carregados": [], "ocupados": []}

    async def load(self, modelo: str) -> dict[str, Any]:
        """Switches the loaded model (requested by the app, through the Gateway)."""
        raise NotImplementedError("Este provider não troca de modelo")
