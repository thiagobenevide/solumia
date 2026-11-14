"""Mapeamento reverso de citações: o autor anexa o documento (pré-TCC inteiro ou só uma parte,
como introdução ou resumo, em .docx ou PDF) a um projeto de leitura; o arquivo fica nos Arquivos e
o Claude (Claude Code, `claude_json` no worker, nunca a LLM local nem a API) lista as referências
(documento inteiro), depois as citações (o texto em partes, para não estourar a resposta), liga
cada referência a um PDF da biblioteca, baixa sozinho o PDF das obras de acesso aberto (OpenAlex e,
sem ele, o Claude buscando na web) e acha em cada PDF o trecho citado. O trecho vira um destaque no
PDF, no projeto (`projetos: [id]`), já classificado (seção, tipo de citação, "Usado"); as
referências fechadas viram pendências de download (tarefas no Quadro de Rotinas). "Refazer" roda
tudo de novo e só acrescenta o que ainda não foi marcado (id do destaque estável por citação).
Nada gravado para o autor (comentário, observação) menciona a IA: ele revisa e decide."""

from __future__ import annotations

import asyncio
import hashlib
import io
import logging
import re
import subprocess
import unicodedata
import xml.etree.ElementTree as ET
import zipfile
from datetime import UTC, datetime
from difflib import SequenceMatcher
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, BackgroundTasks, Depends, File, HTTPException, Request, UploadFile
from pydantic import BaseModel

from backend.api.deps import require_client_api_key
from backend.arquivos.baixar_referencias import buscar_pdf_aberto
from backend.arquivos.biblioteca import (
    AnotacoesConflito,
    ArquivoInvalido,
    ArquivoNaoEncontrado,
    Biblioteca,
)
from backend.arquivos.reescrita import Reescrita

logger = logging.getLogger("gateway.mapeamento")

COR_DESTAQUE = 0x66FFD54F  # amarelo translúcido, como o marca-texto
LIMITE_CATALOGO = 400  # caracteres da 1ª página de cada PDF para o Claude reconhecer a obra
LIMITE_PDF = 160_000  # caracteres de um PDF por pedido (livro grande: só as páginas prováveis)
LIMITE_PARTE = 30_000  # caracteres do documento por pedido de citações
MODELO = "opus"  # mapeamento delicado: o modelo mais capaz do Claude Code
BUSCAS_SIMULTANEAS = 3
TAG_TAREFA = "download-referencia"

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
XHTML = "{http://www.w3.org/1999/xhtml}"


def _agora() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


# --- texto do documento e dos PDFs ---


def texto_docx(conteudo: bytes) -> str:
    """Parágrafos do corpo (com os títulos marcados por `#`) e as notas de rodapé."""
    try:
        zipado = zipfile.ZipFile(io.BytesIO(conteudo))
        corpo = ET.fromstring(zipado.read("word/document.xml"))
    except (zipfile.BadZipFile, KeyError, ET.ParseError) as e:
        raise ArquivoInvalido("Não consegui ler o .docx (arquivo corrompido?).") from e

    def paragrafos(raiz: ET.Element) -> list[str]:
        linhas = []
        for p in raiz.iter(f"{W}p"):
            partes = []
            for el in p.iter():
                if el.tag == f"{W}t" and el.text:
                    partes.append(el.text)
                elif el.tag == f"{W}tab":
                    partes.append("\t")
                elif el.tag in (f"{W}br", f"{W}cr"):
                    partes.append("\n")
            texto = "".join(partes).strip()
            if not texto:
                continue
            estilo = p.find(f"{W}pPr/{W}pStyle")
            nome = (estilo.get(f"{W}val") or "") if estilo is not None else ""
            if re.match(r"(?i)(heading|t[ií]tulo|ttulo)\s*\d", nome):
                texto = "# " + texto
            linhas.append(texto)
        return linhas

    linhas = paragrafos(corpo)
    if "word/footnotes.xml" in zipado.namelist():
        notas = paragrafos(ET.fromstring(zipado.read("word/footnotes.xml")))
        if notas:
            linhas += ["", "# NOTAS DE RODAPÉ", *notas]
    return "\n".join(linhas)


def dividir_documento(texto: str, limite: int = LIMITE_PARTE) -> list[str]:
    """Partes de até [limite] caracteres, cortadas de preferência num título (`#`); cada parte
    que começa no meio de uma seção leva o título dela, para a citação sair com a seção certa."""
    partes: list[str] = []
    atual: list[str] = []
    tamanho, secao, secao_da_parte = 0, "", ""
    for linha in texto.splitlines():
        titulo = linha.startswith("# ")
        if atual and tamanho + len(linha) > limite and (titulo or tamanho > limite * 0.6):
            partes.append(("" if atual[0].startswith("# ") or not secao_da_parte
                           else f"(continuação da seção: {secao_da_parte})\n") + "\n".join(atual))
            atual, tamanho, secao_da_parte = [], 0, secao
        if titulo:
            secao = linha[2:].strip()
            if not atual:
                secao_da_parte = secao
        atual.append(linha)
        tamanho += len(linha) + 1
    if atual:
        partes.append(("" if atual[0].startswith("# ") or not secao_da_parte
                       else f"(continuação da seção: {secao_da_parte})\n") + "\n".join(atual))
    return [x for x in partes if x.strip()]


def paginas_pdf(pdf: Path) -> list[str]:
    """Texto de cada página (pdftotext; páginas separadas por form feed)."""
    try:
        r = subprocess.run(
            ["pdftotext", str(pdf), "-"], capture_output=True, timeout=120, text=True
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []
    paginas = r.stdout.split("\f")
    if paginas and not paginas[-1].strip():
        paginas.pop()
    return paginas


def palavras_pdf(pdf: Path, pagina: int) -> list[tuple[str, list[float], int]]:
    """Palavras da página (0-based) com a caixa em pontos PDF, origem no canto de cima (como o
    leitor do app) e o número da linha."""
    try:
        r = subprocess.run(
            ["pdftotext", "-bbox-layout", "-f", str(pagina + 1), "-l", str(pagina + 1),
             str(pdf), "-"],
            capture_output=True, timeout=60, text=True,
        )
        raiz = ET.fromstring(r.stdout)
    except (FileNotFoundError, subprocess.TimeoutExpired, ET.ParseError):
        return []
    palavras = []
    for n, linha in enumerate(raiz.iter(f"{XHTML}line")):
        for w in linha.iter(f"{XHTML}word"):
            caixa = [float(w.get(k) or 0) for k in ("xMin", "yMin", "xMax", "yMax")]
            palavras.append((w.text or "", caixa, n))
    return palavras


def _norma(texto: str) -> str:
    sem_acento = unicodedata.normalize("NFKD", texto.lower()).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]", "", sem_acento)


def _tokens(texto: str) -> list[str]:
    texto = re.sub(r"(\w)-\s*\n\s*(\w)", r"\1\2", texto)  # hifenização de quebra de linha
    return [t for t in (_norma(p) for p in texto.split()) if t]


def localizar(
    palavras: list[tuple[str, list[float], int]], trecho: str
) -> tuple[list[list[float]], str, float]:
    """Acha [trecho] nas palavras da página (aproximado: o PDF quebra linhas, hifeniza e às vezes
    o trecho vem com pequenas diferenças). Devolve um retângulo por linha, o texto como está no PDF
    e a cobertura (0–1)."""
    alvo = _tokens(trecho)
    if not alvo or not palavras:
        return [], "", 0.0
    # junta palavra hifenizada no fim da linha com a primeira da linha seguinte
    toks: list[str] = []
    origem: list[list[int]] = []
    i = 0
    while i < len(palavras):
        texto, _, linha = palavras[i]
        idx = [i]
        if (
            texto.endswith("-") and i + 1 < len(palavras) and palavras[i + 1][2] != linha
        ):
            texto = texto[:-1] + palavras[i + 1][0]
            idx.append(i + 1)
            i += 1
        t = _norma(texto)
        if t:
            toks.append(t)
            origem.append(idx)
        i += 1
    blocos = [
        b for b in SequenceMatcher(None, toks, alvo, autojunk=False).get_matching_blocks()
        if b.size
    ]
    if not blocos:
        return [], "", 0.0
    maior = max(blocos, key=lambda b: b.size)
    folga = max(8, len(alvo) // 3)
    escolhidos = [
        b for b in blocos
        if maior.a - len(alvo) - folga <= b.a <= maior.a + len(alvo) + folga
    ]
    cobertura = sum(b.size for b in escolhidos) / len(alvo)
    inicio = min(b.a for b in escolhidos)
    fim = max(b.a + b.size for b in escolhidos)
    indices = [j for k in range(inicio, fim) for j in origem[k]]
    por_linha: dict[int, list[float]] = {}
    for j in indices:
        _, c, linha = palavras[j]
        r = por_linha.get(linha)
        por_linha[linha] = (
            list(c) if r is None
            else [min(r[0], c[0]), min(r[1], c[1]), max(r[2], c[2]), max(r[3], c[3])]
        )
    retangulos = [[round(v, 2) for v in por_linha[k]] for k in sorted(por_linha)]
    texto_pdf = " ".join(palavras[j][0] for j in indices)
    return retangulos, texto_pdf, cobertura


# --- Claude ---

SISTEMA_REFERENCIAS = """Você analisa trabalhos acadêmicos brasileiros (pré-projeto de TCC, \
monografia, artigo) em ABNT para o mapeamento reverso das citações: lista as obras que o \
documento cita, para o autor marcar os trechos nas obras originais.

Regras fixas:
- Uma entrada por obra da lista de REFERÊNCIAS do documento e também por obra citada no texto \
que não está na lista (`fora_da_lista` = true). O documento pode ser só uma parte do trabalho \
(introdução, resumo/abstract, um capítulo) sem lista de referências: então monte uma entrada \
para cada obra citada no texto, todas com `fora_da_lista` = true.
- `referencia`: a entrada completa como está no documento; sem ela, o que o texto traz \
("SILVA, 2020"). `autor_citacao`: como aparece no texto ("Silva", "Silva e Souza", "Silva et \
al."). `titulo`: só o título da obra, como está no documento; "" se o documento não traz.
- `arquivo_id`: o id do catálogo de PDFs da biblioteca que é essa mesma obra (confira título, \
autores e ano pelo início do texto); "" se nenhum for ela. Nunca ligue a uma obra parecida.
- Não invente obras nem complete dados que o documento não traz."""

ESQUEMA_REFERENCIAS = {
    "type": "object",
    "properties": {
        "referencias": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "n": {"type": "integer"},
                    "referencia": {"type": "string"},
                    "autor_citacao": {"type": "string"},
                    "ano": {"type": "string"},
                    "titulo": {"type": "string"},
                    "arquivo_id": {"type": "string"},
                    "fora_da_lista": {"type": "boolean"},
                },
                "required": ["n", "referencia", "autor_citacao", "ano", "titulo", "arquivo_id",
                             "fora_da_lista"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["referencias"],
    "additionalProperties": False,
}

SISTEMA_CITACOES = """Você faz o mapeamento reverso das citações de um trabalho acadêmico \
brasileiro (ABNT): recebe a lista numerada das obras citadas e uma parte do texto, e lista cada \
citação feita nessa parte.

Regras fixas:
- Cada ocorrência de citação no corpo do texto, na ordem, com `ref` = o número da obra na lista. \
Ignore a própria lista de referências, sumário e cabeçalhos.
- `trecho_documento`: a frase (ou frases) do documento que traz a citação, copiada como está.
- `citacao`: nas diretas, só o texto entre aspas ou o recuado; "" nas indiretas.
- `tipo`: "direta", "indireta" ou "apud" (citação de citação: `ref` é a obra consultada, a que \
tem o "apud").
- `pagina`: a página citada como está ("p. 23"), ou "".
- `secao`: o título da seção onde a citação está (linhas começando com # são títulos; \
"continuação da seção" diz a seção do começo da parte). Sem títulos marcados, use o título \
que o texto mostra (ex.: "Introdução", "Resumo").
- Uma mesma frase citando duas obras gera duas citações. Não invente citações; citação de obra \
que não está na lista fica de fora."""

ESQUEMA_CITACOES = {
    "type": "object",
    "properties": {
        "citacoes": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "ref": {"type": "integer"},
                    "trecho_documento": {"type": "string"},
                    "citacao": {"type": "string"},
                    "tipo": {"type": "string", "enum": ["direta", "indireta", "apud"]},
                    "pagina": {"type": "string"},
                    "secao": {"type": "string"},
                },
                "required": ["ref", "trecho_documento", "citacao", "tipo", "pagina", "secao"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["citacoes"],
    "additionalProperties": False,
}

SISTEMA_BUSCAR = """Você acha na internet o PDF gratuito e público de uma obra acadêmica citada \
num trabalho, para baixar. Use a busca na web e abra as páginas para conferir.

Regras fixas:
- Identifique a obra pela referência; se ela está incompleta (só autor e ano), use as frases \
que a citam para achar qual é. Sem certeza de que é a mesma obra, `encontrado` = false.
- `urls_pdf`: links que baixam direto o PDF da própria obra (mesmo título, autores e ano; \
preprint/versão aceita do mesmo trabalho vale), de acesso aberto: repositórios institucionais, \
SciELO, PubMed Central, arXiv, site do periódico ou do autor. Do melhor para o pior. Nunca \
sites piratas nem páginas que pedem login ou pagamento.
- `titulo`, `doi` e `referencia_completa` (ABNT) da obra identificada; "" no que não achar.
- Obra fechada, sem PDF público: `encontrado` = true e `urls_pdf` vazio."""

ESQUEMA_BUSCAR = {
    "type": "object",
    "properties": {
        "encontrado": {"type": "boolean"},
        "titulo": {"type": "string"},
        "doi": {"type": "string"},
        "referencia_completa": {"type": "string"},
        "urls_pdf": {"type": "array", "items": {"type": "string"}},
        "observacao": {"type": "string"},
    },
    "required": ["encontrado", "titulo", "doi", "referencia_completa", "urls_pdf", "observacao"],
    "additionalProperties": False,
}

SISTEMA_LOCALIZAR = """Você confere citações de um trabalho acadêmico nas obras originais, como o \
autor faria com o marca-texto: para cada citação, acha na obra o trecho que ela usa.

Regras fixas:
- A obra vem página por página ("=== Página N ===", N é a página do PDF, que pode diferir da \
numeração impressa citada no trabalho).
- `trecho`: copie da obra, palavra por palavra como está no texto da página (mesmo com erros de \
extração), o trecho que a citação usa: nas diretas, exatamente o texto citado; nas indiretas \
(paráfrase), a frase ou as poucas frases que sustentam a ideia (no máximo um parágrafo).
- `pagina`: o N da página onde o trecho começa. Se a citação não está nesta obra ou nas páginas \
enviadas, devolva `encontrado` = false, com o motivo em `observacao`.
- `confianca`: "alta" quando o trecho é claramente o citado, "media" ou "baixa" quando é o mais \
provável. Não invente texto que não está na obra."""

ESQUEMA_LOCALIZAR = {
    "type": "object",
    "properties": {
        "trechos": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "c": {"type": "integer"},
                    "encontrado": {"type": "boolean"},
                    "pagina": {"type": "integer"},
                    "trecho": {"type": "string"},
                    "confianca": {"type": "string", "enum": ["alta", "media", "baixa"]},
                    "observacao": {"type": "string"},
                },
                "required": ["c", "encontrado", "pagina", "trecho", "confianca", "observacao"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["trechos"],
    "additionalProperties": False,
}


def prompt_referencias(documento: str, catalogo: list[dict[str, Any]]) -> str:
    linhas = [
        f'- id "{c["id"]}" · arquivo: {c["titulo"]}'
        + (f" · ficha: {c['ficha']}" if c.get("ficha") else "")
        + f"\n  início: {c['inicio']}"
        for c in catalogo
    ]
    return (
        "<catalogo_de_pdfs>\n" + ("\n".join(linhas) or "(biblioteca vazia)")
        + "\n</catalogo_de_pdfs>\n\n<documento>\n" + documento + "\n</documento>\n\n"
        "Liste todas as obras citadas no documento, ligando ao catálogo."
    )


def _lista_obras(refs: dict[int, dict[str, Any]]) -> str:
    return "\n".join(
        f"{n}. {r['autor_citacao']} ({r['ano']})"
        + (f" — {r['titulo']}" if r.get("titulo") else "")
        + f" · {r['referencia'][:240]}"
        for n, r in sorted(refs.items())
    )


def prompt_citacoes(parte: str, refs: dict[int, dict[str, Any]], k: int, total: int) -> str:
    return (
        f"<obras>\n{_lista_obras(refs)}\n</obras>\n\n"
        f"<texto parte=\"{k} de {total}\">\n{parte}\n</texto>\n\n"
        "Liste todas as citações desta parte do texto."
    )


def prompt_buscar(ref: dict[str, Any], cits: list[dict[str, Any]]) -> str:
    frases = "\n".join(f"- {c['trecho_documento'][:400]}" for c in cits[:4])
    return (
        f"Referência como está no trabalho: {ref['referencia']}\n"
        f"Autor no texto: {ref['autor_citacao']} · ano: {ref['ano']}"
        + (f" · título: {ref['titulo']}" if ref.get("titulo") else "")
        + (f"\n\nFrases do trabalho que citam a obra:\n{frases}" if frases else "")
        + "\n\nAche o PDF público desta obra."
    )


def _paginas_provaveis(paginas: list[str], citacoes: list[dict[str, Any]]) -> list[int]:
    """Livro grande: as páginas com mais palavras em comum com as citações, até o limite."""
    total = sum(len(p) for p in paginas)
    if total <= LIMITE_PDF:
        return list(range(len(paginas)))
    alvo = set()
    for c in citacoes:
        alvo |= {t for t in _tokens(c["citacao"] or c["trecho_documento"]) if len(t) > 4}
    nota = sorted(
        range(len(paginas)),
        key=lambda i: -len(alvo & set(_tokens(paginas[i]))),
    )
    escolhidas, soma = [], 0
    for i in nota:
        if soma + len(paginas[i]) > LIMITE_PDF:
            continue
        escolhidas.append(i)
        soma += len(paginas[i])
    return sorted(escolhidas)


def prompt_localizar(ref: dict[str, Any], citacoes: list[dict[str, Any]], paginas: list[str],
                     indices: list[int]) -> str:
    cits = "\n\n".join(
        f"[{n}] tipo: {c['tipo']}" + (f" · página citada: {c['pagina']}" if c["pagina"] else "")
        + f"\nno trabalho: {c['trecho_documento']}"
        + (f"\ntexto citado: {c['citacao']}" if c["citacao"] else "")
        for n, c in enumerate(citacoes)
    )
    obra = "\n\n".join(f"=== Página {i + 1} ===\n{paginas[i].strip()}" for i in indices)
    return (
        f"Obra: {ref['referencia']}\n\n<citacoes>\n{cits}\n</citacoes>\n\n"
        f"<obra>\n{obra}\n</obra>\n\nAche na obra o trecho de cada citação (`c` = número entre "
        "colchetes)."
    )


# --- processo ---


def _tipo_citacao(c: dict[str, Any], texto: str) -> str:
    if c["tipo"] == "apud":
        return "Citação de citação (apud)"
    if c["tipo"] == "indireta":
        return "Indireta (paráfrase)"
    return "Direta longa (mais de 3 linhas)" if len(texto) > 240 else "Direta curta (até 3 linhas)"


def _id_destaque(projeto_id: str, c: dict[str, Any]) -> str:
    chave = f"{c['trecho_documento']}|{c['citacao']}|{c['ref_texto']}"
    return f"map-{projeto_id}-{hashlib.sha1(chave.encode()).hexdigest()[:12]}"


class Mapeador:
    """Roda um mapeamento por projeto por vez, em segundo plano; o estado fica no projeto
    (`mapeamento`), para o app acompanhar."""

    def __init__(self, request_app: Any) -> None:
        self.app = request_app
        self.rodando: dict[str, asyncio.Task[None]] = {}

    @property
    def biblioteca(self) -> Biblioteca:
        b: Biblioteca = self.app.state.biblioteca
        return b

    @property
    def estudos(self) -> Any:
        return self.app.state.estudos

    @property
    def claude(self) -> Reescrita:
        r: Reescrita = self.app.state.reescrita
        return r

    def estado(self, projeto_id: str) -> dict[str, Any]:
        projeto = self.estudos.projetos.obter(projeto_id)
        m: dict[str, Any] = dict(projeto.get("mapeamento") or {})
        if m.get("estado") == "rodando" and projeto_id not in self.rodando:
            m = self._salvar(projeto_id, estado="erro", erro="Interrompido (servidor reiniciou).")
        return m

    def _salvar(self, projeto_id: str, **campos: Any) -> dict[str, Any]:
        with self.estudos.projetos.trava:
            projeto = self.estudos.projetos.obter(projeto_id)
            m = {**(projeto.get("mapeamento") or {}), **campos}
            self.estudos.projetos.editar(projeto_id, {"mapeamento": m})
        return m

    def iniciar(self, projeto_id: str, documento_id: str) -> dict[str, Any]:
        if projeto_id in self.rodando:
            raise HTTPException(409, "O mapeamento deste projeto já está rodando.")
        motivo = self.claude.disponivel()
        if motivo or self.claude.executar_json is None:
            raise HTTPException(503, motivo or "Claude indisponível neste servidor.")
        meta = self.biblioteca.obter(documento_id)
        m = self._salvar(
            projeto_id,
            documento_id=documento_id,
            documento_titulo=meta["titulo"],
            estado="rodando",
            etapa="Lendo o documento",
            erro=None,
            iniciado=_agora(),
        )
        tarefa = asyncio.create_task(self._rodar(projeto_id, documento_id))
        self.rodando[projeto_id] = tarefa
        tarefa.add_done_callback(lambda _t: self.rodando.pop(projeto_id, None))
        return m

    async def _claude(self, prompt: str, sistema: str, esquema: dict[str, Any],
                      limite_s: float, ferramentas: str = "") -> dict[str, Any]:
        assert self.claude.executar_json is not None
        return await self.claude.executar_json({
            "prompt": prompt, "sistema": sistema, "esquema": esquema,
            "effort": "high", "limite_s": limite_s, "modelo": MODELO,
            "ferramentas": ferramentas,
        })

    def _texto_documento(self, documento_id: str) -> str:
        meta = self.biblioteca.obter(documento_id)
        if meta.get("extensao") == "docx":
            original, _ext = self.biblioteca.caminho_original(documento_id)
            return texto_docx(original.read_bytes())
        pdf = self.biblioteca.caminho_pdf(documento_id)
        return "\n\n".join(paginas_pdf(pdf)) if pdf else ""

    async def _rodar(self, projeto_id: str, documento_id: str) -> None:
        try:
            await self._mapear(projeto_id, documento_id)
        except Exception as e:  # noqa: BLE001 — qualquer falha vira estado legível no app
            logger.exception("mapeamento do projeto %s falhou", projeto_id)
            self._salvar(projeto_id, estado="erro", erro=str(e) or type(e).__name__,
                         concluido=_agora())

    def _catalogo(self, documento_id: str) -> list[dict[str, Any]]:
        fichas = {
            x["arquivo_id"]: x for x in self.estudos.leituras.ler() if x.get("arquivo_id")
        }
        catalogo = []
        for meta in self.biblioteca.listar():
            if meta["id"] == documento_id or meta.get("status") != "pronto":
                continue
            pdf = self.biblioteca.caminho_pdf(meta["id"])
            if pdf is None or meta.get("tipo") not in ("pdf", "documento"):
                continue
            paginas = paginas_pdf(pdf)
            inicio = re.sub(r"\s+", " ", " ".join(paginas[:2]))[:LIMITE_CATALOGO]
            f = fichas.get(meta["id"]) or {}
            ficha = " · ".join(str(f.get(k)) for k in ("autor", "ano", "titulo") if f.get(k))
            catalogo.append({
                "id": meta["id"], "titulo": meta["titulo"], "ficha": ficha, "inicio": inicio,
            })
        return catalogo

    async def _mapear(self, projeto_id: str, documento_id: str) -> None:
        documento = await asyncio.to_thread(self._texto_documento, documento_id)
        if not documento.strip():
            raise RuntimeError("O documento não tem texto selecionável (PDF escaneado?).")
        self._salvar(projeto_id, etapa="Montando o catálogo dos PDFs da biblioteca")
        catalogo = await asyncio.to_thread(self._catalogo, documento_id)
        ids = {c["id"] for c in catalogo}
        self._salvar(projeto_id, etapa="Lendo as referências do documento")
        r = await self._claude(prompt_referencias(documento, catalogo), SISTEMA_REFERENCIAS,
                               ESQUEMA_REFERENCIAS, 900)
        refs = {int(x["n"]): x for x in r.get("referencias") or []}
        if not refs:
            raise RuntimeError("Nenhuma citação de obra encontrada no documento.")

        partes = dividir_documento(documento)
        citacoes: list[dict[str, Any]] = []
        for k, parte in enumerate(partes, 1):
            self._salvar(projeto_id, etapa=f"Lendo as citações do texto ({k}/{len(partes)})")
            rc = await self._claude(prompt_citacoes(parte, refs, k, len(partes)),
                                    SISTEMA_CITACOES, ESQUEMA_CITACOES, 900)
            citacoes += [c for c in rc.get("citacoes") or [] if int(c.get("ref", -1)) in refs]
        for c in citacoes:
            c["ref_texto"] = refs[int(c["ref"])]["referencia"]
        titulos = {m["id"]: m["titulo"] for m in self.biblioteca.listar()}
        referencias = []
        for n, ref in sorted(refs.items()):
            aid = ref.get("arquivo_id") or ""
            referencias.append({
                "n": n,
                "referencia": ref["referencia"],
                "autor_citacao": ref["autor_citacao"],
                "ano": ref["ano"],
                "titulo": ref["titulo"],
                "fora_da_lista": bool(ref.get("fora_da_lista")),
                "arquivo_id": aid if aid in ids else None,
                "arquivo_titulo": titulos.get(aid) if aid in ids else None,
                "citacoes": sum(int(c["ref"]) == n for c in citacoes),
                "marcadas": 0,
                "nao_localizadas": [],
            })
        self._salvar(projeto_id, referencias=referencias, citacoes=len(citacoes))
        await self._baixar_abertos(projeto_id, referencias, citacoes)

        marcadas = 0
        for k, ref in enumerate(referencias):
            if not ref["arquivo_id"] or not ref["citacoes"]:
                continue
            self._salvar(
                projeto_id,
                etapa=f"Procurando as citações em {ref['autor_citacao']} {ref['ano']} "
                f"({k + 1}/{len(referencias)})",
            )
            cits = [c for c in citacoes if int(c["ref"]) == ref["n"]]
            try:
                await self._marcar_obra(projeto_id, ref, cits)
            except Exception as e:  # noqa: BLE001 — uma obra com problema não para as outras
                logger.exception("marcação em %s falhou", ref["arquivo_id"])
                ref["nao_localizadas"].append(f"Falhou nesta obra ({e}); toque em Refazer.")
            marcadas += ref["marcadas"]
            self._salvar(projeto_id, referencias=referencias, marcadas=marcadas)

        self._ficha_leituras(referencias)
        pendentes = [x for x in referencias if not x["arquivo_id"]]
        self._tarefas_download(projeto_id, referencias)
        self._salvar(
            projeto_id,
            estado="pronto",
            etapa="",
            referencias=referencias,
            citacoes=len(citacoes),
            marcadas=marcadas,
            pendentes=len(pendentes),
            concluido=_agora(),
        )

    async def _baixar_abertos(self, projeto_id: str, referencias: list[dict[str, Any]],
                              citacoes: list[dict[str, Any]]) -> None:
        """Para cada referência: DOI e link do artigo (para a planilha citar com o link) e, se
        ainda não tem PDF, baixa sozinho o de acesso aberto (OpenAlex; sem ele, o Claude busca
        na web) para Arquivos (pasta "Referências"). As fechadas ficam como pendência."""
        trava = asyncio.Semaphore(BUSCAS_SIMULTANEAS)
        feitas = 0

        async def uma(ref: dict[str, Any]) -> None:
            nonlocal feitas
            async with trava:
                try:
                    await self._buscar_obra(ref, [c for c in citacoes
                                                  if int(c["ref"]) == ref["n"]])
                except Exception:  # noqa: BLE001 — falha numa obra não para o mapeamento
                    logger.exception("busca da referência %r falhou", ref.get("titulo"))
                feitas += 1
                self._salvar(projeto_id, referencias=referencias,
                             etapa=f"Buscando os artigos e os PDFs abertos "
                             f"({feitas}/{len(referencias)})")

        self._salvar(projeto_id,
                     etapa=f"Buscando os artigos e os PDFs abertos (0/{len(referencias)})")
        await asyncio.gather(*(uma(r) for r in referencias))

    async def _buscar_obra(self, ref: dict[str, Any], cits: list[dict[str, Any]]) -> None:
        baixar = not ref["arquivo_id"]
        achado = await buscar_pdf_aberto(ref, baixar=baixar)
        if (baixar and achado["pdf"] is None) or not achado["link"]:
            r = await self._claude(prompt_buscar(ref, cits), SISTEMA_BUSCAR, ESQUEMA_BUSCAR,
                                   420, ferramentas="WebSearch,WebFetch")
            if r.get("encontrado"):
                if r.get("titulo") and not ref.get("titulo"):
                    ref["titulo"] = r["titulo"]
                if r.get("referencia_completa") and ref.get("fora_da_lista"):
                    ref["referencia_completa"] = r["referencia_completa"]
                extra = f" {r['doi']}" if r.get("doi") else ""
                novo = await buscar_pdf_aberto(
                    {**ref, "referencia": ref["referencia"] + extra},
                    extras=r.get("urls_pdf") or [], baixar=baixar,
                )
                achado = {k: achado[k] or novo[k] for k in achado}
                if not achado["link"] and r.get("urls_pdf"):
                    achado["link"] = r["urls_pdf"][0]
        ref["doi"] = ref.get("doi") or achado["doi"]
        ref["link"] = ref.get("link") or achado["link"] or achado["url_pdf"]
        if achado["pdf"] is None:
            return
        nome = re.sub(r'[\\/:*?"<>|\s]+', " ",
                      f"{ref['autor_citacao']} {ref['ano']} - {ref['titulo']}").strip()[:150]
        try:
            meta = await asyncio.to_thread(
                self.biblioteca.adicionar, f"{nome or 'referencia'}.pdf", achado["pdf"],
                "Referências",
            )
        except ArquivoInvalido:
            return
        ref["arquivo_id"] = meta["id"]
        ref["arquivo_titulo"] = meta["titulo"]
        ref["baixado_auto"] = True
        ref["url_pdf"] = achado["url_pdf"]

    async def _marcar_obra(self, projeto_id: str, ref: dict[str, Any],
                           cits: list[dict[str, Any]]) -> int:
        aid = ref["arquivo_id"]
        pdf = self.biblioteca.caminho_pdf(aid)
        if pdf is None:
            return 0
        paginas = await asyncio.to_thread(paginas_pdf, pdf)
        existentes = {d["id"] for d in self.biblioteca.anotacoes(aid)["destaques"]}
        a_fazer = [c for c in cits if _id_destaque(projeto_id, c) not in existentes]
        ref["marcadas"] = len(cits) - len(a_fazer)  # já marcadas num mapeamento anterior
        if not a_fazer or not paginas:
            if not paginas:
                ref["nao_localizadas"] = ["PDF sem texto (escaneado?): marque à mão."]
            return 0
        indices = _paginas_provaveis(paginas, a_fazer)
        r = await self._claude(prompt_localizar(ref, a_fazer, paginas, indices),
                               SISTEMA_LOCALIZAR, ESQUEMA_LOCALIZAR, 600)
        novos = []
        for t in r.get("trechos") or []:
            n = int(t.get("c", -1))
            if not 0 <= n < len(a_fazer):
                continue
            c = a_fazer[n]
            if not t.get("encontrado") or not str(t.get("trecho") or "").strip():
                ref["nao_localizadas"].append(
                    f"{c['trecho_documento'][:160]} — {t.get('observacao') or 'não achado'}"
                )
                continue
            pagina = max(0, min(len(paginas) - 1, int(t.get("pagina") or 1) - 1))
            retangulos, texto_pdf, cobertura = [], "", 0.0
            for p in dict.fromkeys([pagina, pagina + 1, pagina - 1]):
                if not 0 <= p < len(paginas):
                    continue
                pal = await asyncio.to_thread(palavras_pdf, pdf, p)
                rr, tt, cc = localizar(pal, t["trecho"])
                if cc > cobertura:
                    retangulos, texto_pdf, cobertura, pagina = rr, tt, cc, p
                if cc >= 0.9:
                    break
            achou = cobertura >= 0.6
            comentario = (
                f"[pré-TCC · {c['secao'] or 'sem seção'}] {c['trecho_documento']}"
                + ("" if achou else "\n(Marcação aproximada: confira o trecho nesta página.)")
            )
            novos.append({
                "id": _id_destaque(projeto_id, c),
                "pagina": pagina,
                "texto": texto_pdf if achou else t["trecho"].strip(),
                "cor": COR_DESTAQUE,
                "retangulos": retangulos if achou else [],
                "comentario": comentario,
                "criado": _agora(),
                "projetos": [projeto_id],
            })
            c["_tipo_citacao"] = _tipo_citacao(c, t["trecho"])
            c["_confianca"] = t.get("confianca") or ""
        if novos:
            self._gravar_destaques(aid, novos)
            por_id = {d["id"]: d for d in novos}
            for c in a_fazer:
                d = por_id.get(_id_destaque(projeto_id, c))
                if d is None:
                    continue
                self.estudos.classificar(projeto_id, d["id"], {
                    "secao": c["secao"],
                    "tipo_citacao": c["_tipo_citacao"],
                    "status_uso": "Usado",
                    "parafrase": c["trecho_documento"],
                    "observacoes": (
                        f"Mapeado do documento (confiança {c['_confianca'] or '—'}). "
                        f"Página citada: {c['pagina'] or '—'}."
                    ),
                })
        ref["marcadas"] += len(novos)
        return len(novos)

    def _gravar_destaques(self, arquivo_id: str, novos: list[dict[str, Any]]) -> None:
        for _ in range(5):
            atuais = self.biblioteca.anotacoes(arquivo_id)
            ids = {d["id"] for d in atuais["destaques"]}
            dados = {**atuais, "destaques": [
                *atuais["destaques"], *(d for d in novos if d["id"] not in ids)
            ]}
            try:
                self.biblioteca.salvar_anotacoes(arquivo_id, atuais["versao"], dados)
                return
            except AnotacoesConflito:
                continue
        raise RuntimeError("Não consegui gravar as marcações (arquivo sendo editado).")

    def _ficha_leituras(self, referencias: list[dict[str, Any]]) -> None:
        """Cria a ficha da leitura (autor, ano, referência, DOI e link) dos PDFs ligados que ainda
        não têm, e completa DOI/link/referência que faltam nas existentes, para a matriz e a
        planilha citarem certo e com o link do artigo."""
        from estudos.estudos import AREAS

        fichas = {
            x["arquivo_id"]: x for x in self.estudos.leituras.ler() if x.get("arquivo_id")
        }
        for ref in referencias:
            if not ref["arquivo_id"]:
                continue
            referencia = ref.get("referencia_completa") or ref["referencia"]
            ficha = fichas.get(ref["arquivo_id"])
            if ficha is not None:
                faltam = {
                    k: v for k, v in (("doi", ref.get("doi") or ""), ("url", ref.get("link") or ""),
                                      ("referencia", referencia), ("ano", ref["ano"]))
                    if v and not ficha.get(k)
                }
                if faltam:
                    self.estudos.editar_leitura(ficha["id"], faltam)
                continue
            fichas[ref["arquivo_id"]] = self.estudos.criar_leitura({
                "titulo": ref["titulo"] or ref["arquivo_titulo"] or referencia[:200],
                "autor": ref["autor_citacao"],
                "tipo": "artigo",
                "area": AREAS[0],
                "status": "lido",
                "arquivo_id": ref["arquivo_id"],
                "ano": ref["ano"],
                "referencia": referencia,
                "doi": ref.get("doi") or "",
                "url": ref.get("link") or "",
            })

    def _tarefas_download(self, projeto_id: str, referencias: list[dict[str, Any]]) -> None:
        """Pendência de download no Quadro de Rotinas para cada referência sem PDF; a que já
        tem PDF é concluída."""
        quadro = getattr(self.app.state, "quadro", None)
        if quadro is None:
            return
        projeto = self.estudos.projetos.obter(projeto_id)
        tarefas = {t["titulo"]: t for t in quadro.listar() if TAG_TAREFA in (t.get("tags") or [])}
        for ref in referencias:
            titulo = f"Baixar PDF: {ref['autor_citacao']} ({ref['ano']}) — {ref['titulo']}"[:300]
            t = tarefas.get(titulo)
            if ref["arquivo_id"]:
                if t and t.get("coluna") != "concluida":
                    quadro.mover(t["id"], "concluida")
                continue
            if t is None:
                quadro.criar({
                    "titulo": titulo,
                    "descricao": (
                        f"Referência do projeto de leitura “{projeto.get('nome', '')}” sem PDF "
                        f"nos Arquivos ({ref['citacoes']} citação(ões) no documento).\n\n"
                        f"{ref['referencia']}\n\nBaixe o PDF, envie para Arquivos e toque em "
                        "“Refazer mapeamento” no projeto."
                    ),
                    "prioridade": "alta" if ref["citacoes"] else "media",
                    "tags": [TAG_TAREFA, "estudos"],
                })


# --- rotas ---

router = APIRouter(
    prefix="/api/estudos/projetos",
    tags=["estudos"],
    dependencies=[Depends(require_client_api_key)],
)


def get_mapeador(request: Request) -> Mapeador:
    m: Mapeador | None = getattr(request.app.state, "mapeador", None)
    if m is None:
        m = request.app.state.mapeador = Mapeador(request.app)
    return m


MapeadorDep = Annotated[Mapeador, Depends(get_mapeador)]


def _projeto(m: Mapeador, id_: str) -> dict[str, Any]:
    from estudos.estudos import NaoEncontrado

    try:
        projeto: dict[str, Any] = m.estudos.projetos.obter(id_)
    except NaoEncontrado as e:
        raise HTTPException(404, "Projeto não encontrado") from e
    return projeto


@router.get("/{id_}/mapeamento")
def estado(id_: str, m: MapeadorDep) -> Any:
    _projeto(m, id_)
    return m.estado(id_)


@router.post("/{id_}/documento", status_code=202)
async def anexar(
    id_: str, m: MapeadorDep, tarefas: BackgroundTasks, arquivo: Annotated[UploadFile, File()]
) -> Any:
    """Guarda o documento nos Arquivos (pasta com o nome do projeto; um documento já anexado é
    substituído pela versão nova) e começa o mapeamento."""
    projeto = _projeto(m, id_)
    nome = arquivo.filename or "documento.docx"
    if Path(nome).suffix.lower() not in (".docx", ".pdf"):
        raise HTTPException(422, "Envie o documento em .docx ou PDF.")
    conteudo = await arquivo.read()
    anterior = (projeto.get("mapeamento") or {}).get("documento_id")
    try:
        atual = m.biblioteca.obter(anterior) if anterior else None
    except ArquivoNaoEncontrado:
        atual = None  # o documento anterior foi excluído dos Arquivos
    try:
        if atual and atual.get("extensao") == "docx" and nome.lower().endswith(".docx"):
            meta = m.biblioteca.substituir(anterior, conteudo)
        else:
            meta = m.biblioteca.adicionar(nome, conteudo, pasta=projeto.get("nome", ""))
    except ArquivoInvalido as e:
        raise HTTPException(422, str(e)) from e
    if meta.get("status") == "convertendo":
        tarefas.add_task(m.biblioteca.converter, meta["id"])
    return m.iniciar(id_, meta["id"])


class PedidoMapeamento(BaseModel):
    documento_id: str | None = None
    """Outro .docx/PDF que já está nos Arquivos; vazio = o documento já anexado."""


@router.post("/{id_}/mapeamento", status_code=202)
async def refazer(id_: str, m: MapeadorDep, pedido: PedidoMapeamento | None = None) -> Any:
    projeto = _projeto(m, id_)
    doc = (pedido.documento_id if pedido else None) or \
        (projeto.get("mapeamento") or {}).get("documento_id")
    if not doc:
        raise HTTPException(422, "Anexe o documento (.docx ou PDF) primeiro.")
    try:
        meta = m.biblioteca.obter(doc)
    except ArquivoNaoEncontrado as e:
        raise HTTPException(404, "Documento não está mais nos Arquivos.") from e
    if meta.get("extensao") not in ("docx", "pdf"):
        raise HTTPException(422, "O documento precisa ser .docx ou PDF.")
    return m.iniciar(id_, doc)
