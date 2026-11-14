import asyncio
import logging
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from fastapi import WebSocket

from shared.protocol import ChatRequest

logger = logging.getLogger("gateway.worker_registry")


class WorkerDisconnected(Exception):
    """O worker que estava processando o request caiu antes de responder."""


class WorkerRespondedWithError(Exception):
    """O worker respondeu explicitamente com uma mensagem de erro."""


@dataclass
class ConnectedWorker:
    worker_id: str
    websocket: WebSocket
    available_models: list[str]
    last_seen: float = field(default_factory=time.monotonic)
    recursos: dict[str, Any] | None = None
    conectado_em: float = field(default_factory=time.time)


class WorkerRegistry:
    """Registro em memória dos workers conectados neste processo.

    Single-node, sem persistência: se o processo do Gateway reiniciar, todos
    os workers precisam reconectar (comportamento aceitável nesta etapa —
    Postgres/Redis para presença distribuída ficam para etapas futuras).
    """

    def __init__(self) -> None:
        self._workers: dict[str, ConnectedWorker] = {}
        self._pending: dict[str, tuple[str, asyncio.Future[dict[str, Any]]]] = {}
        self._em_uso: dict[str, dict[str, Any]] = {}
        """Pedidos com origem (módulo) em andamento: enquanto houver, não se troca o modelo."""
        self.ao_medir: Callable[[dict[str, Any]], None] | None = None
        """Chamado ao fim de cada pedido ao worker (dashboard das LLMs): latência, erro, tokens."""
        self.ouvintes: dict[str, Callable[[dict[str, Any]], None]] = {}
        """Canal → quem recebe os `evento` do worker (ex.: `codigo`, etapas do Claude Code)."""

    def register(
        self, worker_id: str, websocket: WebSocket, available_models: list[str]
    ) -> ConnectedWorker:
        worker = ConnectedWorker(
            worker_id=worker_id, websocket=websocket, available_models=available_models
        )
        self._workers[worker_id] = worker
        logger.info("Worker conectado: %s (modelos=%s)", worker_id, available_models)
        return worker

    async def unregister(self, worker_id: str) -> None:
        worker = self._workers.pop(worker_id, None)
        if worker is None:
            return
        logger.info("Worker desconectado: %s", worker_id)
        pending_request_ids = [
            request_id
            for request_id, (owner_id, _) in self._pending.items()
            if owner_id == worker_id
        ]
        for request_id in pending_request_ids:
            self.reject(
                request_id, WorkerDisconnected(f"Worker {worker_id} desconectou antes de responder")
            )

    def touch(self, worker_id: str, recursos: dict[str, Any] | None = None) -> None:
        worker = self._workers.get(worker_id)
        if worker is not None:
            worker.last_seen = time.monotonic()
            if recursos is not None:
                worker.recursos = recursos

    def descrever(self) -> list[dict[str, Any]]:
        """Workers conectados, para o dashboard: modelos, último sinal e uso da máquina."""
        agora = time.monotonic()
        return [
            {
                "id": w.worker_id,
                "modelos": w.available_models,
                "visto_ha_s": round(agora - w.last_seen, 1),
                "conectado_em": w.conectado_em,
                "recursos": w.recursos,
            }
            for w in self._workers.values()
        ]

    def pick_worker(self, model: str | None) -> ConnectedWorker | None:
        if not self._workers:
            return None
        if model:
            for worker in self._workers.values():
                if model in worker.available_models:
                    return worker
        return next(iter(self._workers.values()))

    def em_uso(self) -> list[dict[str, Any]]:
        """Quem está usando o LLM agora (módulo, tarefa, modelo, há quantos segundos)."""
        agora = time.monotonic()
        return [
            {
                "origem": u["origem"],
                "tarefa": u["tarefa"],
                "modelo": u["modelo"],
                "ha_s": round(agora - u["inicio"], 1),
            }
            for u in self._em_uso.values()
        ]

    def atualizar_modelos(self, worker_id: str, modelos: list[str]) -> None:
        worker = self._workers.get(worker_id)
        if worker is not None:
            worker.available_models = modelos

    def all_models(self) -> list[str]:
        models: set[str] = set()
        for worker in self._workers.values():
            models.update(worker.available_models)
        return sorted(models)

    async def send_chat_request(
        self,
        worker: ConnectedWorker,
        request_id: str,
        payload: dict[str, Any],
        timeout_seconds: float,
        origem: str = "",
    ) -> dict[str, Any]:
        """Envia um chat_request ao worker e aguarda o chat_response correspondente.

        Com [origem] (o módulo que pediu), o pedido aparece em `em_uso()` até terminar.

        Levanta `TimeoutError` se o worker não responder a tempo, ou a exceção
        registrada via `reject()` (ex.: `WorkerDisconnected`,
        `WorkerRespondedWithError`) se o worker cair ou reportar erro antes.
        """
        loop = asyncio.get_running_loop()
        future: asyncio.Future[dict[str, Any]] = loop.create_future()
        self._pending[request_id] = (worker.worker_id, future)
        inicio = time.monotonic()
        if origem:
            self._em_uso[request_id] = {
                "origem": origem,
                "tarefa": payload.get("task") or "chat",
                "modelo": payload.get("model") or payload.get("modelo") or "",
                "inicio": inicio,
            }
        erro: str | None = None
        resposta: dict[str, Any] = {}
        try:
            message = ChatRequest(request_id=request_id, payload=payload)
            await worker.websocket.send_json(message.model_dump())
            async with asyncio.timeout(timeout_seconds):
                resposta = await future
                return resposta
        except BaseException as e:
            erro = f"{type(e).__name__}: {e}"
            raise
        finally:
            self._pending.pop(request_id, None)
            self._em_uso.pop(request_id, None)
            if self.ao_medir is not None:
                uso = resposta.get("usage") or {}
                self.ao_medir(
                    {
                        "provedor": "local",
                        "worker": worker.worker_id,
                        "tarefa": payload.get("task") or "chat",
                        "modelo": resposta.get("model") or payload.get("model") or "",
                        "ms": round(1000 * (time.monotonic() - inicio)),
                        "erro": erro,
                        "tokens_entrada": uso.get("prompt_tokens"),
                        "tokens_saida": uso.get("completion_tokens"),
                    }
                )

    def resolve(self, request_id: str, payload: dict[str, Any]) -> None:
        entry = self._pending.get(request_id)
        if entry is None:
            return
        _, future = entry
        if not future.done():
            future.set_result(payload)

    def reject(self, request_id: str, exc: Exception) -> None:
        entry = self._pending.get(request_id)
        if entry is None:
            return
        _, future = entry
        if not future.done():
            future.set_exception(exc)

    async def run_staleness_sweeper(self, interval: float, stale_after: float) -> None:
        """Loop de fundo: derruba workers sem heartbeat há mais de `stale_after` segundos."""
        while True:
            await asyncio.sleep(interval)
            now = time.monotonic()
            stale_worker_ids = [
                worker_id
                for worker_id, worker in self._workers.items()
                if now - worker.last_seen > stale_after
            ]
            for worker_id in stale_worker_ids:
                worker = self._workers.get(worker_id)
                logger.warning(
                    "Worker %s sem heartbeat há mais de %ss, desconectando", worker_id, stale_after
                )
                await self.unregister(worker_id)
                if worker is not None:
                    try:
                        await worker.websocket.close(code=4000)
                    except Exception:
                        logger.debug(
                            "Falha ao fechar websocket do worker %s (já estava fechado)", worker_id
                        )
