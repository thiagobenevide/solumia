"""Motor de plano e aplicação.

- Um **plano** é uma lista ordenada de passos legíveis. A pessoa vê o plano antes de qualquer coisa.
- A aplicação só roda o plano com o mesmo `hash` que foi mostrado (nada muda entre ver e confirmar).
- Cada passo tem `ja_feito` (idempotência: pula o que já está no estado desejado) e `executar`.
- O registro (JSONL por execução) guarda cada passo concluído; reaplicar o mesmo plano depois de uma
  queda retoma do primeiro passo não concluído.
- Todo texto de log passa por `mascarar`, que troca qualquer valor do cofre por `•••`.
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
class Contexto:
    """Passado a cada passo: log, recursos compartilhados entre passos e cancelamento."""

    log: Callable[[str], None]
    recursos: dict[str, Any] = field(default_factory=dict)
    cancelado: threading.Event = field(default_factory=threading.Event)

    def checar_cancelamento(self) -> None:
        if self.cancelado.is_set():
            raise Cancelado()


class Cancelado(Exception):
    pass


@dataclass
class Passo:
    id: str
    titulo: str
    detalhe: str = ""
    executar: Callable[[Contexto], None] = lambda ctx: None
    ja_feito: Callable[[Contexto], bool] | None = None
    destrutivo: bool = False  # exige reconfirmação com TOTP na API
    sempre: bool = False  # roda mesmo na retomada (prepara recursos usados pelos passos seguintes)

    def resumo(self) -> dict[str, Any]:
        return {"id": self.id, "titulo": self.titulo, "detalhe": self.detalhe, "destrutivo": self.destrutivo}


@dataclass
class Plano:
    titulo: str
    passos: list[Passo]
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])

    @property
    def hash(self) -> str:
        bruto = json.dumps([p.resumo() for p in self.passos], ensure_ascii=False, sort_keys=True)
        return hashlib.sha256(f"{self.titulo}\n{bruto}".encode()).hexdigest()[:16]

    @property
    def destrutivo(self) -> bool:
        return any(p.destrutivo for p in self.passos)

    def resumo(self) -> dict[str, Any]:
        return {"id": self.id, "titulo": self.titulo, "hash": self.hash, "destrutivo": self.destrutivo,
                "passos": [p.resumo() for p in self.passos]}


class Mascara:
    def __init__(self, fonte: Callable[[], list[str]] | None = None) -> None:
        self._fonte = fonte or (lambda: [])

    def __call__(self, texto: str) -> str:
        for valor in sorted(self._fonte(), key=len, reverse=True):
            if valor and valor in texto:
                texto = texto.replace(valor, "•••")
        return texto


@dataclass
class Evento:
    n: int
    instante: float
    tipo: str  # inicio | passo | log | pulado | ok | falha | fim
    passo: str | None
    texto: str

    def dict(self) -> dict[str, Any]:
        return {"n": self.n, "t": self.instante, "tipo": self.tipo, "passo": self.passo, "texto": self.texto}


class Execucao:
    def __init__(self, plano: Plano, dir_registro: Path, mascara: Mascara | None = None,
                 recursos: dict[str, Any] | None = None) -> None:
        self.plano = plano
        self.id = f"{time.strftime('%Y%m%d-%H%M%S')}-{plano.hash}"
        self.mascara = mascara or Mascara()
        self.eventos: list[Evento] = []
        self.estado = "pendente"  # pendente | rodando | concluida | falhou | cancelada
        self._lock = threading.Lock()
        self._dir = dir_registro
        self._dir.mkdir(parents=True, exist_ok=True)
        self._arquivo = self._dir / f"{self.id}.jsonl"
        self.ctx = Contexto(log=self._log_passo, recursos=recursos or {})
        self._passo_atual: str | None = None
        self._thread: threading.Thread | None = None

    # --- eventos -----------------------------------------------------------------------------
    def _emitir(self, tipo: str, texto: str, passo: str | None = None) -> None:
        with self._lock:
            ev = Evento(len(self.eventos), time.time(), tipo, passo, self.mascara(texto))
            self.eventos.append(ev)
            with self._arquivo.open("a", encoding="utf-8") as f:
                f.write(json.dumps(ev.dict(), ensure_ascii=False) + "\n")

    def _log_passo(self, texto: str) -> None:
        for linha in str(texto).splitlines() or [""]:
            self._emitir("log", linha, self._passo_atual)

    def eventos_desde(self, n: int) -> list[dict[str, Any]]:
        with self._lock:
            return [e.dict() for e in self.eventos[n:]]

    # --- retomada ------------------------------------------------------------------------------
    def _concluidos_anteriores(self) -> set[str]:
        """Passos concluídos na última execução do mesmo plano (mesmo hash) que não terminou."""
        anteriores = sorted(self._dir.glob(f"*-{self.plano.hash}.jsonl"))
        anteriores = [a for a in anteriores if a != self._arquivo]
        if not anteriores:
            return set()
        feitos: set[str] = set()
        terminou = False
        for linha in anteriores[-1].read_text(encoding="utf-8").splitlines():
            try:
                ev = json.loads(linha)
            except ValueError:
                continue
            if ev["tipo"] == "ok" and ev["passo"]:
                feitos.add(ev["passo"])
            if ev["tipo"] == "fim" and ev["texto"] == "concluida":
                terminou = True
        return set() if terminou else feitos

    # --- execução ------------------------------------------------------------------------------
    def rodar(self) -> str:
        self.estado = "rodando"
        self._emitir("inicio", f"{self.plano.titulo} ({len(self.plano.passos)} passos)")
        retomar = self._concluidos_anteriores()
        if retomar:
            self._emitir("log", f"Retomando: {len(retomar)} passo(s) já concluído(s) na tentativa anterior")
        try:
            for passo in self.plano.passos:
                self.ctx.checar_cancelamento()
                self._passo_atual = passo.id
                self._emitir("passo", passo.titulo, passo.id)
                if passo.id in retomar and not passo.sempre:
                    self._emitir("pulado", "concluído na tentativa anterior", passo.id)
                    self._emitir("ok", "", passo.id)
                    continue
                if passo.ja_feito is not None and passo.ja_feito(self.ctx):
                    self._emitir("pulado", "já está como deveria", passo.id)
                    self._emitir("ok", "", passo.id)
                    continue
                passo.executar(self.ctx)
                self._emitir("ok", "", passo.id)
            self.estado = "concluida"
        except Cancelado:
            self.estado = "cancelada"
            self._emitir("falha", "cancelado pela pessoa", self._passo_atual)
        except Exception as e:  # noqa: BLE001 — qualquer falha vira evento; o detalhe vai ao registro
            self.estado = "falhou"
            self._emitir("falha", f"{type(e).__name__}: {e}", self._passo_atual)
            self._emitir("log", traceback.format_exc(limit=4), self._passo_atual)
        finally:
            self._passo_atual = None
            self._emitir("fim", self.estado)
            fechar = self.ctx.recursos.get("_fechar")
            if callable(fechar):
                try:
                    fechar()
                except Exception:  # noqa: BLE001, S110
                    pass
        return self.estado

    def iniciar(self) -> None:
        self._thread = threading.Thread(target=self.rodar, name=f"execucao-{self.id}", daemon=True)
        self._thread.start()

    def cancelar(self) -> None:
        self.ctx.cancelado.set()

    def resumo(self) -> dict[str, Any]:
        return {"id": self.id, "plano": self.plano.resumo(), "estado": self.estado, "eventos": len(self.eventos)}


def listar_registro(dir_registro: Path, limite: int = 50) -> list[dict[str, Any]]:
    """Tela Registro: últimas execuções com título e estado final."""
    saida = []
    for arquivo in sorted(dir_registro.glob("*.jsonl"), reverse=True)[:limite]:
        titulo, estado = "", "interrompida"
        for linha in arquivo.read_text(encoding="utf-8").splitlines():
            try:
                ev = json.loads(linha)
            except ValueError:
                continue
            if ev["tipo"] == "inicio":
                titulo = ev["texto"]
            elif ev["tipo"] == "fim":
                estado = ev["texto"]
        saida.append({"id": arquivo.stem, "titulo": titulo, "estado": estado})
    return saida
