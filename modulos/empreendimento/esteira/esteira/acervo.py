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

from esteira.projeto import DADOS, RAIZ

_trava = threading.Lock()
_conexoes = {}

ESQUEMA = """
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


def pasta():
    cfg = tomllib.loads((RAIZ / "config.toml").read_text()).get("acervo", {})
    p = Path(cfg.get("pasta", "acervo")).expanduser()
    return p if p.is_absolute() else DADOS / p


def _db():
    chave = threading.get_ident()
    if chave not in _conexoes:
        pasta().mkdir(parents=True, exist_ok=True)
        con = sqlite3.connect(pasta() / "acervo.db", timeout=30)
        con.row_factory = sqlite3.Row
        con.executescript(ESQUEMA)
        _conexoes[chave] = con
    return _conexoes[chave]


def _agora():
    return datetime.now().isoformat(timespec="seconds")


def _sonda(arq):
    """(largura, altura, duração) pelo ffprobe."""
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height:format=duration", "-of", "json", str(arq)],
                         capture_output=True, text=True).stdout
    d = json.loads(out or "{}")
    s = (d.get("streams") or [{}])[0]
    dur = float((d.get("format") or {}).get("duration") or 0)
    return s.get("width") or 0, s.get("height") or 0, dur


def _orientacao(w, h):
    return "retrato" if h > w * 1.05 else "paisagem" if w > h * 1.05 else "quadrado"


def miniatura(item):
    """JPG de 320 px (quadro do meio no vídeo) para o painel e para o modelo de visão."""
    destino = pasta() / ".miniaturas" / f"{item['id']}.jpg"
    if destino.exists():
        return destino
    destino.parent.mkdir(parents=True, exist_ok=True)
    busca = ["-ss", f"{(item['duracao'] or 0) / 2:.2f}"] if item["tipo"] == "video" else []
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", *busca, "-i", str(pasta() / item["arquivo"]),
                    "-frames:v", "1", "-vf", "scale=320:-2", "-q:v", "5", "-update", "1", str(destino)], check=False)
    return destino


def _indexar(con, mid):
    r = con.execute("SELECT * FROM midia WHERE id=?", (mid,)).fetchone()
    con.execute("DELETE FROM busca WHERE id=?", (mid,))
    con.execute("INSERT INTO busca (id, termos, tags, titulo, descricao) VALUES (?,?,?,?,?)",
                (mid, " ".join(json.loads(r["termos"])), r["tags"], r["titulo"], r["descricao"]))


def registrar(cand, origem, termo="", mover=True, normalizado=False):
    """Guarda o arquivo `origem` do candidato de um provedor (id, tipo, url, credito, ...) no acervo e devolve
    o caminho no acervo. Se o id já existe, só acrescenta o termo de busca."""
    con = _db()
    with _trava:
        existe = con.execute("SELECT arquivo, termos FROM midia WHERE id=?", (cand["id"],)).fetchone()
        if existe and (pasta() / existe["arquivo"]).exists():
            termos = json.loads(existe["termos"])
            if termo and termo not in termos:
                con.execute("UPDATE midia SET termos=?, atualizado=? WHERE id=?",
                            (json.dumps(termos + [termo], ensure_ascii=False), _agora(), cand["id"]))
                _indexar(con, cand["id"])
                con.commit()
            return pasta() / existe["arquivo"]
    provedor = cand["id"].split("-")[0]
    ext = Path(origem).suffix.lower() if Path(origem).suffix.lower() not in ("", ".img") else ".jpg"
    if cand["tipo"] == "video" and ext not in (".mp4", ".mov", ".webm"):
        ext = ".mp4"
    rel = f"{provedor}/{cand['id']}{ext}"
    destino = pasta() / rel
    destino.parent.mkdir(parents=True, exist_ok=True)
    if mover:
        shutil.move(str(origem), destino)
    else:  # cópia de arquivo de episódio: link físico quando possível (não ocupa espaço de novo)
        try:
            os.link(origem, destino)
        except OSError:
            shutil.copy2(origem, destino)
    w, h, dur = _sonda(destino)
    with _trava:
        con.execute("""INSERT OR REPLACE INTO midia (id, provedor, tipo, arquivo, url, pagina, credito, licenca,
                       largura, altura, orientacao, duracao, termos, tags, titulo, normalizado, criado, atualizado)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (cand["id"], provedor, cand["tipo"], rel, cand.get("url", ""), cand.get("pagina", ""),
                     cand.get("credito", ""), cand.get("licenca", ""), w, h, _orientacao(w, h),
                     dur if cand["tipo"] == "video" else None, json.dumps([termo] if termo else [], ensure_ascii=False),
                     cand.get("tags", ""), cand.get("titulo", ""), int(normalizado), _agora(), _agora()))
        _indexar(con, cand["id"])
        con.commit()
    return destino


PALAVRAS_VAZIAS = {"a", "an", "the", "of", "in", "on", "with", "and", "or", "to", "for", "at", "by", "de", "da",
                   "do", "e", "o", "um", "uma", "com", "em", "no", "na", "para"}


def _consulta(termo, todas=True):
    palavras = [p for p in re.findall(r"\w+", termo.lower()) if p not in PALAVRAS_VAZIAS and len(p) > 1]
    return (" AND " if todas else " OR ").join(f'"{p}"' for p in palavras[:5])


def procurar(termos, tipo, orientacao, dur_min=0.0, excluir=(), canal=None, max_usos_canal=2, n=8):
    """Itens do acervo para os termos (o primeiro é o mais importante), do melhor para o pior.
    Exige todas as palavras de um dos termos. Filtra tipo, orientação, duração
    mínima (vídeo), itens excluídos, os já usados `max_usos_canal` vezes no canal e os que o modelo de
    visão reprovou (nota ≤ 2) para este mesmo termo."""
    con = _db()
    vistos, saida = set(excluir), []
    consultas = [_consulta(t) for t in termos if t]
    # (sem o recuo para as 2 primeiras palavras: trazia mídia de outro assunto; a relevância decide em midia.ordenar)
    for q in filter(None, dict.fromkeys(consultas)):
        try:
            linhas = con.execute(
                """SELECT m.*, bm25(busca, 0, 3.0, 2.0, 1.0, 1.5) AS rank,
                          (SELECT COUNT(*) FROM uso u WHERE u.midia = m.id AND u.canal = ?) AS usos_canal,
                          (SELECT nota FROM avaliacao a WHERE a.midia = m.id AND a.termo = ?) AS nota_termo
                   FROM busca JOIN midia m ON m.id = busca.id
                   WHERE busca MATCH ? AND m.tipo = ? AND m.orientacao IN (?, 'quadrado')
                   ORDER BY rank LIMIT 40""", (canal or "", termos[0] if termos else "", q, tipo, orientacao)).fetchall()
        except sqlite3.OperationalError:
            continue
        for r in linhas:
            if r["id"] in vistos or r["usos_canal"] >= max_usos_canal or (r["nota_termo"] or 5) <= 2:
                continue
            if tipo == "video" and dur_min and (r["duracao"] or 0) * 2 < dur_min:
                continue
            if not (pasta() / r["arquivo"]).exists():
                continue
            vistos.add(r["id"])
            saida.append(dict(r))
        if len(saida) >= n:
            break
    return saida[:n]


def marcar_uso(mid, canal, ep, cena):
    con = _db()
    with _trava:
        con.execute("INSERT OR REPLACE INTO uso VALUES (?,?,?,?,?)", (mid, canal or "", ep, cena, _agora()))
        con.commit()


def avaliacao(mid, termo):
    r = _db().execute("SELECT nota, problema FROM avaliacao WHERE midia=? AND termo=?", (mid, termo)).fetchone()
    return dict(r) if r else None


def salvar_avaliacao(mid, termo, nota, problema=""):
    con = _db()
    with _trava:
        con.execute("INSERT OR REPLACE INTO avaliacao VALUES (?,?,?,?,?)", (mid, termo, nota, problema, _agora()))
        con.commit()


def salvar_descricao(mid, descricao, tags=""):
    con = _db()
    with _trava:
        con.execute("UPDATE midia SET descricao=?, tags=CASE WHEN ?='' THEN tags ELSE trim(tags || ' ' || ?) END, "
                    "atualizado=? WHERE id=?", (descricao, tags, tags, _agora(), mid))
        _indexar(con, mid)
        con.commit()


def item(mid):
    r = _db().execute("SELECT * FROM midia WHERE id=?", (mid,)).fetchone()
    return dict(r) if r else None


def listar(q="", tipo="", limite=120):
    con = _db()
    if q.strip():
        sql = ("SELECT m.* FROM busca JOIN midia m ON m.id = busca.id WHERE busca MATCH ? "
               + ("AND m.tipo = ? " if tipo else "") + "ORDER BY bm25(busca) LIMIT ?")
        args = [_consulta(q, todas=False)] + ([tipo] if tipo else []) + [limite]
    else:
        sql = "SELECT * FROM midia " + ("WHERE tipo = ? " if tipo else "") + "ORDER BY atualizado DESC LIMIT ?"
        args = ([tipo] if tipo else []) + [limite]
    try:
        linhas = [dict(r) for r in con.execute(sql, args)]
    except sqlite3.OperationalError:
        return []
    for r in linhas:
        r["usos"] = [dict(u) for u in con.execute("SELECT canal, ep, cena FROM uso WHERE midia=?", (r["id"],))]
        r["termos"] = json.loads(r["termos"])
    return linhas


def estatisticas():
    con = _db()
    por = {f"{r['provedor']}/{r['tipo']}": r["n"] for r in
           con.execute("SELECT provedor, tipo, COUNT(*) n FROM midia GROUP BY provedor, tipo")}
    total = con.execute("SELECT COUNT(*) n, SUM(tipo='video') v, SUM(descricao != '') d FROM midia").fetchone()
    usos = con.execute("SELECT COUNT(*) n, COUNT(DISTINCT midia) m FROM uso").fetchone()
    tamanho = sum(f.stat().st_size for f in pasta().rglob("*") if f.is_file()) / 1e9 if pasta().exists() else 0
    return {"itens": total["n"] or 0, "videos": total["v"] or 0, "imagens": (total["n"] or 0) - (total["v"] or 0),
            "descritos": total["d"] or 0, "usos": usos["n"] or 0, "reusados": usos["m"] or 0,
            "por_provedor": por, "gb": round(tamanho, 2)}


def importar_projetos():
    """Traz para o acervo a mídia dos episódios já produzidos (antes do acervo existir). O original foi
    apagado na época, então entra o arquivo da cena (já recortado para o formato do episódio)."""
    from esteira.projeto import Projeto, episodios
    n = 0
    for p in episodios():
        if not (p / "plano.json").exists():
            continue
        proj = Projeto(p)
        plano = json.loads((p / "plano.json").read_text())
        for c in plano["cenas"]:
            if not c.get("midia_id") or not (p / c.get("midia", "")).exists():
                continue
            cand = {"id": c["midia_id"], "tipo": c.get("midia_tipo") or ("video" if c["midia"].endswith(".mp4") else "imagem"),
                    "credito": c.get("credito", "")}
            termo = c.get("busca_en") or c.get("busca") or ""
            registrar(cand, p / c["midia"], termo, mover=False, normalizado=True)
            if c.get("busca") and c.get("busca") != termo:
                registrar(cand, p / c["midia"], c["busca"], mover=False)
            marcar_uso(c["midia_id"], proj.canal, proj.ep, c["id"])
            if c.get("nota_midia"):
                salvar_avaliacao(c["midia_id"], termo, c["nota_midia"], c.get("problema_midia", ""))
            n += 1
    return n


def descrever(limite=200):
    """Descreve com o modelo de visão local (sem tokens do Claude) os itens que ainda não têm descrição:
    a busca no acervo passa a achar a mídia pelo que aparece nela, não só pelo termo que a encontrou."""
    from pydantic import BaseModel, Field
    from esteira.ia import local

    class Descricao(BaseModel):
        descricao: str = Field(max_length=220)
        tags: str = Field("", max_length=160)

    linhas = [dict(r) for r in _db().execute("SELECT * FROM midia WHERE descricao = '' LIMIT ?", (limite,))]
    feitos = 0
    for n, it in enumerate(linhas, 1):
        mini = miniatura(it)
        if not mini.exists():
            continue
        r = local.perguntar(local.prompt("acervo_descrever"), Descricao, modelo=local.VISAO, imagens=[mini],
                            max_tokens=160)
        if r:
            salvar_descricao(it["id"], r.descricao, r.tags)
            feitos += 1
        print(f"\r  {n}/{len(linhas)} descritos", end="", flush=True)
    print()
    return feitos
