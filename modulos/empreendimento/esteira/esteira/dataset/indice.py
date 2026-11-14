"""Índice SQLite do dataset: só para consultar e contar. É derivado: `reindexar()` o refaz dos JSONL."""
import json
import sqlite3
from contextlib import closing

from esteira.dataset import registro as R

ARQUIVO = R.PASTA / "indice.db"
MINIMO = {"peca_animar": 500, "peca_html": 0, "montar": 1500, "corrigir_montagem": 200, "thumb_compor": 300,
          "foto_tratar": 100}

_ESQUEMA = """
CREATE TABLE registros (
  id TEXT PRIMARY KEY, t TEXT, app TEXT, tarefa TEXT, grupo TEXT, pai TEXT, origem TEXT,
  veredito TEXT, nota INTEGER, portao_ok INTEGER, uso TEXT, n1_versao INTEGER, dados TEXT);
CREATE INDEX ix_tarefa ON registros(tarefa, uso);
CREATE INDEX ix_grupo ON registros(grupo);
"""


def reindexar() -> int:
    tmp = ARQUIVO.with_suffix(".db.novo")
    tmp.unlink(missing_ok=True)
    ARQUIVO.parent.mkdir(parents=True, exist_ok=True)
    n = 0
    with closing(sqlite3.connect(tmp)) as db:
        db.executescript(_ESQUEMA)
        for r in R.registros():
            h = r.get("humano") or {}
            p = r.get("portao") or {}
            db.execute("INSERT OR REPLACE INTO registros VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", (
                r["id"], r["t"], r["app"], r["tarefa"], r["grupo"], r.get("pai"), r["origem"], h.get("veredito"),
                h.get("nota"), None if not p else int(bool(p.get("ok"))), r["uso"],
                (r.get("versoes") or {}).get("n1"), json.dumps(r, ensure_ascii=False)))
            n += 1
        db.commit()
    tmp.replace(ARQUIVO)
    return n


def _db() -> sqlite3.Connection:
    if not ARQUIVO.exists():
        reindexar()
    db = sqlite3.connect(ARQUIVO)
    db.row_factory = sqlite3.Row
    return db


def consultar(**filtros) -> list[dict]:
    """Registros que batem com os filtros de coluna (app, tarefa, grupo, origem, veredito, uso)."""
    cols = {"app", "tarefa", "grupo", "origem", "veredito", "uso"}
    onde = [f"{k} = ?" for k in filtros if k in cols]
    with closing(_db()) as db:
        linhas = db.execute(f"SELECT dados FROM registros {'WHERE ' + ' AND '.join(onde) if onde else ''} "
                            "ORDER BY id", [v for k, v in filtros.items() if k in cols]).fetchall()
    return [json.loads(x["dados"]) for x in linhas]


def situacao() -> dict:
    """Por tarefa: total, por uso e quanto falta para o mínimo de treino."""
    reindexar()
    with closing(_db()) as db:
        linhas = db.execute("SELECT tarefa, uso, COUNT(*) n FROM registros GROUP BY tarefa, uso").fetchall()
    saida = {t: {"total": 0, "sft": 0, "dpo_ruim": 0, "pendente": 0, "descartar": 0, "minimo": m}
             for t, m in MINIMO.items()}
    for x in linhas:
        s = saida.setdefault(x["tarefa"], {"total": 0, "minimo": 0})
        s[x["uso"]] = s.get(x["uso"], 0) + x["n"]
        s["total"] += x["n"]
    for s in saida.values():
        s["pronta"] = bool(s["minimo"]) and s.get("sft", 0) >= s["minimo"]
    return saida
