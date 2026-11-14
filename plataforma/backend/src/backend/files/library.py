"""Biblioteca de arquivos de estudo: PDF, documentos e apresentações, com anotações à tinta.

Cada arquivo é uma pasta `<raiz>/<id>/` com `meta.json`, o `original.<ext>`, o `documento.pdf`
que o app exibe (o próprio original quando já é PDF; senão, convertido pelo LibreOffice), a
`miniatura.png` da primeira página e `anotacoes.json` (traços, destaques e textos, em pontos PDF
da página).

As anotações têm `versao`: quem salva manda a versão em que se baseou e recebe conflito se outro
aparelho salvou antes. Toda alteração entra em `mudancas.jsonl` com um `seq` crescente, para os
aparelhos (PC, tablet, celular, web) saberem o que mudou desde a última vez que olharam.
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
    # extratos bancários guardados pelo módulo Finanças (o LibreOffice gera o PDF para ler)
    "csv": "planilha",
    "xls": "planilha",
    "xlsx": "planilha",
    "ods": "planilha",
    "ofx": "extrato",
    "qfx": "extrato",
    "txt": "extrato",
    # dados estruturados: o app mostra o original em árvore, sem PDF
    "xml": "xml",
}
# Tipos que não viram PDF (o app lê o próprio original).
SEM_PDF = ("xml",)
# Apresentação em branco (ODP plano, um slide de título + subtítulo) que o LibreOffice vira .pptx.
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
# Exportação pelo LibreOffice: formato → filtro do `--convert-to` (por tipo de arquivo).
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
        self.atuais = current


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
    """Grava num temporário e renomeia: um leitor nunca vê o arquivo pela metade."""
    tmp = caminho.with_suffix(caminho.suffix + ".tmp")
    tmp.write_text(json.dumps(dados, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, caminho)


def reference(titulo: str, highlight: dict[str, Any]) -> str:
    """Citação em Markdown pronta para colar numa nota."""
    text = " ".join(str(highlight.get("texto", "")).split())
    quote = f"> {text}\n" if text else ""
    return f"{quote}— [[{titulo}]], p. {int(highlight.get('pagina', 0)) + 1}"


class Collection:
    def __init__(self, root: str | Path, soffice: str = "soffice", pdftoppm: str = "pdftoppm"):
        self.raiz = Path(root).expanduser()
        self.raiz.mkdir(parents=True, exist_ok=True)
        self.soffice = soffice
        self.pdftoppm = pdftoppm
        self._trava = threading.RLock()
        self._log = self.raiz / "mudancas.jsonl"

    # --- caminhos ---

    def _pasta(self, id_: str) -> Path:
        if not re.fullmatch(r"[a-z0-9]{12}", id_):
            raise FileNotFound(id_)
        folder = self.raiz / id_
        if not (folder / "meta.json").is_file():
            raise FileNotFound(id_)
        return folder

    def caminho_original(self, id_: str) -> tuple[Path, str]:
        meta = self.obter(id_)
        return self._pasta(id_) / f"original.{meta['extensao']}", meta["nome_original"]

    def caminho_pdf(self, id_: str) -> Path | None:
        pdf = self._pasta(id_) / "documento.pdf"
        return pdf if pdf.is_file() else None

    def caminho_miniatura(self, id_: str) -> Path | None:
        png = self._pasta(id_) / "miniatura.png"
        return png if png.is_file() else None

    # --- mudanças ---

    def _registrar(self, action: str, id_: str, **extra: Any) -> int:
        with self._trava:
            seq = self.seq_atual() + 1
            line = {"seq": seq, "em": _now(), "acao": action, "arquivo_id": id_, **extra}
            with self._log.open("a", encoding="utf-8") as f:
                f.write(json.dumps(line, ensure_ascii=False) + "\n")
            (self.raiz / "seq").write_text(str(seq))
            return seq

    def seq_atual(self) -> int:
        try:
            return int((self.raiz / "seq").read_text())
        except (FileNotFoundError, ValueError):
            return 0

    def mudancas(self, since: int = 0, limite: int = 500) -> dict[str, Any]:
        items: list[dict[str, Any]] = []
        if self._log.is_file():
            with self._log.open(encoding="utf-8") as f:
                for line in f:
                    item = json.loads(line)
                    if item["seq"] > since:
                        items.append(item)
        return {"seq": self.seq_atual(), "mudancas": items[-limite:]}

    # --- arquivos ---

    def listar(self, q: str = "", tipo: str | None = None, pasta: str | None = None) -> list[dict]:
        term = _key(q)
        items = []
        for meta_json in self.raiz.glob("*/meta.json"):
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

    def pastas(self) -> list[str]:
        return sorted({m["pasta"] for m in self.listar() if m["pasta"]})

    def obter(self, id_: str) -> dict[str, Any]:
        meta: dict[str, Any] = _read_json(self._pasta(id_) / "meta.json", None)
        return meta

    def adicionar(self, nome: str, content: bytes, pasta: str = "") -> dict[str, Any]:
        """Guarda o arquivo e devolve o meta. PDF já sai `pronto`; o resto fica `convertendo`
        até [converter] rodar. Um arquivo idêntico já guardado é devolvido com `duplicado`."""
        extension = Path(nome).suffix.lower().lstrip(".")
        kind = KINDS_POR_EXTENSION.get(extension)
        if not kind:
            aceitos = ", ".join(sorted(KINDS_POR_EXTENSION))
            raise FileInvalid(f"Formato .{extension or '?'} não suportado (aceitos: {aceitos})")
        if not content:
            raise FileInvalid("Arquivo vazio")
        sha = hashlib.sha256(content).hexdigest()
        with self._trava:
            for meta in self.listar():
                if meta["sha256"] == sha:
                    return {**meta, "duplicado": True}
            id_ = secrets.token_hex(6)
            destination = self.raiz / id_
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
            _write_json(destination / "anotacoes.json", self._anotacoes_vazias())
            self._registrar("criado", id_)
        if kind == "pdf":
            self._gerar_miniatura(destination)
        return meta

    def editar(self, id_: str, fields: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            meta = self.obter(id_)
            for name in ("titulo", "pasta", "tags"):
                if fields.get(name) is not None:
                    meta[name] = fields[name]
            meta["atualizado"] = _now()
            _write_json(self._pasta(id_) / "meta.json", meta)
            self._registrar("editado", id_)
            return meta

    def substituir(self, id_: str, content: bytes) -> dict[str, Any]:
        """Troca o original por uma versão editada (no app ou num editor de fora). O que vira PDF
        volta a `convertendo`; quem chama roda [converter]."""
        if not content:
            raise FileInvalid("Arquivo vazio")
        with self._trava:
            meta = self.obter(id_)
            folder = self._pasta(id_)
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
            self._registrar("editado", id_)
        if meta["tipo"] == "pdf":
            self._gerar_miniatura(folder)
        return meta

    def duplicar(self, id_: str) -> dict[str, Any]:
        """Cópia com id novo (original, PDF, miniatura e anotações); o envio comum recusaria por
        ser idêntico."""
        with self._trava:
            origin = self._pasta(id_)
            new = secrets.token_hex(6)
            shutil.copytree(origin, self.raiz / new)
            now = _now()
            meta = {**self.obter(id_), "id": new, "criado": now, "atualizado": now}
            meta["titulo"] = f"{meta['titulo']} (cópia)"
            _write_json(self.raiz / new / "meta.json", meta)
            self._registrar("criado", new)
            return meta

    def excluir(self, id_: str) -> None:
        with self._trava:
            shutil.rmtree(self._pasta(id_))
            self._registrar("excluido", id_)

    def converter(self, id_: str) -> dict[str, Any]:
        """Gera `documento.pdf` de um DOCX/PPTX/planilha/extrato pelo LibreOffice headless (demora
        segundos)."""
        folder = self._pasta(id_)
        meta = self.obter(id_)
        if meta["tipo"] == "pdf" or meta["tipo"] in SEM_PDF:
            return meta
        original = folder / f"original.{meta['extensao']}"
        error: str | None = None
        with tempfile.TemporaryDirectory() as tmp:
            if meta["extensao"] in ("ofx", "qfx"):
                # OFX é texto (SGML): o Writer converte a cópia .txt.
                copy = Path(tmp, "original.txt")
                shutil.copyfile(original, copy)
                original = copy
            # Perfil próprio por conversão: duas conversões juntas não brigam pelo mesmo perfil.
            profile = Path(tmp, "perfil").as_uri()
            command = [
                self.soffice, f"-env:UserInstallation={profile}", "--headless",
                "--convert-to", "pdf", "--outdir", tmp, str(original),
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
            self._gerar_miniatura(folder)
        else:
            logger.warning("Conversão de %s falhou: %s", id_, error)
        with self._trava:
            meta = self.obter(id_)
            meta.update(status="erro" if error else "pronto", erro=error, atualizado=_now())
            _write_json(folder / "meta.json", meta)
            self._registrar("convertido", id_, status=meta["status"])
        return meta

    def exportar(self, id_: str, fmt: str) -> tuple[bytes, str]:
        """Original convertido para [formato] (ver `EXPORTACOES`) e o nome do arquivo gerado."""
        meta = self.obter(id_)
        filters = EXPORTS.get(meta["tipo"], {})
        if fmt not in filters:
            aceitos = ", ".join(filters) or "nenhum"
            raise FileInvalid(f"Este arquivo não exporta para {fmt} (aceitos: {aceitos})")
        original, name = self.caminho_original(id_)
        base = Path(name).stem or "arquivo"
        if meta["extensao"] == fmt:
            return original.read_bytes(), name
        with tempfile.TemporaryDirectory() as tmp:
            profile = Path(tmp, "perfil").as_uri()
            command = [
                self.soffice, f"-env:UserInstallation={profile}", "--headless",
                "--convert-to", filters[fmt], "--outdir", tmp, str(original),
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

    def criar_vazio(self, tipo: str, titulo: str, pasta: str = "") -> dict[str, Any]:
        """Documento (.docx), planilha (.xlsx) ou apresentação (.pptx) em branco, gerado pelo
        LibreOffice a partir de um modelo mínimo, e guardado como um envio comum."""
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
                self.soffice, f"-env:UserInstallation={Path(tmp, 'perfil').as_uri()}", "--headless",
                "--convert-to", criteria, "--outdir", tmp, str(model),
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

    def marcar_convertendo(self, id_: str) -> dict[str, Any]:
        with self._trava:
            meta = self.obter(id_)
            meta.update(status="convertendo", erro=None)
            _write_json(self._pasta(id_) / "meta.json", meta)
            return meta

    def _gerar_miniatura(self, pasta: Path) -> None:
        command = [
            self.pdftoppm, "-png", "-singlefile", "-f", "1", "-l", "1", "-scale-to", "360",
            str(pasta / "documento.pdf"), str(pasta / "miniatura"),
        ]
        try:
            subprocess.run(command, capture_output=True, timeout=60, check=False)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            logger.info("Sem miniatura para %s (pdftoppm indisponível)", pasta.name)

    # --- anotações ---

    @staticmethod
    def _anotacoes_vazias() -> dict[str, Any]:
        return {"versao": 0, "atualizado": None, "tracos": [], "destaques": [], "textos": []}

    def anotacoes(self, id_: str) -> dict[str, Any]:
        data: dict[str, Any] = _read_json(
            self._pasta(id_) / "anotacoes.json", self._anotacoes_vazias()
        )
        return data

    def traducao(self, id_: str) -> dict[str, Any]:
        """Tradução para o português por página (0-based, como chave texto):
        `{"3": {"segmentos": [...], "traducoes": [...]}}`, alinhada frase a frase."""
        data: dict[str, Any] = _read_json(self._pasta(id_) / "traducao.json", {})
        return data

    def salvar_traducao(self, id_: str, pages: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            data = {**self.traducao(id_), **pages}
            _write_json(self._pasta(id_) / "traducao.json", data)
            return data

    def salvar_anotacoes(self, id_: str, version_base: int, new: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            current = self.anotacoes(id_)
            if version_base != current["versao"]:
                raise AnnotationsConflict(current)
            data = {
                "versao": current["versao"] + 1,
                "atualizado": _now(),
                **{name: list(new.get(name) or []) for name in LISTS_ANNOTATION},
            }
            folder = self._pasta(id_)
            _write_json(folder / "anotacoes.json", data)
            meta = self.obter(id_)
            meta.update(
                destaques=len(data["destaques"]),
                versao_anotacoes=data["versao"],
                atualizado=data["atualizado"],
            )
            _write_json(folder / "meta.json", meta)
            self._registrar("anotado", id_, versao=data["versao"])
            return data

    def destaques(self, q: str = "", file_id: str | None = None) -> list[dict[str, Any]]:
        """Trechos marcados com o marca-texto em todos os arquivos, cada um com a citação pronta."""
        term = _key(q)
        goals = [self.obter(file_id)] if file_id else self.listar()
        items = []
        for meta in goals:
            for d in self.anotacoes(meta["id"])["destaques"]:
                if term and term not in _key(f"{d.get('texto', '')} {d.get('comentario', '')}"):
                    continue
                items.append({
                    **d,
                    "arquivo_id": meta["id"],
                    "arquivo_titulo": meta["titulo"],
                    "referencia": reference(meta["titulo"], d),
                })
        return sorted(items, key=lambda d: str(d.get("criado") or ""), reverse=True)

    def marcacoes_do_projeto(self, project_id: str) -> list[dict[str, Any]]:
        """Destaques, textos e traços à mão ligados ao projeto de leitura (campo `projetos` de cada
        elemento), com `tipo` (`destaque`/`texto`/`traco`) e o arquivo de origem."""
        items = []
        for meta in self.listar():
            anot = self.anotacoes(meta["id"])
            pairs = (("destaque", "destaques"), ("texto", "textos"), ("traco", "tracos"))
            for kind, lista in pairs:
                for e in anot.get(lista) or []:
                    if project_id in (e.get("projetos") or []):
                        items.append({
                            **e,
                            "tipo": kind,
                            "arquivo_id": meta["id"],
                            "arquivo_titulo": meta["titulo"],
                        })
        return items
