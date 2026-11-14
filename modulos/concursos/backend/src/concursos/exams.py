"""Concursos guardados em `<raiz>/<id>/`: `concurso.json` (dados, estrutura gerada pelo Claude,
prazos e tarefas), `edital.pdf` e `edital.txt` (texto extraído pelo pdftotext).

`geracao.estado`: `sem_plano` → `gerando` → `pronto` | `erro`."""

import json
import os
import shutil
import subprocess
import threading
import uuid
from collections.abc import Callable
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any

from concursos import schedule
from concursos.study import Study

FIELDS_EDITABLE = {
    "nome",
    "banca",
    "cargo",
    "data_prova",
    "minutos_util",
    "minutos_fds",
    "observacoes",
    "edital_url",
}


class NotFound(Exception):
    pass


class Invalid(Exception):
    pass


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _data(text: str | None) -> date | None:
    try:
        return date.fromisoformat(str(text)[:10]) if text else None
    except ValueError:
        return None


def text_pdf(pdf: Path) -> str:
    try:
        r = subprocess.run(
            ["pdftotext", "-layout", str(pdf), "-"], capture_output=True, timeout=120, text=True
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        raise Invalid("Não foi possível ler o PDF (pdftotext ausente ou demorou demais).") from e
    return r.stdout


class Exams:
    def __init__(self, root: str | Path, hoje: Callable[[], date] = date.today) -> None:
        self.root = Path(root).expanduser()
        self.root.mkdir(parents=True, exist_ok=True)
        self.hoje = hoje
        self._lock = threading.RLock()
        self.study = Study(self.root)

    # --- arquivos ---
    def _folder(self, id_: str) -> Path:
        folder = self.root / id_
        if not id_.isalnum() or not (folder / "concurso.json").exists():
            raise NotFound(id_)
        return folder

    def _read(self, id_: str) -> dict[str, Any]:
        data: dict[str, Any] = json.loads((self._folder(id_) / "concurso.json").read_text("utf-8"))
        return data

    def _write(self, c: dict[str, Any]) -> None:
        c["atualizado"] = _now()
        file = self.root / c["id"] / "concurso.json"
        tmp = file.with_suffix(".tmp")
        tmp.write_text(json.dumps(c, ensure_ascii=False, indent=1), "utf-8")
        os.replace(tmp, file)

    # --- CRUD ---
    def criar(self, dados: dict[str, Any]) -> dict[str, Any]:
        id_ = uuid.uuid4().hex[:12]
        c = {
            "id": id_,
            "nome": dados["nome"],
            "banca": dados.get("banca", ""),
            "cargo": dados["cargo"],
            "data_prova": dados.get("data_prova"),
            "minutos_util": int(dados.get("minutos_util", 120)),
            "minutos_fds": int(dados.get("minutos_fds", 240)),
            "observacoes": dados.get("observacoes", ""),
            "edital_url": dados.get("edital_url", ""),
            "edital": None,
            "criado": _now(),
            "geracao": {"estado": "sem_plano", "erro": "", "inicio": None, "fim": None},
            "radar": dados.get("radar"),
            "estrutura": None,
            "resumo_plano": None,
            "prazos": [],
            "tarefas": [],
        }
        with self._lock:
            (self.root / id_).mkdir()
            self._write(c)
        return c

    def list_all(self) -> list[dict[str, Any]]:
        output = []
        for file in sorted(self.root.glob("*/concurso.json")):
            c = json.loads(file.read_text("utf-8"))
            output.append(self.resumo(c))
        return sorted(output, key=lambda c: (c["data_prova"] or "9999", c["nome"]))

    def resumo(self, c: dict[str, Any]) -> dict[str, Any]:
        today = self.hoje()
        tasks = c["tarefas"]
        done = sum(1 for t in tasks if t["feito"])
        proof = _data(c["data_prova"])
        futuros = sorted(
            (p for p in c["prazos"] if (_data(p["data"]) or date.min) >= today),
            key=lambda p: p["data"],
        )
        return {
            "id": c["id"],
            "nome": c["nome"],
            "banca": c["banca"],
            "cargo": c["cargo"],
            "data_prova": c["data_prova"],
            "dias_para_prova": (proof - today).days if proof else None,
            "estado": c["geracao"]["estado"],
            "tem_edital": bool(c["edital"]),
            "tarefas": len(tasks),
            "feitas": done,
            "atrasadas": sum(1 for t in tasks if not t["feito"] and t["data"] < today.isoformat()),
            "proximo_prazo": futuros[0] if futuros else None,
        }

    def obter(self, id_: str) -> dict[str, Any]:
        c = self._read(id_)
        c["situacao"] = self.resumo(c)
        return c

    def atualizar(self, id_: str, fields: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            c = self._read(id_)
            for k, v in fields.items():
                if k in FIELDS_EDITABLE:
                    c[k] = v
            self._write(c)
        return self.obter(id_)

    def excluir(self, id_: str) -> None:
        with self._lock:
            shutil.rmtree(self._folder(id_))

    # --- edital ---
    def save_notice(self, id_: str, nome: str, content: bytes) -> dict[str, Any]:
        if not content.startswith(b"%PDF"):
            raise Invalid("O edital precisa ser um PDF.")
        folder = self._folder(id_)
        (folder / "edital.pdf").write_bytes(content)
        text = text_pdf(folder / "edital.pdf")
        if len(text.strip()) < 500:
            raise Invalid("O PDF não tem texto legível (edital escaneado?).")
        (folder / "edital.txt").write_text(text, "utf-8")
        with self._lock:
            c = self._read(id_)
            c["edital"] = {
                "nome": nome,
                "bytes": len(content),
                "caracteres": len(text),
                "enviado": _now(),
            }
            self._write(c)
        return self.obter(id_)

    def text_notice(self, id_: str) -> str:
        file = self._folder(id_) / "edital.txt"
        if not file.exists():
            raise Invalid("Envie o edital (PDF) antes de gerar o plano.")
        return file.read_text("utf-8")

    # --- plano ---
    def mark_generation(self, id_: str, estado: str, erro: str = "") -> None:
        with self._lock:
            c = self._read(id_)
            g = c["geracao"]
            g.update(estado=estado, erro=erro)
            if estado == "gerando":
                g.update(inicio=_now(), fim=None)
            else:
                g["fim"] = _now()
            self._write(c)

    def apply_structure(self, id_: str, structure: dict[str, Any]) -> dict[str, Any]:
        """Guarda a estrutura do Claude, troca os prazos vindos do edital (os manuais ficam) e
        gera o calendário de hoje até a prova."""
        with self._lock:
            c = self._read(id_)
            c["estrutura"] = structure
            if not _data(c["data_prova"]) and _data(structure.get("data_prova")):
                c["data_prova"] = structure["data_prova"][:10]
            manuais = [p for p in c["prazos"] if p.get("origem") == "manual"]
            of_notice = [
                {**p, "id": uuid.uuid4().hex[:10], "origem": "edital"}
                for p in structure.get("prazos", [])
                if _data(p.get("data"))
            ]
            c["prazos"] = sorted(manuais + of_notice, key=lambda p: (p["data"], p.get("hora", "")))
            c["tarefas"] = []
            self._replan(c)
            c["geracao"].update(estado="pronto", erro="", fim=_now())
            self._write(c)
        return self.obter(id_)

    def _replan(self, c: dict[str, Any]) -> None:
        proof = _data(c["data_prova"])
        if not proof or not c["estrutura"]:
            raise Invalid("Sem data da prova ou sem plano gerado.")
        today = self.hoje()
        # feitas ficam; o resto (inclusive atrasadas) é redistribuído de hoje em diante
        kept = [t for t in c["tarefas"] if t["feito"]]
        keys = {t["chave"] for t in kept if t.get("chave")}
        new, summary = schedule.generate(
            c["estrutura"], today, proof, c["minutos_util"], c["minutos_fds"], keys
        )
        c["tarefas"] = sorted(kept + new, key=lambda t: t["data"])
        c["resumo_plano"] = {**summary, "gerado_em": today.isoformat()}

    def replan(self, id_: str) -> dict[str, Any]:
        with self._lock:
            c = self._read(id_)
            self._replan(c)
            self._write(c)
        return self.obter(id_)

    def mark_task(self, id_: str, task_id: str, done: bool) -> dict[str, Any]:
        with self._lock:
            c = self._read(id_)
            for t in c["tarefas"]:
                if t["id"] == task_id:
                    t["feito"] = done
                    t["feito_em"] = self.hoje().isoformat() if done else None
                    self._write(c)
                    return t
        raise NotFound(task_id)

    # --- prazos manuais ---
    def add_deadline(self, id_: str, deadline: dict[str, Any]) -> dict[str, Any]:
        if not _data(deadline.get("data")):
            raise Invalid("Data inválida (use AAAA-MM-DD).")
        new = {
            "hora": "",
            "tipo": "outro",
            "detalhe": "",
            **deadline,
            "id": uuid.uuid4().hex[:10],
            "origem": "manual",
        }
        with self._lock:
            c = self._read(id_)
            c["prazos"] = sorted(c["prazos"] + [new], key=lambda p: (p["data"], p.get("hora", "")))
            self._write(c)
        return new

    def remove_deadline(self, id_: str, deadline_id: str) -> None:
        with self._lock:
            c = self._read(id_)
            before = len(c["prazos"])
            c["prazos"] = [p for p in c["prazos"] if p["id"] != deadline_id]
            if len(c["prazos"]) == before:
                raise NotFound(deadline_id)
            self._write(c)

    # --- alertas ---
    def alerts(self) -> list[dict[str, Any]]:
        """Alertas de todos os concursos para hoje: prazos dos próximos 15 dias, contagem até a
        prova, tarefas de hoje e atrasadas. `nivel`: critico | aviso | info."""
        today = self.hoje()
        output: list[dict[str, Any]] = []
        for file in sorted(self.root.glob("*/concurso.json")):
            c = json.loads(file.read_text("utf-8"))

            def alerta(nivel: str, text: str, c: dict[str, Any] = c) -> None:
                output.append(
                    {"nivel": nivel, "texto": text, "concurso_id": c["id"], "concurso": c["nome"]}
                )

            proof = _data(c["data_prova"])
            if proof and proof >= today:
                days = (proof - today).days
                if days == 0:
                    alerta("critico", f"{c['nome']}: a prova é hoje.")
                elif days <= 7:
                    alerta(
                        "critico",
                        f"{c['nome']}: prova em {days} dia(s). Semana final: só revisão leve.",
                    )
                else:
                    alerta("info", f"{c['nome']}: faltam {days} dias para a prova.")
            for p in c["prazos"]:
                d = _data(p["data"])
                if not d or d < today or (d - today).days > 15 or p.get("tipo") == "prova":
                    continue
                days = (d - today).days
                when = "hoje" if days == 0 else "amanhã" if days == 1 else f"em {days} dias"
                hour = f" às {p['hora']}" if p.get("hora") else ""
                nivel = "critico" if days <= 2 else "aviso" if days <= 7 else "info"
                alerta(nivel, f"{c['nome']}: {p['titulo']} {when} ({d.strftime('%d/%m')}{hour}).")
            pending = [t for t in c["tarefas"] if not t["feito"]]
            atrasadas = [t for t in pending if t["data"] < today.isoformat()]
            of_today = [t for t in pending if t["data"] == today.isoformat()]
            if atrasadas:
                nivel = "critico" if len(atrasadas) >= 5 else "aviso"
                alerta(
                    nivel,
                    f"{c['nome']}: {len(atrasadas)} tarefa(s) atrasada(s). Use Replanejar.",
                )
            if of_today:
                minutes = sum(t["minutos"] for t in of_today)
                alerta(
                    "info", f"{c['nome']}: hoje {len(of_today)} tarefa(s) de estudo ({minutes} min)."
                )
        order = {"critico": 0, "aviso": 1, "info": 2}
        return sorted(output, key=lambda a: order[a["nivel"]])
