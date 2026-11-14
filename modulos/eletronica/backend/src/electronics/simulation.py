"""In-memory simulation tasks: the netlist goes to the runner (worker on the PC or local
ngspice)."""

import base64
import time
from collections.abc import Awaitable, Callable
from typing import Any
from uuid import uuid4

from electronics.spice import read_raw, result

# SPICE netlist → {raw_b64, log, codigo} (see `shared.ngspice.run_ngspice`).
Executor = Callable[[str], Awaitable[dict[str, Any]]]
# Error message when there is nowhere to run ngspice; None when simulation is possible.
Available = Callable[[], str | None]


class Unavailable(Exception):
    pass


class Simulations:
    def __init__(
        self, execute: Executor, available: Available = lambda: None, limite: int = 50
    ) -> None:
        self.executar = execute
        self.disponivel = available
        self.limit = limite
        self._tasks: dict[str, dict[str, Any]] = {}
        self._internos: dict[str, dict[str, Any]] = {}  # netlist, nodes and axis of each task

    def criar(self, project: str, analysis: str, gerado: dict[str, Any]) -> dict[str, Any]:
        """Registers the task; raises Unavailable without a worker or local ngspice."""
        if (reason := self.disponivel()) is not None:
            raise Unavailable(reason)
        id_ = uuid4().hex[:12]
        self._tasks[id_] = {
            "id": id_,
            "projeto": project,
            "analise": analysis,
            "estado": "fila",
            "criada": time.time(),
            "ignorados": gerado["ignorados"],
            "avisos": gerado["avisos"],
        }
        self._internos[id_] = gerado
        for velha in list(self._tasks)[: -self.limit]:
            self._tasks.pop(velha, None)
            self._internos.pop(velha, None)
        return self._tasks[id_]

    def obter(self, id_: str) -> dict[str, Any] | None:
        return self._tasks.get(id_)

    async def rodar(self, id_: str) -> None:
        t, g = self._tasks.get(id_), self._internos.get(id_)
        if t is None or g is None:
            return
        t["estado"] = "rodando"
        try:
            r = await self.executar(g["texto"])
            t["log"] = "\n".join(str(r.get("log", "")).strip().splitlines()[-20:])
            data = base64.b64decode(str(r.get("raw_b64", "")))
            if not data:
                ultimas = t["log"].splitlines()[-8:]
                raise RuntimeError("O ngspice falhou: " + (" | ".join(ultimas) or "sem saída"))
            t["resultado"] = result(t["analise"], read_raw(data), g["nos"], g["eixo"])
            t["estado"] = "pronto"
        except Exception as e:  # the error goes into the task, the screen shows it
            t["erro"] = str(e) or type(e).__name__
            t["estado"] = "erro"
