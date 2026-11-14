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
    """Provider llama.cpp em modo roteador: um só `llama-server` serve todos os modelos.

    Modelos vêm de [modelos_dir]: `.gguf` solto (id = nome sem extensão) ou subpasta com o modelo
    e o `mmproj-*` (visão; id = nome da pasta). O roteador carrega sob demanda e descarrega quando
    fica ocioso.
    O servidor é compartilhado com a esteira (quem chegar primeiro sobe) e sobrevive ao worker.
    Trocar o modelo é recusado enquanto algum modelo estiver processando (de qualquer cliente).
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
        self._ativos = 0
        self._trava = asyncio.Lock()

    async def _modelos(self) -> list[dict[str, Any]]:
        r = await self._client.get("/models", timeout=5)
        r.raise_for_status()
        return list(r.json().get("data") or [])

    async def _garantir(self) -> None:
        """Sobe o roteador se ainda não houver um na porta (a esteira pode já ter subido)."""
        try:
            await self._modelos()
            return
        except httpx.HTTPError:
            pass
        self._dir.mkdir(parents=True, exist_ok=True)
        logger.info("Subindo llama-server (roteador) com os modelos de %s", self._dir)
        with (self._dir / "llama-server.log").open("ab") as log:
            subprocess.Popen(  # noqa: ASYNC220 - só dispara; o processo segue sozinho
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
                await self._modelos()
                return
            except httpx.HTTPError:
                pass
        raise RuntimeError("llama-server não subiu; ver llama-server.log na pasta de modelos")

    async def list_models(self) -> list[str]:
        await self._garantir()
        return sorted(m["id"] for m in await self._modelos())

    async def estado(self) -> dict[str, Any]:
        """Modelos disponíveis, os carregados na GPU e os que estão processando agora."""
        await self._garantir()
        models = await self._modelos()
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

    async def carregar(self, modelo: str) -> dict[str, Any]:
        async with self._trava:
            est = await self.estado()
            if self._ativos or est["ocupados"]:
                raise RuntimeError("Há pedidos em andamento no LLM; troque quando terminarem.")
            if modelo not in est["modelos"]:
                raise RuntimeError(f"Modelo '{modelo}' não encontrado em {self._dir}")
            if modelo not in est["carregados"]:
                r = await self._client.post("/models/load", json={"model": modelo})
                r.raise_for_status()
                await self._esperar_carga(modelo)
        return {"modelo": modelo}

    async def _esperar_carga(self, modelo: str) -> None:
        # Carregar o modelo na GPU leva de segundos a minutos.
        for _ in range(600):
            st = next((m["status"] for m in await self._modelos() if m["id"] == modelo), {})
            if st.get("value") == "loaded":
                return
            if st.get("failed"):
                raise RuntimeError(
                    f"llama-server falhou ao carregar {modelo}; ver llama-server.log"
                )
            await asyncio.sleep(0.5)
        raise RuntimeError(f"{modelo} não terminou de carregar a tempo")

    async def chat_completion(self, payload: dict[str, Any]) -> dict[str, Any]:
        await self._garantir()
        if not payload.get("model"):
            est = await self.estado()
            # embedding (busca das notas) e as pastas adaptadores/ (LoRA) e voz/ não conversam:
            # chat neles dá HTTP 500
            def chat(ids: list[str]) -> list[str]:
                return [
                    m for m in ids if "embed" not in m.lower() and m not in ("adaptadores", "voz")
                ]

            default = (chat(est["carregados"]) or chat(est["modelos"]) or [""])[0]
            payload = {**payload, "model": default}
        # Espera uma troca em curso terminar antes de começar.
        async with self._trava:
            self._ativos += 1
        try:
            # stream=False porque o Gateway simula o streaming.
            response = await self._client.post(
                "/v1/chat/completions", json={**payload, "stream": False}
            )
            response.raise_for_status()
            result: dict[str, Any] = response.json()
            return result
        finally:
            self._ativos -= 1

    async def aclose(self) -> None:
        await self._client.aclose()
