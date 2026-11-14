import json
from pathlib import Path


class ModelLLM:
    """Modelo do LLM local escolhido no app. Fica em `llm.json` e vale na hora, sem reiniciar.

    Sem escolha salva, usa [padrao] (GATEWAY_ROTINAS_MODELO); vazio = o carregado no worker.
    """

    def __init__(self, arquivo: str, default: str = "") -> None:
        self._arquivo = Path(arquivo).expanduser()
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
