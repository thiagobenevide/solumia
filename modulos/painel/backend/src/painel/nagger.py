"""Cobrador: metas com ritmo, agenda do dia (sugerida a partir das tarefas e editada pelo usuário),
contestação quando a edição tira ou empurra uma entrega prioritária, e alertas de desvio.

Tudo fica em `cobrador.json` na pasta de dados. Horários da agenda são locais (fuso configurado),
no formato `HH:MM`; datas são `AAAA-MM-DD`."""

import json
import os
import threading
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

PRIORITIES = {"alta": 0, "media": 1, "baixa": 2}
FREQUENCIES = ("diaria", "semanal")

# janela padrão do dia sugerido: blocos de foco de 50 min com 10 min de pausa
START_DAY = "08:00"
END_DAY = "18:00"
BLOCK_MIN = 50
PAUSE_MIN = 10


class NotFound(Exception):
    pass


class Invalid(Exception):
    pass


def _min(hhmm: str) -> int:
    try:
        h, m = hhmm.split(":")
        total = int(h) * 60 + int(m)
    except ValueError as e:
        raise Invalid(f"Horário inválido: {hhmm!r}") from e
    if not 0 <= total < 24 * 60:
        raise Invalid(f"Horário inválido: {hhmm!r}")
    return total


def _hhmm(minutos: int) -> str:
    return f"{minutos // 60:02d}:{minutos % 60:02d}"


def _id() -> str:
    return uuid.uuid4().hex[:10]


class Nagger:
    def __init__(self, root: str | Path, timezone: str = "America/Sao_Paulo") -> None:
        self.root = Path(root).expanduser()
        self.root.mkdir(parents=True, exist_ok=True)
        self.timezone = ZoneInfo(timezone)
        self._arquivo = self.root / "cobrador.json"
        self._lock = threading.RLock()

    def agora(self) -> datetime:
        return datetime.now(self.timezone)

    def _read(self) -> dict[str, Any]:
        if not self._arquivo.exists():
            return {"metas": [], "acoes": [], "agendas": {}}
        data: dict[str, Any] = json.loads(self._arquivo.read_text("utf-8"))
        return data

    def _write(self, dados: dict[str, Any]) -> None:
        tmp = self._arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1), "utf-8")
        os.replace(tmp, self._arquivo)

    # --- metas ---

    def metas(self, hoje: date | None = None) -> list[dict[str, Any]]:
        """Metas com o progresso do período atual (dia ou semana iniciada na segunda)."""
        hoje = hoje or self.agora().date()
        with self._lock:
            data = self._read()
        output = []
        for m in data["metas"]:
            start = hoje if m["frequencia"] == "diaria" else hoje - timedelta(days=hoje.weekday())
            done = sum(
                a["quantidade"]
                for a in data["acoes"]
                if a["meta_id"] == m["id"] and start.isoformat() <= a["data"] <= hoje.isoformat()
            )
            # ritmo esperado: na semana, proporcional aos dias corridos (seg=1/7 … dom=7/7)
            fraction = 1.0 if m["frequencia"] == "diaria" else (hoje.weekday() + 1) / 7
            output.append(m | {"feito": done, "esperado": round(m["alvo"] * fraction, 1)})
        return output

    def create_meta(self, d: dict[str, Any]) -> dict[str, Any]:
        if d.get("frequencia", "diaria") not in FREQUENCIES:
            raise Invalid("Frequência deve ser diaria ou semanal")
        if d.get("alvo", 1) <= 0:
            raise Invalid("Alvo deve ser positivo")
        meta = {
            "id": _id(),
            "titulo": d["titulo"].strip(),
            "frequencia": d.get("frequencia", "diaria"),
            "alvo": d.get("alvo", 1),
            "unidade": d.get("unidade", "vez"),
            "criada_em": self.agora().isoformat(timespec="seconds"),
        }
        with self._lock:
            data = self._read()
            data["metas"].append(meta)
            self._write(data)
        return meta

    def delete_meta(self, id_: str) -> None:
        with self._lock:
            data = self._read()
            if not any(m["id"] == id_ for m in data["metas"]):
                raise NotFound(id_)
            data["metas"] = [m for m in data["metas"] if m["id"] != id_]
            data["acoes"] = [a for a in data["acoes"] if a["meta_id"] != id_]
            self._write(data)

    def register_action(self, meta_id: str, quantidade: float = 1, note: str = "") -> dict[str, Any]:
        now = self.agora()
        with self._lock:
            data = self._read()
            if not any(m["id"] == meta_id for m in data["metas"]):
                raise NotFound(meta_id)
            action = {
                "id": _id(),
                "meta_id": meta_id,
                "data": now.date().isoformat(),
                "em": now.isoformat(timespec="seconds"),
                "quantidade": quantidade,
                "nota": note,
            }
            data["acoes"].append(action)
            self._write(data)
        return action

    # --- agenda ---

    def agenda(self, day: str) -> dict[str, Any]:
        date.fromisoformat(day)
        with self._lock:
            ag = self._read()["agendas"].get(day)
        return ag or {"data": day, "blocos": [], "sugerida": None, "alteracoes": []}

    def suggest(self, day: str, tarefas: list[dict[str, Any]]) -> dict[str, Any]:
        """Monta a agenda do dia com as tarefas abertas: prazo vencido/de hoje primeiro, depois
        prioridade e prazo. Guarda a sugestão como referência para contestar mudanças."""
        today = date.fromisoformat(day)
        opened = [t for t in tarefas if t.get("coluna") != "concluida"]

        def chave(t: dict[str, Any]) -> tuple[int, int, str]:
            deadline = (t.get("prazo") or "9999-12-31")[:10]
            return (
                0 if deadline <= today.isoformat() else 1,
                PRIORITIES.get(t["prioridade"], 1),
                deadline,
            )

        blocks = []
        cursor, end = _min(START_DAY), _min(END_DAY)
        for t in sorted(opened, key=chave):
            if cursor + BLOCK_MIN > end:
                break
            blocks.append(
                {
                    "id": _id(),
                    "titulo": t["titulo"],
                    "inicio": _hhmm(cursor),
                    "fim": _hhmm(cursor + BLOCK_MIN),
                    "prioridade": t["prioridade"],
                    "tarefa_id": t["id"],
                    "prazo": t.get("prazo"),
                    "feito": False,
                }
            )
            cursor += BLOCK_MIN + PAUSE_MIN
        ag = {
            "data": day,
            "blocos": blocks,
            "sugerida": [dict(b) for b in blocks],
            "alteracoes": [],
        }
        with self._lock:
            data = self._read()
            data["agendas"][day] = ag
            self._write(data)
        return ag

    def salvar(self, day: str, blocks: list[dict[str, Any]], motivo: str = "") -> dict[str, Any]:
        """Grava a agenda editada e devolve as contestações: entregas prioritárias que saíram do
        dia ou foram empurradas para depois. `motivo` vai para o histórico de alterações."""
        date.fromisoformat(day)
        for b in blocks:
            if _min(b["inicio"]) >= _min(b["fim"]):
                raise Invalid(f"Bloco {b.get('titulo')!r} termina antes de começar")
            b.setdefault("id", _id())
            b.setdefault("feito", False)
            b.setdefault("prioridade", "media")
        with self._lock:
            data = self._read()
            before = data["agendas"].get(day) or self.agenda(day)
            contestacoes = self._contestar(before["blocos"], blocks)
            alteracoes = before.get("alteracoes", []) + [
                {
                    "em": self.agora().isoformat(timespec="seconds"),
                    "motivo": motivo,
                    "contestacoes": contestacoes,
                }
            ]
            ag = before | {
                "blocos": sorted(blocks, key=lambda b: b["inicio"]),
                "alteracoes": alteracoes,
            }
            data["agendas"][day] = ag
            self._write(data)
        return ag | {"contestacoes": contestacoes}

    @staticmethod
    def _contestar(before: list[dict[str, Any]], after: list[dict[str, Any]]) -> list[str]:
        new = {b.get("tarefa_id") or b["titulo"]: b for b in after}
        output = []
        for b in before:
            if b["prioridade"] != "alta" or b.get("feito"):
                continue
            novo = new.get(b.get("tarefa_id") or b["titulo"])
            deadline = f" (prazo {b['prazo'][:10]})" if b.get("prazo") else ""
            if novo is None:
                output.append(
                    f"Você tirou do dia “{b['titulo']}”, prioridade alta{deadline}. "
                    "Qual entrega substitui?"
                )
            elif _min(novo["inicio"]) > _min(b["inicio"]) + 120:
                output.append(
                    f"“{b['titulo']}” foi de {b['inicio']} para {novo['inicio']}{deadline}. "
                    "Empurrar a prioridade para o fim do dia costuma virar adiamento."
                )
        return output

    def marcar(self, day: str, block_id: str, done: bool = True) -> dict[str, Any]:
        with self._lock:
            data = self._read()
            ag = data["agendas"].get(day)
            block = next((b for b in (ag or {}).get("blocos", []) if b["id"] == block_id), None)
            if block is None:
                raise NotFound(block_id)
            block["feito"] = done
            self._write(data)
        return block

    # --- cobrança ---

    def disciplina(
        self, tarefas: list[dict[str, Any]], agora: datetime | None = None
    ) -> dict[str, Any]:
        """Retrato do dia: blocos cumpridos até agora, metas no ritmo e a lista de alertas."""
        agora = agora or self.agora()
        day = agora.date().isoformat()
        minuto = agora.hour * 60 + agora.minute
        ag = self.agenda(day)
        vencidos = [b for b in ag["blocos"] if _min(b["fim"]) <= minuto]
        done = [b for b in vencidos if b["feito"]]
        goals = self.metas(agora.date())
        alerts: list[dict[str, str]] = []

        def alerta(nivel: str, text: str) -> None:
            alerts.append({"nivel": nivel, "texto": text})

        if not ag["blocos"] and minuto >= _min(START_DAY):
            alerta("aviso", "Sem agenda para hoje. Peça a sugestão do dia e ajuste.")
        for b in vencidos:
            if not b["feito"]:
                nivel = "critico" if b["prioridade"] == "alta" else "aviso"
                alerta(
                    nivel,
                    f"“{b['titulo']}” ({b['inicio']}–{b['fim']}) passou "
                    "e não foi marcado como feito.",
                )
        current = next(
            (b for b in ag["blocos"] if _min(b["inicio"]) <= minuto < _min(b["fim"])), None
        )
        for m in goals:
            if m["feito"] < m["esperado"] and (m["frequencia"] == "semanal" or minuto >= 18 * 60):
                alerta(
                    "aviso",
                    f"Meta “{m['titulo']}”: {m['feito']:g} de {m['esperado']:g} "
                    f"{m['unidade']} esperados.",
                )
        in_agenda = {b.get("tarefa_id") for b in ag["blocos"]}
        for t in tarefas:
            deadline = (t.get("prazo") or "")[:10]
            if (
                t.get("coluna") != "concluida"
                and deadline
                and deadline <= day
                and t["id"] not in in_agenda
            ):
                alerta(
                    "critico",
                    f"“{t['titulo']}” vence {'hoje' if deadline == day else 'atrasada'} "
                    "e está fora da agenda.",
                )

        goals_ok = sum(m["feito"] >= m["esperado"] for m in goals)
        points = [len(done) / len(vencidos)] if vencidos else []
        if goals:
            points.append(goals_ok / len(goals))
        index = round(100 * sum(points) / len(points)) if points else None
        return {
            "data": day,
            "agora": _hhmm(minuto),
            "indice": index,
            "dentro": index is None or index >= 70,
            "blocos": {
                "total": len(ag["blocos"]),
                "vencidos": len(vencidos),
                "feitos": len(done),
            },
            "bloco_atual": current,
            "metas": {"total": len(goals), "no_ritmo": goals_ok},
            "alertas": alerts,
        }

    def contexto(self, tarefas: list[dict[str, Any]]) -> str:
        """Retrato do dia em texto para o prompt do cobrador."""
        return self.moment(tarefas) + "\n" + self.portrait(tarefas)

    def moment(self, tarefas: list[dict[str, Any]]) -> str:
        """O que muda a cada minuto (hora, índice, alertas). Fica fora do prompt de sistema para o
        llama-server reaproveitar o cache do prefixo entre as mensagens."""
        d = self.disciplina(tarefas)
        lines = [f"Hoje {d['data']}, agora {d['agora']}. Índice de disciplina: {d['indice']}."]
        lines.append("## Alertas")
        lines += [f"- [{a['nivel']}] {a['texto']}" for a in d["alertas"]] or ["- nenhum"]
        return "\n".join(lines)

    def portrait(self, tarefas: list[dict[str, Any]], max_tasks: int = 40) -> str:
        """Agenda, metas e tarefas abertas (as mais urgentes primeiro, no máximo [max_tarefas])."""
        lines = ["## Agenda do dia"]
        for b in self.agenda(self.agora().date().isoformat())["blocos"]:
            mark = "x" if b["feito"] else " "
            lines.append(
                f"- [{mark}] {b['inicio']}–{b['fim']} {b['titulo']} (prioridade {b['prioridade']})"
            )
        lines.append("\n## Metas")
        for m in self.metas():
            lines.append(
                f"- {m['titulo']}: {m['feito']:g}/{m['alvo']:g} {m['unidade']} ({m['frequencia']})"
            )
        lines.append("\n## Tarefas abertas")
        opened = [t for t in tarefas if t.get("coluna") != "concluida"]
        weight = {"alta": 0, "media": 1, "baixa": 2}
        opened.sort(
            key=lambda t: (
                t.get("coluna") != "execucao",
                not t.get("prazo"),
                str(t.get("prazo") or ""),
                weight.get(str(t.get("prioridade")), 1),
            )
        )
        for t in opened[:max_tasks]:
            deadline = f", prazo {t['prazo']}" if t.get("prazo") else ""
            lines.append(f"- {t['titulo']} ({t['prioridade']}{deadline}, {t.get('coluna')})")
        if len(opened) > max_tasks:
            lines.append(f"- … e mais {len(opened) - max_tasks} tarefas de menor urgência")
        return "\n".join(lines)
