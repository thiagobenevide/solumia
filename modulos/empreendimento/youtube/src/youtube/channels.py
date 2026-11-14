"""Canais do YouTube sobre o cofre de notas: cada canal é uma pasta `RAIZ/<slug>/`
com a nota do canal (`tipo: canal`) e as subpastas das coleções. Nada é guardado fora do Markdown.

O cofre chega pronto da plataforma (`backend.notes.vault.Cofre`); aqui só se usam `na_pasta`,
`obter`, `criar`, `atualizar` e `excluir`, que levantam `KeyError` (não achou) e `ValueError`
(conflito).
"""

import re
from collections import Counter
from pathlib import Path
from typing import Any

from youtube.schema import COLECOES, MAPA, MODELO_CANAL, RAIZ, STATUS_CANAL, esquema
from youtube.importer import importar

SLUG = re.compile(r"^[a-z0-9][a-z0-9_-]{0,40}$")
LINK = re.compile(r"^\s*\[\[([^\[\]|#]+)(?:#[^\[\]|]*)?(?:\|[^\[\]]*)?\]\]\s*$")


class NaoEncontrado(KeyError):
    pass


class Invalido(ValueError):
    pass


def _link(titulo: str) -> str:
    return titulo if LINK.match(titulo) else f"[[{titulo.strip()}]]"


def _sem_link(valor: Any) -> str:
    m = LINK.match(str(valor))
    return m.group(1).strip() if m else str(valor)


def _numero(props: dict[str, Any]) -> int | None:
    for nome in ("numero", "video"):
        try:
            return int(props[nome])
        except (KeyError, TypeError, ValueError):
            continue
    return None


def _colecao(colecao: str) -> dict[str, Any]:
    if colecao not in COLECOES:
        raise NaoEncontrado(f"Coleção desconhecida: {colecao}")
    return COLECOES[colecao]


def _props(c: dict[str, Any], recebidas: dict[str, Any]) -> dict[str, Any]:
    """Valida os campos da coleção; valor vazio vira None (apagar o campo)."""
    saida: dict[str, Any] = {}
    campos = {x["nome"]: x for x in c["campos"]}
    for nome, valor in recebidas.items():
        campo = campos.get(nome)
        if campo is None:
            raise Invalido(f"Campo desconhecido em {c['nome']}: {nome}")
        if valor is None or str(valor).strip() == "":
            saida[nome] = None
        elif campo["tipo"] == "numero":
            try:
                saida[nome] = int(valor)
            except (TypeError, ValueError) as e:
                raise Invalido(f"{campo['rotulo']} precisa ser um número") from e
        elif campo["tipo"] == "opcoes" and valor not in campo["opcoes"]:
            raise Invalido(f"{campo['rotulo']} inválido: {valor}")
        elif campo["tipo"] == "link":
            saida[nome] = _link(str(valor))
        else:
            saida[nome] = valor
    return saida


def _mesclar(atuais: dict[str, Any], novas: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in (atuais | novas).items() if v is not None}


class Youtube:
    def __init__(self, cofre: Any, vault: str | Path = "~/Documents/github/obsidian") -> None:
        self.cofre = cofre
        self.vault = Path(vault).expanduser()

    # ---------- canais ----------

    def _pasta(self, slug: str) -> str:
        if not SLUG.match(slug):
            raise Invalido(
                f"Identificador de canal inválido: {slug!r} (use minúsculas, números e -)"
            )
        return f"{RAIZ}/{slug}"

    def _canal_nota(self, slug: str, notas: list[dict] | None = None) -> dict[str, Any]:
        pasta = self._pasta(slug)
        for n in notas if notas is not None else self.cofre.na_pasta(pasta):
            if n["tipo"] == "canal" and n["pasta"] == pasta:
                return n
        raise NaoEncontrado(f"Canal não encontrado: {slug}")

    def _contagens(self, slug: str, notas: list[dict]) -> dict[str, Any]:
        """Gerência do canal: total e status de cada coleção."""
        saida = {}
        for k, c in COLECOES.items():
            pasta = f"{RAIZ}/{slug}/{c['pasta']}"
            doc = [n for n in notas if n["tipo"] == c["tipo"] and n["pasta"].startswith(pasta)]
            status = Counter(n["status"] or "sem status" for n in doc)
            saida[k] = {"total": len(doc), "status": dict(status.most_common())}
        return saida

    def _canal(self, n: dict[str, Any], notas: list[dict]) -> dict[str, Any]:
        slug = n["pasta"].removeprefix(f"{RAIZ}/")
        return {
            "slug": slug,
            "id": n["id"],
            "titulo": n["titulo"],
            "nome": (n["aliases"] or [slug])[0],
            "status": n["status"],
            "tags": n["tags"],
            "atualizada": n["atualizada"],
            "colecoes": self._contagens(slug, notas),
        }

    def canais(self) -> list[dict[str, Any]]:
        notas = self.cofre.na_pasta(RAIZ)
        canais = [
            n
            for n in notas
            if n["tipo"] == "canal" and n["pasta"].count("/") == RAIZ.count("/") + 1
        ]
        return sorted((self._canal(n, notas) for n in canais), key=lambda c: c["titulo"])

    def canal(self, slug: str) -> dict[str, Any]:
        notas = self.cofre.na_pasta(self._pasta(slug))
        n = self._canal_nota(slug, notas)
        return self.cofre.obter(n["id"]) | self._canal(n, notas)

    def criar_canal(self, dados: dict[str, Any]) -> dict[str, Any]:
        slug = dados["slug"]
        pasta = self._pasta(slug)
        if any(n["tipo"] == "canal" for n in self.cofre.na_pasta(pasta)):
            raise Invalido(f"O canal {slug!r} já existe")
        status = dados.get("status") or "ideia"
        if status not in STATUS_CANAL:
            raise Invalido(f"Status inválido: {status}")
        nome = (dados.get("nome") or "").strip()
        self.cofre.criar(
            {
                "titulo": dados["titulo"],
                "tipo": "canal",
                "pasta": pasta,
                "tags": ["empreendimento/youtube/canais", *dados.get("tags", [])],
                "aliases": [nome] if nome else [],
                "propriedades": {"mapa": MAPA, "status": status},
                "corpo": dados.get("corpo") or f"# {dados['titulo']}\n\n{MODELO_CANAL}",
            }
        )
        return self.canal(slug)

    def editar_canal(self, slug: str, dados: dict[str, Any]) -> dict[str, Any]:
        atual = self.cofre.obter(self._canal_nota(slug)["id"])
        edicao: dict[str, Any] = {
            k: dados[k] for k in ("titulo", "tags", "corpo") if dados.get(k) is not None
        }
        if dados.get("nome") is not None:
            nome = dados["nome"].strip()
            edicao["aliases"] = [nome, *atual["aliases"][1:]] if nome else atual["aliases"][1:]
        if dados.get("status") is not None:
            if dados["status"] not in STATUS_CANAL:
                raise Invalido(f"Status inválido: {dados['status']}")
            edicao["propriedades"] = atual["propriedades"] | {"status": dados["status"]}
        self.cofre.atualizar(atual["id"], edicao)
        return self.canal(slug)

    def excluir_canal(self, slug: str) -> None:
        notas = self.cofre.na_pasta(self._pasta(slug))
        n = self._canal_nota(slug, notas)
        if len(notas) > 1:
            raise Invalido(f"O canal ainda tem {len(notas) - 1} notas; exclua-as antes")
        self.cofre.excluir(n["id"])

    # ---------- coleções (temas, histórias, roteiros, planos, métodos) ----------

    def _item(self, n: dict[str, Any], c: dict[str, Any]) -> dict[str, Any]:
        p = n["propriedades"]
        return {
            "id": n["id"],
            "titulo": n["titulo"],
            "status": n["status"],
            "numero": _numero(p),
            "fio": p.get("fio"),
            "formato": p.get("formato"),
            "evidencia": p.get("evidencia"),
            "tags": n["tags"],
            "atualizada": n["atualizada"],
            "ligacoes": {
                x["nome"]: _sem_link(p[x["nome"]])
                for x in c["campos"]
                if x["tipo"] == "link" and p.get(x["nome"])
            },
        }

    def itens(
        self, slug: str, colecao: str, q: str = "", status: str | None = None
    ) -> list[dict[str, Any]]:
        c = _colecao(colecao)
        notas = self.cofre.na_pasta(self._pasta(slug))
        self._canal_nota(slug, notas)
        pasta = f"{RAIZ}/{slug}/{c['pasta']}"
        termo = q.strip().casefold()
        saida = [
            self._item(n, c)
            for n in notas
            if n["tipo"] == c["tipo"]
            and n["pasta"].startswith(pasta)
            and (not termo or termo in n["titulo"].casefold())
            and (not status or (n["status"] or "sem status") == status)
        ]
        return sorted(saida, key=lambda i: (i["numero"] is None, i["numero"] or 0, i["titulo"]))

    def item(self, slug: str, colecao: str, id_: str) -> dict[str, Any]:
        c = _colecao(colecao)
        n = self.cofre.obter(id_)
        if n["tipo"] != c["tipo"] or not n["pasta"].startswith(f"{self._pasta(slug)}/"):
            raise NaoEncontrado(f"{c['item']} não encontrado neste canal")
        return n | {"colecao": colecao, "ligacoes": self._item(n, c)["ligacoes"]}

    def _titulo(self, c: dict[str, Any], titulo: str) -> str:
        titulo = titulo.strip()
        return titulo if titulo.startswith(c["item"]) else f"{c['item']} — {titulo}"

    def criar(self, slug: str, colecao: str, dados: dict[str, Any]) -> dict[str, Any]:
        c = _colecao(colecao)
        canal = self._canal_nota(slug)
        props = _mesclar(
            {"canal": _link(canal["titulo"])}, _props(c, dados.get("propriedades", {}))
        )
        n = self.cofre.criar(
            {
                "titulo": self._titulo(c, dados["titulo"]),
                "tipo": c["tipo"],
                "pasta": f"{RAIZ}/{slug}/{c['pasta']}",
                "tags": [c["tag"], *(t for t in dados.get("tags", []) if t != c["tag"])],
                "propriedades": props,
                "corpo": dados.get("corpo") or c["modelo"],
            }
        )
        return self.item(slug, colecao, n["id"])

    def editar(self, slug: str, colecao: str, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        c = _colecao(colecao)
        atual = self.item(slug, colecao, id_)
        edicao: dict[str, Any] = {
            k: dados[k] for k in ("tags", "corpo") if dados.get(k) is not None
        }
        if dados.get("titulo"):
            edicao["titulo"] = self._titulo(c, dados["titulo"])
        if dados.get("propriedades") is not None:
            edicao["propriedades"] = _mesclar(
                atual["propriedades"], _props(c, dados["propriedades"])
            )
        self.cofre.atualizar(id_, edicao)
        return self.item(slug, colecao, id_)

    def excluir(self, slug: str, colecao: str, id_: str) -> None:
        self.item(slug, colecao, id_)
        self.cofre.excluir(id_)

    def derivar(self, slug: str, tema_id: str, colecao: str) -> dict[str, Any]:
        """Cria o roteiro ou a história de um tema, com o mesmo nome, e liga os dois."""
        if colecao not in ("roteiros", "historias"):
            raise Invalido("Só se derivam roteiros e histórias de um tema")
        campo = "roteiro" if colecao == "roteiros" else "historia"
        tema = self.item(slug, "temas", tema_id)
        if any(s["tipo"] == campo and s["id"] for s in tema["saidas"]):
            raise Invalido(f"O tema já tem {COLECOES[colecao]['item'].lower()}")
        p = tema["propriedades"]
        resto = re.sub(r"^Tema\b\s*", "", tema["titulo"])
        props: dict[str, Any] = {"tema": tema["titulo"], "status": "rascunho"}
        if colecao == "roteiros":
            props |= {"video": _numero(p), "fio": p.get("fio"), "plano": p.get("plano")}
        elif p.get("roteiro"):
            props["roteiro"] = p["roteiro"]
        novo = self.criar(
            slug,
            colecao,
            {"titulo": f"{COLECOES[colecao]['item']} {resto}", "propriedades": props},
        )
        self.editar(slug, "temas", tema_id, {"propriedades": {campo: novo["titulo"]}})
        return novo

    # ---------- esquema e importação ----------

    def esquema(self) -> dict[str, Any]:
        return esquema()

    def importar(self, substituir: bool = False) -> dict[str, Any]:
        return importar(self.vault, self.cofre.raiz, substituir)
