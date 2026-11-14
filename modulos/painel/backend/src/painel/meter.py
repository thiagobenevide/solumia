"""Registro de uso das LLMs (worker local e Claude): cada pedido vira uma linha em `uso.jsonl` e
fica nos últimos [MEMORIA] em memória para o dashboard (latência, erros, tokens por provedor)."""

import json
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any

MEMORY = 2000


def _pct(values: list[int], p: float) -> int | None:
    if not values:
        return None
    ordenados = sorted(values)
    return ordenados[min(len(ordenados) - 1, int(p * len(ordenados)))]


class Meter:
    def __init__(self, root: str | Path) -> None:
        self.root = Path(root).expanduser()
        self.root.mkdir(parents=True, exist_ok=True)
        self._arquivo = self.root / "uso.jsonl"
        self._lock = threading.Lock()
        self._lines: deque[dict[str, Any]] = deque(maxlen=MEMORY)
        if self._arquivo.exists():
            with self._arquivo.open(encoding="utf-8") as f:
                for line in f:
                    if line.strip():
                        self._lines.append(json.loads(line))

    def registrar(self, event: dict[str, Any]) -> None:
        line = {"em": time.time(), **event}
        with self._lock:
            self._lines.append(line)
            with self._arquivo.open("a", encoding="utf-8") as f:
                f.write(json.dumps(line, ensure_ascii=False) + "\n")

    def resumo(self, horas: float = 24, recent: int = 50) -> dict[str, Any]:
        since = time.time() - horas * 3600
        with self._lock:
            lines = [x for x in self._lines if x["em"] >= since]
        providers: dict[str, dict[str, Any]] = {}
        for p in sorted({x["provedor"] for x in lines}):
            dele = [x for x in lines if x["provedor"] == p]
            ok = [x for x in dele if not x.get("erro")]
            ms = [x["ms"] for x in ok]
            providers[p] = {
                "pedidos": len(dele),
                "erros": len(dele) - len(ok),
                "disponibilidade_pct": round(100 * len(ok) / len(dele), 1),
                "latencia_p50_ms": _pct(ms, 0.5),
                "latencia_p95_ms": _pct(ms, 0.95),
                "tokens_entrada": sum(x.get("tokens_entrada") or 0 for x in dele),
                "tokens_saida": sum(x.get("tokens_saida") or 0 for x in dele),
                "ultimo_em": dele[-1]["em"],
            }
        return {
            "janela_horas": horas,
            "provedores": providers,
            "recentes": list(reversed(lines[-recent:])),
        }
