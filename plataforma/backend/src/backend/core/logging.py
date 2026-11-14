import json
import logging
import sys
from contextvars import ContextVar
from datetime import UTC, datetime
from typing import Any

from backend.core.config import Settings

request_id_ctx: ContextVar[str | None] = ContextVar("request_id", default=None)


class RequestIdFilter(logging.Filter):
    """Injeta o request_id do contexto atual (se houver) em cada log record."""

    def filter(self, record: logging.LogRecord) -> bool:
        record.request_id = request_id_ctx.get()
        return True


class JsonFormatter(logging.Formatter):
    """Formata cada log record como uma linha JSON, adequada para produção."""

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        request_id = getattr(record, "request_id", None)
        if request_id:
            payload["request_id"] = request_id
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False)


class ConsoleFormatter(logging.Formatter):
    """Formato legível por humano, usado em desenvolvimento."""

    def format(self, record: logging.LogRecord) -> str:
        request_id = getattr(record, "request_id", None)
        prefix = f"[{request_id}] " if request_id else ""
        base = (
            f"{self.formatTime(record, '%Y-%m-%d %H:%M:%S')} "
            f"{record.levelname:<8} {record.name}: {prefix}{record.getMessage()}"
        )
        if record.exc_info:
            base += "\n" + self.formatException(record.exc_info)
        return base


def configure_logging(settings: Settings) -> None:
    """Configura o logging raiz da aplicação de acordo com as settings do Gateway."""
    handler = logging.StreamHandler(stream=sys.stdout)
    handler.addFilter(RequestIdFilter())
    handler.setFormatter(JsonFormatter() if settings.log_format == "json" else ConsoleFormatter())

    root_logger = logging.getLogger()
    root_logger.handlers.clear()
    root_logger.addHandler(handler)
    root_logger.setLevel(settings.log_level.upper())

    # Bibliotecas de terceiros ficam em WARNING para não poluir o log de acesso.
    for noisy_logger in ("uvicorn.error", "uvicorn.access"):
        logging.getLogger(noisy_logger).setLevel(logging.WARNING)
