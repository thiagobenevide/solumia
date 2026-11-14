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
RESERVADAS = ("id", "tipo", "tags", "aliases", "criada", "atualizada")
ENCERRADOS = {"concluida", "cancelada", "resolvida", "arquivada"}
DIAS_PARADA = 14
# tipos do app e como o vault do Obsidian costuma escrevê-los (`type: task`, `tipo: projeto`...)
TIPOS_DO_APP = {
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


class NotaNaoEncontrada(KeyError):
    pass


class NotaConflito(ValueError):
    pass


def chave(texto: str) -> str:
    """Forma normalizada para resolver links: sem acento, minúsculas, espaços simples."""
    s = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode()
    return re.sub(r"\s+", " ", s).strip().lower()


def nome_arquivo(titulo: str) -> str:
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


def _lista(v: Any) -> list[str]:
    if v is None:
        return []
    return [str(x) for x in v] if isinstance(v, list) else [str(v)]


def _agora() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat()


@dataclass
class Nota:
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
        return self.status is not None and chave(self.status) not in ENCERRADOS

    def relacoes(self) -> list[tuple[str, str]]:
        """(tipo, alvo) de cada link: propriedades primeiro, depois o corpo."""
        rel = []
        for nome, valor in self.propriedades.items():
            for item in _lista(valor):
                rel += [(nome, alvo.strip()) for alvo in LINK.findall(item)]
        rel += [("menciona", alvo.strip()) for alvo in LINK.findall(self.corpo)]
        return rel

    def texto(self) -> str:
        original = self.tipo_original and tipo_do_app(self.tipo_original) == self.tipo
        tipo = self.tipo_original if original else self.tipo
        meta: dict[str, Any] = {"id": self.id, "tipo": tipo}
        if self.tags:
            meta["tags"] = self.tags
        if self.aliases:
            meta["aliases"] = self.aliases
        meta |= self.propriedades
        meta |= {"criada": self.criada, "atualizada": self.atualizada}
        cabeca = yaml.safe_dump(meta, allow_unicode=True, sort_keys=False, default_flow_style=None)
        return f"---\n{cabeca}---\n\n{self.corpo.rstrip()}\n"

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


def tipo_do_app(bruto: Any) -> str:
    """Sinônimo do vault -> tipo do app; os demais (roteiro, canal...) ficam como estão."""
    texto = str(bruto or "").strip()
    return TIPOS_DO_APP.get(chave(texto), texto or "nota")


def ler(arquivo: Path, raiz: Path) -> Nota:
    texto = arquivo.read_text("utf-8")
    meta: dict[str, Any] = {}
    corpo = texto
    if texto.startswith("---\n"):
        fim = texto.find("\n---", 3)
        if fim != -1:
            try:
                carregado = yaml.safe_load(texto[4:fim])
            except yaml.YAMLError:
                carregado = None
            if isinstance(carregado, dict):
                meta = _json(carregado)
                corpo = texto[fim + 4 :].lstrip("\n")
    rel = arquivo.relative_to(raiz)
    mtime = arquivo.stat().st_mtime_ns
    data_arq = datetime.fromtimestamp(mtime / 1e9, UTC).replace(microsecond=0).isoformat()
    return Nota(
        # notas criadas fora do app (vault) não têm id: deriva do caminho, sem regravar o arquivo
        id=str(meta.get("id") or hashlib.sha1(str(rel).encode()).hexdigest()[:10]),
        caminho=rel,
        titulo=arquivo.stem,
        # sem tipo mas com `status: todo` (tarefas do Obsidian) conta como tarefa
        tipo=tipo_do_app(
            meta.get("tipo")
            or meta.get("type")
            or (chave(str(meta.get("status"))) == "todo" and "task")
        ),
        tipo_original=str(meta.get("tipo") or ""),
        tags=_lista(meta.get("tags")),
        aliases=_lista(meta.get("aliases")),
        propriedades={k: v for k, v in meta.items() if k not in RESERVADAS},
        corpo=corpo,
        criada=str(meta.get("criada") or data_arq),
        atualizada=str(meta.get("atualizada") or data_arq),
        mtime_ns=mtime,
    )


class Cofre:
    def __init__(self, raiz: Path | str) -> None:
        self.raiz = Path(raiz).expanduser()
        self._notas: dict[str, Nota] = {}
        self._trava = threading.RLock()

    # ---------- índice ----------

    def _sincronizar(self) -> None:
        self.raiz.mkdir(parents=True, exist_ok=True)
        por_caminho = {n.caminho: n for n in self._notas.values()}
        novas: dict[str, Nota] = {}
        for arq in self.raiz.rglob("*.md"):
            rel = arq.relative_to(self.raiz)
            if any(p.startswith(".") for p in rel.parts):
                continue
            atual = por_caminho.get(rel)
            if atual is None or atual.mtime_ns != arq.stat().st_mtime_ns:
                atual = ler(arq, self.raiz)
            novas[atual.id] = atual
        self._notas = novas

    def _indice(self) -> dict[str, Nota]:
        idx: dict[str, Nota] = {}
        for n in self._notas.values():
            for nome in (n.titulo, *n.aliases):
                idx.setdefault(chave(nome), n)
        return idx

    def _entradas(self, idx: dict[str, Nota]) -> dict[str, list[tuple[Nota, str, str]]]:
        """id -> [(origem, tipo, alvo como escrito)]."""
        ent: dict[str, list[tuple[Nota, str, str]]] = {}
        for n in self._notas.values():
            for tipo, alvo in n.relacoes():
                destino = idx.get(chave(alvo))
                if destino and destino.id != n.id:
                    ent.setdefault(destino.id, []).append((n, tipo, alvo))
        return ent

    def _pegar(self, id_: str) -> Nota:
        self._sincronizar()
        if id_ not in self._notas:
            raise NotaNaoEncontrada(id_)
        return self._notas[id_]

    # ---------- leitura ----------

    def listar(self, q: str = "", tipo: str | None = None, tag: str | None = None) -> list[dict]:
        with self._trava:
            self._sincronizar()
            ent = self._entradas(self._indice())
            termo = chave(q)
            saida = []
            for n in self._notas.values():
                # "nota" também traz os tipos que o app não conhece (roteiro, moc...)
                outro = tipo == "nota" and n.tipo not in TIPOS_DO_APP.values()
                if tipo and n.tipo != tipo and not outro or tag and tag not in n.tags:
                    continue
                if termo and termo not in chave(" ".join([n.titulo, *n.aliases, n.corpo])):
                    continue
                saida.append(n.resumo() | {"entradas": len(ent.get(n.id, []))})
            return sorted(saida, key=lambda r: r["atualizada"], reverse=True)

    def obter(self, id_: str) -> dict[str, Any]:
        with self._trava:
            n = self._pegar(id_)
            idx = self._indice()
            ent = self._entradas(idx)
            saidas = []
            for tipo, alvo in n.relacoes():
                d = idx.get(chave(alvo))
                saidas.append({"tipo": tipo, "titulo": d.titulo if d else alvo, "id": d and d.id})
            entradas = [
                {"tipo": t, "id": o.id, "titulo": o.titulo, "trecho": _trecho(o, alvo, t)}
                for o, t, alvo in ent.get(n.id, [])
            ]
            ligadas = {o.id for o, _, _ in ent.get(n.id, [])}
            nomes = [chave(x) for x in (n.titulo, *n.aliases) if len(x) >= 3]
            mencoes = [
                {"tipo": "sem link", "id": o.id, "titulo": o.titulo, "trecho": ""}
                for o in self._notas.values()
                if o.id != n.id
                and o.id not in ligadas
                and any(re.search(rf"\b{re.escape(x)}\b", chave(o.corpo)) for x in nomes)
            ]
            return {
                **n.resumo(),
                "aliases": n.aliases,
                "propriedades": n.propriedades,
                "corpo": n.corpo,
                "criada": n.criada,
                "saidas": saidas,
                "entradas": entradas,
                "mencoes": mencoes[:20],
            }

    def na_pasta(self, pasta: str) -> list[dict[str, Any]]:
        """Notas dentro de `pasta` (e subpastas), com propriedades: para módulos que organizam
        o cofre por pastas, como o YouTube (`Notas/Empreendimento/YouTube/<canal>/...`)."""
        raiz = Path(pasta)
        with self._trava:
            self._sincronizar()
            return [
                n.resumo() | {"aliases": n.aliases, "propriedades": n.propriedades}
                for n in self._notas.values()
                if n.caminho.parent == raiz or raiz in n.caminho.parents
            ]

    def sugerir(self, q: str, limite: int = 10) -> list[dict[str, str]]:
        with self._trava:
            self._sincronizar()
            termo = chave(q)
            achadas = []
            for n in self._notas.values():
                for nome in (n.titulo, *n.aliases):
                    c = chave(nome)
                    if termo in c:
                        achadas.append((not c.startswith(termo), len(c), nome, n))
                        break
            achadas.sort(key=lambda a: a[:2])
            return [
                {"id": n.id, "titulo": nome, "tipo": n.tipo} for *_, nome, n in achadas[:limite]
            ]

    def analise(self, hoje: date | None = None) -> dict[str, Any]:
        """Visão do cofre para o painel e o Cobrador: saúde dos links e o que está atrasado."""
        hoje = hoje or date.today()
        with self._trava:
            self._sincronizar()
            idx = self._indice()
            ent = self._entradas(idx)
            notas = list(self._notas.values())
            quebrados, com_saida = [], set()
            for n in notas:
                for tipo, alvo in n.relacoes():
                    if chave(alvo) in idx:
                        com_saida.add(n.id)
                    else:
                        quebrados.append(
                            {"tipo": tipo, "id": n.id, "titulo": n.titulo, "trecho": alvo}
                        )
            abertas = [n for n in notas if n.aberta]
            limite_parada = (hoje - timedelta(days=DIAS_PARADA)).isoformat()

            def resumos(lista: list[Nota]) -> list[dict[str, Any]]:
                return [n.resumo() | {"entradas": len(ent.get(n.id, []))} for n in lista]

            por_tipo: dict[str, int] = {}
            for n in notas:
                por_tipo[n.tipo] = por_tipo.get(n.tipo, 0) + 1
            hubs = sorted(notas, key=lambda n: len(ent.get(n.id, [])), reverse=True)
            return {
                "total": len(notas),
                "por_tipo": por_tipo,
                "abertas": len(abertas),
                "orfas": resumos([n for n in notas if n.id not in ent and n.id not in com_saida]),
                "quebrados": quebrados,
                "hubs": resumos([n for n in hubs[:5] if ent.get(n.id)]),
                "vencidas": resumos(
                    sorted((n for n in abertas if n.prazo and n.prazo < hoje), key=_prazo)
                ),
                "a_vencer": resumos(
                    sorted(
                        (n for n in abertas if n.prazo and hoje <= n.prazo <= hoje + timedelta(7)),
                        key=_prazo,
                    )
                ),
                "paradas": resumos([n for n in abertas if n.atualizada[:10] < limite_parada]),
            }

    def grafo(self) -> dict[str, list[dict[str, Any]]]:
        with self._trava:
            self._sincronizar()
            idx = self._indice()
            arestas = []
            for n in self._notas.values():
                for tipo, alvo in n.relacoes():
                    d = idx.get(chave(alvo))
                    if d and d.id != n.id:
                        arestas.append({"de": n.id, "para": d.id, "tipo": tipo})
            grau: dict[str, int] = {}
            for a in arestas:
                grau[a["de"]] = grau.get(a["de"], 0) + 1
                grau[a["para"]] = grau.get(a["para"], 0) + 1
            nos = [
                {
                    "id": n.id,
                    "titulo": n.titulo,
                    "tipo": n.tipo,
                    "tags": n.tags,
                    "grau": grau.get(n.id, 0),
                }
                for n in self._notas.values()
            ]
            return {"nos": nos, "arestas": arestas}

    # ---------- escrita ----------

    def criar(self, dados: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            self._sincronizar()
            titulo = nome_arquivo(dados["titulo"])
            if chave(titulo) in self._indice():
                raise NotaConflito(f"Já existe uma nota chamada {titulo!r}")
            pasta = Path(dados.get("pasta") or "")
            if pasta.is_absolute() or ".." in pasta.parts:
                raise NotaConflito(f"Pasta inválida: {pasta}")
            agora = _agora()
            n = Nota(
                id=secrets.token_hex(5),
                caminho=pasta / f"{titulo}.md",
                titulo=titulo,
                tipo=dados.get("tipo") or "nota",
                tags=dados.get("tags") or [],
                aliases=dados.get("aliases") or [],
                propriedades=dados.get("propriedades") or {},
                corpo=dados.get("corpo") or "",
                criada=agora,
                atualizada=agora,
            )
            self._gravar(n)
            return self.obter(n.id)

    def atualizar(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            n = self._pegar(id_)
            novo = nome_arquivo(dados.get("titulo") or n.titulo)
            if novo != n.titulo:
                outra = self._indice().get(chave(novo))
                if outra and outra.id != n.id:
                    raise NotaConflito(f"Já existe uma nota chamada {novo!r}")
                self._renomear(n, novo)
            for campo in ("tipo", "tags", "aliases", "propriedades", "corpo"):
                if dados.get(campo) is not None:
                    setattr(n, campo, dados[campo])
            n.atualizada = _agora()
            self._gravar(n)
            return self.obter(n.id)

    def excluir(self, id_: str) -> None:
        with self._trava:
            n = self._pegar(id_)
            (self.raiz / n.caminho).unlink(missing_ok=True)
            del self._notas[id_]

    def _renomear(self, n: Nota, novo: str) -> None:
        """Move o arquivo e reescreve os links das outras notas, como o Obsidian faz."""
        antigo = chave(n.titulo)

        def trocar(m: re.Match[str]) -> str:
            return f"[[{novo}" if chave(m.group(1)) == antigo else m.group(0)

        padrao = re.compile(r"\[\[([^\[\]|#]+)(?=[\]|#])")
        (self.raiz / n.caminho).unlink(missing_ok=True)
        n.caminho = n.caminho.with_name(f"{novo}.md")
        n.titulo = novo
        for o in self._notas.values():
            if o.id == n.id:
                continue
            corpo = padrao.sub(trocar, o.corpo)
            props = {k: _trocar(v, padrao, trocar) for k, v in o.propriedades.items()}
            if corpo != o.corpo or props != o.propriedades:
                o.corpo, o.propriedades = corpo, props
                self._gravar(o)

    def _gravar(self, n: Nota) -> None:
        arq = self.raiz / n.caminho
        arq.parent.mkdir(parents=True, exist_ok=True)
        arq.write_text(n.texto(), "utf-8")
        n.mtime_ns = arq.stat().st_mtime_ns
        self._notas[n.id] = n


def _trocar(v: Any, padrao: re.Pattern[str], trocar: Callable[[re.Match[str]], str]) -> Any:
    if isinstance(v, str):
        return padrao.sub(trocar, v)
    if isinstance(v, list):
        return [_trocar(x, padrao, trocar) for x in v]
    return v


def _prazo(n: Nota) -> date:
    return n.prazo or date.max


def _trecho(origem: Nota, alvo: str, tipo: str) -> str:
    if tipo != "menciona":
        return f"{tipo}: [[{alvo}]]"
    for linha in origem.corpo.splitlines():
        if f"[[{alvo}" in linha:
            linha = linha.strip()
            return linha if len(linha) <= 160 else linha[:157] + "…"
    return ""
