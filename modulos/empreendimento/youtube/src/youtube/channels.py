"""YouTube channels on top of the notes vault: each channel is a folder `ROOT/<slug>/`
with the channel note (`tipo: canal`) and the collection subfolders. Nothing is stored outside
Markdown.

The vault comes ready from the platform (`backend.notes.vault.Vault`); only `in_folder`,
`obter`, `criar`, `atualizar` and `excluir` are used here, which raise `KeyError` (not found) and
`ValueError` (conflict).
"""

import re
from collections import Counter
from pathlib import Path
from typing import Any

from youtube.importer import run_import
from youtube.schema import COLLECTIONS, MAP, MODEL_CHANNEL, ROOT, STATUS_CHANNEL, schema

SLUG = re.compile(r"^[a-z0-9][a-z0-9_-]{0,40}$")
LINK = re.compile(r"^\s*\[\[([^\[\]|#]+)(?:#[^\[\]|]*)?(?:\|[^\[\]]*)?\]\]\s*$")


class NotFound(KeyError):
    pass


class Invalid(ValueError):
    pass


def _link(title: str) -> str:
    return title if LINK.match(title) else f"[[{title.strip()}]]"


def _without_link(value: Any) -> str:
    m = LINK.match(str(value))
    return m.group(1).strip() if m else str(value)


def _number(props: dict[str, Any]) -> int | None:
    for name in ("numero", "video"):
        try:
            return int(props[name])
        except (KeyError, TypeError, ValueError):
            continue
    return None


def _collection(collection: str) -> dict[str, Any]:
    if collection not in COLLECTIONS:
        raise NotFound(f"Unknown collection: {collection}")
    return COLLECTIONS[collection]


def _props(c: dict[str, Any], received: dict[str, Any]) -> dict[str, Any]:
    """Validates the collection fields; an empty value becomes None (delete the field)."""
    output: dict[str, Any] = {}
    fields = {x["nome"]: x for x in c["campos"]}
    for name, value in received.items():
        field = fields.get(name)
        if field is None:
            raise Invalid(f"Unknown field in {c['nome']}: {name}")
        if value is None or str(value).strip() == "":
            output[name] = None
        elif field["tipo"] == "numero":
            try:
                output[name] = int(value)
            except (TypeError, ValueError) as e:
                raise Invalid(f"{field['rotulo']} must be a number") from e
        elif field["tipo"] == "opcoes" and value not in field["opcoes"]:
            raise Invalid(f"Invalid {field['rotulo']}: {value}")
        elif field["tipo"] == "link":
            output[name] = _link(str(value))
        else:
            output[name] = value
    return output


def _merge(current: dict[str, Any], new: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in (current | new).items() if v is not None}


class Youtube:
    def __init__(self, store: Any, vault: str | Path = "~/Documents/github/obsidian") -> None:
        self.store = store
        self.vault = Path(vault).expanduser()

    # ---------- channels ----------

    def _folder(self, slug: str) -> str:
        if not SLUG.match(slug):
            raise Invalid(
                f"Invalid channel id: {slug!r} (use lowercase letters, digits and -)"
            )
        return f"{ROOT}/{slug}"

    def _channel_note(self, slug: str, notes: list[dict] | None = None) -> dict[str, Any]:
        folder = self._folder(slug)
        for n in notes if notes is not None else self.store.in_folder(folder):
            if n["tipo"] == "canal" and n["pasta"] == folder:
                return n
        raise NotFound(f"Channel not found: {slug}")

    def _counts(self, slug: str, notes: list[dict]) -> dict[str, Any]:
        """Channel overview: total and status of each collection."""
        output = {}
        for k, c in COLLECTIONS.items():
            folder = f"{ROOT}/{slug}/{c['pasta']}"
            doc = [n for n in notes if n["tipo"] == c["tipo"] and n["pasta"].startswith(folder)]
            status = Counter(n["status"] or "sem status" for n in doc)
            output[k] = {"total": len(doc), "status": dict(status.most_common())}
        return output

    def _channel_summary(self, n: dict[str, Any], notes: list[dict]) -> dict[str, Any]:
        slug = n["pasta"].removeprefix(f"{ROOT}/")
        return {
            "slug": slug,
            "id": n["id"],
            "titulo": n["titulo"],
            "nome": (n["aliases"] or [slug])[0],
            "status": n["status"],
            "tags": n["tags"],
            "atualizada": n["atualizada"],
            "colecoes": self._counts(slug, notes),
        }

    def channels(self) -> list[dict[str, Any]]:
        notes = self.store.in_folder(ROOT)
        channels = [
            n
            for n in notes
            if n["tipo"] == "canal" and n["pasta"].count("/") == ROOT.count("/") + 1
        ]
        summaries = [self._channel_summary(n, notes) for n in channels]
        return sorted(summaries, key=lambda c: c["titulo"])

    def channel(self, slug: str) -> dict[str, Any]:
        notes = self.store.in_folder(self._folder(slug))
        n = self._channel_note(slug, notes)
        return self.store.obter(n["id"]) | self._channel_summary(n, notes)

    def create_channel(self, data: dict[str, Any]) -> dict[str, Any]:
        slug = data["slug"]
        folder = self._folder(slug)
        if any(n["tipo"] == "canal" for n in self.store.in_folder(folder)):
            raise Invalid(f"Channel {slug!r} already exists")
        status = data.get("status") or "ideia"
        if status not in STATUS_CHANNEL:
            raise Invalid(f"Invalid status: {status}")
        name = (data.get("nome") or "").strip()
        self.store.criar(
            {
                "titulo": data["titulo"],
                "tipo": "canal",
                "pasta": folder,
                "tags": ["empreendimento/youtube/canais", *data.get("tags", [])],
                "aliases": [name] if name else [],
                "propriedades": {"mapa": MAP, "status": status},
                "corpo": data.get("corpo") or f"# {data['titulo']}\n\n{MODEL_CHANNEL}",
            }
        )
        return self.channel(slug)

    def edit_channel(self, slug: str, data: dict[str, Any]) -> dict[str, Any]:
        current = self.store.obter(self._channel_note(slug)["id"])
        edit: dict[str, Any] = {
            k: data[k] for k in ("titulo", "tags", "corpo") if data.get(k) is not None
        }
        if data.get("nome") is not None:
            name = data["nome"].strip()
            edit["aliases"] = [name, *current["aliases"][1:]] if name else current["aliases"][1:]
        if data.get("status") is not None:
            if data["status"] not in STATUS_CHANNEL:
                raise Invalid(f"Invalid status: {data['status']}")
            edit["propriedades"] = current["propriedades"] | {"status": data["status"]}
        self.store.atualizar(current["id"], edit)
        return self.channel(slug)

    def delete_channel(self, slug: str) -> None:
        notes = self.store.in_folder(self._folder(slug))
        n = self._channel_note(slug, notes)
        if len(notes) > 1:
            raise Invalid(f"The channel still has {len(notes) - 1} notes; delete them first")
        self.store.excluir(n["id"])

    # ---------- collections (temas, historias, roteiros, planos, metodos) ----------

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

    def items(
        self, slug: str, collection: str, q: str = "", status: str | None = None
    ) -> list[dict[str, Any]]:
        c = _collection(collection)
        notes = self.store.in_folder(self._folder(slug))
        self._channel_note(slug, notes)
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
        n = self.store.obter(id_)
        if n["tipo"] != c["tipo"] or not n["pasta"].startswith(f"{self._folder(slug)}/"):
            raise NotFound(f"{c['item']} not found in this channel")
        return n | {"colecao": collection, "ligacoes": self._item(n, c)["ligacoes"]}

    def _title(self, c: dict[str, Any], title: str) -> str:
        title = title.strip()
        return title if title.startswith(c["item"]) else f"{c['item']} — {title}"

    def create(self, slug: str, collection: str, data: dict[str, Any]) -> dict[str, Any]:
        c = _collection(collection)
        channel = self._channel_note(slug)
        props = _merge(
            {"canal": _link(channel["titulo"])}, _props(c, data.get("propriedades", {}))
        )
        n = self.store.criar(
            {
                "titulo": self._title(c, data["titulo"]),
                "tipo": c["tipo"],
                "pasta": f"{ROOT}/{slug}/{c['pasta']}",
                "tags": [c["tag"], *(t for t in data.get("tags", []) if t != c["tag"])],
                "propriedades": props,
                "corpo": data.get("corpo") or c["modelo"],
            }
        )
        return self.item(slug, collection, n["id"])

    def edit(self, slug: str, collection: str, id_: str, data: dict[str, Any]) -> dict[str, Any]:
        c = _collection(collection)
        current = self.item(slug, collection, id_)
        edit: dict[str, Any] = {
            k: data[k] for k in ("tags", "corpo") if data.get(k) is not None
        }
        if data.get("titulo"):
            edit["titulo"] = self._title(c, data["titulo"])
        if data.get("propriedades") is not None:
            edit["propriedades"] = _merge(
                current["propriedades"], _props(c, data["propriedades"])
            )
        self.store.atualizar(id_, edit)
        return self.item(slug, collection, id_)

    def delete(self, slug: str, collection: str, id_: str) -> None:
        self.item(slug, collection, id_)
        self.store.excluir(id_)

    def derive(self, slug: str, theme_id: str, collection: str) -> dict[str, Any]:
        """Creates the script or the story of a theme, with the same name, and links both."""
        if collection not in ("roteiros", "historias"):
            raise Invalid("Only roteiros and historias can be derived from a theme")
        field = "roteiro" if collection == "roteiros" else "historia"
        theme = self.item(slug, "temas", theme_id)
        if any(s["tipo"] == field and s["id"] for s in theme["saidas"]):
            raise Invalid(f"The theme already has a {COLLECTIONS[collection]['item'].lower()}")
        p = theme["propriedades"]
        rest = re.sub(r"^Tema\b\s*", "", theme["titulo"])
        props: dict[str, Any] = {"tema": theme["titulo"], "status": "rascunho"}
        if collection == "roteiros":
            props |= {"video": _number(p), "fio": p.get("fio"), "plano": p.get("plano")}
        elif p.get("roteiro"):
            props["roteiro"] = p["roteiro"]
        new = self.create(
            slug,
            collection,
            {"titulo": f"{COLLECTIONS[collection]['item']} {rest}", "propriedades": props},
        )
        self.edit(slug, "temas", theme_id, {"propriedades": {field: new["titulo"]}})
        return new

    # ---------- schema and import ----------

    def schema(self) -> dict[str, Any]:
        return schema()

    def run_import(self, replace: bool = False) -> dict[str, Any]:
        return run_import(self.vault, self.store.root, replace)
