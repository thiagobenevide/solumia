"""Roteiro do vault gerado sem tokens do Claude: Python + LLM local (llama.cpp `qwen3-14b`).

Fluxo (`./dark script finlumia:41 [--to 50]`):
1. Python lê a linha do plano (Arco do canal): título, gancho, artigos-base, busca em inglês, evidência, formato.
2. Python acha estudos de ACESSO ABERTO no OpenAlex (os artigos-base do plano primeiro, depois a busca
   em inglês) e baixa os PDFs com `.claude/scripts/artigo` (que recusa o que não é aberto).
3. Python separa as frases com números de cada PDF; o LLM local escolhe as que provam algo e traduz.
4. O LLM local escreve cada Parte usando só esses fatos; Python reprova fala com número que não está no
   fato e monta o markdown, os blocos `[!cite]` (via `artigo citar`, que confere o trecho no PDF) e a lista
   de fontes. No fim, `artigo checar`.
Saída: `Roteiro — NNN <título>.md` com `status: rascunho-llm` (revisar antes de gravar).
"""
import json
import re
import subprocess
import tomllib
import unicodedata
import urllib.parse
from pathlib import Path

import pymupdf
import requests
from pydantic import BaseModel, Field

from esteira.core import trace
from esteira.ai import local
from esteira.project import ROOT

UA = {"User-Agent": "esteira-dark/1.0 (roteiros com fontes abertas)"}
NUM = re.compile(r"\d+(?:[.,]\d+)*\s*%?")

# Estrutura por formato do plano: (nome, função, fração das palavras)
PARTS = {
    "M": [("Gancho", "abrir com a cena ou o dado mais forte e a pergunta do vídeo", .08),
          ("Por que isso importa para você", "trazer o tema para a vida de quem assiste e prometer o que vem", .08),
          ("Ato 1", "apresentar o primeiro estudo como uma história: quem, o quê, como mediram", .2),
          ("Ato 2", "o que o estudo achou e por que acontece", .2),
          ("Ato 3", "o outro lado: limitação, réplica ou estudo que complica a história", .16),
          ("A revelação", "fechar a pergunta do gancho com o que a evidência diz, separando fato e opinião", .1),
          ("O que fazer com isso", "três ações práticas, sem recomendação de produto", .12),
          ("Fechamento", "pergunta para os comentários e convite para o próximo vídeo do canal", .06)],
}
PARTS["L"] = PARTS["M"][:5] + [("Ato 4", "um segundo ângulo ou dado que amplia a história", .12)] + PARTS["M"][5:]
PARTS["D"] = PARTS["L"]
WORDS = {"M": 1650, "L": 2600, "D": 2300}


def _cfg():
    return tomllib.loads((ROOT / "config.toml").read_text())["fontes"]


def _vault():
    return Path(_cfg()["vault"]).expanduser()


def _article(*args, timeout=300):
    import os
    env = {**os.environ, "OPENALEX_API_KEY": _key_openalex(),
           "ARTIGO_PROGRESSO": str(trace.external_file("artigo"))}
    r = subprocess.run([str(_vault() / ".claude/scripts/artigo"), *map(str, args)], capture_output=True, text=True,
                       timeout=timeout, cwd=_vault(), env=env)
    return r.returncode, r.stdout, r.stderr


def _slug(t):
    s = unicodedata.normalize("NFKD", t.lower())
    return re.sub(r"[^a-z0-9]+", " ", "".join(c for c in s if not unicodedata.combining(c))).strip()


# ---------------------------------------------------------------- 1. plano

def line_of_plan(channel, n):
    folder = _vault() / "Notas/Empreendimento/YouTube" / channel / "Temas"
    for arc in sorted(folder.rglob("*Arco*.md")):
        for line in arc.read_text().splitlines():
            if re.match(rf"^\|\s*{n}\s*\|", line):
                c = [x.strip() for x in line.strip().strip("|").split("|")]
                title = re.sub(r"\s*·\s*\[\[.*$", "", c[2]).strip("* ")
                search = re.search(r"\[([^\]]+)\]\(", c[5])
                return {"n": n, "fio": c[1], "titulo": title, "gancho": c[3], "base": c[4],
                        "busca": search.group(1) if search else title, "evidencia": c[6], "fmt": (c[8] or "M")[:1],
                        "arco": arc.stem}
    raise SystemExit(f"vídeo {n} não está no plano de {channel}")


# ---------------------------------------------------------------- 2. fontes abertas

def _key_openalex():
    from esteira.project import load_env
    return load_env().get("OPENALEX_API_KEY", "")


def _openalex(params):
    key = _key_openalex()
    try:
        r = requests.get("https://api.openalex.org/works", params={**params, **({"api_key": key} if key else {})},
                         headers=UA, timeout=30)
        if r.status_code == 429:
            raise SystemExit("OpenAlex: cota diária sem chave esgotada (volta à meia-noite UTC). "
                             "Ponha OPENALEX_API_KEY no .env da esteira (chave gratuita em openalex.org).")
        return r.json().get("results", [])
    except (requests.RequestException, ValueError):
        return []


def _candidates_base(base):
    """Artigos-base do plano ("Sobrenome (Ano) — *Revista*"): o trabalho no OpenAlex, se for aberto."""
    output = []
    for m in re.finditer(r"([A-ZÀ-Ý][\wÀ-ÿ'\-]+)[^()]*\((\d{4})\)\s*—\s*\*([^*]+)\*", base):
        surname, year, revista = m.groups()
        for w in _openalex({"filter": f"raw_author_name.search:{surname},publication_year:{year}", "per_page": 10}):
            source = (((w.get("primary_location") or {}).get("source") or {}).get("display_name") or "")
            if _slug(revista)[:12] in _slug(source):  # o mesmo trabalho do plano; entra só se for aberto
                if (w.get("open_access") or {}).get("is_oa") and w.get("doi"):
                    output.append(w)
                break
    return output


def _candidates_search(search, n=12):
    return [w for w in _openalex({"search": search, "filter": "is_oa:true,type:article|preprint|report",
                                   "per_page": n, "sort": "relevance_score:desc"})
            if w.get("doi") and (w.get("cited_by_count") or 0) >= 5]


def sources_open(line, maximum=4):
    """PDFs abertos baixados para o vídeo: [{arquivo, titulo, autores, ano, revista, doi}]."""
    seen, sources = set(), []
    trace.step("openalex", f"base: {line['base'][:80]} · busca: {line['busca'][:80]}")
    for w in _candidates_base(line["base"]) + _candidates_search(line["busca"]):
        doi = w["doi"].replace("https://doi.org/", "")
        if doi.lower() in seen or len(sources) >= maximum:
            continue
        seen.add(doi.lower())
        trace.step("pdf", f"{doi} · {w.get('title', '')[:90]}")
        cod, out, _ = _article("baixar", doi)
        if cod or not out.startswith("ok"):
            continue
        file = re.search(r"(Referências/Artigos/\S+\.pdf)", out).group(1)
        ind = json.loads((_vault() / "Referências/Artigos/indice.json").read_text())
        reg = next((v for v in ind.values() if v.get("arquivo") == file), {})
        sources.append({"arquivo": file, "doi": doi, "titulo": reg.get("titulo") or w.get("title", ""),
                       "autores": reg.get("autores", ""), "ano": reg.get("ano") or str(w.get("publication_year", "")),
                       "revista": reg.get("revista", "")})
        print(f"  fonte: {file.split('/')[-1]}")
    return sources


def label(f):
    names = [x.strip().split()[-1] for x in f["autores"].split(",") if x.strip()]
    author = names[0] + (" et al." if len(names) > 2 else f" e {names[1]}" if len(names) == 2 else "") if names else "?"
    return f"{author} ({f['ano']})"


# ---------------------------------------------------------------- 3. fatos (frases do PDF)

class Finding(BaseModel):
    indice: int
    traducao: str = Field(max_length=300)
    achado: str = Field(max_length=220)


class Findings(BaseModel):
    achados: list[Finding] = Field(max_length=3)


def _sentences(pdf, terms, max_pages=25, n=14):
    doc = pymupdf.open(_vault() / pdf)
    output = []
    for k in range(min(len(doc), max_pages)):
        text = re.sub(r"\s+", " ", re.sub(r"-\n(?=[a-z])", "", doc[k].get_text()))
        for f in re.split(r"(?<=[.!?])\s+(?=[A-Z(])", text):
            if not 60 <= len(f) <= 380 or not re.search(r"\d", f):
                continue
            note = 2 * bool(re.search(r"\d+(?:\.\d+)?\s*(%|percent)", f)) + sum(t in f.lower() for t in terms)
            note += 1 if k < 3 else 0  # resumo e introdução trazem o resultado principal
            if note >= 2:
                output.append((note, k + 1, f.strip()))
    output.sort(key=lambda x: (-x[0], x[1]))
    return output[:n]


def facts(line, sources):
    """[{id, fonte, pagina, en, pt, achado}] verificados no PDF pelo `artigo citar`."""
    terms = [t for t in re.findall(r"[a-z]{4,}", line["busca"].lower())]
    output = []
    for f in sources:
        trace.step("trechos", f"{f['arquivo'].split('/')[-1]} · termos: {', '.join(terms[:8])}")
        sentences = _sentences(f["arquivo"], terms)
        if not sentences:
            continue
        items = "\n".join(f"{i}. (p.{p}) {txt}" for i, (_, p, txt) in enumerate(sentences))
        trace.step("fatos", f"{len(sentences)} frases com números de {label(f)}")
        r = local.ask(local.prompt("script_excerpts", tema=line["titulo"], gancho=line["gancho"],
                                         estudo=f"{label(f)}, {f['titulo']}", frases=items),
                            Findings, max_tokens=900)
        for a in (r.achados if r else []):
            if not 0 <= a.indice < len(sentences):
                continue
            _, pag, en = sentences[a.indice]
            trace.step("citar", f"p.{pag}: {en[:120]}")
            cod, block, _ = _article("citar", Path(f["arquivo"]).name, "-p", pag, "-t", en, "-r", a.traducao)
            if cod:
                continue
            block = re.sub(r"^> \[!cite\] .*$", f"> [!cite] {label(f)}" + (f" — {f['revista']}" if f["revista"] else ""),
                           block.strip(), count=1, flags=re.M)  # cabeçalho pelo índice (autor e ano certos)
            output.append({"id": len(output), "fonte": f, "en": en, "pt": a.traducao, "achado": a.achado,
                          "bloco": block})
    return output


# ---------------------------------------------------------------- 4. texto falado

class Speech(BaseModel):
    texto: str = Field(max_length=500)
    fato: int = -1


class Part(BaseModel):
    cena: str = Field(max_length=220)
    falas: list[Speech] = Field(min_length=1, max_length=14)


def _numbers(t):
    return {re.sub(r"[^\d]", "", x) for x in NUM.findall(t) if re.sub(r"[^\d]", "", x)}


def _speech_ok(speech, facts_):
    """Todo número da fala (exceto 1–10 e anos) precisa estar no fato citado (achado ou trecho em inglês)."""
    nums = {n for n in _numbers(speech.texto) if not (len(n) <= 1 or re.fullmatch(r"(19|20)\d\d", n))}
    if not nums:
        return True
    if not 0 <= speech.fato < len(facts_):
        return False
    base = _numbers(facts_[speech.fato]["achado"]) | _numbers(facts_[speech.fato]["en"])
    return nums <= base


def write(line, facts_, channel):
    fmt = line["fmt"] if line["fmt"] in PARTS else "M"
    structure, total = PARTS[fmt], WORDS.get(fmt, 1650)
    items = "\n".join(f"{x['id']}. {x['achado']} — {label(x['fonte'])}" for x in facts_) or "(nenhum)"
    parts, previous = [], ""
    for i, (name, funcao, frac) in enumerate(structure, 1):
        words = max(60, int(total * frac))
        n_speeches = max(2, round(words / 40) + 1)
        r = None
        for attempt in (1, 2, 3):
            trace.step("partes", f"parte {i}/{len(structure)}: {name} · ~{words} palavras · tentativa {attempt}")
            trace.progress(i, len(structure), name)
            r = local.ask(local.prompt(
                "script_part", canal=channel, titulo=line["titulo"], gancho=line["gancho"], parte_n=i,
                total=len(structure), parte_nome=name, funcao=funcao, palavras=words, n_falas=n_speeches,
                anterior=f"Última fala da parte anterior: \"{previous}\"" if previous else "", fatos=items)
                + ("\n(Atenção: na tentativa anterior havia número fora dos FATOS ou o texto ficou curto; "
                   f"escreva {n_speeches} falas de 35 a 60 palavras cada.)" if attempt > 1 else ""),
                Part, temperature=0.4, max_tokens=2200)
            trace.step("validar", f"parte {i}: números de cada fala contra os fatos; tamanho ≥ 70% de {words}")
            if r and all(_speech_ok(f, facts_) for f in r.falas) and \
                    sum(len(f.texto.split()) for f in r.falas) >= 0.7 * words:
                break
        if not r:
            raise SystemExit(f"LLM local não respondeu na parte {i}")
        speeches = [f for f in r.falas if _speech_ok(f, facts_)]  # fala com número sem fonte sai
        parts.append({"nome": name, "cena": r.cena, "falas": speeches})
        previous = speeches[-1].texto if speeches else previous
        print(f"  parte {i}/{len(structure)}: {name} ({sum(len(f.texto.split()) for f in speeches)} palavras)")
    return parts


# ---------------------------------------------------------------- 5. markdown

def _file(channel, line):
    name = re.sub(r"[?:/\\]", "", re.sub(r"\s*[—–-]\s*", ", ", line["titulo"])).strip(" ,.")
    return _vault() / "Notas/Empreendimento/YouTube" / channel / "Roteiros" / f"Roteiro — {line['n']:03d} {name[:90]}.md"


def assemble(channel, line, sources, facts_, parts, channel_note):
    from datetime import datetime
    today = datetime.now().strftime("%Y-%m-%d")
    fmt = line["fmt"]
    t0, lines_md, used, step = 0.0, [], set(), 0
    for i, p in enumerate(parts, 1):
        mm = int(t0 // 60)
        lines_md += [f"## Parte {i} — {p['nome']} ({mm}:{int(t0 % 60):02d})", "",
                      "> [!example] Cena", f"> {p['cena']}", ""]
        for f in p["falas"]:
            step += 1
            lines_md += [f"**Passo {step}**", f"\"{f.texto}\""]
            if 0 <= f.fato < len(facts_) and f.fato not in used:
                lines_md += [facts_[f.fato]["bloco"]]
                used.add(f.fato)
            lines_md.append("")
            t0 += len(f.texto.split()) / 2.6
    sources_md = [f"- [ ] **{label(f)}**: \"{f['titulo']}\", *{f['revista'] or 'acesso aberto'}*. DOI {f['doi']}."
                 for f in sources]
    words = sum(len(f.texto.split()) for p in parts for f in p["falas"])
    md = f"""---
id: "{datetime.now().strftime('%Y%m%d%H%M')}"
tipo: roteiro
tags:
  - empreendimento/youtube/roteiros
canal: "[[{channel_note}]]"
plano: "[[{line['arco']}]]"
video: {line['n']}
fio: {line['fio']}
formato: {fmt}
evidencia: {line['evidencia']}
anterior: ""
criado: "{today}"
atualizado: {today}
status: rascunho-llm
modo: dark
---

# Roteiro — {line['n']:03d} {line['titulo']}

> [!info] Vídeo {line['n']} · Fio {line['fio']} · Formato {fmt} · Termômetro: **{line['evidencia']}**
> **Gancho do plano:** {line['gancho']}
> Gerado por Python + LLM local ({local.TEXT}) com fontes de acesso aberto; ~{words} palavras de fala. Revisar o texto antes de gravar.

## Leitura antes de gravar

{chr(10).join(sources_md) or '- (nenhuma fonte aberta encontrada: completar antes de gravar)'}

> [!warning] Conferir antes de gravar
> - Texto escrito pelo LLM local: revisar fluidez, exemplos e números (cada número veio de um trecho com `[!cite]`).
> - Dados brasileiros atuais (Selic, inflação, leis) não foram incluídos automaticamente.

{chr(10).join(lines_md)}
## Notas de produção

- Fontes: {', '.join(label(f) for f in sources)}.
- Gerado por `./dark script` (esteira-dark) em {today}.
"""
    return md, words


def generate(target, until=None):
    """`canal:N` (ou `canal:N` + ate=M) → roteiros no vault. Pula os que já existem."""
    channel, _, n = target.partition(":")
    folder = _vault() / "Notas/Empreendimento/YouTube" / channel
    channel_note = next((p.stem for p in folder.glob("Canal *.md")), channel)
    for k in range(int(n), int(until or n) + 1):
        if any((folder / "Roteiros").glob(f"Roteiro — {k:03d} *.md")):
            print(f"{k:03d}: já existe, pulado")
            continue
        trace.node(f"roteiro:{channel}:{k}", "plano", f"vídeo {k} (lote {n}–{until or n})")
        line = line_of_plan(channel, k)
        print(f"{k:03d} · {line['titulo']} (Fmt {line['fmt']})")
        sources = sources_open(line)
        facts_ = facts(line, sources)
        print(f"  {len(sources)} fontes abertas, {len(facts_)} fatos conferidos no PDF")
        if len(facts_) < 2:  # sem prova em PDF aberto não há roteiro: o LLM inventaria
            print(f"  ✗ {k:03d} pulado: menos de 2 fatos de fontes abertas; precisa de pesquisa manual")
            continue
        parts = write(line, facts_, channel)
        trace.step("montar", f"{len(parts)} partes, {len(facts_)} blocos [!cite]")
        md, words = assemble(channel, line, sources, facts_, parts, channel_note)
        destination = _file(channel, line)
        destination.write_text(md)
        trace.step("checar", destination.name)
        cod, out, _ = _article("checar", destination)
        print(f"  ✓ {destination.name} · {words} palavras · {out.strip().splitlines()[-1] if out.strip() else ''}")
