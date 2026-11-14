import asyncio

from worker.core.config import get_settings
from worker.core.logging import configure_logging
from worker.providers.llamacpp import LlamaCppProvider
from worker.ws_client import WorkerClient


async def _run() -> None:
    settings = get_settings()
    provider = LlamaCppProvider(
        binario=settings.llama_server_bin,
        modelos_dir=settings.modelos_dir,
        porta=settings.llama_porta,
        args=settings.llama_args,
        timeout=settings.provider_timeout_seconds,
    )
    try:
        await WorkerClient(settings, provider).run_forever()
    finally:
        await provider.aclose()


def run() -> None:
    """Entry point used by `python -m worker.main` / the development script."""
    configure_logging(get_settings())
    asyncio.run(_run())


if __name__ == "__main__":
    run()
