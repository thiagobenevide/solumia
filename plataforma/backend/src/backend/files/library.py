"""Library of study files: PDFs, documents and presentations, with ink annotations.

Each file is a folder `<root>/<id>/` with `meta.json`, the `original.<ext>`, the `documento.pdf`
the app displays (the original itself when it is already a PDF; otherwise, converted by
LibreOffice), the `miniatura.png` of the first page and `anotacoes.json` (strokes, highlights and
texts, in PDF points of the page).

Annotations have `versao`: whoever saves sends the version they based it on and gets a conflict if
another device saved first. Every change goes into `mudancas.jsonl` with an increasing `seq`, so the
devices (PC, tablet, phone, web) know what changed since they last looked.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import secrets
import shutil
import subprocess
import tempfile
import threading
import unicodedata
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

logger = logging.getLogger("gateway.arquivos")

KINDS_POR_EXTENSION = {
    "pdf": "pdf",
    "docx": "documento",
    "doc": "documento",
    "odt": "documento",
    "rtf": "documento",
    "pptx": "apresentacao",
    "ppt": "apresentacao",
    "odp": "apresentacao",
    # bank statements stored by the Finance module (LibreOffice generates the PDF to read)
    "csv": "planilha",
    "xls": "planilha",
    "xlsx": "planilha",
    "ods": "planilha",
    "ofx": "extrato",
    "qfx": "extrato",
    "txt": "extrato",
    # structured data: the app shows the original as a tree, without PDF
    "xml": "xml",
}
# Types that do not become PDF (the app reads the original itself).
SEM_PDF = ("xml",)
# Blank presentation (flat ODP, one title + subtitle slide) that LibreOffice turns into .pptx.
PRESENTATION_EMPTY = """<?xml version="1.0" encoding="UTF-8"?>
<office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
 xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
 xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
 xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
 xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
 xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
 xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0"
 office:version="1.3" office:mimetype="application/vnd.oasis.opendocument.presentation">
 <office:automatic-styles>
  <style:page-layout style:name="PM1">
   <style:page-layout-properties fo:page-width="28cm" fo:page-height="15.75cm"
    style:print-orientation="landscape"/>
  </style:page-layout>
 </office:automatic-styles>
 <office:master-styles>
  <style:master-page style:name="Padrao" style:page-layout-name="PM1"/>
 </office:master-styles>
 <office:body><office:presentation>
  <draw:page draw:name="Slide 1" draw:master-page-name="Padrao">
   <draw:frame presentation:class="title" svg:x="2cm" svg:y="4cm" svg:width="24cm"
    svg:height="3cm">
    <draw:text-box><text:p>Título</text:p></draw:text-box>
   </draw:frame>
   <draw:frame presentation:class="subtitle" svg:x="2cm" svg:y="8cm" svg:width="24cm"
    svg:height="3cm">
    <draw:text-box><text:p>Subtítulo</text:p></draw:text-box>
   </draw:frame>
  </draw:page>
 </office:presentation></office:body>
</office:document>
""".encode()
SEM_SOFFICE = "LibreOffice (soffice) não está instalado neste servidor"
# Export through LibreOffice: format → `--convert-to` filter (per file type).
EXPORTS = {
    "documento": {
        "pdf": "pdf", "docx": "docx:MS Word 2007 XML", "odt": "odt", "rtf": "rtf",
        "txt": "txt:Text (encoded):UTF8", "html": "html:XHTML Writer File:UTF8",
    },
    "planilha": {"pdf": "pdf", "xlsx": "xlsx:Calc MS Excel 2007 XML", "ods": "ods", "csv": "csv"},
    "apresentacao": {
        "pdf": "pdf", "pptx": "pptx:Impress MS PowerPoint 2007 XML", "odp": "odp",
    },
}
LISTS_ANNOTATION = ("tracos", "destaques", "textos")
TIME_CONVERSION = 180


class FileNotFound(KeyError):
    pass


class FileInvalid(ValueError):
    pass


class AnnotationsConflict(ValueError):
    def __init__(self, current: dict[str, Any]) -> None:
        super().__init__("As anotações mudaram em outro aparelho")
        self.current = current


def _now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat()


def _key(text: str) -> str:
    s = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"\s+", " ", s).strip().lower()


def _read_json(caminho: Path, default: Any) -> Any:
    try:
        return json.loads(caminho.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def _write_json(caminho: Path, dados: Any) -> None:
    """Writes to a temporary file and renames: a reader never sees a half-written file."""
    tmp = caminho.with_suffix(caminho.suffix + ".tmp")
    tmp.write_text(json.dumps(dados, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, caminho)


def reference(titulo: str, highlight: dict[str, Any]) -> str:
    """Markdown citation ready to paste into a note."""
    text = " ".join(str(highlight.get("texto", "")).split())
    quote = f"> {text}\n" if text else ""
    return f"{quote}— [[{titulo}]], p. {int(highlight.get('pagina', 0)) + 1}"


class Collection:
    def __init__(self, root: str | Path, soffice: str = "soffice", pdftoppm: str = "pdftoppm"):
        self.root = Path(root).expanduser()
        self.root.mkdir(parents=True, exist_ok=True)
        self.soffice = soffice
        self.pdftoppm = pdftoppm
        self._lock = threading.RLock()
        self._log = self.root / "mudancas.jsonl"

    # --- paths ---

    def _folder(self, id_: str) -> Path:
        if not re.fullmatch(r"[a-z0-9]{12}", id_):
            raise FileNotFound(id_)
        folder = self.root / id_
        if not (folder / "meta.json").is_file():
            raise FileNotFound(id_)
        return folder

    def path_original(self, id_: str) -> tuple[Path, str]:
        meta = self.obter(id_)
        return self._folder(id_) / f"original.{meta['extensao']}", meta["nome_original"]

    def path_pdf(self, id_: str) -> Path | None:
        pdf = self._folder(id_) / "documento.pdf"
        return pdf if pdf.is_file() else None

    def path_thumbnail(self, id_: str) -> Path | None:
        png = self._folder(id_) / "miniatura.png"
        return png if png.is_file() else None

    # --- changes ---

    def _register(self, action: str, id_: str, **extra: Any) -> int:
        with self._lock:
            seq = self.seq_current() + 1
            line = {"seq": seq, "em": _now(), "acao": action, "arquivo_id": id_, **extra}
            with self._log.open("a", encoding="utf-8") as f:
                f.write(json.dumps(line, ensure_ascii=False) + "\n")
            (self.root / "seq").write_text(str(seq))
            return seq

    def seq_current(self) -> int:
        try:
            return int((self.root / "seq").read_text())
        except (FileNotFoundError, ValueError):
            return 0

    def changes(self, since: int = 0, limite: int = 500) -> dict[str, Any]:
        items: list[dict[str, Any]] = []
        if self._log.is_file():
            with self._log.open(encoding="utf-8") as f:
                for line in f:
                    item = json.loads(line)
                    if item["seq"] > since:
                        items.append(item)
        return {"seq": self.seq_current(), "mudancas": items[-limite:]}

    # --- files ---

    def list_all(
        self, q: str = "", tipo: str | None = None, pasta: str | None = None
    ) -> list[dict]:
        term = _key(q)
        items = []
        for meta_json in self.root.glob("*/meta.json"):
            meta = _read_json(meta_json, None)
            if not meta:
                continue
            if tipo and meta["tipo"] != tipo:
                continue
            if pasta is not None and meta["pasta"] != pasta:
                continue
            target = _key(" ".join([meta["titulo"], meta["nome_original"], *meta["tags"]]))
            if term and term not in target:
                continue
            items.append(meta)
        return sorted(items, key=lambda m: m["atualizado"], reverse=True)

    def folders(self) -> list[str]:
        return sorted({m["pasta"] for m in self.list_all() if m["pasta"]})

    def obter(self, id_: str) -> dict[str, Any]:
        meta: dict[str, Any] = _read_json(self._folder(id_) / "meta.json", None)
        return meta

    def adicionar(self, nome: str, content: bytes, pasta: str = "") -> dict[str, Any]:
        """Stores the file and returns the meta. A PDF comes out `pronto` right away; the rest stays
        `convertendo` until the conversion runs. An identical file already stored is returned with
        `duplicado`."""
        extension = Path(nome).suffix.lower().lstrip(".")
        kind = KINDS_POR_EXTENSION.get(extension)
        if not kind:
            aceitos = ", ".join(sorted(KINDS_POR_EXTENSION))
            raise FileInvalid(f"Formato .{extension or '?'} não suportado (aceitos: {aceitos})")
        if not content:
            raise FileInvalid("Arquivo vazio")
        sha = hashlib.sha256(content).hexdigest()
        with self._lock:
            for meta in self.list_all():
                if meta["sha256"] == sha:
                    return {**meta, "duplicado": True}
            id_ = secrets.token_hex(6)
            destination = self.root / id_
            destination.mkdir()
            (destination / f"original.{extension}").write_bytes(content)
            if kind == "pdf":
                (destination / "documento.pdf").write_bytes(content)
            now = _now()
            meta = {
                "id": id_,
                "titulo": Path(nome).stem.strip() or "sem titulo",
                "nome_original": Path(nome).name,
                "extensao": extension,
                "tipo": kind,
                "tamanho": len(content),
                "sha256": sha,
                "pasta": pasta.strip(),
                "tags": [],
                "status": "pronto" if kind == "pdf" or kind in SEM_PDF else "convertendo",
                "erro": None,
                "destaques": 0,
                "versao_anotacoes": 0,
                "criado": now,
                "atualizado": now,
            }
            _write_json(destination / "meta.json", meta)
            _write_json(destination / "anotacoes.json", self._annotations_empty())
            self._register("criado", id_)
        if kind == "pdf":
            self._generate_thumbnail(destination)
        return meta

    def edit(self, id_: str, fields: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            meta = self.obter(id_)
            for name in ("titulo", "pasta", "tags"):
                if fields.get(name) is not None:
                    meta[name] = fields[name]
            meta["atualizado"] = _now()
            _write_json(self._folder(id_) / "meta.json", meta)
            self._register("editado", id_)
            return meta

    def substituir(self, id_: str, content: bytes) -> dict[str, Any]:
        """Replaces the original with an edited version (in the app or an external editor). What
        becomes PDF goes back to `convertendo`; the caller runs the conversion."""
        if not content:
            raise FileInvalid("Arquivo vazio")
        with self._lock:
            meta = self.obter(id_)
            folder = self._folder(id_)
            (folder / f"original.{meta['extensao']}").write_bytes(content)
            if meta["tipo"] == "pdf":
                (folder / "documento.pdf").write_bytes(content)
            without_conversion = meta["tipo"] == "pdf" or meta["tipo"] in SEM_PDF
            meta.update(
                sha256=hashlib.sha256(content).hexdigest(),
                tamanho=len(content),
                status="pronto" if without_conversion else "convertendo",
                erro=None,
                atualizado=_now(),
            )
            _write_json(folder / "meta.json", meta)
            self._register("editado", id_)
        if meta["tipo"] == "pdf":
            self._generate_thumbnail(folder)
        return meta

    def duplicate(self, id_: str) -> dict[str, Any]:
        """Copy with a new id (original, PDF, thumbnail and annotations); the regular upload would
        refuse it for being identical."""
        with self._lock:
            origin = self._folder(id_)
            new = secrets.token_hex(6)
            shutil.copytree(origin, self.root / new)
            now = _now()
            meta = {**self.obter(id_), "id": new, "criado": now, "atualizado": now}
            meta["titulo"] = f"{meta['titulo']} (cópia)"
            _write_json(self.root / new / "meta.json", meta)
            self._register("criado", new)
            return meta

    def excluir(self, id_: str) -> None:
        with self._lock:
            shutil.rmtree(self._folder(id_))
            self._register("excluido", id_)

    def convert(self, id_: str) -> dict[str, Any]:
        """Generates `documento.pdf` from a DOCX/PPTX/spreadsheet/statement through headless
        LibreOffice (takes seconds)."""
        folder = self._folder(id_)
        meta = self.obter(id_)
        if meta["tipo"] == "pdf" or meta["tipo"] in SEM_PDF:
            return meta
        original = folder / f"original.{meta['extensao']}"
        error: str | None = None
        with tempfile.TemporaryDirectory() as tmp:
            if meta["extensao"] in ("ofx", "qfx"):
                # OFX is text (SGML): Writer converts the .txt copy.
                copy = Path(tmp, "original.txt")
                shutil.copyfile(original, copy)
                original = copy
            # Own profile per conversion: two simultaneous conversions do not fight over the same
            # profile.
            profile = Path(tmp, "perfil").as_uri()
            command = [
                self.soffice,
                f"-env:UserInstallation={profile}",
                "--headless",
                "--convert-to",
                "pdf",
                "--outdir",
                tmp,
                str(original),
            ]
            try:
                r = subprocess.run(command, capture_output=True, timeout=TIME_CONVERSION, text=True)
                gerado = Path(tmp, "original.pdf")
                if gerado.is_file():
                    shutil.move(gerado, folder / "documento.pdf")
                else:
                    error = (r.stderr or r.stdout or "LibreOffice não gerou o PDF").strip()[-500:]
            except FileNotFoundError:
                error = "LibreOffice (soffice) não está instalado neste servidor"
            except subprocess.TimeoutExpired:
                error = f"Conversão passou de {TIME_CONVERSION} s"
        if error is None:
            self._generate_thumbnail(folder)
        else:
            logger.warning("Conversão de %s falhou: %s", id_, error)
        with self._lock:
            meta = self.obter(id_)
            meta.update(status="erro" if error else "pronto", erro=error, atualizado=_now())
            _write_json(folder / "meta.json", meta)
            self._register("convertido", id_, status=meta["status"])
        return meta

    def export(self, id_: str, fmt: str) -> tuple[bytes, str]:
        """Original converted to the format (see the exports table) and the generated file name."""
        meta = self.obter(id_)
        filters = EXPORTS.get(meta["tipo"], {})
        if fmt not in filters:
            aceitos = ", ".join(filters) or "nenhum"
            raise FileInvalid(f"Este arquivo não exporta para {fmt} (aceitos: {aceitos})")
        original, name = self.path_original(id_)
        base = Path(name).stem or "arquivo"
        if meta["extensao"] == fmt:
            return original.read_bytes(), name
        with tempfile.TemporaryDirectory() as tmp:
            profile = Path(tmp, "perfil").as_uri()
            command = [
                self.soffice,
                f"-env:UserInstallation={profile}",
                "--headless",
                "--convert-to",
                filters[fmt],
                "--outdir",
                tmp,
                str(original),
            ]
            try:
                r = subprocess.run(command, capture_output=True, timeout=TIME_CONVERSION, text=True)
            except FileNotFoundError as e:
                raise FileInvalid(SEM_SOFFICE) from e
            except subprocess.TimeoutExpired as e:
                raise FileInvalid(f"Exportação passou de {TIME_CONVERSION} s") from e
            gerado = Path(tmp, f"{original.stem}.{fmt}")
            if not gerado.is_file():
                error = (r.stderr or r.stdout or "LibreOffice não gerou o arquivo").strip()[-500:]
                raise FileInvalid(error)
            return gerado.read_bytes(), f"{base}.{fmt}"

    def create_empty(self, tipo: str, titulo: str, pasta: str = "") -> dict[str, Any]:
        """Blank document (.docx), spreadsheet (.xlsx) or presentation (.pptx), generated by
        LibreOffice from a minimal template, and stored as a regular upload."""
        models = {
            "documento": ("txt", "docx:MS Word 2007 XML", b""),
            "planilha": ("csv", "xlsx:Calc MS Excel 2007 XML", b"\n"),
            "apresentacao": ("fodp", "pptx:Impress MS PowerPoint 2007 XML", PRESENTATION_EMPTY),
        }
        if tipo not in models:
            raise FileInvalid(f"Tipo desconhecido: {tipo}")
        ext_model, criteria, content = models[tipo]
        destination = criteria.split(":")[0]
        name = re.sub(r'[\\/:*?"<>|]+', " ", titulo).strip() or "Sem título"
        with tempfile.TemporaryDirectory() as tmp:
            model = Path(tmp, f"vazio.{ext_model}")
            model.write_bytes(content)
            command = [
                self.soffice,
                f"-env:UserInstallation={Path(tmp, 'perfil').as_uri()}",
                "--headless",
                "--convert-to",
                criteria,
                "--outdir",
                tmp,
                str(model),
            ]
            try:
                subprocess.run(command, capture_output=True, timeout=TIME_CONVERSION)
            except FileNotFoundError as e:
                raise FileInvalid(SEM_SOFFICE) from e
            except subprocess.TimeoutExpired as e:
                raise FileInvalid(f"Criação passou de {TIME_CONVERSION} s") from e
            gerado = Path(tmp, f"vazio.{destination}")
            if not gerado.is_file():
                raise FileInvalid("LibreOffice não gerou o arquivo em branco")
            return self.adicionar(f"{name}.{destination}", gerado.read_bytes(), pasta)

    def mark_convertendo(self, id_: str) -> dict[str, Any]:
        with self._lock:
            meta = self.obter(id_)
            meta.update(status="convertendo", erro=None)
            _write_json(self._folder(id_) / "meta.json", meta)
            return meta

    def _generate_thumbnail(self, pasta: Path) -> None:
        command = [
            self.pdftoppm,
            "-png",
            "-singlefile",
            "-f",
            "1",
            "-l",
            "1",
            "-scale-to",
            "360",
            str(pasta / "documento.pdf"),
            str(pasta / "miniatura"),
        ]
        try:
            subprocess.run(command, capture_output=True, timeout=60, check=False)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            logger.info("Sem miniatura para %s (pdftoppm indisponível)", pasta.name)

    # --- annotations ---

    @staticmethod
    def _annotations_empty() -> dict[str, Any]:
        return {"versao": 0, "atualizado": None, "tracos": [], "destaques": [], "textos": []}

    def annotations(self, id_: str) -> dict[str, Any]:
        data: dict[str, Any] = _read_json(
            self._folder(id_) / "anotacoes.json", self._annotations_empty()
        )
        return data

    def traducao(self, id_: str) -> dict[str, Any]:
        """Portuguese translation per page (0-based, as a text key):
        `{"3": {"segmentos": [...], "traducoes": [...]}}`, aligned sentence by sentence."""
        data: dict[str, Any] = _read_json(self._folder(id_) / "traducao.json", {})
        return data

    def save_translation(self, id_: str, pages: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            data = {**self.traducao(id_), **pages}
            _write_json(self._folder(id_) / "traducao.json", data)
            return data

    def save_annotations(self, id_: str, version_base: int, new: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            current = self.annotations(id_)
            if version_base != current["versao"]:
                raise AnnotationsConflict(current)
            data = {
                "versao": current["versao"] + 1,
                "atualizado": _now(),
                **{name: list(new.get(name) or []) for name in LISTS_ANNOTATION},
            }
            folder = self._folder(id_)
            _write_json(folder / "anotacoes.json", data)
            meta = self.obter(id_)
            meta.update(
                destaques=len(data["destaques"]),
                versao_anotacoes=data["versao"],
                atualizado=data["atualizado"],
            )
            _write_json(folder / "meta.json", meta)
            self._register("anotado", id_, versao=data["versao"])
            return data

    def destaques(self, q: str = "", file_id: str | None = None) -> list[dict[str, Any]]:
        """Excerpts marked with the highlighter in all files, each one with a ready citation."""
        term = _key(q)
        goals = [self.obter(file_id)] if file_id else self.list_all()
        items = []
        for meta in goals:
            for d in self.annotations(meta["id"])["destaques"]:
                if term and term not in _key(f"{d.get('texto', '')} {d.get('comentario', '')}"):
                    continue
                items.append(
                    {
                        **d,
                        "arquivo_id": meta["id"],
                        "arquivo_titulo": meta["titulo"],
                        "referencia": reference(meta["titulo"], d),
                    }
                )
        return sorted(items, key=lambda d: str(d.get("criado") or ""), reverse=True)

    def markings_of_project(self, project_id: str) -> list[dict[str, Any]]:
        """Highlights, texts and handwritten strokes linked to the reading project (each element's
        `projetos` field), with `tipo` (`destaque`/`texto`/`traco`) and the source file."""

        items = []
        for meta in self.list_all():
            anot = self.annotations(meta["id"])
            pairs = (("destaque", "destaques"), ("texto", "textos"), ("traco", "tracos"))
            for kind, lista in pairs:
                for e in anot.get(lista) or []:
                    if project_id in (e.get("projetos") or []):
                        items.append(
                            {
                                **e,
                                "tipo": kind,
                                "arquivo_id": meta["id"],
                                "arquivo_titulo": meta["titulo"],
                            }
                        )
        return items
