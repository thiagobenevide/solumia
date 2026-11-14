import json
import logging
import sys
from datetime import UTC, datetime
from typing import Any

from worker.core.config import WorkerSettings

# Cópia intencional de gateway/src/gateway/core/logging.py: Gateway e Worker
# são implantados/atualizados de forma independente (VPS vs. máquina
# pessoal), então não compartilham um módulo de infraestrutura — só os
# contratos de protocolo em shared/. Mantenha as duas cópias em sincronia se
# o formato mudar.


class JsonFormatter(logging.Formatter):
    """Formata cada log record como uma linha JSON, adequada para produção."""

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False)


class ConsoleFormatter(logging.Formatter):
    """Formato legível por humano, usado em desenvolvimento."""

    def format(self, record: logging.LogRecord) -> str:
        base = (
            f"{self.formatTime(record, '%Y-%m-%d %H:%M:%S')} "
            f"{record.levelname:<8} {record.name}: {record.getMessage()}"
        )
        if record.exc_info:
            base += "\n" + self.formatException(record.exc_info)
        return base


def configure_logging(settings: WorkerSettings) -> None:
    """Configura o logging raiz do Worker de acordo com as settings."""
    handler = logging.StreamHandler(stream=sys.stdout)
    handler.setFormatter(JsonFormatter() if settings.log_format == "json" else ConsoleFormatter())

    root_logger = logging.getLogger()
    root_logger.handlers.clear()
    root_logger.addHandler(handler)
    root_logger.setLevel(settings.log_level.upper())

    # websockets é bem verboso em DEBUG/INFO durante ping/pong; mantém em WARNING.
    logging.getLogger("websockets").setLevel(logging.WARNING)
