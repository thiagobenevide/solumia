"""Tarefas de simulação em memória: a netlist vai ao executor (worker no PC ou ngspice local)."""

import base64
import time
from collections.abc import Awaitable, Callable
from typing import Any
from uuid import uuid4

from eletronica.spice import ler_raw, resultado

# netlist SPICE → {raw_b64, log, codigo} (ver `shared.ngspice.run_ngspice`).
Executor = Callable[[str], Awaitable[dict[str, Any]]]
# Mensagem de erro quando não há onde rodar o ngspice; None quando dá para simular.
Disponivel = Callable[[], str | None]


class Indisponivel(Exception):
    pass


class Simulacoes:
    def __init__(
        self, executar: Executor, disponivel: Disponivel = lambda: None, limite: int = 50
    ) -> None:
        self.executar = executar
        self.disponivel = disponivel
        self.limite = limite
        self._tarefas: dict[str, dict[str, Any]] = {}
        self._internos: dict[str, dict[str, Any]] = {}  # netlist, nós e eixo de cada tarefa

    def criar(self, projeto: str, analise: str, gerado: dict[str, Any]) -> dict[str, Any]:
        """Registra a tarefa; levanta Indisponivel sem worker nem ngspice local."""
        if (motivo := self.disponivel()) is not None:
            raise Indisponivel(motivo)
        id_ = uuid4().hex[:12]
        self._tarefas[id_] = {
            "id": id_,
            "projeto": projeto,
            "analise": analise,
            "estado": "fila",
            "criada": time.time(),
            "ignorados": gerado["ignorados"],
            "avisos": gerado["avisos"],
        }
        self._internos[id_] = gerado
        for velha in list(self._tarefas)[: -self.limite]:
            self._tarefas.pop(velha, None)
            self._internos.pop(velha, None)
        return self._tarefas[id_]

    def obter(self, id_: str) -> dict[str, Any] | None:
        return self._tarefas.get(id_)

    async def rodar(self, id_: str) -> None:
        t, g = self._tarefas.get(id_), self._internos.get(id_)
        if t is None or g is None:
            return
        t["estado"] = "rodando"
        try:
            r = await self.executar(g["texto"])
            t["log"] = "\n".join(str(r.get("log", "")).strip().splitlines()[-20:])
            dados = base64.b64decode(str(r.get("raw_b64", "")))
            if not dados:
                ultimas = t["log"].splitlines()[-8:]
                raise RuntimeError("O ngspice falhou: " + (" | ".join(ultimas) or "sem saída"))
            t["resultado"] = resultado(t["analise"], ler_raw(dados), g["nos"], g["eixo"])
            t["estado"] = "pronto"
        except Exception as e:  # o erro vai para a tarefa, a tela mostra
            t["erro"] = str(e) or type(e).__name__
            t["estado"] = "erro"
