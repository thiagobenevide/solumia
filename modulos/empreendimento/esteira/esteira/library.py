"""Acervo de mídia: toda imagem e vídeo baixado fica guardado com metadados e é reaproveitado.

Antes de chamar Pexels/Pixabay/Openverse, a busca de mídia consulta o acervo (SQLite + FTS5, sem rede e
sem LLM). Cada item guarda o arquivo original, de onde veio (crédito e licença), dimensões, orientação,
duração, os termos de busca que o acharam, as tags do banco, a descrição feita pelo modelo de visão local,
as notas que recebeu por termo (para não reavaliar) e onde já foi usado (para não repetir no mesmo canal).

Arquivos: `<pasta>/<provedor>/<id>.<ext>` e miniaturas em `<pasta>/.miniaturas/<id>.jpg`;
banco: `<pasta>/acervo.db`. Pasta em `[acervo] pasta` do config.toml.
"""
import json
import os
import re
import shutil
import sqlite3
import subprocess
import threading
import tomllib
from datetime import datetime
from pathlib import Path

from esteira.project import DATA, ROOT

_lock = threading.Lock()
_connections = {}

SCHEMA = """
CREATE TABLE IF NOT EXISTS midia (
  id TEXT PRIMARY KEY, provedor TEXT, tipo TEXT, arquivo TEXT, url TEXT, pagina TEXT, credito TEXT,
  licenca TEXT, largura INT, altura INT, orientacao TEXT, duracao REAL, termos TEXT DEFAULT '[]',
  tags TEXT DEFAULT '', titulo TEXT DEFAULT '', descricao TEXT DEFAULT '', normalizado INT DEFAULT 0,
  criado TEXT, atualizado TEXT);
CREATE TABLE IF NOT EXISTS uso (
  midia TEXT, canal TEXT, ep TEXT, cena INT, quando TEXT, PRIMARY KEY (midia, ep, cena));
CREATE TABLE IF NOT EXISTS avaliacao (
  midia TEXT, termo TEXT, nota INT, problema TEXT, quando TEXT, PRIMARY KEY (midia, termo));
CREATE VIRTUAL TABLE IF NOT EXISTS busca USING fts5(id UNINDEXED, termos, tags, titulo, descricao,
  tokenize = 'porter unicode61 remove_diacritics 2');
"""


def folder():
    cfg = tomllib.loads((ROOT / "config.toml").read_text()).get("acervo", {})
    p = Path(cfg.get("pasta", "acervo")).expanduser()
    return p if p.is_absolute() else DATA / p


def _db():
    key = threading.get_ident()
    if key not in _connections:
        folder().mkdir(parents=True, exist_ok=True)
        con = sqlite3.connect(folder() / "acervo.db", timeout=30)
        con.row_factory = sqlite3.Row
        con.executescript(SCHEMA)
        _connections[key] = con
    return _connections[key]


def _now():
    return datetime.now().isoformat(timespec="seconds")


def _probe(file):
    """(largura, altura, duração) pelo ffprobe."""
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height:format=duration", "-of", "json", str(file)],
                         capture_output=True, text=True).stdout
    d = json.loads(out or "{}")
    s = (d.get("streams") or [{}])[0]
    duration = float((d.get("format") or {}).get("duration") or 0)
    return s.get("width") or 0, s.get("height") or 0, duration


def _orientation(w, h):
    return "retrato" if h > w * 1.05 else "paisagem" if w > h * 1.05 else "quadrado"


def thumbnail(item):
    """JPG de 320 px (quadro do meio no vídeo) para o painel e para o modelo de visão."""
    destination = folder() / ".miniaturas" / f"{item['id']}.jpg"
    if destination.exists():
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    search = ["-ss", f"{(item['duracao'] or 0) / 2:.2f}"] if item["tipo"] == "video" else []
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", *search, "-i", str(folder() / item["arquivo"]),
                    "-frames:v", "1", "-vf", "scale=320:-2", "-q:v", "5", "-update", "1", str(destination)], check=False)
    return destination


def _index(con, mid):
    r = con.execute("SELECT * FROM midia WHERE id=?", (mid,)).fetchone()
    con.execute("DELETE FROM busca WHERE id=?", (mid,))
    con.execute("INSERT INTO busca (id, termos, tags, titulo, descricao) VALUES (?,?,?,?,?)",
                (mid, " ".join(json.loads(r["termos"])), r["tags"], r["titulo"], r["descricao"]))


def register(cand, origin, term="", move=True, normalizado=False):
    """Guarda o arquivo `origem` do candidato de um provedor (id, tipo, url, credito, ...) no acervo e devolve
    o caminho no acervo. Se o id já existe, só acrescenta o termo de busca."""
    con = _db()
    with _lock:
        exists = con.execute("SELECT arquivo, termos FROM midia WHERE id=?", (cand["id"],)).fetchone()
        if exists and (folder() / exists["arquivo"]).exists():
            terms = json.loads(exists["termos"])
            if term and term not in terms:
                con.execute("UPDATE midia SET termos=?, atualizado=? WHERE id=?",
                            (json.dumps(terms + [term], ensure_ascii=False), _now(), cand["id"]))
                _index(con, cand["id"])
                con.commit()
            return folder() / exists["arquivo"]
    provider = cand["id"].split("-")[0]
    ext = Path(origin).suffix.lower() if Path(origin).suffix.lower() not in ("", ".img") else ".jpg"
    if cand["tipo"] == "video" and ext not in (".mp4", ".mov", ".webm"):
        ext = ".mp4"
    rel = f"{provider}/{cand['id']}{ext}"
    destination = folder() / rel
    destination.parent.mkdir(parents=True, exist_ok=True)
    if move:
        shutil.move(str(origin), destination)
    else:  # cópia de arquivo de episódio: link físico quando possível (não ocupa espaço de novo)
        try:
            os.link(origin, destination)
        except OSError:
            shutil.copy2(origin, destination)
    w, h, duration = _probe(destination)
    with _lock:
        con.execute("""INSERT OR REPLACE INTO midia (id, provedor, tipo, arquivo, url, pagina, credito, licenca,
                       largura, altura, orientacao, duracao, termos, tags, titulo, normalizado, criado, atualizado)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (cand["id"], provider, cand["tipo"], rel, cand.get("url", ""), cand.get("pagina", ""),
                     cand.get("credito", ""), cand.get("licenca", ""), w, h, _orientation(w, h),
                     duration if cand["tipo"] == "video" else None, json.dumps([term] if term else [], ensure_ascii=False),
                     cand.get("tags", ""), cand.get("titulo", ""), int(normalizado), _now(), _now()))
        _index(con, cand["id"])
        con.commit()
    return destination


WORDS_EMPTY = {"a", "an", "the", "of", "in", "on", "with", "and", "or", "to", "for", "at", "by", "de", "da",
                   "do", "e", "o", "um", "uma", "com", "em", "no", "na", "para"}


def _query(term, all_items=True):
    words = [p for p in re.findall(r"\w+", term.lower()) if p not in WORDS_EMPTY and len(p) > 1]
    return (" AND " if all_items else " OR ").join(f'"{p}"' for p in words[:5])


def search(terms, kind, orientation, duration_min=0.0, exclude=(), channel=None, max_uses_channel=2, n=8):
    """Itens do acervo para os termos (o primeiro é o mais importante), do melhor para o pior.
    Exige todas as palavras de um dos termos. Filtra tipo, orientação, duração
    mínima (vídeo), itens excluídos, os já usados `max_usos_canal` vezes no canal e os que o modelo de
    visão reprovou (nota ≤ 2) para este mesmo termo."""
    con = _db()
    seen, output = set(exclude), []
    queries = [_query(t) for t in terms if t]
    # (sem o recuo para as 2 primeiras palavras: trazia mídia de outro assunto; a relevância decide em midia.ordenar)
    for q in filter(None, dict.fromkeys(queries)):
        try:
            lines = con.execute(
                """SELECT m.*, bm25(busca, 0, 3.0, 2.0, 1.0, 1.5) AS rank,
                          (SELECT COUNT(*) FROM uso u WHERE u.midia = m.id AND u.canal = ?) AS usos_canal,
                          (SELECT nota FROM avaliacao a WHERE a.midia = m.id AND a.termo = ?) AS nota_termo
                   FROM busca JOIN midia m ON m.id = busca.id
                   WHERE busca MATCH ? AND m.tipo = ? AND m.orientacao IN (?, 'quadrado')
                   ORDER BY rank LIMIT 40""", (channel or "", terms[0] if terms else "", q, kind, orientation)).fetchall()
        except sqlite3.OperationalError:
            continue
        for r in lines:
            if r["id"] in seen or r["usos_canal"] >= max_uses_channel or (r["nota_termo"] or 5) <= 2:
                continue
            if kind == "video" and duration_min and (r["duracao"] or 0) * 2 < duration_min:
                continue
            if not (folder() / r["arquivo"]).exists():
                continue
            seen.add(r["id"])
            output.append(dict(r))
        if len(output) >= n:
            break
    return output[:n]


def mark_usage(mid, channel, ep, scene):
    con = _db()
    with _lock:
        con.execute("INSERT OR REPLACE INTO uso VALUES (?,?,?,?,?)", (mid, channel or "", ep, scene, _now()))
        con.commit()


def evaluation(mid, term):
    r = _db().execute("SELECT nota, problema FROM avaliacao WHERE midia=? AND termo=?", (mid, term)).fetchone()
    return dict(r) if r else None


def save_evaluation(mid, term, note, problem=""):
    con = _db()
    with _lock:
        con.execute("INSERT OR REPLACE INTO avaliacao VALUES (?,?,?,?,?)", (mid, term, note, problem, _now()))
        con.commit()


def save_description(mid, description, tags=""):
    con = _db()
    with _lock:
        con.execute("UPDATE midia SET descricao=?, tags=CASE WHEN ?='' THEN tags ELSE trim(tags || ' ' || ?) END, "
                    "atualizado=? WHERE id=?", (description, tags, tags, _now(), mid))
        _index(con, mid)
        con.commit()


def item(mid):
    r = _db().execute("SELECT * FROM midia WHERE id=?", (mid,)).fetchone()
    return dict(r) if r else None


def list_all(q="", kind="", limit=120):
    con = _db()
    if q.strip():
        sql = ("SELECT m.* FROM busca JOIN midia m ON m.id = busca.id WHERE busca MATCH ? "
               + ("AND m.tipo = ? " if kind else "") + "ORDER BY bm25(busca) LIMIT ?")
        args = [_query(q, all_items=False)] + ([kind] if kind else []) + [limit]
    else:
        sql = "SELECT * FROM midia " + ("WHERE tipo = ? " if kind else "") + "ORDER BY atualizado DESC LIMIT ?"
        args = ([kind] if kind else []) + [limit]
    try:
        lines = [dict(r) for r in con.execute(sql, args)]
    except sqlite3.OperationalError:
        return []
    for r in lines:
        r["usos"] = [dict(u) for u in con.execute("SELECT canal, ep, cena FROM uso WHERE midia=?", (r["id"],))]
        r["termos"] = json.loads(r["termos"])
    return lines


def call_statistics():
    con = _db()
    by_choice = {f"{r['provedor']}/{r['tipo']}": r["n"] for r in
           con.execute("SELECT provedor, tipo, COUNT(*) n FROM midia GROUP BY provedor, tipo")}
    total = con.execute("SELECT COUNT(*) n, SUM(tipo='video') v, SUM(descricao != '') d FROM midia").fetchone()
    uses = con.execute("SELECT COUNT(*) n, COUNT(DISTINCT midia) m FROM uso").fetchone()
    size = sum(f.stat().st_size for f in folder().rglob("*") if f.is_file()) / 1e9 if folder().exists() else 0
    return {"itens": total["n"] or 0, "videos": total["v"] or 0, "imagens": (total["n"] or 0) - (total["v"] or 0),
            "descritos": total["d"] or 0, "usos": uses["n"] or 0, "reusados": uses["m"] or 0,
            "por_provedor": by_choice, "gb": round(size, 2)}


def import_projects():
    """Traz para o acervo a mídia dos episódios já produzidos (antes do acervo existir). O original foi
    apagado na época, então entra o arquivo da cena (já recortado para o formato do episódio)."""
    from esteira.project import Project, episodes
    n = 0
    for p in episodes():
        if not (p / "plano.json").exists():
            continue
        proj = Project(p)
        plan = json.loads((p / "plano.json").read_text())
        for c in plan["cenas"]:
            if not c.get("midia_id") or not (p / c.get("midia", "")).exists():
                continue
            cand = {"id": c["midia_id"], "tipo": c.get("midia_tipo") or ("video" if c["midia"].endswith(".mp4") else "imagem"),
                    "credito": c.get("credito", "")}
            term = c.get("busca_en") or c.get("busca") or ""
            register(cand, p / c["midia"], term, move=False, normalizado=True)
            if c.get("busca") and c.get("busca") != term:
                register(cand, p / c["midia"], c["busca"], move=False)
            mark_usage(c["midia_id"], proj.canal, proj.ep, c["id"])
            if c.get("nota_midia"):
                save_evaluation(c["midia_id"], term, c["nota_midia"], c.get("problema_midia", ""))
            n += 1
    return n


def describe(limit=200):
    """Descreve com o modelo de visão local (sem tokens do Claude) os itens que ainda não têm descrição:
    a busca no acervo passa a achar a mídia pelo que aparece nela, não só pelo termo que a encontrou."""
    from pydantic import BaseModel, Field
    from esteira.ai import local

    class Description(BaseModel):
        description: str = Field(max_length=220)
        tags: str = Field("", max_length=160)

    lines = [dict(r) for r in _db().execute("SELECT * FROM midia WHERE descricao = '' LIMIT ?", (limit,))]
    done = 0
    for n, it in enumerate(lines, 1):
        mini = thumbnail(it)
        if not mini.exists():
            continue
        r = local.ask(local.prompt("library_describe"), Description, model=local.VISION, images=[mini],
                            max_tokens=160)
        if r:
            save_description(it["id"], r.descricao, r.tags)
            done += 1
        print(f"\r  {n}/{len(lines)} descritos", end="", flush=True)
    print()
    return done
