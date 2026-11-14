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


def _attach(arq: Path, dado: dict) -> None:
    """Uma linha inteira por escrita, com trava e fsync: falha no meio corrompe no máximo a última linha."""
    arq.parent.mkdir(parents=True, exist_ok=True)
    linha = json.dumps(dado, ensure_ascii=False, separators=(",", ":")) + "\n"
    with open(arq, "a", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(linha)
        f.flush()
        os.fsync(f.fileno())
        fcntl.flock(f, fcntl.LOCK_UN)


def artifact(dado: Any) -> str:
    """Guarda um artefato (bytes, str ou JSON) por conteúdo → "sha:<hex>". Repetido não se regrava."""
    if isinstance(dado, bytes):
        bruto, ext = dado, ".bin"
    elif isinstance(dado, str):
        bruto, ext = dado.encode(), ".txt"
    else:
        bruto, ext = json.dumps(dado, ensure_ascii=False, sort_keys=True).encode(), ".json"
    sha = hashlib.sha256(bruto).hexdigest()
    arq = ARTIFACTS / sha[:2] / f"{sha}{ext}"
    if not arq.exists():
        arq.parent.mkdir(parents=True, exist_ok=True)
        tmp = arq.with_suffix(arq.suffix + ".parcial")
        tmp.write_bytes(bruto)
        tmp.replace(arq)
    return f"sha:{sha}"


def read_artifact(ref: str) -> Any:
    sha = ref.removeprefix("sha:")
    for arq in (ARTIFACTS / sha[:2]).glob(f"{sha}.*"):
        if arq.suffix == ".json":
            return json.loads(arq.read_text())
        return arq.read_text() if arq.suffix == ".txt" else arq.read_bytes()
    raise KeyError(ref)


def file_artifact(ref: str) -> Path:
    sha = ref.removeprefix("sha:")
    return next((ARTIFACTS / sha[:2]).glob(f"{sha}.*"))


def write(tarefa: str, *, grupo: str, contexto: dict, saida: Any, origem: str, pai: str | None = None,
           n0: Any = None, portao: dict | None = None, humano: dict | None = None, versoes: dict | None = None,
           metricas: dict | None = None, extra: dict | None = None) -> str:
    """Grava um registro → id. `saida` é o N1 (ou o artefato equivalente: código da peça, decisão N2)."""
    if tarefa not in TASKS:
        raise ValueError(f"tarefa desconhecida: {tarefa}")
    if humano and humano.get("veredito") not in VERDICTS:
        raise ValueError(f"veredito inválido: {humano.get('veredito')}")
    id_ = "rg_" + ulid()
    ctx = json.dumps(contexto, ensure_ascii=False)
    r = {
        "id": id_, "t": _now(), "app": TASKS[tarefa], "tarefa": tarefa, "grupo": grupo, "pai": pai,
        "versoes": versoes or {}, "origem": origem,
        "contexto": contexto if len(ctx) <= INLINE else {"ref": artifact(contexto)},
        "saida": {"n1": artifact(saida), "tokens": len(json.dumps(saida, ensure_ascii=False)) // 4},
        "n0": n0 if n0 is None or isinstance(n0, dict) else {"sha": artifact(n0), "comandos": len(n0)},
        "portao": portao, "humano": humano, "metricas": metricas or {},
    }
    if extra:
        r["extra"] = extra
    _attach(RECORD / TASKS[tarefa] / tarefa / f"{time.strftime('%Y-%m')}.jsonl", r)
    return id_


def evaluate(id_: str, veredito: str, *, nota: int | None = None, motivo: str | None = None,
            comentario: str | None = None) -> None:
    """Veredito humano que chega depois: evento à parte (o registro original não muda)."""
    if veredito not in VERDICTS:
        raise ValueError(f"veredito inválido: {veredito}")
    _attach(EVENTS / f"{time.strftime('%Y-%m')}.jsonl", {
        "t": _now(), "ref": id_, "tipo": "humano",
        "dado": {"veredito": veredito, "nota": nota, "motivo": motivo, "comentario": comentario, "em": _now()}})


def measure(id_: str, **metricas) -> None:
    """Métricas que chegam depois (CTR, retenção, nota da bancada)."""
    _attach(EVENTS / f"{time.strftime('%Y-%m')}.jsonl", {"t": _now(), "ref": id_, "tipo": "metricas",
                                                          "dado": metricas})


def _lines(arq: Path) -> Iterator[dict]:
    with open(arq, encoding="utf-8") as f:
        for linha in f:
            try:
                yield json.loads(linha)
            except ValueError:  # última linha de uma escrita interrompida
                continue


def _events() -> dict[str, list[dict]]:
    ev: dict[str, list[dict]] = {}
    for arq in sorted(EVENTS.glob("*.jsonl")):
        for e in _lines(arq):
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


def records(tarefa: str | None = None, app: str | None = None) -> Iterator[dict]:
    """Registros com os eventos posteriores aplicados (o último veredito vale) e o campo `uso` calculado."""
    ev = _events()
    base = RECORD / app if app else RECORD
    padrao = f"**/{tarefa}/*.jsonl" if tarefa else "**/*.jsonl"
    for arq in sorted(base.glob(padrao)):
        if arq.parent.name == "_eventos":
            continue
        for r in _lines(arq):
            for e in ev.get(r["id"], ()):
                if e["tipo"] == "humano":
                    r["humano"] = e["dado"]
                else:
                    r["metricas"] = {**(r.get("metricas") or {}), **e["dado"]}
            r["uso"] = usage(r)
            yield r


def last(grupo: str | None = None, tarefa: str | None = None, **extra) -> dict | None:
    """Registro mais recente de um grupo e/ou com esses campos em `extra` (ex.: `peca=<id>`)."""
    achado = None
    for r in records(tarefa):
        if grupo and r["grupo"] != grupo:
            continue
        if any((r.get("extra") or {}).get(k) != v for k, v in extra.items()):
            continue
        if achado is None or r["id"] > achado["id"]:
            achado = r
    return achado
