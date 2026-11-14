import json
import logging
import sys
from datetime import UTC, datetime
from typing import Any

from worker.core.config import WorkerSettings

# Intentional copy of backend/core/logging.py: Gateway and Worker are
# deployed/updated independently (VPS vs. personal machine), so they do not
# share an infrastructure module — only the protocol contracts in shared/.
# Keep both copies in sync if the format changes.


class JsonFormatter(logging.Formatter):
    """Formats each log record as one JSON line, suitable for production."""

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
    """Human-readable format, used in development."""

    def format(self, record: logging.LogRecord) -> str:
        base = (
            f"{self.formatTime(record, '%Y-%m-%d %H:%M:%S')} "
            f"{record.levelname:<8} {record.name}: {record.getMessage()}"
        )
        if record.exc_info:
            base += "\n" + self.formatException(record.exc_info)
        return base


def configure_logging(settings: WorkerSettings) -> None:
    """Configures the Worker root logging according to the settings."""
    handler = logging.StreamHandler(stream=sys.stdout)
    handler.setFormatter(JsonFormatter() if settings.log_format == "json" else ConsoleFormatter())

    root_logger = logging.getLogger()
    root_logger.handlers.clear()
    root_logger.addHandler(handler)
    root_logger.setLevel(settings.log_level.upper())

    # websockets is very verbose at DEBUG/INFO during ping/pong; keep it at WARNING.
    logging.getLogger("websockets").setLevel(logging.WARNING)
