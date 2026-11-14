"""Plan and apply engine.

- A **plan** is an ordered list of readable steps. The person sees the plan before anything happens.
- Applying only runs the plan with the same `hash` that was shown (nothing changes between viewing and confirming).
- Each step has `ja_feito` (idempotency: skips what is already in the desired state) and `executar`.
- The run log (one JSONL per run) records each finished step; reapplying the same plan after a
  crash resumes from the first unfinished step.
- All log text goes through the `Mask`, which replaces any vault value with `•••`.
"""

from __future__ import annotations

import hashlib
import json
import threading
import time
import traceback
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class Context:
    """Passado a cada passo: log, recursos compartilhados entre passos e cancelamento."""

    log: Callable[[str], None]
    recursos: dict[str, Any] = field(default_factory=dict)
    cancelado: threading.Event = field(default_factory=threading.Event)

    def check_cancelled(self) -> None:
        if self.cancelado.is_set():
            raise Cancelado()


class Cancelado(Exception):
    pass


@dataclass
class Step:
    id: str
    titulo: str
    detalhe: str = ""
    executar: Callable[[Context], None] = lambda ctx: None
    ja_feito: Callable[[Context], bool] | None = None
    destrutivo: bool = False  # requires TOTP reconfirmation in the API
    sempre: bool = False  # runs even when resuming (prepares resources used by the following steps)

    def summary(self) -> dict[str, Any]:
        return {"id": self.id, "titulo": self.titulo, "detalhe": self.detalhe, "destrutivo": self.destrutivo}


@dataclass
class Plan:
    titulo: str
    passos: list[Step]
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])

    @property
    def hash(self) -> str:
        raw = json.dumps([p.summary() for p in self.passos], ensure_ascii=False, sort_keys=True)
        return hashlib.sha256(f"{self.titulo}\n{raw}".encode()).hexdigest()[:16]

    @property
    def destrutivo(self) -> bool:
        return any(p.destrutivo for p in self.passos)

    def summary(self) -> dict[str, Any]:
        return {"id": self.id, "titulo": self.titulo, "hash": self.hash, "destrutivo": self.destrutivo,
                "passos": [p.summary() for p in self.passos]}


class Mask:
    def __init__(self, source: Callable[[], list[str]] | None = None) -> None:
        self._source = source or (lambda: [])

    def __call__(self, text: str) -> str:
        for value in sorted(self._source(), key=len, reverse=True):
            if value and value in text:
                text = text.replace(value, "•••")
        return text


@dataclass
class Event:
    n: int
    instante: float
    tipo: str  # inicio | passo | log | pulado | ok | falha | fim
    passo: str | None
    texto: str

    def dict(self) -> dict[str, Any]:
        return {"n": self.n, "t": self.instante, "tipo": self.tipo, "passo": self.passo, "texto": self.texto}


class Execucao:
    def __init__(self, plan: Plan, dir_record: Path, mask: Mask | None = None,
                 recursos: dict[str, Any] | None = None) -> None:
        self.plano = plan
        self.id = f"{time.strftime('%Y%m%d-%H%M%S')}-{plan.hash}"
        self.mask = mask or Mask()
        self.events: list[Event] = []
        self.state = "pendente"  # pendente | rodando | concluida | falhou | cancelada
        self._lock = threading.Lock()
        self._dir = dir_record
        self._dir.mkdir(parents=True, exist_ok=True)
        self._file = self._dir / f"{self.id}.jsonl"
        self.ctx = Context(log=self._log_step, recursos=recursos or {})
        self._current_step: str | None = None
        self._thread: threading.Thread | None = None

    # --- eventos -----------------------------------------------------------------------------
    def _issue(self, tipo: str, text: str, step: str | None = None) -> None:
        with self._lock:
            ev = Event(len(self.events), time.time(), tipo, step, self.mask(text))
            self.events.append(ev)
            with self._file.open("a", encoding="utf-8") as f:
                f.write(json.dumps(ev.dict(), ensure_ascii=False) + "\n")

    def _log_step(self, text: str) -> None:
        for line in str(text).splitlines() or [""]:
            self._issue("log", line, self._current_step)

    def events_since(self, n: int) -> list[dict[str, Any]]:
        with self._lock:
            return [e.dict() for e in self.events[n:]]

    # --- retomada ------------------------------------------------------------------------------
    def _previous_done(self) -> set[str]:
        """Steps finished in the last unfinished run of the same plan (same hash)."""
        previous = sorted(self._dir.glob(f"*-{self.plano.hash}.jsonl"))
        previous = [a for a in previous if a != self._file]
        if not previous:
            return set()
        done: set[str] = set()
        finished = False
        for line in previous[-1].read_text(encoding="utf-8").splitlines():
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev["tipo"] == "ok" and ev["passo"]:
                done.add(ev["passo"])
            if ev["tipo"] == "fim" and ev["texto"] == "concluida":
                finished = True
        return set() if finished else done

    # --- run ------------------------------------------------------------------------------------
    def rodar(self) -> str:
        self.state = "rodando"
        self._issue("inicio", f"{self.plano.titulo} ({len(self.plano.passos)} passos)")
        resume = self._previous_done()
        if resume:
            self._issue("log", f"Retomando: {len(resume)} passo(s) já concluído(s) na tentativa anterior")
        try:
            for step in self.plano.passos:
                self.ctx.check_cancelled()
                self._current_step = step.id
                self._issue("passo", step.titulo, step.id)
                if step.id in resume and not step.sempre:
                    self._issue("pulado", "concluído na tentativa anterior", step.id)
                    self._issue("ok", "", step.id)
                    continue
                if step.ja_feito is not None and step.ja_feito(self.ctx):
                    self._issue("pulado", "já está como deveria", step.id)
                    self._issue("ok", "", step.id)
                    continue
                step.executar(self.ctx)
                self._issue("ok", "", step.id)
            self.state = "concluida"
        except Cancelado:
            self.state = "cancelada"
            self._issue("falha", "cancelado pela pessoa", self._current_step)
        except Exception as e:  # noqa: BLE001 — any failure becomes an event; the details go to the run log
            self.state = "falhou"
            self._issue("falha", f"{type(e).__name__}: {e}", self._current_step)
            self._issue("log", traceback.format_exc(limit=4), self._current_step)
        finally:
            self._current_step = None
            self._issue("fim", self.state)
            close = self.ctx.recursos.get("_fechar")
            if callable(close):
                try:
                    close()
                except Exception:  # noqa: BLE001, S110
                    pass
        return self.state

    def iniciar(self) -> None:
        self._thread = threading.Thread(target=self.rodar, name=f"execucao-{self.id}", daemon=True)
        self._thread.start()

    def cancel(self) -> None:
        self.ctx.cancelado.set()

    def summary(self) -> dict[str, Any]:
        return {"id": self.id, "plano": self.plano.summary(), "estado": self.state, "eventos": len(self.events)}


def list_runs(dir_record: Path, limit: int = 50) -> list[dict[str, Any]]:
    """Log screen: latest runs with title and final state."""
    output = []
    for file in sorted(dir_record.glob("*.jsonl"), reverse=True)[:limit]:
        title, state = "", "interrompida"
        for line in file.read_text(encoding="utf-8").splitlines():
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev["tipo"] == "inicio":
                title = ev["texto"]
            elif ev["tipo"] == "fim":
                state = ev["texto"]
        output.append({"id": file.stem, "titulo": title, "estado": state})
    return output
