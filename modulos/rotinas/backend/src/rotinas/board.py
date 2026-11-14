"""Quadro Kanban guardado em `tarefas.json` na pasta de dados. Cada tarefa tem uma coluna
(pendente, execução, concluída), uma ordem dentro dela e as sessões do temporizador
(`{"inicio", "fim"}` em ISO UTC; `fim` nulo = cronômetro rodando)."""

import json
import os
import threading
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

COLUMNS = ("pendente", "execucao", "concluida")
PRIORITIES = ("baixa", "media", "alta")
FIELDS_EDITABLE = {"titulo", "descricao", "prioridade", "tags", "prazo"}


class NotFound(Exception):
    pass


class Invalid(Exception):
    pass


def _now() -> datetime:
    return datetime.now(UTC)


def _iso(moment: datetime) -> str:
    return moment.isoformat(timespec="seconds")


def _seconds(session: dict[str, Any], agora: datetime) -> int:
    end = datetime.fromisoformat(session["fim"]) if session["fim"] else agora
    return max(0, int((end - datetime.fromisoformat(session["inicio"])).total_seconds()))


class Frame:
    def __init__(self, root: str | Path) -> None:
        self.root = Path(root).expanduser()
        self.root.mkdir(parents=True, exist_ok=True)
        self._arquivo = self.root / "tarefas.json"
        self._lock = threading.RLock()

    def _read(self) -> list[dict[str, Any]]:
        if not self._arquivo.exists():
            return []
        data: list[dict[str, Any]] = json.loads(self._arquivo.read_text("utf-8"))
        return data

    def _write(self, tarefas: list[dict[str, Any]]) -> None:
        tmp = self._arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(tarefas, ensure_ascii=False, indent=1), "utf-8")
        os.replace(tmp, self._arquivo)

    @staticmethod
    def _find(tarefas: list[dict[str, Any]], id_: str) -> dict[str, Any]:
        for t in tarefas:
            if t["id"] == id_:
                return t
        raise NotFound(id_)

    @staticmethod
    def _publica(t: dict[str, Any], agora: datetime) -> dict[str, Any]:
        """Tarefa com os campos derivados do temporizador."""
        aberta = next((s for s in t["sessoes"] if not s["fim"]), None)
        return {
            **t,
            "tempo_total": sum(_seconds(s, agora) for s in t["sessoes"]),
            "rodando_desde": aberta["inicio"] if aberta else None,
        }

    @staticmethod
    def _validate(dados: dict[str, Any]) -> None:
        if dados.get("prioridade", "media") not in PRIORITIES:
            raise Invalid(f"Prioridade inválida: {dados['prioridade']}")
        if dados.get("prazo"):
            try:
                datetime.fromisoformat(dados["prazo"])
            except ValueError as e:
                raise Invalid(f"Prazo inválido: {dados['prazo']}") from e

    @staticmethod
    def _stop(t: dict[str, Any], agora: datetime) -> None:
        for s in t["sessoes"]:
            if not s["fim"]:
                s["fim"] = _iso(agora)

    @staticmethod
    def _reordenar(tarefas: list[dict[str, Any]], coluna: str) -> None:
        of_coluna = sorted((t for t in tarefas if t["coluna"] == coluna), key=lambda t: t["ordem"])
        for i, t in enumerate(of_coluna):
            t["ordem"] = i

    # --- consultas ---

    def list_all(self) -> list[dict[str, Any]]:
        now = _now()
        with self._lock:
            tasks = self._read()
        tasks.sort(key=lambda t: (COLUMNS.index(t["coluna"]), t["ordem"]))
        return [self._publica(t, now) for t in tasks]

    def obter(self, id_: str) -> dict[str, Any]:
        with self._lock:
            return self._publica(self._find(self._read(), id_), _now())

    def resumo(self) -> dict[str, Any]:
        """Contagem por coluna, tempo gasto hoje (UTC) e o cronômetro ativo."""
        now = _now()
        start_day = now.replace(hour=0, minute=0, second=0, microsecond=0)
        tasks = self.list_all()
        today = 0
        for t in tasks:
            for s in t["sessoes"]:
                start = max(datetime.fromisoformat(s["inicio"]), start_day)
                end = datetime.fromisoformat(s["fim"]) if s["fim"] else now
                today += max(0, int((end - start).total_seconds()))
        return {
            "colunas": {c: sum(t["coluna"] == c for t in tasks) for c in COLUMNS},
            "tempo_hoje": today,
            "tempo_total": sum(t["tempo_total"] for t in tasks),
            "rodando": next((t["id"] for t in tasks if t["rodando_desde"]), None),
        }

    # --- edição ---

    def criar(self, dados: dict[str, Any]) -> dict[str, Any]:
        self._validate(dados)
        coluna = dados.get("coluna", "pendente")
        if coluna not in COLUMNS:
            raise Invalid(f"Coluna inválida: {coluna}")
        now = _now()
        with self._lock:
            tasks = self._read()
            t = {
                "id": uuid.uuid4().hex[:12],
                "titulo": dados["titulo"].strip(),
                "descricao": dados.get("descricao", ""),
                "prioridade": dados.get("prioridade", "media"),
                "tags": dados.get("tags", []),
                "prazo": dados.get("prazo"),
                "coluna": coluna,
                "ordem": sum(x["coluna"] == coluna for x in tasks),
                "criada_em": _iso(now),
                "concluida_em": _iso(now) if coluna == "concluida" else None,
                "sessoes": [],
            }
            tasks.append(t)
            self._write(tasks)
            return self._publica(t, now)

    def atualizar(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        changes = {k: v for k, v in dados.items() if k in FIELDS_EDITABLE and v is not None}
        self._validate(changes)
        with self._lock:
            tasks = self._read()
            t = self._find(tasks, id_)
            t.update(changes)
            if "prazo" in dados and dados["prazo"] == "":
                t["prazo"] = None
            self._write(tasks)
            return self._publica(t, _now())

    def mover(self, id_: str, coluna: str, order: int | None = None) -> dict[str, Any]:
        """Leva a tarefa para [coluna] na posição [ordem] (fim da coluna se nula). Concluir para o
        cronômetro; reabrir limpa a data de conclusão."""
        if coluna not in COLUMNS:
            raise Invalid(f"Coluna inválida: {coluna}")
        now = _now()
        with self._lock:
            tasks = self._read()
            t = self._find(tasks, id_)
            origin = t["coluna"]
            destination = sorted(
                (x for x in tasks if x["coluna"] == coluna and x is not t),
                key=lambda x: x["ordem"],
            )
            pos = len(destination) if order is None else max(0, min(order, len(destination)))
            destination.insert(pos, t)
            for i, x in enumerate(destination):
                x["ordem"] = i
            t["coluna"] = coluna
            if coluna == "concluida":
                self._stop(t, now)
                t["concluida_em"] = t["concluida_em"] or _iso(now)
            else:
                t["concluida_em"] = None
            if origin != coluna:
                self._reordenar(tasks, origin)
            self._write(tasks)
            return self._publica(t, now)

    def excluir(self, id_: str) -> None:
        with self._lock:
            tasks = self._read()
            t = self._find(tasks, id_)
            tasks.remove(t)
            self._reordenar(tasks, t["coluna"])
            self._write(tasks)

    # --- temporizador ---

    def iniciar(self, id_: str) -> dict[str, Any]:
        """Um cronômetro por vez: pausa o que estiver rodando e leva a tarefa para execução."""
        now = _now()
        with self._lock:
            tasks = self._read()
            t = self._find(tasks, id_)
            if t["coluna"] == "concluida":
                raise Invalid("Reabra a tarefa antes de iniciar o cronômetro")
            if any(not s["fim"] for s in t["sessoes"]):
                return self._publica(t, now)
            for other in tasks:
                self._stop(other, now)
            t["sessoes"].append({"inicio": _iso(now), "fim": None})
            self._write(tasks)
        if t["coluna"] == "pendente":
            return self.mover(id_, "execucao", 0)
        return self._publica(t, now)

    def pause(self, id_: str) -> dict[str, Any]:
        now = _now()
        with self._lock:
            tasks = self._read()
            t = self._find(tasks, id_)
            self._stop(t, now)
            self._write(tasks)
            return self._publica(t, now)

    def zerar(self, id_: str) -> dict[str, Any]:
        with self._lock:
            tasks = self._read()
            t = self._find(tasks, id_)
            t["sessoes"] = []
            self._write(tasks)
            return self._publica(t, _now())

    # --- LLM ---

    def contexto(self) -> str:
        """Retrato do quadro em texto para o prompt do assistente."""

        def dur(s: int) -> str:
            return f"{s // 3600}h{s % 3600 // 60:02d}min"

        names = {"pendente": "Pendentes", "execucao": "Em execução", "concluida": "Concluídas"}
        tasks = self.list_all()
        lines = [f"Agora (UTC): {_iso(_now())}"]
        for c in COLUMNS:
            lines.append(f"\n## {names[c]}")
            for t in (x for x in tasks if x["coluna"] == c):
                extra = [f"prioridade {t['prioridade']}", f"tempo {dur(t['tempo_total'])}"]
                if t["prazo"]:
                    extra.append(f"prazo {t['prazo']}")
                if t["tags"]:
                    extra.append("tags " + ", ".join(t["tags"]))
                if t["rodando_desde"]:
                    extra.append("cronômetro rodando")
                lines.append(f"- {t['titulo']} ({'; '.join(extra)})")
                if t["descricao"]:
                    lines.append(f"  {t['descricao'][:300]}")
        return "\n".join(lines)
