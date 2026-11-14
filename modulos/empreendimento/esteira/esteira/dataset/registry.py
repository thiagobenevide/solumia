"""Registro canônico do dataset (`docs/PLANO-DATASET.md` §4): um JSONL que só cresce por tarefa e mês.

Cada geração ou decisão vira um registro com o **contexto estruturado** (nunca o prompt pronto: ele é montado na
exportação, com o modelo de prompt da época), a saída em N1, o N0 compilado, o portão e o veredito humano.
Saídas e contextos grandes vão para `artefatos/` por sha256. Vereditos e métricas que chegam depois são eventos em
`registro/_eventos/`, nunca reescrita da linha original; `registros()` junta os dois.
"""
import fcntl
import hashlib
import json
import os
import secrets
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

from esteira.project import DATA

FOLDER = DATA / "dataset"
RECORD = FOLDER / "registro"
ARTIFACTS = FOLDER / "artefatos"
EVENTS = RECORD / "_eventos"

TASKS = {  # tarefa → app
    "peca_animar": "effectcraft",
    "peca_html": "html",  # peças do motor HTML da fábrica: base para o porte ao EffectCraft
    "montar": "filmcraft",
    "corrigir_montagem": "filmcraft",
    "thumb_compor": "photocraft",
    "foto_tratar": "photocraft",
}
VERDICTS = {"aprovada", "ajuste", "reprovada", "escolhida", "preterida", "editada", "descartada"}
GOOD = {"aprovada", "escolhida", "editada"}
INLINE = 16_000  # contexto acima disso (bytes de JSON) vai para artefatos/

_B32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def ulid() -> str:
    """26 caracteres, ordenável por tempo (48 bits de ms + 80 aleatórios, base32 de Crockford)."""
    n = (int(time.time() * 1000) << 80) | secrets.randbits(80)
    return "".join(_B32[(n >> (5 * i)) & 31] for i in range(25, -1, -1))


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def _attach(file: Path, given: dict) -> None:
    """Uma linha inteira por escrita, com trava e fsync: falha no meio corrompe no máximo a última linha."""
    file.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(given, ensure_ascii=False, separators=(",", ":")) + "\n"
    with open(file, "a", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(line)
        f.flush()
        os.fsync(f.fileno())
        fcntl.flock(f, fcntl.LOCK_UN)


def artifact(given: Any) -> str:
    """Guarda um artefato (bytes, str ou JSON) por conteúdo → "sha:<hex>". Repetido não se regrava."""
    if isinstance(given, bytes):
        raw, ext = given, ".bin"
    elif isinstance(given, str):
        raw, ext = given.encode(), ".txt"
    else:
        raw, ext = json.dumps(given, ensure_ascii=False, sort_keys=True).encode(), ".json"
    sha = hashlib.sha256(raw).hexdigest()
    file = ARTIFACTS / sha[:2] / f"{sha}{ext}"
    if not file.exists():
        file.parent.mkdir(parents=True, exist_ok=True)
        tmp = file.with_suffix(file.suffix + ".parcial")
        tmp.write_bytes(raw)
        tmp.replace(file)
    return f"sha:{sha}"


def read_artifact(ref: str) -> Any:
    sha = ref.removeprefix("sha:")
    for file in (ARTIFACTS / sha[:2]).glob(f"{sha}.*"):
        if file.suffix == ".json":
            return json.loads(file.read_text())
        return file.read_text() if file.suffix == ".txt" else file.read_bytes()
    raise KeyError(ref)


def file_artifact(ref: str) -> Path:
    sha = ref.removeprefix("sha:")
    return next((ARTIFACTS / sha[:2]).glob(f"{sha}.*"))


def write(task: str, *, group: str, context: dict, output: Any, origin: str, parent: str | None = None,
           n0: Any = None, gate: dict | None = None, humano: dict | None = None, versions: dict | None = None,
           metricas: dict | None = None, extra: dict | None = None) -> str:
    """Grava um registro → id. `saida` é o N1 (ou o artefato equivalente: código da peça, decisão N2)."""
    if task not in TASKS:
        raise ValueError(f"tarefa desconhecida: {task}")
    if humano and humano.get("veredito") not in VERDICTS:
        raise ValueError(f"veredito inválido: {humano.get('veredito')}")
    id_ = "rg_" + ulid()
    ctx = json.dumps(context, ensure_ascii=False)
    r = {
        "id": id_, "t": _now(), "app": TASKS[task], "tarefa": task, "grupo": group, "pai": parent,
        "versoes": versions or {}, "origem": origin,
        "contexto": context if len(ctx) <= INLINE else {"ref": artifact(context)},
        "saida": {"n1": artifact(output), "tokens": len(json.dumps(output, ensure_ascii=False)) // 4},
        "n0": n0 if n0 is None or isinstance(n0, dict) else {"sha": artifact(n0), "comandos": len(n0)},
        "portao": gate, "humano": humano, "metricas": metricas or {},
    }
    if extra:
        r["extra"] = extra
    _attach(RECORD / TASKS[task] / task / f"{time.strftime('%Y-%m')}.jsonl", r)
    return id_


def evaluate(id_: str, verdict: str, *, nota: int | None = None, motivo: str | None = None,
            comentario: str | None = None) -> None:
    """Veredito humano que chega depois: evento à parte (o registro original não muda)."""
    if verdict not in VERDICTS:
        raise ValueError(f"veredito inválido: {verdict}")
    _attach(EVENTS / f"{time.strftime('%Y-%m')}.jsonl", {
        "t": _now(), "ref": id_, "tipo": "humano",
        "dado": {"veredito": verdict, "nota": nota, "motivo": motivo, "comentario": comentario, "em": _now()}})


def measure(id_: str, **metricas) -> None:
    """Métricas que chegam depois (CTR, retenção, nota da bancada)."""
    _attach(EVENTS / f"{time.strftime('%Y-%m')}.jsonl", {"t": _now(), "ref": id_, "tipo": "metricas",
                                                          "dado": metricas})


def _lines(file: Path) -> Iterator[dict]:
    with open(file, encoding="utf-8") as f:
        for line in f:
            try:
                yield json.loads(line)
            except ValueError:  # última linha de uma escrita interrompida
                continue


def _events() -> dict[str, list[dict]]:
    ev: dict[str, list[dict]] = {}
    for file in sorted(EVENTS.glob("*.jsonl")):
        for e in _lines(file):
            ev.setdefault(e["ref"], []).append(e)
    return ev


def usage(r: dict) -> str:
    """Para que o registro serve no treino (regras do §4)."""
    h = (r.get("humano") or {}).get("veredito")
    ok = (r.get("portao") or {}).get("ok", True)
    if h in GOOD and ok:
        return "sft"
    if r["tarefa"] == "montar" and r["origem"] == "traducao" and ok and h is None:
        return "sft"  # imitação do código determinístico da montagem (as correções humanas vêm em corrigir_montagem)
    if h in ("reprovada", "preterida", "descartada"):
        return "dpo_ruim"
    if h == "ajuste":
        return "dpo_ruim"  # a versão seguinte (filha) é a boa
    return "descartar" if not ok else "pendente"


def records(task: str | None = None, app: str | None = None) -> Iterator[dict]:
    """Registros com os eventos posteriores aplicados (o último veredito vale) e o campo `uso` calculado."""
    ev = _events()
    base = RECORD / app if app else RECORD
    default = f"**/{task}/*.jsonl" if task else "**/*.jsonl"
    for file in sorted(base.glob(default)):
        if file.parent.name == "_eventos":
            continue
        for r in _lines(file):
            for e in ev.get(r["id"], ()):
                if e["tipo"] == "humano":
                    r["humano"] = e["dado"]
                else:
                    r["metricas"] = {**(r.get("metricas") or {}), **e["dado"]}
            r["uso"] = usage(r)
            yield r


def last(grupo: str | None = None, tarefa: str | None = None, **extra) -> dict | None:
    """Registro mais recente de um grupo e/ou com esses campos em `extra` (ex.: `peca=<id>`)."""
    found = None
    for r in records(tarefa):
        if grupo and r["grupo"] != grupo:
            continue
        if any((r.get("extra") or {}).get(k) != v for k, v in extra.items()):
            continue
        if found is None or r["id"] > found["id"]:
            found = r
    return found
