"""Cofre de notas: arquivos Markdown com frontmatter YAML, legíveis pelo Obsidian.

O arquivo é a fonte da verdade (D3); o índice em memória é refeito só para os arquivos que mudaram.
Relações vêm de dois lugares: todo `[[alvo]]` do corpo (tipo `menciona`) e toda propriedade cujos
valores são links (`depende_de: ["[[X]]"]`), cujo nome vira o tipo da relação. Assim a estrutura
serve a qualquer módulo sem esquema fixo: o Cobrador lê `status`/`prazo` e as relações `cobra`.
"""

from __future__ import annotations

import hashlib
import re
import secrets
import threading
import unicodedata
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any

import yaml

LINK = re.compile(r"\[\[([^\[\]|#]+)(?:#[^\[\]|]*)?(?:\|[^\[\]]*)?\]\]")
RESERVED = ("id", "tipo", "tags", "aliases", "criada", "atualizada")
CLOSED = {"concluida", "cancelada", "resolvida", "arquivada"}
DAYS_STOP = 14
# tipos do app e como o vault do Obsidian costuma escrevê-los (`type: task`, `tipo: projeto`...)
KINDS_DO_APP = {
    "nota": "nota",
    "tarefa": "tarefa",
    "task": "tarefa",
    "todo": "tarefa",
    "meta": "meta",
    "goal": "meta",
    "objetivo": "meta",
    "cobranca": "cobranca",
    "projeto": "projeto",
    "project": "projeto",
    "pessoa": "pessoa",
    "person": "pessoa",
}


class NoteNotFound(KeyError):
    pass


class NoteConflict(ValueError):
    pass


def key(text: str) -> str:
    """Forma normalizada para resolver links: sem acento, minúsculas, espaços simples."""
    s = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"\s+", " ", s).strip().lower()


def name_file(titulo: str) -> str:
    return re.sub(r'[\\/:*?"<>|#^\[\]]', "", titulo).strip() or "sem titulo"


def _json(v: Any) -> Any:
    """YAML devolve date/datetime; a API só fala JSON."""
    if isinstance(v, datetime | date):
        return v.isoformat()
    if isinstance(v, dict):
        return {str(k): _json(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_json(x) for x in v]
    return v


def _list(v: Any) -> list[str]:
    if v is None:
        return []
    return [str(x) for x in v] if isinstance(v, list) else [str(v)]


def _now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat()


@dataclass
class Note:
    id: str
    caminho: Path  # relativo ao cofre
    titulo: str
    tipo: str
    tags: list[str]
    aliases: list[str]
    propriedades: dict[str, Any]
    corpo: str
    criada: str
    atualizada: str
    mtime_ns: int = 0
    tipo_original: str = ""  # como estava no arquivo (ex.: `task`); regravado se o tipo não mudou

    @property
    def status(self) -> str | None:
        s = self.propriedades.get("status")
        return str(s) if s is not None else None

    @property
    def prazo(self) -> date | None:
        p = self.propriedades.get("prazo")
        try:
            return date.fromisoformat(str(p)[:10]) if p else None
        except ValueError:
            return None

    @property
    def aberta(self) -> bool:
        return self.status is not None and key(self.status) not in CLOSED

    def relacoes(self) -> list[tuple[str, str]]:
        """(tipo, alvo) de cada link: propriedades primeiro, depois o corpo."""
        rel = []
        for name, value in self.propriedades.items():
            for item in _list(value):
                rel += [(name, target.strip()) for target in LINK.findall(item)]
        rel += [("menciona", target.strip()) for target in LINK.findall(self.corpo)]
        return rel

    def texto(self) -> str:
        original = self.tipo_original and kind_of_app(self.tipo_original) == self.tipo
        kind = self.tipo_original if original else self.tipo
        meta: dict[str, Any] = {"id": self.id, "tipo": kind}
        if self.tags:
            meta["tags"] = self.tags
        if self.aliases:
            meta["aliases"] = self.aliases
        meta |= self.propriedades
        meta |= {"criada": self.criada, "atualizada": self.atualizada}
        head = yaml.safe_dump(meta, allow_unicode=True, sort_keys=False, default_flow_style=None)
        return f"---\n{head}---\n\n{self.corpo.rstrip()}\n"

    def resumo(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "titulo": self.titulo,
            "tipo": self.tipo,
            "tags": self.tags,
            "status": self.status,
            "prazo": self.prazo.isoformat() if self.prazo else None,
            "atualizada": self.atualizada,
            "pasta": "" if self.caminho.parent == Path(".") else self.caminho.parent.as_posix(),
        }


def kind_of_app(raw: Any) -> str:
    """Sinônimo do vault -> tipo do app; os demais (roteiro, canal...) ficam como estão."""
    text = str(raw or "").strip()
    return KINDS_DO_APP.get(key(text), text or "nota")


def read(arquivo: Path, root: Path) -> Note:
    text = arquivo.read_text("utf-8")
    meta: dict[str, Any] = {}
    body = text
    if text.startswith("---\n"):
        end = text.find("\n---", 3)
        if end != -1:
            try:
                carregado = yaml.safe_load(text[4:end])
            except yaml.YAMLError:
                carregado = None
            if isinstance(carregado, dict):
                meta = _json(carregado)
                body = text[end + 4 :].lstrip("\n")
    rel = arquivo.relative_to(root)
    mtime = arquivo.stat().st_mtime_ns
    data_file = datetime.fromtimestamp(mtime / 1e9, UTC).replace(microsecond=0).isoformat()
    return Note(
        # notas criadas fora do app (vault) não têm id: deriva do caminho, sem regravar o arquivo
        id=str(meta.get("id") or hashlib.sha1(str(rel).encode()).hexdigest()[:10]),
        caminho=rel,
        titulo=arquivo.stem,
        # sem tipo mas com `status: todo` (tarefas do Obsidian) conta como tarefa
        tipo=kind_of_app(
            meta.get("tipo")
            or meta.get("type")
            or (key(str(meta.get("status"))) == "todo" and "task")
        ),
        tipo_original=str(meta.get("tipo") or ""),
        tags=_list(meta.get("tags")),
        aliases=_list(meta.get("aliases")),
        propriedades={k: v for k, v in meta.items() if k not in RESERVED},
        corpo=body,
        criada=str(meta.get("criada") or data_file),
        atualizada=str(meta.get("atualizada") or data_file),
        mtime_ns=mtime,
    )


class Vault:
    def __init__(self, root: Path | str) -> None:
        self.raiz = Path(root).expanduser()
        self._notas: dict[str, Note] = {}
        self._trava = threading.RLock()

    # ---------- índice ----------

    def _sincronizar(self) -> None:
        self.raiz.mkdir(parents=True, exist_ok=True)
        by_path = {n.caminho: n for n in self._notas.values()}
        new: dict[str, Note] = {}
        for file in self.raiz.rglob("*.md"):
            rel = file.relative_to(self.raiz)
            if any(p.startswith(".") for p in rel.parts):
                continue
            current = by_path.get(rel)
            if current is None or current.mtime_ns != file.stat().st_mtime_ns:
                current = read(file, self.raiz)
            new[current.id] = current
        self._notas = new

    def _indice(self) -> dict[str, Note]:
        idx: dict[str, Note] = {}
        for n in self._notas.values():
            for name in (n.titulo, *n.aliases):
                idx.setdefault(key(name), n)
        return idx

    def _entradas(self, idx: dict[str, Note]) -> dict[str, list[tuple[Note, str, str]]]:
        """id -> [(origem, tipo, alvo como escrito)]."""
        ent: dict[str, list[tuple[Note, str, str]]] = {}
        for n in self._notas.values():
            for kind, target in n.relacoes():
                destination = idx.get(key(target))
                if destination and destination.id != n.id:
                    ent.setdefault(destination.id, []).append((n, kind, target))
        return ent

    def _pegar(self, id_: str) -> Note:
        self._sincronizar()
        if id_ not in self._notas:
            raise NoteNotFound(id_)
        return self._notas[id_]

    # ---------- leitura ----------

    def listar(self, q: str = "", tipo: str | None = None, tag: str | None = None) -> list[dict]:
        with self._trava:
            self._sincronizar()
            ent = self._entradas(self._indice())
            term = key(q)
            output = []
            for n in self._notas.values():
                # "nota" também traz os tipos que o app não conhece (roteiro, moc...)
                outro = tipo == "nota" and n.tipo not in KINDS_DO_APP.values()
                if tipo and n.tipo != tipo and not outro or tag and tag not in n.tags:
                    continue
                if term and term not in key(" ".join([n.titulo, *n.aliases, n.corpo])):
                    continue
                output.append(n.resumo() | {"entradas": len(ent.get(n.id, []))})
            return sorted(output, key=lambda r: r["atualizada"], reverse=True)

    def obter(self, id_: str) -> dict[str, Any]:
        with self._trava:
            n = self._pegar(id_)
            idx = self._indice()
            ent = self._entradas(idx)
            saidas = []
            for kind, target in n.relacoes():
                d = idx.get(key(target))
                saidas.append({"tipo": kind, "titulo": d.titulo if d else target, "id": d and d.id})
            inputs = [
                {"tipo": t, "id": o.id, "titulo": o.titulo, "trecho": _span(o, target, t)}
                for o, t, target in ent.get(n.id, [])
            ]
            ligadas = {o.id for o, _, _ in ent.get(n.id, [])}
            names = [key(x) for x in (n.titulo, *n.aliases) if len(x) >= 3]
            mencoes = [
                {"tipo": "sem link", "id": o.id, "titulo": o.titulo, "trecho": ""}
                for o in self._notas.values()
                if o.id != n.id
                and o.id not in ligadas
                and any(re.search(rf"\b{re.escape(x)}\b", key(o.corpo)) for x in names)
            ]
            return {
                **n.resumo(),
                "aliases": n.aliases,
                "propriedades": n.propriedades,
                "corpo": n.corpo,
                "criada": n.criada,
                "saidas": saidas,
                "entradas": inputs,
                "mencoes": mencoes[:20],
            }

    def na_pasta(self, pasta: str) -> list[dict[str, Any]]:
        """Notas dentro de `pasta` (e subpastas), com propriedades: para módulos que organizam
        o cofre por pastas, como o YouTube (`Notas/Empreendimento/YouTube/<canal>/...`)."""
        root = Path(pasta)
        with self._trava:
            self._sincronizar()
            return [
                n.resumo() | {"aliases": n.aliases, "propriedades": n.propriedades}
                for n in self._notas.values()
                if n.caminho.parent == root or root in n.caminho.parents
            ]

    def sugerir(self, q: str, limite: int = 10) -> list[dict[str, str]]:
        with self._trava:
            self._sincronizar()
            term = key(q)
            found = []
            for n in self._notas.values():
                for name in (n.titulo, *n.aliases):
                    c = key(name)
                    if term in c:
                        found.append((not c.startswith(term), len(c), name, n))
                        break
            found.sort(key=lambda a: a[:2])
            return [
                {"id": n.id, "titulo": name, "tipo": n.tipo} for *_, name, n in found[:limite]
            ]

    def analise(self, hoje: date | None = None) -> dict[str, Any]:
        """Visão do cofre para o painel e o Cobrador: saúde dos links e o que está atrasado."""
        hoje = hoje or date.today()
        with self._trava:
            self._sincronizar()
            idx = self._indice()
            ent = self._entradas(idx)
            notes = list(self._notas.values())
            quebrados, with_output = [], set()
            for n in notes:
                for kind, target in n.relacoes():
                    if key(target) in idx:
                        with_output.add(n.id)
                    else:
                        quebrados.append(
                            {"tipo": kind, "id": n.id, "titulo": n.titulo, "trecho": target}
                        )
            opened = [n for n in notes if n.aberta]
            limit_stop = (hoje - timedelta(days=DAYS_STOP)).isoformat()

            def resumos(items: list[Note]) -> list[dict[str, Any]]:
                return [n.resumo() | {"entradas": len(ent.get(n.id, []))} for n in items]

            by_kind: dict[str, int] = {}
            for n in notes:
                by_kind[n.tipo] = by_kind.get(n.tipo, 0) + 1
            hubs = sorted(notes, key=lambda n: len(ent.get(n.id, [])), reverse=True)
            return {
                "total": len(notes),
                "por_tipo": by_kind,
                "abertas": len(opened),
                "orfas": resumos([n for n in notes if n.id not in ent and n.id not in with_output]),
                "quebrados": quebrados,
                "hubs": resumos([n for n in hubs[:5] if ent.get(n.id)]),
                "vencidas": resumos(
                    sorted((n for n in opened if n.prazo and n.prazo < hoje), key=_deadline)
                ),
                "a_vencer": resumos(
                    sorted(
                        (n for n in opened if n.prazo and hoje <= n.prazo <= hoje + timedelta(7)),
                        key=_deadline,
                    )
                ),
                "paradas": resumos([n for n in opened if n.atualizada[:10] < limit_stop]),
            }

    def grafo(self) -> dict[str, list[dict[str, Any]]]:
        with self._trava:
            self._sincronizar()
            idx = self._indice()
            arestas = []
            for n in self._notas.values():
                for kind, target in n.relacoes():
                    d = idx.get(key(target))
                    if d and d.id != n.id:
                        arestas.append({"de": n.id, "para": d.id, "tipo": kind})
            grau: dict[str, int] = {}
            for a in arestas:
                grau[a["de"]] = grau.get(a["de"], 0) + 1
                grau[a["para"]] = grau.get(a["para"], 0) + 1
            nodes = [
                {
                    "id": n.id,
                    "titulo": n.titulo,
                    "tipo": n.tipo,
                    "tags": n.tags,
                    "grau": grau.get(n.id, 0),
                }
                for n in self._notas.values()
            ]
            return {"nos": nodes, "arestas": arestas}

    # ---------- escrita ----------

    def criar(self, dados: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            self._sincronizar()
            title = name_file(dados["titulo"])
            if key(title) in self._indice():
                raise NoteConflict(f"Já existe uma nota chamada {title!r}")
            folder = Path(dados.get("pasta") or "")
            if folder.is_absolute() or ".." in folder.parts:
                raise NoteConflict(f"Pasta inválida: {folder}")
            now = _now()
            n = Note(
                id=secrets.token_hex(5),
                caminho=folder / f"{title}.md",
                titulo=title,
                tipo=dados.get("tipo") or "nota",
                tags=dados.get("tags") or [],
                aliases=dados.get("aliases") or [],
                propriedades=dados.get("propriedades") or {},
                corpo=dados.get("corpo") or "",
                criada=now,
                atualizada=now,
            )
            self._gravar(n)
            return self.obter(n.id)

    def atualizar(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            n = self._pegar(id_)
            new = name_file(dados.get("titulo") or n.titulo)
            if new != n.titulo:
                other = self._indice().get(key(new))
                if other and other.id != n.id:
                    raise NoteConflict(f"Já existe uma nota chamada {new!r}")
                self._renomear(n, new)
            for field in ("tipo", "tags", "aliases", "propriedades", "corpo"):
                if dados.get(field) is not None:
                    setattr(n, field, dados[field])
            n.atualizada = _now()
            self._gravar(n)
            return self.obter(n.id)

    def excluir(self, id_: str) -> None:
        with self._trava:
            n = self._pegar(id_)
            (self.raiz / n.caminho).unlink(missing_ok=True)
            del self._notas[id_]

    def _renomear(self, n: Note, new: str) -> None:
        """Move o arquivo e reescreve os links das outras notas, como o Obsidian faz."""
        old = key(n.titulo)

        def trocar(m: re.Match[str]) -> str:
            return f"[[{new}" if key(m.group(1)) == old else m.group(0)

        default = re.compile(r"\[\[([^\[\]|#]+)(?=[\]|#])")
        (self.raiz / n.caminho).unlink(missing_ok=True)
        n.caminho = n.caminho.with_name(f"{new}.md")
        n.titulo = new
        for o in self._notas.values():
            if o.id == n.id:
                continue
            body = default.sub(trocar, o.corpo)
            props = {k: _swap(v, default, trocar) for k, v in o.propriedades.items()}
            if body != o.corpo or props != o.propriedades:
                o.corpo, o.propriedades = body, props
                self._gravar(o)

    def _gravar(self, n: Note) -> None:
        file = self.raiz / n.caminho
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(n.texto(), "utf-8")
        n.mtime_ns = file.stat().st_mtime_ns
        self._notas[n.id] = n


def _swap(v: Any, default: re.Pattern[str], swap: Callable[[re.Match[str]], str]) -> Any:
    if isinstance(v, str):
        return default.sub(swap, v)
    if isinstance(v, list):
        return [_swap(x, default, swap) for x in v]
    return v


def _deadline(n: Note) -> date:
    return n.prazo or date.max


def _span(origem: Note, target: str, tipo: str) -> str:
    if tipo != "menciona":
        return f"{tipo}: [[{target}]]"
    for line in origem.corpo.splitlines():
        if f"[[{target}" in line:
            line = line.strip()
            return line if len(line) <= 160 else line[:157] + "…"
    return ""
