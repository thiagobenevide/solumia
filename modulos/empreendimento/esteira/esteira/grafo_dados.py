"""Dados extras do nó clicado no grafo do Monitor: estatísticas das chamadas (tokens, velocidade, latência,
energia), ficha do modelo no Ollama, modelo de prompt, execuções das etapas (eventos dos episódios), gasto
do Claude e arquivos produzidos. Tudo lido de arquivos locais; leituras pesadas ficam 15 s em memória.
"""
import json
import statistics
import time
import tomllib
import urllib.parse
import urllib.request
from datetime import date, datetime
from pathlib import Path

from esteira.projeto import CACHE, PROJETOS, RAIZ

PROMPTS = RAIZ / "esteira" / "ia" / "prompts"
PROMPTS_DO_NO = {
    "r_fatos": ["roteiro_trechos"], "r_partes": ["roteiro_parte"], "limpar": ["corte", "corte_par"],
    "curar": ["curadoria"], "avaliar": ["avaliar"], "graficos": ["grafico_numero", "grafico_nota", "grafico_citacao", "termos_en"],
    "thumb": ["thumb_conceitos"],
}
MODELOS = {"qwen3": "qwen3-14b", "qwen_vl": "qwen2.5vl-7b"}  # ids no llama.cpp
ANTIGOS = {"qwen3-14b": "qwen3:14b", "qwen2.5vl-7b": "qwen2.5vl:7b"}  # mesmo modelo no tempo do Ollama
ETAPAS = {"transcrever", "limpar", "cenas", "curar", "buscar", "avaliar", "graficos", "montar", "thumb"}
_memo = {}


def _guardado(chave, seg, f):
    v = _memo.get(chave)
    if v and time.time() - v[0] < seg:
        return v[1]
    r = f()
    _memo[chave] = (time.time(), r)
    return r


def _cfg():
    return tomllib.loads((RAIZ / "config.toml").read_text())


def _cauda(arq, n_bytes=400_000):
    with open(arq, "rb") as f:
        f.seek(max(0, arq.stat().st_size - n_bytes))
        linhas = f.read().decode("utf-8", "replace").splitlines()[1:]
    for l in linhas:
        try:
            yield json.loads(l)
        except ValueError:
            pass


def _pct(vals, p):
    vals = sorted(vals)
    return round(vals[min(len(vals) - 1, int(p * len(vals)))], 2) if vals else None


# ---------- chamadas de LLM ----------

def estatisticas(chamadas, hist_monitor=()):
    """Resumo das chamadas do rastro + energia estimada pela potência da GPU durante cada chamada."""
    if not chamadas:
        return None
    ok = [c for c in chamadas if c.get("ok")]
    tin = [c["tokens_entrada"] for c in ok if c.get("tokens_entrada")]
    tout = [c["tokens_saida"] for c in ok if c.get("tokens_saida")]
    tok_s = [c["tok_s"] for c in ok if c.get("tok_s")]
    pre = [c["prefill_tok_s"] for c in ok if c.get("prefill_tok_s")]
    lat = [c.get("total_s") or c.get("seg") for c in ok if c.get("total_s") or c.get("seg")]
    por_prompt = {}
    for c in chamadas:
        d = por_prompt.setdefault(c.get("nome") or "?", {"n": 0, "seg": 0.0, "tokens": 0})
        d["n"] += 1
        d["seg"] += c.get("total_s") or c.get("seg") or 0
        d["tokens"] += c.get("tokens_saida") or 0
    # energia: integra a potência da GPU (amostras de 2 s do monitor) dentro da janela de cada chamada
    wh, tok_e = 0.0, 0
    for c in ok:
        ini, fim = c["t"] - (c.get("total_s") or c.get("seg") or 0), c["t"]
        amostras = [h["gpu_w"] for h in hist_monitor if h.get("gpu_w") and ini - 1 <= h["t"] <= fim + 1]
        if amostras:
            wh += statistics.mean(amostras) * (fim - ini) / 3600
            tok_e += (c.get("tokens_entrada") or 0) + (c.get("tokens_saida") or 0)
    return {
        "n": len(chamadas), "ok_pct": round(100 * len(ok) / len(chamadas)), "tentativas_extra": sum(1 for c in chamadas if (c.get("params") or {}).get("tentativa", 1) > 1),
        "tokens_entrada": sum(tin), "tokens_saida": sum(tout),
        "media_entrada": round(statistics.mean(tin)) if tin else None, "media_saida": round(statistics.mean(tout)) if tout else None,
        "tok_s": round(statistics.median(tok_s), 1) if tok_s else None, "prefill_tok_s": round(statistics.median(pre)) if pre else None,
        "lat_p50": _pct(lat, .5), "lat_p95": _pct(lat, .95), "custo_usd": round(sum(c.get("custo_usd") or 0 for c in chamadas), 4),
        "wh": round(wh, 3) if wh else None, "wh_por_mil_tokens": round(wh / tok_e * 1000, 4) if tok_e else None,
        "por_prompt": sorted(({"nome": k, **v, "seg": round(v["seg"], 1)} for k, v in por_prompt.items()), key=lambda x: -x["n"])[:8],
        "serie": [{"t": c["t"], "tok_s": c.get("tok_s"), "seg": c.get("total_s") or c.get("seg"),
                   "tokens": c.get("tokens_saida"), "ok": c.get("ok")} for c in chamadas[-40:]],
    }


def ficha_modelo(nome):
    """Metadados do GGUF pelo llama-server (`/props`; só com o modelo carregado) e o tamanho em disco."""
    def ler():
        from esteira.ia import llama
        m = next((m for m in llama.modelos() or [] if m["id"] == nome), None)
        if m is None:
            return None
        ficha = {"formato": "gguf", "gb": llama.gb(nome), "visao": llama.visao(m), "estado": m["status"]["value"]}
        if ficha["estado"] == "loaded":
            try:
                req = urllib.request.Request(f"{llama.HOST}/props?model={urllib.parse.quote(nome)}")
                with urllib.request.urlopen(req, timeout=3) as r:
                    p = json.load(r)
                ger = p.get("default_generation_settings") or {}
                ficha |= {"contexto_max": ger.get("n_ctx"), "familia": (p.get("model_alias") or nome),
                          "arquivo": Path(p.get("model_path") or "").name or None}
            except (OSError, ValueError):
                pass
        return ficha
    return _guardado(f"ficha:{nome}", 600, ler)


def historico_eventos_llm(modelo):
    """Chamadas antigas (antes do rastro) gravadas como eventos `llm` nos episódios: ms e tokens gerados."""
    def ler():
        regs = []
        for arq in PROJETOS.glob("*/*/log/eventos.jsonl"):
            for e in _cauda(arq, 800_000):
                if e.get("msg") == "llm" and e.get("modelo") in (modelo, ANTIGOS.get(modelo)):
                    regs.append({"ms": e.get("ms"), "tokens": e.get("tokens"), "etapa": e.get("etapa"), "ep": e.get("ep")})
        if not regs:
            return None
        ms = [r["ms"] for r in regs if r["ms"]]
        tk = [r["tokens"] for r in regs if r["tokens"]]
        por = {}
        for r in regs:
            por[r["etapa"]] = por.get(r["etapa"], 0) + 1
        return {"n": len(regs), "lat_p50": _pct([m / 1000 for m in ms], .5), "lat_p95": _pct([m / 1000 for m in ms], .95),
                "tokens_saida": sum(tk), "tok_s_aprox": round(sum(tk) / (sum(ms) / 1000), 1) if ms and tk else None,
                "por_etapa": sorted(por.items(), key=lambda x: -x[1])}
    return _guardado(f"evllm:{modelo}", 15, ler)


def cache_llm():
    def ler():
        arq = CACHE / "llm.jsonl"
        if not arq.exists():
            return None
        with open(arq, "rb") as f:
            n = sum(1 for _ in f)
        return {"respostas": n, "mb": round(arq.stat().st_size / 2**20, 1)}
    return _guardado("cache_llm", 30, ler)


def prompts(id_no):
    saida = []
    for nome in PROMPTS_DO_NO.get(id_no, []):
        p = PROMPTS / f"{nome}.md"
        if p.exists():
            saida.append({"nome": nome, "texto": p.read_text()[:6000]})
    return saida


# ---------- Claude ----------

def claude():
    def ler():
        arq = CACHE / "claude.jsonl"
        regs = list(_cauda(arq, 2_000_000)) if arq.exists() else []
        hoje, mes = date.today().isoformat(), date.today().isoformat()[:7]
        c = _cfg().get("claude", {})
        por = {}
        for r in regs:
            m = (r.get("motivo") or "?").split(":")[0]
            d = por.setdefault(m, {"n": 0, "custo": 0.0})
            d["n"] += 1
            d["custo"] += r.get("custo") or 0
        return {"hoje": round(sum(r["custo"] for r in regs if r["t"].startswith(hoje)), 4),
                "mes": round(sum(r["custo"] for r in regs if r["t"].startswith(mes)), 4),
                "chamadas": len(regs), "chamadas_hoje": sum(1 for r in regs if r["t"].startswith(hoje)),
                "teto_dia": c.get("teto_dia_usd"), "teto_episodio": c.get("teto_episodio_usd"), "teto_chamada": c.get("teto_chamada_usd"),
                "modelo": c.get("modelo"), "ativo": c.get("ativo", True),
                "por_motivo": sorted(({"motivo": k, "n": v["n"], "custo": round(v["custo"], 4)} for k, v in por.items()), key=lambda x: -x["custo"])[:8],
                "ultimas": [{"t": r["t"], "ep": r.get("ep"), "motivo": r.get("motivo"), "custo": r.get("custo"), "ok": r.get("resposta") is not None} for r in regs[-8:][::-1]]}
    return _guardado("claude", 15, ler)


# ---------- etapas dos episódios ----------

def execucoes(etapa):
    """Últimas execuções da etapa em todos os episódios + mensagens, avisos e chamadas registradas nelas."""
    def ler():
        runs, msgs, n_llm, n_claude = [], [], 0, 0
        for arq in PROJETOS.glob("*/*/log/eventos.jsonl"):
            atual = None
            for e in _cauda(arq, 800_000):
                if e.get("etapa") != etapa:
                    continue
                tipo = e.get("tipo")
                if tipo == "inicio":
                    atual = {"ep": e["ep"], "inicio": e["t"], "status": "rodando", "avisos": 0, "dur": None, "ultima": ""}
                    runs.append(atual)
                elif atual is None:
                    continue
                elif tipo in ("fim", "erro"):
                    atual.update(status="ok" if tipo == "fim" else "erro", dur=e.get("dur"), ultima=e.get("msg") or atual["ultima"])
                elif tipo == "aviso":
                    atual["avisos"] += 1
                    msgs.append({"t": e["t"], "ep": e["ep"], "tipo": "aviso", "msg": e.get("msg")})
                elif tipo == "saida":
                    atual["ultima"] = e.get("msg")
                    msgs.append({"t": e["t"], "ep": e["ep"], "tipo": "saida", "msg": e.get("msg")})
                elif tipo == "claude":
                    n_claude += 1
                    msgs.append({"t": e["t"], "ep": e["ep"], "tipo": "claude", "msg": f"{e.get('msg')} · US$ {e.get('custo', 0):.4f}"})
                elif tipo == "debug" and e.get("msg") == "llm":
                    n_llm += 1
        runs.sort(key=lambda r: r["inicio"])
        durs = [r["dur"] for r in runs if r["status"] == "ok" and r["dur"]]
        return {"execucoes": runs[-10:][::-1], "n": len(runs), "ok": sum(r["status"] == "ok" for r in runs),
                "erros": sum(r["status"] == "erro" for r in runs), "dur_media": round(statistics.mean(durs)) if durs else None,
                "chamadas_llm": n_llm, "chamadas_claude": n_claude,
                "mensagens": sorted(msgs, key=lambda m: m["t"])[-12:][::-1]}
    return _guardado(f"exec:{etapa}", 15, ler)


# ---------- arquivos produzidos ----------

def _vault():
    return Path(_cfg().get("fontes", {}).get("vault", "~/Documents/github/obsidian")).expanduser()


def _quando(ts):
    return datetime.fromtimestamp(ts).strftime("%d/%m %H:%M")


def arquivos(id_no):
    v = _vault()
    if id_no in ("r_pdf", "openalex", "r_trechos", "r_citar"):
        def pdfs():
            ind = v / "Referências/Artigos/indice.json"
            d = json.loads(ind.read_text()) if ind.exists() else {}
            itens = []
            for r in d.values():
                p = v / r.get("arquivo", "")
                if p.exists():
                    itens.append((p.stat().st_mtime, r))
            itens.sort(key=lambda x: -x[0])
            return {"titulo": f"PDFs no índice ({len(d)} no total)", "itens": [
                {"quando": _quando(m), "nome": f"{r.get('autores', '?').split(',')[0]} ({r.get('ano', '?')}) · {r.get('titulo', '')[:90]}",
                 "extra": f"{r.get('paginas', '?')} p. · {r.get('revista', '')[:40]}"} for m, r in itens[:10]]}
        return _guardado("arq:pdfs", 15, pdfs)
    if id_no in ("r_montar", "r_checar", "r_partes", "r_validar", "r_plano"):
        def roteiros():
            fs = sorted(v.glob("Notas/Empreendimento/YouTube/*/Roteiros/Roteiro — *.md"), key=lambda p: -p.stat().st_mtime)[:10]
            itens = []
            for f in fs:
                txt = f.read_text()
                status = next((l.split(":", 1)[1].strip() for l in txt.splitlines()[:20] if l.startswith("status:")), "?")
                itens.append({"quando": _quando(f.stat().st_mtime), "nome": f.stem.replace("Roteiro — ", ""),
                              "extra": f"{status} · {txt.count('[!cite]')} citações · {len(txt.split())} palavras · {f.parent.parent.name}"})
            return {"titulo": "Roteiros mais recentes no vault", "itens": itens}
        return _guardado("arq:roteiros", 15, roteiros)
    if id_no in ("graficos", "chromium"):
        fs = sorted(PROJETOS.glob("*/*/graficos/*.mov"), key=lambda p: -p.stat().st_mtime)[:10]
        return {"titulo": "Gráficos renderizados", "itens": [{"quando": _quando(f.stat().st_mtime), "nome": f.name,
                "extra": f"{f.parent.parent.parent.name}-{f.parent.parent.name} · {f.stat().st_size / 2**20:.0f} MB"} for f in fs]}
    if id_no in ("thumb", "sdxl"):
        fs = sorted(PROJETOS.glob("*/*/thumbs/*.png"), key=lambda p: -p.stat().st_mtime)[:10]
        return {"titulo": "Thumbs e fundos gerados", "itens": [{"quando": _quando(f.stat().st_mtime), "nome": f.name,
                "extra": f"{f.parent.parent.parent.name}-{f.parent.parent.name}"} for f in fs]}
    if id_no in ("buscar", "bancos", "avaliar", "qwen_vl"):
        try:
            from esteira import acervo
            e = acervo.estatisticas()
            return {"titulo": "Acervo de mídia", "itens": [{"quando": "", "nome": f"{e['itens']} itens · {e['videos']} vídeos · {e['imagens']} imagens",
                    "extra": f"{e['descritos']} descritos pelo modelo de visão · {e['usos']} usos · {e['gb']:.2f} GB"}]}
        except Exception:
            return None
    if id_no in ("montar", "filmcraft"):
        fs = sorted(PROJETOS.glob("*/*/final.mp4"), key=lambda p: -p.stat().st_mtime)[:10]
        return {"titulo": "Vídeos exportados", "itens": [{"quando": _quando(f.stat().st_mtime), "nome": f"{f.parent.parent.name}-{f.parent.name}",
                "extra": f"{f.stat().st_size / 2**20:.0f} MB"} for f in fs]}
    if id_no in ("transcrever", "whisper"):
        fs = sorted(PROJETOS.glob("*/*/transcricao.json"), key=lambda p: -p.stat().st_mtime)[:10]
        return {"titulo": "Transcrições", "itens": [{"quando": _quando(f.stat().st_mtime), "nome": f"{f.parent.parent.name}-{f.parent.name}",
                "extra": f"{f.stat().st_size / 1024:.0f} KB"} for f in fs]}
    return None


def openalex():
    env = RAIZ / ".env"
    tem = env.exists() and any(l.startswith("OPENALEX_API_KEY=") and l.strip() != "OPENALEX_API_KEY=" for l in env.read_text().splitlines())
    return {"chave": tem}


def extras(id_no, chamadas, hist_monitor):
    """Tudo o que a gaveta mostra além do básico, conforme o tipo do nó."""
    e = {"estat": estatisticas(chamadas, hist_monitor), "prompts": prompts(id_no), "arquivos": arquivos(id_no)}
    if id_no in MODELOS:
        e["ficha"] = ficha_modelo(MODELOS[id_no])
        e["antigo"] = historico_eventos_llm(MODELOS[id_no])
        e["cache"] = cache_llm()
    if id_no == "claude" or id_no == "editor":
        e["claude"] = claude()
    if id_no in ETAPAS:
        e["execucoes"] = execucoes(id_no)
    if id_no in ("openalex", "r_openalex"):
        e["openalex"] = openalex()
    return e
