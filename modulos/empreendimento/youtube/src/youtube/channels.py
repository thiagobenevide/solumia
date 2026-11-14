"""Canais do YouTube sobre o cofre de notas: cada canal é uma pasta `RAIZ/<slug>/`
com a nota do canal (`tipo: canal`) e as subpastas das coleções. Nada é guardado fora do Markdown.

O cofre chega pronto da plataforma (`backend.notes.vault.Vault`); aqui só se usam `na_pasta`,
`obter`, `criar`, `atualizar` e `excluir`, que levantam `KeyError` (não achou) e `ValueError`
(conflito).
"""

import re
from collections import Counter
from pathlib import Path
from typing import Any

from youtube.schema import COLLECTIONS, MAP, MODEL_CHANNEL, ROOT, STATUS_CHANNEL, schema
from youtube.importer import run_import

SLUG = re.compile(r"^[a-z0-9][a-z0-9_-]{0,40}$")
LINK = re.compile(r"^\s*\[\[([^\[\]|#]+)(?:#[^\[\]|]*)?(?:\|[^\[\]]*)?\]\]\s*$")


class NotFound(KeyError):
    pass


class Invalid(ValueError):
    pass


def _link(titulo: str) -> str:
    return titulo if LINK.match(titulo) else f"[[{titulo.strip()}]]"


def _without_link(valor: Any) -> str:
    m = LINK.match(str(valor))
    return m.group(1).strip() if m else str(valor)


def _number(props: dict[str, Any]) -> int | None:
    for name in ("numero", "video"):
        try:
            return int(props[name])
        except (KeyError, TypeError, ValueError):
            continue
    return None


def _collection(collection: str) -> dict[str, Any]:
    if collection not in COLLECTIONS:
        raise NotFound(f"Coleção desconhecida: {collection}")
    return COLLECTIONS[collection]


def _props(c: dict[str, Any], recebidas: dict[str, Any]) -> dict[str, Any]:
    """Valida os campos da coleção; valor vazio vira None (apagar o campo)."""
    output: dict[str, Any] = {}
    fields = {x["nome"]: x for x in c["campos"]}
    for name, value in recebidas.items():
        field = fields.get(name)
        if field is None:
            raise Invalid(f"Campo desconhecido em {c['nome']}: {name}")
        if value is None or str(value).strip() == "":
            output[name] = None
        elif field["tipo"] == "numero":
            try:
                output[name] = int(value)
            except (TypeError, ValueError) as e:
                raise Invalid(f"{field['rotulo']} precisa ser um número") from e
        elif field["tipo"] == "opcoes" and value not in field["opcoes"]:
            raise Invalid(f"{field['rotulo']} inválido: {value}")
        elif field["tipo"] == "link":
            output[name] = _link(str(value))
        else:
            output[name] = value
    return output


def _merge(current: dict[str, Any], new: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in (current | new).items() if v is not None}


class Youtube:
    def __init__(self, cofre: Any, vault: str | Path = "~/Documents/github/obsidian") -> None:
        self.cofre = cofre
        self.vault = Path(vault).expanduser()

    # ---------- canais ----------

    def _pasta(self, slug: str) -> str:
        if not SLUG.match(slug):
            raise Invalid(
                f"Identificador de canal inválido: {slug!r} (use minúsculas, números e -)"
            )
        return f"{ROOT}/{slug}"

    def _canal_nota(self, slug: str, notes: list[dict] | None = None) -> dict[str, Any]:
        folder = self._pasta(slug)
        for n in notes if notes is not None else self.cofre.na_pasta(folder):
            if n["tipo"] == "canal" and n["pasta"] == folder:
                return n
        raise NotFound(f"Canal não encontrado: {slug}")

    def _contagens(self, slug: str, notes: list[dict]) -> dict[str, Any]:
        """Gerência do canal: total e status de cada coleção."""
        output = {}
        for k, c in COLLECTIONS.items():
            folder = f"{ROOT}/{slug}/{c['pasta']}"
            doc = [n for n in notes if n["tipo"] == c["tipo"] and n["pasta"].startswith(folder)]
            status = Counter(n["status"] or "sem status" for n in doc)
            output[k] = {"total": len(doc), "status": dict(status.most_common())}
        return output

    def _canal(self, n: dict[str, Any], notes: list[dict]) -> dict[str, Any]:
        slug = n["pasta"].removeprefix(f"{ROOT}/")
        return {
            "slug": slug,
            "id": n["id"],
            "titulo": n["titulo"],
            "nome": (n["aliases"] or [slug])[0],
            "status": n["status"],
            "tags": n["tags"],
            "atualizada": n["atualizada"],
            "colecoes": self._contagens(slug, notes),
        }

    def canais(self) -> list[dict[str, Any]]:
        notes = self.cofre.na_pasta(ROOT)
        channels = [
            n
            for n in notes
            if n["tipo"] == "canal" and n["pasta"].count("/") == ROOT.count("/") + 1
        ]
        return sorted((self._canal(n, notes) for n in channels), key=lambda c: c["titulo"])

    def canal(self, slug: str) -> dict[str, Any]:
        notes = self.cofre.na_pasta(self._pasta(slug))
        n = self._canal_nota(slug, notes)
        return self.cofre.obter(n["id"]) | self._canal(n, notes)

    def criar_canal(self, dados: dict[str, Any]) -> dict[str, Any]:
        slug = dados["slug"]
        folder = self._pasta(slug)
        if any(n["tipo"] == "canal" for n in self.cofre.na_pasta(folder)):
            raise Invalid(f"O canal {slug!r} já existe")
        status = dados.get("status") or "ideia"
        if status not in STATUS_CHANNEL:
            raise Invalid(f"Status inválido: {status}")
        name = (dados.get("nome") or "").strip()
        self.cofre.criar(
            {
                "titulo": dados["titulo"],
                "tipo": "canal",
                "pasta": folder,
                "tags": ["empreendimento/youtube/canais", *dados.get("tags", [])],
                "aliases": [name] if name else [],
                "propriedades": {"mapa": MAP, "status": status},
                "corpo": dados.get("corpo") or f"# {dados['titulo']}\n\n{MODEL_CHANNEL}",
            }
        )
        return self.canal(slug)

    def editar_canal(self, slug: str, dados: dict[str, Any]) -> dict[str, Any]:
        current = self.cofre.obter(self._canal_nota(slug)["id"])
        edit: dict[str, Any] = {
            k: dados[k] for k in ("titulo", "tags", "corpo") if dados.get(k) is not None
        }
        if dados.get("nome") is not None:
            name = dados["nome"].strip()
            edit["aliases"] = [name, *current["aliases"][1:]] if name else current["aliases"][1:]
        if dados.get("status") is not None:
            if dados["status"] not in STATUS_CHANNEL:
                raise Invalid(f"Status inválido: {dados['status']}")
            edit["propriedades"] = current["propriedades"] | {"status": dados["status"]}
        self.cofre.atualizar(current["id"], edit)
        return self.canal(slug)

    def excluir_canal(self, slug: str) -> None:
        notes = self.cofre.na_pasta(self._pasta(slug))
        n = self._canal_nota(slug, notes)
        if len(notes) > 1:
            raise Invalid(f"O canal ainda tem {len(notes) - 1} notas; exclua-as antes")
        self.cofre.excluir(n["id"])

    # ---------- coleções (temas, histórias, roteiros, planos, métodos) ----------

    def _item(self, n: dict[str, Any], c: dict[str, Any]) -> dict[str, Any]:
        p = n["propriedades"]
        return {
            "id": n["id"],
            "titulo": n["titulo"],
            "status": n["status"],
            "numero": _number(p),
            "fio": p.get("fio"),
            "formato": p.get("formato"),
            "evidencia": p.get("evidencia"),
            "tags": n["tags"],
            "atualizada": n["atualizada"],
            "ligacoes": {
                x["nome"]: _without_link(p[x["nome"]])
                for x in c["campos"]
                if x["tipo"] == "link" and p.get(x["nome"])
            },
        }

    def itens(
        self, slug: str, collection: str, q: str = "", status: str | None = None
    ) -> list[dict[str, Any]]:
        c = _collection(collection)
        notes = self.cofre.na_pasta(self._pasta(slug))
        self._canal_nota(slug, notes)
        folder = f"{ROOT}/{slug}/{c['pasta']}"
        term = q.strip().casefold()
        output = [
            self._item(n, c)
            for n in notes
            if n["tipo"] == c["tipo"]
            and n["pasta"].startswith(folder)
            and (not term or term in n["titulo"].casefold())
            and (not status or (n["status"] or "sem status") == status)
        ]
        return sorted(output, key=lambda i: (i["numero"] is None, i["numero"] or 0, i["titulo"]))

    def item(self, slug: str, collection: str, id_: str) -> dict[str, Any]:
        c = _collection(collection)
        n = self.cofre.obter(id_)
        if n["tipo"] != c["tipo"] or not n["pasta"].startswith(f"{self._pasta(slug)}/"):
            raise NotFound(f"{c['item']} não encontrado neste canal")
        return n | {"colecao": collection, "ligacoes": self._item(n, c)["ligacoes"]}

    def _titulo(self, c: dict[str, Any], titulo: str) -> str:
        titulo = titulo.strip()
        return titulo if titulo.startswith(c["item"]) else f"{c['item']} — {titulo}"

    def criar(self, slug: str, collection: str, dados: dict[str, Any]) -> dict[str, Any]:
        c = _collection(collection)
        channel = self._canal_nota(slug)
        props = _merge(
            {"canal": _link(channel["titulo"])}, _props(c, dados.get("propriedades", {}))
        )
        n = self.cofre.criar(
            {
                "titulo": self._titulo(c, dados["titulo"]),
                "tipo": c["tipo"],
                "pasta": f"{ROOT}/{slug}/{c['pasta']}",
                "tags": [c["tag"], *(t for t in dados.get("tags", []) if t != c["tag"])],
                "propriedades": props,
                "corpo": dados.get("corpo") or c["modelo"],
            }
        )
        return self.item(slug, collection, n["id"])

    def editar(self, slug: str, collection: str, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        c = _collection(collection)
        current = self.item(slug, collection, id_)
        edit: dict[str, Any] = {
            k: dados[k] for k in ("tags", "corpo") if dados.get(k) is not None
        }
        if dados.get("titulo"):
            edit["titulo"] = self._titulo(c, dados["titulo"])
        if dados.get("propriedades") is not None:
            edit["propriedades"] = _merge(
                current["propriedades"], _props(c, dados["propriedades"])
            )
        self.cofre.atualizar(id_, edit)
        return self.item(slug, collection, id_)

    def excluir(self, slug: str, collection: str, id_: str) -> None:
        self.item(slug, collection, id_)
        self.cofre.excluir(id_)

    def derivar(self, slug: str, tema_id: str, collection: str) -> dict[str, Any]:
        """Cria o roteiro ou a história de um tema, com o mesmo nome, e liga os dois."""
        if collection not in ("roteiros", "historias"):
            raise Invalid("Só se derivam roteiros e histórias de um tema")
        field = "roteiro" if collection == "roteiros" else "historia"
        tema = self.item(slug, "temas", tema_id)
        if any(s["tipo"] == field and s["id"] for s in tema["saidas"]):
            raise Invalid(f"O tema já tem {COLLECTIONS[collection]['item'].lower()}")
        p = tema["propriedades"]
        rest = re.sub(r"^Tema\b\s*", "", tema["titulo"])
        props: dict[str, Any] = {"tema": tema["titulo"], "status": "rascunho"}
        if collection == "roteiros":
            props |= {"video": _number(p), "fio": p.get("fio"), "plano": p.get("plano")}
        elif p.get("roteiro"):
            props["roteiro"] = p["roteiro"]
        new = self.criar(
            slug,
            collection,
            {"titulo": f"{COLLECTIONS[collection]['item']} {rest}", "propriedades": props},
        )
        self.editar(slug, "temas", tema_id, {"propriedades": {field: new["titulo"]}})
        return new

    # ---------- esquema e importação ----------

    def esquema(self) -> dict[str, Any]:
        return schema()

    def importar(self, replace: bool = False) -> dict[str, Any]:
        return run_import(self.vault, self.cofre.raiz, replace)
