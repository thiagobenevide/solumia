import asyncio
import logging
import os
import shlex
import subprocess
from pathlib import Path
from typing import Any

import httpx

from worker.providers.base import Provider

logger = logging.getLogger("worker.llamacpp")


class LlamaCppProvider(Provider):
    """llama.cpp provider in router mode: a single `llama-server` serves every model.

    Models come from the models folder: a loose `.gguf` (id = name without extension) or a subfolder
    with the model and the `mmproj-*` (vision; id = folder name). The router loads on demand and
    unloads when idle.
    The server is shared with the pipeline (whoever comes first starts it) and outlives the worker.
    Switching models is refused while any model is processing (from any client).
    """

    def __init__(
        self,
        binario: str,
        modelos_dir: str,
        porta: int,
        args: str,
        timeout: float,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._binario = os.path.expanduser(binario)
        self._dir = Path(modelos_dir).expanduser()
        self._porta = porta
        self._args = shlex.split(args)
        self._client = client or httpx.AsyncClient(
            base_url=f"http://127.0.0.1:{porta}", timeout=timeout
        )
        self._active = 0
        self._lock = asyncio.Lock()

    async def _models(self) -> list[dict[str, Any]]:
        r = await self._client.get("/models", timeout=5)
        r.raise_for_status()
        return list(r.json().get("data") or [])

    async def _ensure(self) -> None:
        """Starts the router if there is none on the port yet (the pipeline may have started it)."""
        try:
            await self._models()
            return
        except httpx.HTTPError:
            pass
        self._dir.mkdir(parents=True, exist_ok=True)
        logger.info("Subindo llama-server (roteador) com os modelos de %s", self._dir)
        with (self._dir / "llama-server.log").open("ab") as log:
            subprocess.Popen(  # noqa: ASYNC220 - fire and forget; the process runs on its own
                [
                    self._binario,
                    "--models-dir", str(self._dir),
                    "--host", "127.0.0.1",
                    "--port", str(self._porta),
                    *self._args,
                ],
                stdout=log,
                stderr=log,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
        for _ in range(120):
            await asyncio.sleep(0.5)
            try:
                await self._models()
                return
            except httpx.HTTPError:
                pass
        raise RuntimeError("llama-server não subiu; ver llama-server.log na pasta de modelos")

    async def list_models(self) -> list[str]:
        await self._ensure()
        return sorted(m["id"] for m in await self._models())

    async def estado(self) -> dict[str, Any]:
        """Available models, the ones loaded on the GPU and the ones processing right now."""
        await self._ensure()
        models = await self._models()
        carregados = [m["id"] for m in models if m["status"]["value"] == "loaded"]
        ocupados = []
        for id_ in carregados:
            try:
                r = await self._client.get("/slots", params={"model": id_}, timeout=5)
                if any(s.get("is_processing") for s in r.json()):
                    ocupados.append(id_)
            except (httpx.HTTPError, ValueError, AttributeError):
                pass
        return {
            "modelos": sorted(m["id"] for m in models),
            "carregados": carregados,
            "ocupados": ocupados,
        }

    async def load(self, modelo: str) -> dict[str, Any]:
        async with self._lock:
            est = await self.estado()
            if self._active or est["ocupados"]:
                raise RuntimeError("Há pedidos em andamento no LLM; troque quando terminarem.")
            if modelo not in est["modelos"]:
                raise RuntimeError(f"Modelo '{modelo}' não encontrado em {self._dir}")
            if modelo not in est["carregados"]:
                r = await self._client.post("/models/load", json={"model": modelo})
                r.raise_for_status()
                await self._esperar_load(modelo)
        return {"modelo": modelo}

    async def _esperar_load(self, modelo: str) -> None:
        # Loading the model onto the GPU takes from seconds to minutes.
        for _ in range(600):
            st = next((m["status"] for m in await self._models() if m["id"] == modelo), {})
            if st.get("value") == "loaded":
                return
            if st.get("failed"):
                raise RuntimeError(
                    f"llama-server falhou ao carregar {modelo}; ver llama-server.log"
                )
            await asyncio.sleep(0.5)
        raise RuntimeError(f"{modelo} não terminou de carregar a tempo")

    async def chat_completion(self, payload: dict[str, Any]) -> dict[str, Any]:
        await self._ensure()
        if not payload.get("model"):
            est = await self.estado()
            # embedding (notes search) and the adaptadores/ (LoRA) and voz/ folders do not chat:
            # chatting with them gives HTTP 500
            def chat(ids: list[str]) -> list[str]:
                return [
                    m for m in ids if "embed" not in m.lower() and m not in ("adaptadores", "voz")
                ]

            default = (chat(est["carregados"]) or chat(est["modelos"]) or [""])[0]
            payload = {**payload, "model": default}
        # Wait for a switch in progress to finish before starting.
        async with self._lock:
            self._active += 1
        try:
            # stream=False porque o Gateway simula o streaming.
            response = await self._client.post(
                "/v1/chat/completions", json={**payload, "stream": False}
            )
            response.raise_for_status()
            result: dict[str, Any] = response.json()
            return result
        finally:
            self._active -= 1

    async def aclose(self) -> None:
        await self._client.aclose()
