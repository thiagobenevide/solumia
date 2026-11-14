from abc import ABC, abstractmethod
from typing import Any


class Provider(ABC):
    """Abstração sobre o backend local de LLM (LM Studio, Ollama, vLLM, ...).

    O WorkerClient nunca fala diretamente com um backend específico — só com
    esta interface, para que novas implementações (OllamaProvider,
    VLLMProvider, ...) possam ser adicionadas sem alterar o resto do Worker.
    """

    @abstractmethod
    async def list_models(self) -> list[str]:
        """Lista os ids de modelo atualmente disponíveis no backend local."""

    @abstractmethod
    async def chat_completion(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Executa um chat completion (payload OpenAI-compatible) e retorna a resposta crua."""

    async def estado(self) -> dict[str, Any]:
        """Modelos disponíveis, carregados e ocupados (processando) agora."""
        return {"modelos": await self.list_models(), "carregados": [], "ocupados": []}

    async def carregar(self, modelo: str) -> dict[str, Any]:
        """Troca o modelo carregado (pedido pelo app, via Gateway)."""
        raise NotImplementedError("Este provider não troca de modelo")
