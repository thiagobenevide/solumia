"""Roteiros do vault Obsidian → roteiro.txt da esteira, notas de cena e lista de fontes.

Formato dos roteiros (`Notas/Empreendimento/YouTube/<canal>/Roteiros/*.md`):
  frontmatter (video, status, ...) · `# Roteiro — NNN Título` · seções `## Parte N — ...` com
  `**Passo N**` seguido da fala entre aspas e callouts `> [!example] Cena` com a direção visual.
  Fora das partes (`## Leitura antes de gravar`, `## Notas de produção`) ficam as fontes, com DOI.
  Logo depois da fala que cita um estudo vem o bloco `> [!cite] Autor (Ano) — Revista` com **Título:**,
  **PDF:** [[Referências/Artigos/x.pdf#page=N|...]], **Página:**, **EN:** ==trecho como está no PDF== e
  **PT:** tradução (gerado e conferido por `.claude/scripts/artigo citar` no vault).
"""
import re
from pathlib import Path

import frontmatter

RE_SPEECH = re.compile(r'^\s*["“](.+)["”]\s*$')
RE_SOURCE = re.compile(r'^\s*- (?:\[.\] )?\*\*(?P<autores>[^*]+?)\s*\((?P<ano>\d{4}[a-z]?)\)\*\*\s*:?\s*'
                      r'["“](?P<titulo>[^"”]+)["”],?\s*(?:\*(?P<revista>[^*]+)\*)?(?P<resto>.*)')
RE_DOI = re.compile(r"\b(10\.\d{4,9}/[^\s)\]]+)")
RE_FIELD = re.compile(r">\s*\*\*(\w+):\*\*\s*(.*)")
RE_HEADER = re.compile(r"^>\s*\[!cite\]\s*(?P<autores>.+?)\s*\((?P<ano>\d{4}[a-z]?|s\.d\.)\)\s*(?:[—–-]\s*(?P<revista>.+))?$")


def folder_channels(vault):
    return Path(vault).expanduser() / "Notas/Empreendimento/YouTube"


def channels(vault):
    return sorted(p.name for p in folder_channels(vault).iterdir() if (p / "Roteiros").is_dir())


def _number(name, meta):
    if isinstance(meta.get("video"), int):
        return meta["video"]
    m = re.search(r"\b(\d{3})\b", name)
    return int(m.group(1)) if m else None


def title_clean(h1):
    t = re.sub(r"^(?:Roteiro|Short)\s*(\d+[a-z]?\s*)?[—–-]\s*(\d+[a-z]?\s+)?", "", h1.strip("# ").strip())
    return re.sub(r"\s*\([^)]*\)\s*$", "", t).strip()


def short(name, meta):
    """Letra do Short ("a" em `Short 005a — ...`), ou "" para vídeo longo."""
    if meta.get("tipo") != "short" and not re.match(r"Short\b", name):
        return ""
    m = re.search(r"\b\d{3}([a-z])\b", name)
    return str(meta.get("short") or (m.group(1) if m else "a"))


def list_all(vault, channel=None):
    """Roteiros (16:9, pasta Roteiros/) e Shorts (9:16, pasta Shorts/) do vault: [{canal, numero, short,
    formato, titulo, status, caminho, atualizado}] ordenados."""
    output = []
    for c in [channel] if channel else channels(vault):
        for md in [*(folder_channels(vault) / c / "Roteiros").glob("*.md"), *(folder_channels(vault) / c / "Shorts").glob("*.md")]:
            post = frontmatter.load(md)
            h1 = next((l for l in post.content.splitlines() if l.startswith("# ")), md.stem)
            letter = short(md.name, post.metadata)
            output.append({"canal": c, "numero": _number(md.name, post.metadata), "short": letter,
                          "formato": "9:16" if letter else "16:9", "titulo": title_clean(h1),
                          "modo": str(post.metadata.get("modo") or "").strip().lower(),
                          "status": str(post.metadata.get("status", "")), "caminho": str(md),
                          "atualizado": str(post.metadata.get("atualizado", ""))})
    return sorted(output, key=lambda r: (r["canal"], r["numero"] or 0, r["short"]))


def _inline(text):
    """Markdown da fala → marcação da esteira: **x** vira *x* (destaque), links viram texto."""
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"*\1*", text)
    return text.replace("’", "'").strip()


def _quote(cit):
    """Campos do bloco [!cite] → dados da citação (arquivo relativo ao vault, página 1-based)."""
    target = re.search(r"\[\[([^#|\]]+\.pdf)(?:#page=(\d+))?", cit.pop("pdf", ""))
    page = re.sub(r"\D", "", cit.pop("página", cit.pop("pagina", ""))) or (target and target.group(2)) or ""
    cit["en"] = re.sub(r"^==|==$", "", cit.get("en", "")).strip()
    if not (target and page and cit["en"]):
        return None
    cit.update(arquivo=target.group(1), pagina=int(page), pt=cit.get("pt", "").strip(), titulo=cit.get("título", ""))
    cit.pop("título", None)
    return cit


def convert(md_text):
    """Devolve (titulo, linhas_do_roteiro, notas_de_cena, fontes, citacoes)."""
    post = frontmatter.loads(md_text)
    title, lines, notes, sources, quotes = None, [], [], [], []
    secao, part, callout, cit = "", None, None, None
    for line in post.content.splitlines() + [""]:
        if cit is not None and (not line.startswith(">") or re.match(r">\s*\[!", line)):
            if cit := _quote(cit):
                quotes.append(cit)
            cit = None
        if line.startswith("# ") and not title:
            title = title_clean(line)
            continue
        if line.startswith("## "):
            secao = line[3:].strip()
            m = re.match(r"Parte\s+(\d+)\s*[—–-]?\s*(.*?)(\s*\(\d+:\d+\))?$", secao)
            part = {"n": int(m.group(1)), "nome": m.group(2).strip()} if m else None
            callout = None
            continue
        f = RE_SOURCE.match(line)
        if f:
            doi = RE_DOI.search(line)
            url = re.search(r"\]\((https?://[^)]+)\)", line)
            sources.append({"autores": f["autores"].strip(), "ano": f["ano"], "titulo": f["titulo"].strip(),
                           "revista": (f["revista"] or "").strip(), "detalhes": f["resto"].split("DOI")[0].strip(" .,"),
                           "doi": doi.group(1).rstrip(".") if doi else None, "url": url.group(1) if url else None})
            continue
        if not part:
            continue
        c = RE_HEADER.match(line)
        if c or re.match(r"^>\s*\[!cite\]", line):
            cit = {"parte": part["n"], "fala": sum("fala" in x for x in lines) - 1,
                   **({k: (v or "").strip() for k, v in c.groupdict().items()} if c else {})}
            continue
        if cit is not None:
            m = RE_FIELD.match(line)
            if m:
                cit[m.group(1).lower()] = m.group(2).strip()
            continue
        if re.match(r"^>\s*\[!example\]", line):
            callout = {"parte": part["n"], "antes_da_fala": sum("fala" in x for x in lines), "texto": ""}
            notes.append(callout)
            continue
        if line.startswith(">") and callout is not None:
            callout["texto"] = (callout["texto"] + " " + line.lstrip("> ").strip()).strip()
            continue
        callout = None
        m = RE_SPEECH.match(line)
        if m:
            if not lines or lines[-1].get("parte") != part["n"]:
                lines.append({"parte": part["n"], "capitulo": part["nome"]})
            lines.append({"parte": part["n"], "fala": _inline(m.group(1))})
    return title, lines, notes, sources, quotes


def script_txt(title, lines):
    """Texto no formato lido por `cenas.ler_roteiro` (uma fala por linha)."""
    return "\n".join([f"# {title}", ""] + [l["fala"] for l in lines if "fala" in l]) + "\n"


def chapters(lines):
    """[(parte, nome, índice da 1ª fala)] para títulos de capítulo e marcadores."""
    output, k = [], 0
    for l in lines:
        if "capitulo" in l:
            output.append({"parte": l["parte"], "nome": l["capitulo"], "fala": k})
        else:
            k += 1
    return output


def _norm_slug(text):
    import unicodedata
    s = unicodedata.normalize("NFKD", text.lower())
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")[:40]
