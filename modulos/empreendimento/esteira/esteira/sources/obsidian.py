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

RE_FALA = re.compile(r'^\s*["“](.+)["”]\s*$')
RE_FONTE = re.compile(r'^\s*- (?:\[.\] )?\*\*(?P<autores>[^*]+?)\s*\((?P<ano>\d{4}[a-z]?)\)\*\*\s*:?\s*'
                      r'["“](?P<titulo>[^"”]+)["”],?\s*(?:\*(?P<revista>[^*]+)\*)?(?P<resto>.*)')
RE_DOI = re.compile(r"\b(10\.\d{4,9}/[^\s)\]]+)")
RE_CAMPO = re.compile(r">\s*\*\*(\w+):\*\*\s*(.*)")
RE_CAB = re.compile(r"^>\s*\[!cite\]\s*(?P<autores>.+?)\s*\((?P<ano>\d{4}[a-z]?|s\.d\.)\)\s*(?:[—–-]\s*(?P<revista>.+))?$")


def pasta_canais(vault):
    return Path(vault).expanduser() / "Notas/Empreendimento/YouTube"


def canais(vault):
    return sorted(p.name for p in pasta_canais(vault).iterdir() if (p / "Roteiros").is_dir())


def _numero(nome, meta):
    if isinstance(meta.get("video"), int):
        return meta["video"]
    m = re.search(r"\b(\d{3})\b", nome)
    return int(m.group(1)) if m else None


def titulo_limpo(h1):
    t = re.sub(r"^(?:Roteiro|Short)\s*(\d+[a-z]?\s*)?[—–-]\s*(\d+[a-z]?\s+)?", "", h1.strip("# ").strip())
    return re.sub(r"\s*\([^)]*\)\s*$", "", t).strip()


def short(nome, meta):
    """Letra do Short ("a" em `Short 005a — ...`), ou "" para vídeo longo."""
    if meta.get("tipo") != "short" and not re.match(r"Short\b", nome):
        return ""
    m = re.search(r"\b\d{3}([a-z])\b", nome)
    return str(meta.get("short") or (m.group(1) if m else "a"))


def listar(vault, canal=None):
    """Roteiros (16:9, pasta Roteiros/) e Shorts (9:16, pasta Shorts/) do vault: [{canal, numero, short,
    formato, titulo, status, caminho, atualizado}] ordenados."""
    saida = []
    for c in [canal] if canal else canais(vault):
        for md in [*(pasta_canais(vault) / c / "Roteiros").glob("*.md"), *(pasta_canais(vault) / c / "Shorts").glob("*.md")]:
            post = frontmatter.load(md)
            h1 = next((l for l in post.content.splitlines() if l.startswith("# ")), md.stem)
            letra = short(md.name, post.metadata)
            saida.append({"canal": c, "numero": _numero(md.name, post.metadata), "short": letra,
                          "formato": "9:16" if letra else "16:9", "titulo": titulo_limpo(h1),
                          "modo": str(post.metadata.get("modo") or "").strip().lower(),
                          "status": str(post.metadata.get("status", "")), "caminho": str(md),
                          "atualizado": str(post.metadata.get("atualizado", ""))})
    return sorted(saida, key=lambda r: (r["canal"], r["numero"] or 0, r["short"]))


def _inline(texto):
    """Markdown da fala → marcação da esteira: **x** vira *x* (destaque), links viram texto."""
    texto = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", texto)
    texto = re.sub(r"\*\*(.+?)\*\*", r"*\1*", texto)
    return texto.replace("’", "'").strip()


def _citacao(cit):
    """Campos do bloco [!cite] → dados da citação (arquivo relativo ao vault, página 1-based)."""
    alvo = re.search(r"\[\[([^#|\]]+\.pdf)(?:#page=(\d+))?", cit.pop("pdf", ""))
    pagina = re.sub(r"\D", "", cit.pop("página", cit.pop("pagina", ""))) or (alvo and alvo.group(2)) or ""
    cit["en"] = re.sub(r"^==|==$", "", cit.get("en", "")).strip()
    if not (alvo and pagina and cit["en"]):
        return None
    cit.update(arquivo=alvo.group(1), pagina=int(pagina), pt=cit.get("pt", "").strip(), titulo=cit.get("título", ""))
    cit.pop("título", None)
    return cit


def converter(md_texto):
    """Devolve (titulo, linhas_do_roteiro, notas_de_cena, fontes, citacoes)."""
    post = frontmatter.loads(md_texto)
    titulo, linhas, notas, fontes, citacoes = None, [], [], [], []
    secao, parte, callout, cit = "", None, None, None
    for linha in post.content.splitlines() + [""]:
        if cit is not None and (not linha.startswith(">") or re.match(r">\s*\[!", linha)):
            if cit := _citacao(cit):
                citacoes.append(cit)
            cit = None
        if linha.startswith("# ") and not titulo:
            titulo = titulo_limpo(linha)
            continue
        if linha.startswith("## "):
            secao = linha[3:].strip()
            m = re.match(r"Parte\s+(\d+)\s*[—–-]?\s*(.*?)(\s*\(\d+:\d+\))?$", secao)
            parte = {"n": int(m.group(1)), "nome": m.group(2).strip()} if m else None
            callout = None
            continue
        f = RE_FONTE.match(linha)
        if f:
            doi = RE_DOI.search(linha)
            url = re.search(r"\]\((https?://[^)]+)\)", linha)
            fontes.append({"autores": f["autores"].strip(), "ano": f["ano"], "titulo": f["titulo"].strip(),
                           "revista": (f["revista"] or "").strip(), "detalhes": f["resto"].split("DOI")[0].strip(" .,"),
                           "doi": doi.group(1).rstrip(".") if doi else None, "url": url.group(1) if url else None})
            continue
        if not parte:
            continue
        c = RE_CAB.match(linha)
        if c or re.match(r"^>\s*\[!cite\]", linha):
            cit = {"parte": parte["n"], "fala": sum("fala" in x for x in linhas) - 1,
                   **({k: (v or "").strip() for k, v in c.groupdict().items()} if c else {})}
            continue
        if cit is not None:
            m = RE_CAMPO.match(linha)
            if m:
                cit[m.group(1).lower()] = m.group(2).strip()
            continue
        if re.match(r"^>\s*\[!example\]", linha):
            callout = {"parte": parte["n"], "antes_da_fala": sum("fala" in x for x in linhas), "texto": ""}
            notas.append(callout)
            continue
        if linha.startswith(">") and callout is not None:
            callout["texto"] = (callout["texto"] + " " + linha.lstrip("> ").strip()).strip()
            continue
        callout = None
        m = RE_FALA.match(linha)
        if m:
            if not linhas or linhas[-1].get("parte") != parte["n"]:
                linhas.append({"parte": parte["n"], "capitulo": parte["nome"]})
            linhas.append({"parte": parte["n"], "fala": _inline(m.group(1))})
    return titulo, linhas, notas, fontes, citacoes


def roteiro_txt(titulo, linhas):
    """Texto no formato lido por `cenas.ler_roteiro` (uma fala por linha)."""
    return "\n".join([f"# {titulo}", ""] + [l["fala"] for l in linhas if "fala" in l]) + "\n"


def capitulos(linhas):
    """[(parte, nome, índice da 1ª fala)] para títulos de capítulo e marcadores."""
    saida, k = [], 0
    for l in linhas:
        if "capitulo" in l:
            saida.append({"parte": l["parte"], "nome": l["capitulo"], "fala": k})
        else:
            k += 1
    return saida


def _norm_slug(texto):
    import unicodedata
    s = unicodedata.normalize("NFKD", texto.lower())
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")[:40]
