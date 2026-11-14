"""Résumés of the Jobs section: one Markdown per résumé in `<root>/vagas/curriculos/<id>.md` (they
can be edited or dropped there directly). Name, source opening and which one is the default live in
`curriculos.json` in the same folder. With the folder empty, the template `curriculo_modelo.md`
(from
this package) becomes the default; the default is the base of the résumés generated for each
opening."""

import json
import re
import unicodedata
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

MODEL = Path(__file__).with_name("curriculo_modelo.md")
_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,80}$")


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _slug(text: str) -> str:
    without_accent = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", without_accent.lower()).strip("-")[:60] or "curriculo"


class Resumes:
    def __init__(self, root: Path | str) -> None:
        self.pasta = Path(root).expanduser() / "vagas" / "curriculos"
        self._index = self.pasta / "curriculos.json"

    def _read(self) -> dict[str, Any]:
        if not self._index.exists():
            return {"padrao": "", "itens": {}}
        data: dict[str, Any] = json.loads(self._index.read_text())
        data.setdefault("padrao", "")
        data.setdefault("itens", {})
        return data

    def _write(self, dados: dict[str, Any]) -> None:
        self.pasta.mkdir(parents=True, exist_ok=True)
        tmp = self._index.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1))
        tmp.replace(self._index)

    def _arquivo(self, id_: str) -> Path | None:
        return self.pasta / f"{id_}.md" if _ID.match(id_) else None

    def _seed(self) -> None:
        self.pasta.mkdir(parents=True, exist_ok=True)
        if any(self.pasta.glob("*.md")) or not MODEL.exists():
            return
        self.salvar(None, "Meu currículo (modelo)", MODEL.read_text())

    def _default(self, dados: dict[str, Any]) -> str:
        """The marked one, if its file still exists; otherwise the first one not generated for an
        opening."""
        ids = sorted(a.stem for a in self.pasta.glob("*.md"))
        if dados["padrao"] in ids:
            return str(dados["padrao"])
        bases = [i for i in ids if not dados["itens"].get(i, {}).get("vaga")]
        return (bases or ids or [""])[0]

    def list_all(self) -> dict[str, Any]:
        self._seed()
        data = self._read()
        default = self._default(data)
        items = []
        for file in self.pasta.glob("*.md"):
            meta = data["itens"].get(file.stem, {})
            em = meta.get("em") or datetime.fromtimestamp(file.stat().st_mtime, UTC).isoformat(
                timespec="seconds"
            )
            items.append(
                {
                    "id": file.stem,
                    "nome": meta.get("nome") or file.stem,
                    "vaga": meta.get("vaga", ""),
                    "em": em,
                    "padrao": file.stem == default,
                }
            )
        items.sort(key=lambda c: c["em"], reverse=True)
        items.sort(key=lambda c: not c["padrao"])
        return {"pasta": str(self.pasta), "curriculos": items}

    def existe(self, id_: str) -> bool:
        file = self._arquivo(id_)
        return file is not None and file.exists()

    def ler(self, id_: str) -> dict[str, Any] | None:
        file = self._arquivo(id_)
        if file is None or not file.exists():
            return None
        item = next(c for c in self.list_all()["curriculos"] if c["id"] == id_)
        return {**item, "conteudo": file.read_text()}

    def salvar(self, id_: str | None, nome: str, content: str, vaga: str = "") -> dict[str, Any]:
        """Creates (without `id_`, from the name) or rewrites the résumé. The first one becomes the
        default."""
        data = self._read()
        if id_ is None:
            base = _slug(nome)
            id_, n = base, 2
            while (self.pasta / f"{id_}.md").exists():
                id_, n = f"{base}-{n}", n + 1
        file = self._arquivo(id_)
        if file is None:
            raise ValueError("id de currículo inválido")
        self.pasta.mkdir(parents=True, exist_ok=True)
        file.write_text(content)
        old = data["itens"].get(id_, {})
        data["itens"][id_] = {
            "nome": nome.strip() or old.get("nome") or id_,
            "vaga": vaga or old.get("vaga", ""),
            "em": _now(),
        }
        if not data["padrao"]:
            data["padrao"] = id_
        self._write(data)
        return {"id": id_, **data["itens"][id_], "padrao": data["padrao"] == id_}

    def definir_default(self, id_: str) -> bool:
        if not self.existe(id_):
            return False
        data = self._read()
        data["padrao"] = id_
        self._write(data)
        return True

    def remover(self, id_: str) -> bool:
        file = self._arquivo(id_)
        if file is None or not file.exists():
            return False
        file.unlink()
        data = self._read()
        data["itens"].pop(id_, None)
        if data["padrao"] == id_:
            data["padrao"] = ""
        self._write(data)
        return True

    def default(self) -> dict[str, Any] | None:
        self._seed()
        id_ = self._default(self._read())
        return self.ler(id_) if id_ else None
