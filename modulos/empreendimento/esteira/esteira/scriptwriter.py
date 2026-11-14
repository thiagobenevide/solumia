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
from esteira.project import RAIZ

UA = {"User-Agent": "esteira-dark/1.0 (roteiros com fontes abertas)"}
NUM = re.compile(r"\d+(?:[.,]\d+)*\s*%?")

# Estrutura por formato do plano: (nome, função, fração das palavras)
PARTES = {
    "M": [("Gancho", "abrir com a cena ou o dado mais forte e a pergunta do vídeo", .08),
          ("Por que isso importa para você", "trazer o tema para a vida de quem assiste e prometer o que vem", .08),
          ("Ato 1", "apresentar o primeiro estudo como uma história: quem, o quê, como mediram", .2),
          ("Ato 2", "o que o estudo achou e por que acontece", .2),
          ("Ato 3", "o outro lado: limitação, réplica ou estudo que complica a história", .16),
          ("A revelação", "fechar a pergunta do gancho com o que a evidência diz, separando fato e opinião", .1),
          ("O que fazer com isso", "três ações práticas, sem recomendação de produto", .12),
          ("Fechamento", "pergunta para os comentários e convite para o próximo vídeo do canal", .06)],
}
PARTES["L"] = PARTES["M"][:5] + [("Ato 4", "um segundo ângulo ou dado que amplia a história", .12)] + PARTES["M"][5:]
PARTES["D"] = PARTES["L"]
PALAVRAS = {"M": 1650, "L": 2600, "D": 2300}


def _cfg():
    return tomllib.loads((RAIZ / "config.toml").read_text())["fontes"]


def _vault():
    return Path(_cfg()["vault"]).expanduser()


def _artigo(*args, timeout=300):
    import os
    env = {**os.environ, "OPENALEX_API_KEY": _chave_openalex(),
           "ARTIGO_PROGRESSO": str(trace.external_file("artigo"))}
    r = subprocess.run([str(_vault() / ".claude/scripts/artigo"), *map(str, args)], capture_output=True, text=True,
                       timeout=timeout, cwd=_vault(), env=env)
    return r.returncode, r.stdout, r.stderr


def _slug(t):
    s = unicodedata.normalize("NFKD", t.lower())
    return re.sub(r"[^a-z0-9]+", " ", "".join(c for c in s if not unicodedata.combining(c))).strip()


# ---------------------------------------------------------------- 1. plano

def linha_do_plano(canal, n):
    pasta = _vault() / "Notas/Empreendimento/YouTube" / canal / "Temas"
    for arco in sorted(pasta.rglob("*Arco*.md")):
        for linha in arco.read_text().splitlines():
            if re.match(rf"^\|\s*{n}\s*\|", linha):
                c = [x.strip() for x in linha.strip().strip("|").split("|")]
                titulo = re.sub(r"\s*·\s*\[\[.*$", "", c[2]).strip("* ")
                busca = re.search(r"\[([^\]]+)\]\(", c[5])
                return {"n": n, "fio": c[1], "titulo": titulo, "gancho": c[3], "base": c[4],
                        "busca": busca.group(1) if busca else titulo, "evidencia": c[6], "fmt": (c[8] or "M")[:1],
                        "arco": arco.stem}
    raise SystemExit(f"vídeo {n} não está no plano de {canal}")


# ---------------------------------------------------------------- 2. fontes abertas

def _chave_openalex():
    from esteira.project import carregar_env
    return carregar_env().get("OPENALEX_API_KEY", "")


def _openalex(params):
    chave = _chave_openalex()
    try:
        r = requests.get("https://api.openalex.org/works", params={**params, **({"api_key": chave} if chave else {})},
                         headers=UA, timeout=30)
        if r.status_code == 429:
            raise SystemExit("OpenAlex: cota diária sem chave esgotada (volta à meia-noite UTC). "
                             "Ponha OPENALEX_API_KEY no .env da esteira (chave gratuita em openalex.org).")
        return r.json().get("results", [])
    except (requests.RequestException, ValueError):
        return []


def _candidatos_base(base):
    """Artigos-base do plano ("Sobrenome (Ano) — *Revista*"): o trabalho no OpenAlex, se for aberto."""
    saida = []
    for m in re.finditer(r"([A-ZÀ-Ý][\wÀ-ÿ'\-]+)[^()]*\((\d{4})\)\s*—\s*\*([^*]+)\*", base):
        sobrenome, ano, revista = m.groups()
        for w in _openalex({"filter": f"raw_author_name.search:{sobrenome},publication_year:{ano}", "per_page": 10}):
            fonte = (((w.get("primary_location") or {}).get("source") or {}).get("display_name") or "")
            if _slug(revista)[:12] in _slug(fonte):  # o mesmo trabalho do plano; entra só se for aberto
                if (w.get("open_access") or {}).get("is_oa") and w.get("doi"):
                    saida.append(w)
                break
    return saida


def _candidatos_busca(busca, n=12):
    return [w for w in _openalex({"search": busca, "filter": "is_oa:true,type:article|preprint|report",
                                   "per_page": n, "sort": "relevance_score:desc"})
            if w.get("doi") and (w.get("cited_by_count") or 0) >= 5]


def fontes_abertas(linha, maximo=4):
    """PDFs abertos baixados para o vídeo: [{arquivo, titulo, autores, ano, revista, doi}]."""
    vistos, fontes = set(), []
    trace.step("openalex", f"base: {linha['base'][:80]} · busca: {linha['busca'][:80]}")
    for w in _candidatos_base(linha["base"]) + _candidatos_busca(linha["busca"]):
        doi = w["doi"].replace("https://doi.org/", "")
        if doi.lower() in vistos or len(fontes) >= maximo:
            continue
        vistos.add(doi.lower())
        trace.step("pdf", f"{doi} · {w.get('title', '')[:90]}")
        cod, out, _ = _artigo("baixar", doi)
        if cod or not out.startswith("ok"):
            continue
        arq = re.search(r"(Referências/Artigos/\S+\.pdf)", out).group(1)
        ind = json.loads((_vault() / "Referências/Artigos/indice.json").read_text())
        reg = next((v for v in ind.values() if v.get("arquivo") == arq), {})
        fontes.append({"arquivo": arq, "doi": doi, "titulo": reg.get("titulo") or w.get("title", ""),
                       "autores": reg.get("autores", ""), "ano": reg.get("ano") or str(w.get("publication_year", "")),
                       "revista": reg.get("revista", "")})
        print(f"  fonte: {arq.split('/')[-1]}")
    return fontes


def rotulo(f):
    nomes = [x.strip().split()[-1] for x in f["autores"].split(",") if x.strip()]
    autor = nomes[0] + (" et al." if len(nomes) > 2 else f" e {nomes[1]}" if len(nomes) == 2 else "") if nomes else "?"
    return f"{autor} ({f['ano']})"


# ---------------------------------------------------------------- 3. fatos (frases do PDF)

class Achado(BaseModel):
    indice: int
    traducao: str = Field(max_length=300)
    achado: str = Field(max_length=220)


class Achados(BaseModel):
    achados: list[Achado] = Field(max_length=3)


def _frases(pdf, termos, max_paginas=25, n=14):
    doc = pymupdf.open(_vault() / pdf)
    saida = []
    for k in range(min(len(doc), max_paginas)):
        texto = re.sub(r"\s+", " ", re.sub(r"-\n(?=[a-z])", "", doc[k].get_text()))
        for f in re.split(r"(?<=[.!?])\s+(?=[A-Z(])", texto):
            if not 60 <= len(f) <= 380 or not re.search(r"\d", f):
                continue
            nota = 2 * bool(re.search(r"\d+(?:\.\d+)?\s*(%|percent)", f)) + sum(t in f.lower() for t in termos)
            nota += 1 if k < 3 else 0  # resumo e introdução trazem o resultado principal
            if nota >= 2:
                saida.append((nota, k + 1, f.strip()))
    saida.sort(key=lambda x: (-x[0], x[1]))
    return saida[:n]


def fatos(linha, fontes):
    """[{id, fonte, pagina, en, pt, achado}] verificados no PDF pelo `artigo citar`."""
    termos = [t for t in re.findall(r"[a-z]{4,}", linha["busca"].lower())]
    saida = []
    for f in fontes:
        trace.step("trechos", f"{f['arquivo'].split('/')[-1]} · termos: {', '.join(termos[:8])}")
        frases = _frases(f["arquivo"], termos)
        if not frases:
            continue
        lista = "\n".join(f"{i}. (p.{p}) {txt}" for i, (_, p, txt) in enumerate(frases))
        trace.step("fatos", f"{len(frases)} frases com números de {rotulo(f)}")
        r = local.ask(local.prompt("roteiro_trechos", tema=linha["titulo"], gancho=linha["gancho"],
                                         estudo=f"{rotulo(f)}, {f['titulo']}", frases=lista),
                            Achados, max_tokens=900)
        for a in (r.achados if r else []):
            if not 0 <= a.indice < len(frases):
                continue
            _, pag, en = frases[a.indice]
            trace.step("citar", f"p.{pag}: {en[:120]}")
            cod, bloco, _ = _artigo("citar", Path(f["arquivo"]).name, "-p", pag, "-t", en, "-r", a.traducao)
            if cod:
                continue
            bloco = re.sub(r"^> \[!cite\] .*$", f"> [!cite] {rotulo(f)}" + (f" — {f['revista']}" if f["revista"] else ""),
                           bloco.strip(), count=1, flags=re.M)  # cabeçalho pelo índice (autor e ano certos)
            saida.append({"id": len(saida), "fonte": f, "en": en, "pt": a.traducao, "achado": a.achado,
                          "bloco": bloco})
    return saida


# ---------------------------------------------------------------- 4. texto falado

class Fala(BaseModel):
    texto: str = Field(max_length=500)
    fato: int = -1


class Parte(BaseModel):
    cena: str = Field(max_length=220)
    falas: list[Fala] = Field(min_length=1, max_length=14)


def _numeros(t):
    return {re.sub(r"[^\d]", "", x) for x in NUM.findall(t) if re.sub(r"[^\d]", "", x)}


def _fala_ok(fala, fatos_):
    """Todo número da fala (exceto 1–10 e anos) precisa estar no fato citado (achado ou trecho em inglês)."""
    nums = {n for n in _numeros(fala.texto) if not (len(n) <= 1 or re.fullmatch(r"(19|20)\d\d", n))}
    if not nums:
        return True
    if not 0 <= fala.fato < len(fatos_):
        return False
    base = _numeros(fatos_[fala.fato]["achado"]) | _numeros(fatos_[fala.fato]["en"])
    return nums <= base


def escrever(linha, fatos_, canal):
    fmt = linha["fmt"] if linha["fmt"] in PARTES else "M"
    estrutura, total = PARTES[fmt], PALAVRAS.get(fmt, 1650)
    lista = "\n".join(f"{x['id']}. {x['achado']} — {rotulo(x['fonte'])}" for x in fatos_) or "(nenhum)"
    partes, anterior = [], ""
    for i, (nome, funcao, frac) in enumerate(estrutura, 1):
        palavras = max(60, int(total * frac))
        n_falas = max(2, round(palavras / 40) + 1)
        r = None
        for tentativa in (1, 2, 3):
            trace.step("partes", f"parte {i}/{len(estrutura)}: {nome} · ~{palavras} palavras · tentativa {tentativa}")
            trace.progress(i, len(estrutura), nome)
            r = local.ask(local.prompt(
                "roteiro_parte", canal=canal, titulo=linha["titulo"], gancho=linha["gancho"], parte_n=i,
                total=len(estrutura), parte_nome=nome, funcao=funcao, palavras=palavras, n_falas=n_falas,
                anterior=f"Última fala da parte anterior: \"{anterior}\"" if anterior else "", fatos=lista)
                + ("\n(Atenção: na tentativa anterior havia número fora dos FATOS ou o texto ficou curto; "
                   f"escreva {n_falas} falas de 35 a 60 palavras cada.)" if tentativa > 1 else ""),
                Parte, temperature=0.4, max_tokens=2200)
            trace.step("validar", f"parte {i}: números de cada fala contra os fatos; tamanho ≥ 70% de {palavras}")
            if r and all(_fala_ok(f, fatos_) for f in r.falas) and \
                    sum(len(f.texto.split()) for f in r.falas) >= 0.7 * palavras:
                break
        if not r:
            raise SystemExit(f"LLM local não respondeu na parte {i}")
        falas = [f for f in r.falas if _fala_ok(f, fatos_)]  # fala com número sem fonte sai
        partes.append({"nome": nome, "cena": r.cena, "falas": falas})
        anterior = falas[-1].texto if falas else anterior
        print(f"  parte {i}/{len(estrutura)}: {nome} ({sum(len(f.texto.split()) for f in falas)} palavras)")
    return partes


# ---------------------------------------------------------------- 5. markdown

def _arquivo(canal, linha):
    nome = re.sub(r"[?:/\\]", "", re.sub(r"\s*[—–-]\s*", ", ", linha["titulo"])).strip(" ,.")
    return _vault() / "Notas/Empreendimento/YouTube" / canal / "Roteiros" / f"Roteiro — {linha['n']:03d} {nome[:90]}.md"


def montar(canal, linha, fontes, fatos_, partes, canal_nota):
    from datetime import datetime
    hoje = datetime.now().strftime("%Y-%m-%d")
    fmt = linha["fmt"]
    t0, linhas_md, usados, passo = 0.0, [], set(), 0
    for i, p in enumerate(partes, 1):
        mm = int(t0 // 60)
        linhas_md += [f"## Parte {i} — {p['nome']} ({mm}:{int(t0 % 60):02d})", "",
                      "> [!example] Cena", f"> {p['cena']}", ""]
        for f in p["falas"]:
            passo += 1
            linhas_md += [f"**Passo {passo}**", f"\"{f.texto}\""]
            if 0 <= f.fato < len(fatos_) and f.fato not in usados:
                linhas_md += [fatos_[f.fato]["bloco"]]
                usados.add(f.fato)
            linhas_md.append("")
            t0 += len(f.texto.split()) / 2.6
    fontes_md = [f"- [ ] **{rotulo(f)}**: \"{f['titulo']}\", *{f['revista'] or 'acesso aberto'}*. DOI {f['doi']}."
                 for f in fontes]
    palavras = sum(len(f.texto.split()) for p in partes for f in p["falas"])
    md = f"""---
id: "{datetime.now().strftime('%Y%m%d%H%M')}"
tipo: roteiro
tags:
  - empreendimento/youtube/roteiros
canal: "[[{canal_nota}]]"
plano: "[[{linha['arco']}]]"
video: {linha['n']}
fio: {linha['fio']}
formato: {fmt}
evidencia: {linha['evidencia']}
anterior: ""
criado: "{hoje}"
atualizado: {hoje}
status: rascunho-llm
modo: dark
---

# Roteiro — {linha['n']:03d} {linha['titulo']}

> [!info] Vídeo {linha['n']} · Fio {linha['fio']} · Formato {fmt} · Termômetro: **{linha['evidencia']}**
> **Gancho do plano:** {linha['gancho']}
> Gerado por Python + LLM local ({local.TEXT}) com fontes de acesso aberto; ~{palavras} palavras de fala. Revisar o texto antes de gravar.

## Leitura antes de gravar

{chr(10).join(fontes_md) or '- (nenhuma fonte aberta encontrada: completar antes de gravar)'}

> [!warning] Conferir antes de gravar
> - Texto escrito pelo LLM local: revisar fluidez, exemplos e números (cada número veio de um trecho com `[!cite]`).
> - Dados brasileiros atuais (Selic, inflação, leis) não foram incluídos automaticamente.

{chr(10).join(linhas_md)}
## Notas de produção

- Fontes: {', '.join(rotulo(f) for f in fontes)}.
- Gerado por `./dark script` (esteira-dark) em {hoje}.
"""
    return md, palavras


def gerar(alvo, ate=None):
    """`canal:N` (ou `canal:N` + ate=M) → roteiros no vault. Pula os que já existem."""
    canal, _, n = alvo.partition(":")
    pasta = _vault() / "Notas/Empreendimento/YouTube" / canal
    canal_nota = next((p.stem for p in pasta.glob("Canal *.md")), canal)
    for k in range(int(n), int(ate or n) + 1):
        if any((pasta / "Roteiros").glob(f"Roteiro — {k:03d} *.md")):
            print(f"{k:03d}: já existe, pulado")
            continue
        trace.node(f"roteiro:{canal}:{k}", "plano", f"vídeo {k} (lote {n}–{ate or n})")
        linha = linha_do_plano(canal, k)
        print(f"{k:03d} · {linha['titulo']} (Fmt {linha['fmt']})")
        fontes = fontes_abertas(linha)
        fatos_ = fatos(linha, fontes)
        print(f"  {len(fontes)} fontes abertas, {len(fatos_)} fatos conferidos no PDF")
        if len(fatos_) < 2:  # sem prova em PDF aberto não há roteiro: o LLM inventaria
            print(f"  ✗ {k:03d} pulado: menos de 2 fatos de fontes abertas; precisa de pesquisa manual")
            continue
        partes = escrever(linha, fatos_, canal)
        trace.step("montar", f"{len(partes)} partes, {len(fatos_)} blocos [!cite]")
        md, palavras = montar(canal, linha, fontes, fatos_, partes, canal_nota)
        destino = _arquivo(canal, linha)
        destino.write_text(md)
        trace.step("checar", destino.name)
        cod, out, _ = _artigo("checar", destino)
        print(f"  ✓ {destino.name} · {palavras} palavras · {out.strip().splitlines()[-1] if out.strip() else ''}")
