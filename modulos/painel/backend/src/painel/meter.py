"""Registro de uso das LLMs (worker local e Claude): cada pedido vira uma linha em `uso.jsonl` e
fica nos últimos [MEMORIA] em memória para o dashboard (latência, erros, tokens por provedor)."""

import json
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any

MEMORIA = 2000


def _pct(valores: list[int], p: float) -> int | None:
    if not valores:
        return None
    ordenados = sorted(valores)
    return ordenados[min(len(ordenados) - 1, int(p * len(ordenados)))]


class Medidor:
    def __init__(self, raiz: str | Path) -> None:
        self.raiz = Path(raiz).expanduser()
        self.raiz.mkdir(parents=True, exist_ok=True)
        self._arquivo = self.raiz / "uso.jsonl"
        self._trava = threading.Lock()
        self._linhas: deque[dict[str, Any]] = deque(maxlen=MEMORIA)
        if self._arquivo.exists():
            with self._arquivo.open(encoding="utf-8") as f:
                for linha in f:
                    if linha.strip():
                        self._linhas.append(json.loads(linha))

    def registrar(self, evento: dict[str, Any]) -> None:
        linha = {"em": time.time(), **evento}
        with self._trava:
            self._linhas.append(linha)
            with self._arquivo.open("a", encoding="utf-8") as f:
                f.write(json.dumps(linha, ensure_ascii=False) + "\n")

    def resumo(self, horas: float = 24, recentes: int = 50) -> dict[str, Any]:
        desde = time.time() - horas * 3600
        with self._trava:
            linhas = [x for x in self._linhas if x["em"] >= desde]
        provedores: dict[str, dict[str, Any]] = {}
        for p in sorted({x["provedor"] for x in linhas}):
            dele = [x for x in linhas if x["provedor"] == p]
            ok = [x for x in dele if not x.get("erro")]
            ms = [x["ms"] for x in ok]
            provedores[p] = {
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
            "provedores": provedores,
            "recentes": list(reversed(linhas[-recentes:])),
        }
