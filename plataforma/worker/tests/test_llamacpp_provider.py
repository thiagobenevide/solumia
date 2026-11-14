from collections.abc import Callable
from typing import Any

import httpx
import pytest

from worker.providers.llamacpp import LlamaCppProvider


def _provider(
    modelos: list[dict[str, Any]], ocupado: bool = False, registro: list[str] | None = None
) -> LlamaCppProvider:
    def handler(request: httpx.Request) -> httpx.Response:
        if registro is not None:
            registro.append(f"{request.method} {request.url.path}")
        if request.url.path == "/models":
            return httpx.Response(200, json={"data": modelos})
        if request.url.path == "/slots":
            return httpx.Response(200, json=[{"id": 0, "is_processing": ocupado}])
        if request.url.path == "/models/load":
            modelos[0]["status"] = {"value": "loaded"}
            return httpx.Response(200, json={"success": True})
        if request.url.path == "/v1/chat/completions":
            return httpx.Response(200, json={"modelo": request.read().decode()})
        return httpx.Response(404)

    cliente = httpx.AsyncClient(base_url="http://x", transport=httpx.MockTransport(handler))
    return LlamaCppProvider("llama-server", "/tmp/nada", 1, "", 5, client=cliente)


def _m(id_: str, status: str = "unloaded") -> dict[str, Any]:
    return {"id": id_, "status": {"value": status}}


async def test_state_lists_loaded_and_busy() -> None:
    p = _provider([_m("b"), _m("a", "loaded")], ocupado=True)
    assert await p.estado() == {"modelos": ["a", "b"], "carregados": ["a"], "ocupados": ["a"]}


async def test_refuses_switch_while_model_processing() -> None:
    p = _provider([_m("b"), _m("a", "loaded")], ocupado=True)
    with pytest.raises(RuntimeError, match="em andamento"):
        await p.load("b")


async def test_loads_through_router() -> None:
    calls: list[str] = []
    p = _provider([_m("b"), _m("a", "loaded")], registro=calls)
    assert await p.load("b") == {"modelo": "b"}
    assert "POST /models/load" in calls


async def test_unknown_model() -> None:
    with pytest.raises(RuntimeError, match="não encontrado"):
        await _provider([_m("a")]).load("x")


async def test_chat_without_model_uses_loaded_one() -> None:
    p = _provider([_m("b"), _m("a", "loaded")])
    r: Callable[..., Any] = p.chat_completion
    answer = await r({"messages": []})
    assert '"model":"a"' in answer["modelo"].replace(" ", "")
