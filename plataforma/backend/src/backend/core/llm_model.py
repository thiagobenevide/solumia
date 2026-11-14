import json
from pathlib import Path


class ModelLLM:
    """Local LLM model chosen in the app. Lives in `llm.json` and applies immediately, without a
    restart.

    Without a saved choice, uses the default (GATEWAY_ROTINAS_MODELO); empty = the one loaded on
    the worker.
    """

    def __init__(self, file: str, default: str = "") -> None:
        self._arquivo = Path(file).expanduser()
        self._default = default

    @property
    def atual(self) -> str:
        try:
            return str(json.loads(self._arquivo.read_text())["modelo"])
        except (OSError, ValueError, KeyError):
            return self._default

    def swap(self, modelo: str) -> None:
        self._arquivo.parent.mkdir(parents=True, exist_ok=True)
        temp = self._arquivo.with_suffix(".tmp")
        temp.write_text(json.dumps({"modelo": modelo}, ensure_ascii=False))
        temp.replace(self._arquivo)
