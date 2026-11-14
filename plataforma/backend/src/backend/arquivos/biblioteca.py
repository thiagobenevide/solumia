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

TIPOS_POR_EXTENSAO = {
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
APRESENTACAO_VAZIA = """<?xml version="1.0" encoding="UTF-8"?>
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
EXPORTACOES = {
    "documento": {
        "pdf": "pdf", "docx": "docx:MS Word 2007 XML", "odt": "odt", "rtf": "rtf",
        "txt": "txt:Text (encoded):UTF8", "html": "html:XHTML Writer File:UTF8",
    },
    "planilha": {"pdf": "pdf", "xlsx": "xlsx:Calc MS Excel 2007 XML", "ods": "ods", "csv": "csv"},
    "apresentacao": {
        "pdf": "pdf", "pptx": "pptx:Impress MS PowerPoint 2007 XML", "odp": "odp",
    },
}
LISTAS_ANOTACAO = ("tracos", "destaques", "textos")
TEMPO_CONVERSAO = 180


class ArquivoNaoEncontrado(KeyError):
    pass


class ArquivoInvalido(ValueError):
    pass


class AnotacoesConflito(ValueError):
    def __init__(self, atuais: dict[str, Any]) -> None:
        super().__init__("As anotações mudaram em outro aparelho")
        self.atuais = atuais


def _agora() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat()


def _chave(texto: str) -> str:
    s = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode()
    return re.sub(r"\s+", " ", s).strip().lower()


def _ler_json(caminho: Path, padrao: Any) -> Any:
    try:
        return json.loads(caminho.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return padrao


def _gravar_json(caminho: Path, dados: Any) -> None:
    """Grava num temporário e renomeia: um leitor nunca vê o arquivo pela metade."""
    tmp = caminho.with_suffix(caminho.suffix + ".tmp")
    tmp.write_text(json.dumps(dados, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, caminho)


def referencia(titulo: str, destaque: dict[str, Any]) -> str:
    """Citação em Markdown pronta para colar numa nota."""
    texto = " ".join(str(destaque.get("texto", "")).split())
    citacao = f"> {texto}\n" if texto else ""
    return f"{citacao}— [[{titulo}]], p. {int(destaque.get('pagina', 0)) + 1}"


class Biblioteca:
    def __init__(self, raiz: str | Path, soffice: str = "soffice", pdftoppm: str = "pdftoppm"):
        self.raiz = Path(raiz).expanduser()
        self.raiz.mkdir(parents=True, exist_ok=True)
        self.soffice = soffice
        self.pdftoppm = pdftoppm
        self._trava = threading.RLock()
        self._log = self.raiz / "mudancas.jsonl"

    # --- caminhos ---

    def _pasta(self, id_: str) -> Path:
        if not re.fullmatch(r"[a-z0-9]{12}", id_):
            raise ArquivoNaoEncontrado(id_)
        pasta = self.raiz / id_
        if not (pasta / "meta.json").is_file():
            raise ArquivoNaoEncontrado(id_)
        return pasta

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

    def _registrar(self, acao: str, id_: str, **extra: Any) -> int:
        with self._trava:
            seq = self.seq_atual() + 1
            linha = {"seq": seq, "em": _agora(), "acao": acao, "arquivo_id": id_, **extra}
            with self._log.open("a", encoding="utf-8") as f:
                f.write(json.dumps(linha, ensure_ascii=False) + "\n")
            (self.raiz / "seq").write_text(str(seq))
            return seq

    def seq_atual(self) -> int:
        try:
            return int((self.raiz / "seq").read_text())
        except (FileNotFoundError, ValueError):
            return 0

    def mudancas(self, desde: int = 0, limite: int = 500) -> dict[str, Any]:
        itens: list[dict[str, Any]] = []
        if self._log.is_file():
            with self._log.open(encoding="utf-8") as f:
                for linha in f:
                    item = json.loads(linha)
                    if item["seq"] > desde:
                        itens.append(item)
        return {"seq": self.seq_atual(), "mudancas": itens[-limite:]}

    # --- arquivos ---

    def listar(self, q: str = "", tipo: str | None = None, pasta: str | None = None) -> list[dict]:
        termo = _chave(q)
        itens = []
        for meta_json in self.raiz.glob("*/meta.json"):
            meta = _ler_json(meta_json, None)
            if not meta:
                continue
            if tipo and meta["tipo"] != tipo:
                continue
            if pasta is not None and meta["pasta"] != pasta:
                continue
            alvo = _chave(" ".join([meta["titulo"], meta["nome_original"], *meta["tags"]]))
            if termo and termo not in alvo:
                continue
            itens.append(meta)
        return sorted(itens, key=lambda m: m["atualizado"], reverse=True)

    def pastas(self) -> list[str]:
        return sorted({m["pasta"] for m in self.listar() if m["pasta"]})

    def obter(self, id_: str) -> dict[str, Any]:
        meta: dict[str, Any] = _ler_json(self._pasta(id_) / "meta.json", None)
        return meta

    def adicionar(self, nome: str, conteudo: bytes, pasta: str = "") -> dict[str, Any]:
        """Guarda o arquivo e devolve o meta. PDF já sai `pronto`; o resto fica `convertendo`
        até [converter] rodar. Um arquivo idêntico já guardado é devolvido com `duplicado`."""
        extensao = Path(nome).suffix.lower().lstrip(".")
        tipo = TIPOS_POR_EXTENSAO.get(extensao)
        if not tipo:
            aceitos = ", ".join(sorted(TIPOS_POR_EXTENSAO))
            raise ArquivoInvalido(f"Formato .{extensao or '?'} não suportado (aceitos: {aceitos})")
        if not conteudo:
            raise ArquivoInvalido("Arquivo vazio")
        sha = hashlib.sha256(conteudo).hexdigest()
        with self._trava:
            for meta in self.listar():
                if meta["sha256"] == sha:
                    return {**meta, "duplicado": True}
            id_ = secrets.token_hex(6)
            destino = self.raiz / id_
            destino.mkdir()
            (destino / f"original.{extensao}").write_bytes(conteudo)
            if tipo == "pdf":
                (destino / "documento.pdf").write_bytes(conteudo)
            agora = _agora()
            meta = {
                "id": id_,
                "titulo": Path(nome).stem.strip() or "sem titulo",
                "nome_original": Path(nome).name,
                "extensao": extensao,
                "tipo": tipo,
                "tamanho": len(conteudo),
                "sha256": sha,
                "pasta": pasta.strip(),
                "tags": [],
                "status": "pronto" if tipo == "pdf" or tipo in SEM_PDF else "convertendo",
                "erro": None,
                "destaques": 0,
                "versao_anotacoes": 0,
                "criado": agora,
                "atualizado": agora,
            }
            _gravar_json(destino / "meta.json", meta)
            _gravar_json(destino / "anotacoes.json", self._anotacoes_vazias())
            self._registrar("criado", id_)
        if tipo == "pdf":
            self._gerar_miniatura(destino)
        return meta

    def editar(self, id_: str, campos: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            meta = self.obter(id_)
            for nome in ("titulo", "pasta", "tags"):
                if campos.get(nome) is not None:
                    meta[nome] = campos[nome]
            meta["atualizado"] = _agora()
            _gravar_json(self._pasta(id_) / "meta.json", meta)
            self._registrar("editado", id_)
            return meta

    def substituir(self, id_: str, conteudo: bytes) -> dict[str, Any]:
        """Troca o original por uma versão editada (no app ou num editor de fora). O que vira PDF
        volta a `convertendo`; quem chama roda [converter]."""
        if not conteudo:
            raise ArquivoInvalido("Arquivo vazio")
        with self._trava:
            meta = self.obter(id_)
            pasta = self._pasta(id_)
            (pasta / f"original.{meta['extensao']}").write_bytes(conteudo)
            if meta["tipo"] == "pdf":
                (pasta / "documento.pdf").write_bytes(conteudo)
            sem_conversao = meta["tipo"] == "pdf" or meta["tipo"] in SEM_PDF
            meta.update(
                sha256=hashlib.sha256(conteudo).hexdigest(),
                tamanho=len(conteudo),
                status="pronto" if sem_conversao else "convertendo",
                erro=None,
                atualizado=_agora(),
            )
            _gravar_json(pasta / "meta.json", meta)
            self._registrar("editado", id_)
        if meta["tipo"] == "pdf":
            self._gerar_miniatura(pasta)
        return meta

    def duplicar(self, id_: str) -> dict[str, Any]:
        """Cópia com id novo (original, PDF, miniatura e anotações); o envio comum recusaria por
        ser idêntico."""
        with self._trava:
            origem = self._pasta(id_)
            novo = secrets.token_hex(6)
            shutil.copytree(origem, self.raiz / novo)
            agora = _agora()
            meta = {**self.obter(id_), "id": novo, "criado": agora, "atualizado": agora}
            meta["titulo"] = f"{meta['titulo']} (cópia)"
            _gravar_json(self.raiz / novo / "meta.json", meta)
            self._registrar("criado", novo)
            return meta

    def excluir(self, id_: str) -> None:
        with self._trava:
            shutil.rmtree(self._pasta(id_))
            self._registrar("excluido", id_)

    def converter(self, id_: str) -> dict[str, Any]:
        """Gera `documento.pdf` de um DOCX/PPTX/planilha/extrato pelo LibreOffice headless (demora
        segundos)."""
        pasta = self._pasta(id_)
        meta = self.obter(id_)
        if meta["tipo"] == "pdf" or meta["tipo"] in SEM_PDF:
            return meta
        original = pasta / f"original.{meta['extensao']}"
        erro: str | None = None
        with tempfile.TemporaryDirectory() as tmp:
            if meta["extensao"] in ("ofx", "qfx"):
                # OFX é texto (SGML): o Writer converte a cópia .txt.
                copia = Path(tmp, "original.txt")
                shutil.copyfile(original, copia)
                original = copia
            # Perfil próprio por conversão: duas conversões juntas não brigam pelo mesmo perfil.
            perfil = Path(tmp, "perfil").as_uri()
            comando = [
                self.soffice, f"-env:UserInstallation={perfil}", "--headless",
                "--convert-to", "pdf", "--outdir", tmp, str(original),
            ]
            try:
                r = subprocess.run(comando, capture_output=True, timeout=TEMPO_CONVERSAO, text=True)
                gerado = Path(tmp, "original.pdf")
                if gerado.is_file():
                    shutil.move(gerado, pasta / "documento.pdf")
                else:
                    erro = (r.stderr or r.stdout or "LibreOffice não gerou o PDF").strip()[-500:]
            except FileNotFoundError:
                erro = "LibreOffice (soffice) não está instalado neste servidor"
            except subprocess.TimeoutExpired:
                erro = f"Conversão passou de {TEMPO_CONVERSAO} s"
        if erro is None:
            self._gerar_miniatura(pasta)
        else:
            logger.warning("Conversão de %s falhou: %s", id_, erro)
        with self._trava:
            meta = self.obter(id_)
            meta.update(status="erro" if erro else "pronto", erro=erro, atualizado=_agora())
            _gravar_json(pasta / "meta.json", meta)
            self._registrar("convertido", id_, status=meta["status"])
        return meta

    def exportar(self, id_: str, formato: str) -> tuple[bytes, str]:
        """Original convertido para [formato] (ver `EXPORTACOES`) e o nome do arquivo gerado."""
        meta = self.obter(id_)
        filtros = EXPORTACOES.get(meta["tipo"], {})
        if formato not in filtros:
            aceitos = ", ".join(filtros) or "nenhum"
            raise ArquivoInvalido(f"Este arquivo não exporta para {formato} (aceitos: {aceitos})")
        original, nome = self.caminho_original(id_)
        base = Path(nome).stem or "arquivo"
        if meta["extensao"] == formato:
            return original.read_bytes(), nome
        with tempfile.TemporaryDirectory() as tmp:
            perfil = Path(tmp, "perfil").as_uri()
            comando = [
                self.soffice, f"-env:UserInstallation={perfil}", "--headless",
                "--convert-to", filtros[formato], "--outdir", tmp, str(original),
            ]
            try:
                r = subprocess.run(comando, capture_output=True, timeout=TEMPO_CONVERSAO, text=True)
            except FileNotFoundError as e:
                raise ArquivoInvalido(SEM_SOFFICE) from e
            except subprocess.TimeoutExpired as e:
                raise ArquivoInvalido(f"Exportação passou de {TEMPO_CONVERSAO} s") from e
            gerado = Path(tmp, f"{original.stem}.{formato}")
            if not gerado.is_file():
                erro = (r.stderr or r.stdout or "LibreOffice não gerou o arquivo").strip()[-500:]
                raise ArquivoInvalido(erro)
            return gerado.read_bytes(), f"{base}.{formato}"

    def criar_vazio(self, tipo: str, titulo: str, pasta: str = "") -> dict[str, Any]:
        """Documento (.docx), planilha (.xlsx) ou apresentação (.pptx) em branco, gerado pelo
        LibreOffice a partir de um modelo mínimo, e guardado como um envio comum."""
        modelos = {
            "documento": ("txt", "docx:MS Word 2007 XML", b""),
            "planilha": ("csv", "xlsx:Calc MS Excel 2007 XML", b"\n"),
            "apresentacao": ("fodp", "pptx:Impress MS PowerPoint 2007 XML", APRESENTACAO_VAZIA),
        }
        if tipo not in modelos:
            raise ArquivoInvalido(f"Tipo desconhecido: {tipo}")
        ext_modelo, filtro, conteudo = modelos[tipo]
        destino = filtro.split(":")[0]
        nome = re.sub(r'[\\/:*?"<>|]+', " ", titulo).strip() or "Sem título"
        with tempfile.TemporaryDirectory() as tmp:
            modelo = Path(tmp, f"vazio.{ext_modelo}")
            modelo.write_bytes(conteudo)
            comando = [
                self.soffice, f"-env:UserInstallation={Path(tmp, 'perfil').as_uri()}", "--headless",
                "--convert-to", filtro, "--outdir", tmp, str(modelo),
            ]
            try:
                subprocess.run(comando, capture_output=True, timeout=TEMPO_CONVERSAO)
            except FileNotFoundError as e:
                raise ArquivoInvalido(SEM_SOFFICE) from e
            except subprocess.TimeoutExpired as e:
                raise ArquivoInvalido(f"Criação passou de {TEMPO_CONVERSAO} s") from e
            gerado = Path(tmp, f"vazio.{destino}")
            if not gerado.is_file():
                raise ArquivoInvalido("LibreOffice não gerou o arquivo em branco")
            return self.adicionar(f"{nome}.{destino}", gerado.read_bytes(), pasta)

    def marcar_convertendo(self, id_: str) -> dict[str, Any]:
        with self._trava:
            meta = self.obter(id_)
            meta.update(status="convertendo", erro=None)
            _gravar_json(self._pasta(id_) / "meta.json", meta)
            return meta

    def _gerar_miniatura(self, pasta: Path) -> None:
        comando = [
            self.pdftoppm, "-png", "-singlefile", "-f", "1", "-l", "1", "-scale-to", "360",
            str(pasta / "documento.pdf"), str(pasta / "miniatura"),
        ]
        try:
            subprocess.run(comando, capture_output=True, timeout=60, check=False)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            logger.info("Sem miniatura para %s (pdftoppm indisponível)", pasta.name)

    # --- anotações ---

    @staticmethod
    def _anotacoes_vazias() -> dict[str, Any]:
        return {"versao": 0, "atualizado": None, "tracos": [], "destaques": [], "textos": []}

    def anotacoes(self, id_: str) -> dict[str, Any]:
        dados: dict[str, Any] = _ler_json(
            self._pasta(id_) / "anotacoes.json", self._anotacoes_vazias()
        )
        return dados

    def traducao(self, id_: str) -> dict[str, Any]:
        """Tradução para o português por página (0-based, como chave texto):
        `{"3": {"segmentos": [...], "traducoes": [...]}}`, alinhada frase a frase."""
        dados: dict[str, Any] = _ler_json(self._pasta(id_) / "traducao.json", {})
        return dados

    def salvar_traducao(self, id_: str, paginas: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            dados = {**self.traducao(id_), **paginas}
            _gravar_json(self._pasta(id_) / "traducao.json", dados)
            return dados

    def salvar_anotacoes(self, id_: str, versao_base: int, novas: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            atuais = self.anotacoes(id_)
            if versao_base != atuais["versao"]:
                raise AnotacoesConflito(atuais)
            dados = {
                "versao": atuais["versao"] + 1,
                "atualizado": _agora(),
                **{nome: list(novas.get(nome) or []) for nome in LISTAS_ANOTACAO},
            }
            pasta = self._pasta(id_)
            _gravar_json(pasta / "anotacoes.json", dados)
            meta = self.obter(id_)
            meta.update(
                destaques=len(dados["destaques"]),
                versao_anotacoes=dados["versao"],
                atualizado=dados["atualizado"],
            )
            _gravar_json(pasta / "meta.json", meta)
            self._registrar("anotado", id_, versao=dados["versao"])
            return dados

    def destaques(self, q: str = "", arquivo_id: str | None = None) -> list[dict[str, Any]]:
        """Trechos marcados com o marca-texto em todos os arquivos, cada um com a citação pronta."""
        termo = _chave(q)
        metas = [self.obter(arquivo_id)] if arquivo_id else self.listar()
        itens = []
        for meta in metas:
            for d in self.anotacoes(meta["id"])["destaques"]:
                if termo and termo not in _chave(f"{d.get('texto', '')} {d.get('comentario', '')}"):
                    continue
                itens.append({
                    **d,
                    "arquivo_id": meta["id"],
                    "arquivo_titulo": meta["titulo"],
                    "referencia": referencia(meta["titulo"], d),
                })
        return sorted(itens, key=lambda d: str(d.get("criado") or ""), reverse=True)

    def marcacoes_do_projeto(self, projeto_id: str) -> list[dict[str, Any]]:
        """Destaques, textos e traços à mão ligados ao projeto de leitura (campo `projetos` de cada
        elemento), com `tipo` (`destaque`/`texto`/`traco`) e o arquivo de origem."""
        itens = []
        for meta in self.listar():
            anot = self.anotacoes(meta["id"])
            pares = (("destaque", "destaques"), ("texto", "textos"), ("traco", "tracos"))
            for tipo, lista in pares:
                for e in anot.get(lista) or []:
                    if projeto_id in (e.get("projetos") or []):
                        itens.append({
                            **e,
                            "tipo": tipo,
                            "arquivo_id": meta["id"],
                            "arquivo_titulo": meta["titulo"],
                        })
        return itens
