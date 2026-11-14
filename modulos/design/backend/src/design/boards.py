"""Quadros brancos guardados um por arquivo em `quadros/<id>.json` na pasta de dados.

Cada quadro tem `elementos` em coordenadas do mundo (quadro infinito): `traco` (pontos `[x, y, p]`,
p = pressão 0–1), `forma` (reta, seta, retângulo, elipse entre `a` e `b`), `texto` e os blocos
(`no`) e setas (`ligacao`) de fluxograma, `tabela` (células editáveis) e `imagem` (id em
`imagens/`); `grupo` junta elementos (Ctrl+G). `paginas` ([{id, nome}]) divide o quadro em
abas; cada elemento diz a sua em `pagina` (vazio = a primeira). O backend só
confere o envelope (`id` e `tipo`); o desenho é do app. `versao` sobe a cada gravação: quem grava
com uma versão velha recebe [Conflito] e mescla antes de tentar de novo (vários aparelhos)."""

import json
import os
import re
import shutil
import threading
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

BACKGROUNDS = ("liso", "pontos", "grade", "linhas")
KINDS = ("traco", "forma", "texto", "no", "ligacao", "tabela", "imagem")
FIELDS_EDITABLE = {"titulo", "fundo", "pasta", "paginas"}
_ID = re.compile(r"^[0-9a-f]{32}$")
PNG = b"\x89PNG\r\n\x1a\n"
MAX_THUMBNAIL = 512 * 1024
MAX_ATTACHMENT = 8 * 1024 * 1024


class NotFound(Exception):
    pass


class Invalid(Exception):
    pass


class Conflict(Exception):
    def __init__(self, atual: dict[str, Any]) -> None:
        super().__init__("O quadro mudou em outro aparelho")
        self.atual = atual


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _summary(q: dict[str, Any]) -> dict[str, Any]:
    return {**{k: v for k, v in q.items() if k != "elementos"}, "total": len(q["elementos"])}


class Frames:
    """A mesma guarda serve aos wireframes (pasta `wireframes/`, tipos de `wireframe_ia`)."""

    def __init__(
        self, root: str | Path, pasta: str = "quadros", kinds: tuple[str, ...] = KINDS
    ) -> None:
        self.root = Path(root).expanduser() / pasta
        self.root.mkdir(parents=True, exist_ok=True)
        self.tipos = kinds
        self._lock = threading.RLock()

    def _path(self, id_: str) -> Path:
        if not _ID.match(id_):
            raise NotFound(id_)
        return self.root / f"{id_}.json"

    def _read(self, id_: str) -> dict[str, Any]:
        path = self._path(id_)
        if not path.exists():
            raise NotFound(id_)
        data: dict[str, Any] = json.loads(path.read_text("utf-8"))
        return data

    def _write(self, q: dict[str, Any]) -> None:
        path = self._path(q["id"])
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(q, ensure_ascii=False, separators=(",", ":")), "utf-8")
        os.replace(tmp, path)

    def _validate(self, fields: dict[str, Any]) -> None:
        if fields.get("fundo", "pontos") not in BACKGROUNDS:
            raise Invalid(f"Fundo inválido: {fields['fundo']}")
        pages = fields.get("paginas", [])
        if not isinstance(pages, list) or not all(
            isinstance(p, dict) and p.get("id") and isinstance(p.get("nome"), str) for p in pages
        ):
            raise Invalid("Páginas precisam de id e nome")
        for e in fields.get("elementos", []):
            if not isinstance(e, dict) or not e.get("id") or e.get("tipo") not in self.tipos:
                raise Invalid("Elemento sem id ou com tipo desconhecido")

    def list_all(self, pasta: str | None = None) -> list[dict[str, Any]]:
        with self._lock:
            frames = [
                {**_summary(self._read(p.stem)), "miniatura": p.with_suffix(".png").exists()}
                for p in self.root.glob("*.json")
            ]
        if pasta is not None:
            frames = [q for q in frames if q["pasta"] == pasta]
        return sorted(frames, key=lambda q: q["atualizado"], reverse=True)

    def obter(self, id_: str) -> dict[str, Any]:
        with self._lock:
            return self._read(id_)

    def criar(self, fields: dict[str, Any]) -> dict[str, Any]:
        self._validate(fields)
        now = _now()
        q = {
            "id": uuid.uuid4().hex,
            "titulo": fields.get("titulo") or "Quadro sem título",
            "fundo": fields.get("fundo", "pontos"),
            "pasta": fields.get("pasta", ""),
            "criado": now,
            "atualizado": now,
            "versao": 1,
            "paginas": fields.get("paginas", []),
            "elementos": fields.get("elementos", []),
        }
        with self._lock:
            self._write(q)
        return q

    def edit(self, id_: str, fields: dict[str, Any]) -> dict[str, Any]:
        fields = {k: v for k, v in fields.items() if k in FIELDS_EDITABLE and v is not None}
        self._validate(fields)
        with self._lock:
            q = self._read(id_)
            q.update(fields, atualizado=_now())
            self._write(q)
        return _summary(q)

    def salvar(self, id_: str, elementos: list[dict[str, Any]], versao: int) -> dict[str, Any]:
        """Troca os elementos se [versao] for a atual; devolve o resumo com a versão nova."""
        self._validate({"elementos": elementos})
        with self._lock:
            q = self._read(id_)
            if versao != q["versao"]:
                raise Conflict(q)
            q.update(elementos=elementos, versao=q["versao"] + 1, atualizado=_now())
            self._write(q)
        return _summary(q)

    def substituir(self, id_: str, fields: dict[str, Any]) -> dict[str, Any]:
        """Troca título, páginas e elementos de uma vez (importação), subindo a versão."""
        fields = {k: fields[k] for k in ("titulo", "paginas", "elementos") if k in fields}
        self._validate(fields)
        with self._lock:
            q = self._read(id_)
            q.update(fields, versao=q["versao"] + 1, atualizado=_now())
            self._write(q)
        return q

    def duplicate(self, id_: str) -> dict[str, Any]:
        q = self.obter(id_)
        return self.criar({**q, "titulo": f"{q['titulo']} (cópia)"})

    def thumbnail(self, id_: str) -> Path:
        """PNG pequeno do quadro, gerado pelo app a cada gravação (a galeria mostra)."""
        path = self._path(id_).with_suffix(".png")
        if not path.exists():
            raise NotFound(id_)
        return path

    def store_thumbnail(self, id_: str, dados: bytes) -> None:
        if not dados.startswith(PNG) or len(dados) > MAX_THUMBNAIL:
            raise Invalid("Miniatura deve ser PNG de até 512 KB")
        with self._lock:
            self._read(id_)
            path = self._path(id_).with_suffix(".png")
            tmp = path.with_suffix(".tmp")
            tmp.write_bytes(dados)
            os.replace(tmp, path)

    def _anexos(self, id_: str) -> Path:
        return self._path(id_).with_suffix(".anexos")

    def store_png(self, id_: str, nome: str, dados: bytes) -> None:
        """PNG avulso do documento (ex.: render de cada tela do wireframe), em `<id>.anexos/`."""
        if not re.fullmatch(r"[\w-]{1,64}", nome):
            raise Invalid("Nome de anexo inválido")
        if not dados.startswith(PNG) or len(dados) > MAX_ATTACHMENT:
            raise Invalid("Anexo deve ser PNG de até 8 MB")
        with self._lock:
            self._read(id_)
            folder = self._anexos(id_)
            folder.mkdir(exist_ok=True)
            tmp = folder / f"{nome}.tmp"
            tmp.write_bytes(dados)
            os.replace(tmp, folder / f"{nome}.png")

    def pngs(self, id_: str) -> dict[str, bytes]:
        """{nome: bytes} dos PNGs guardados com [guardar_png]."""
        folder = self._anexos(id_)
        return (
            {p.stem: p.read_bytes() for p in sorted(folder.glob("*.png"))} if folder.is_dir() else {}
        )

    def excluir(self, id_: str) -> None:
        with self._lock:
            path = self._path(id_)
            if not path.exists():
                raise NotFound(id_)
            path.unlink()
            path.with_suffix(".png").unlink(missing_ok=True)
            shutil.rmtree(self._anexos(id_), ignore_errors=True)
