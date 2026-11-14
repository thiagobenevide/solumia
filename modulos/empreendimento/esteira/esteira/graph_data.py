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

from esteira.project import CACHE, PROJECTS, ROOT

PROMPTS = ROOT / "esteira" / "ai" / "prompts"
PROMPTS_DO_NODE = {
    "r_fatos": ["script_excerpts"], "r_partes": ["script_part"], "clean": ["cut", "cut_pair"],
    "curate": ["curation"], "evaluate": ["evaluate"], "graphics": ["graphic_number", "graphic_note", "graphic_quote", "terms_en"],
    "thumb": ["thumb_concepts"],
}
MODELS = {"qwen3": "qwen3-14b", "qwen_vl": "qwen2.5vl-7b"}  # ids no llama.cpp
OLD = {"qwen3-14b": "qwen3:14b", "qwen2.5vl-7b": "qwen2.5vl:7b"}  # mesmo modelo no tempo do Ollama
STAGES = {"transcribe", "clean", "scenes", "curate", "fetch", "evaluate", "graphics", "assemble", "thumb"}
_memo = {}


def _stored(key, seg, f):
    v = _memo.get(key)
    if v and time.time() - v[0] < seg:
        return v[1]
    r = f()
    _memo[key] = (time.time(), r)
    return r


def _cfg():
    return tomllib.loads((ROOT / "config.toml").read_text())


def _tail(file, n_bytes=400_000):
    with open(file, "rb") as f:
        f.seek(max(0, file.stat().st_size - n_bytes))
        lines = f.read().decode("utf-8", "replace").splitlines()[1:]
    for l in lines:
        try:
            yield json.loads(l)
        except ValueError:
            pass


def _pct(vals, p):
    vals = sorted(vals)
    return round(vals[min(len(vals) - 1, int(p * len(vals)))], 2) if vals else None


# ---------- chamadas de LLM ----------

def call_statistics(calls, hist_monitor=()):
    """Resumo das chamadas do rastro + energia estimada pela potência da GPU durante cada chamada."""
    if not calls:
        return None
    ok = [c for c in calls if c.get("ok")]
    tin = [c["input_tokens"] for c in ok if c.get("input_tokens")]
    tout = [c["output_tokens"] for c in ok if c.get("output_tokens")]
    tok_s = [c["tok_s"] for c in ok if c.get("tok_s")]
    pre = [c["prefill_tok_s"] for c in ok if c.get("prefill_tok_s")]
    lat = [c.get("total_s") or c.get("seconds") for c in ok if c.get("total_s") or c.get("seconds")]
    by_prompt = {}
    for c in calls:
        d = by_prompt.setdefault(c.get("name") or "?", {"n": 0, "seg": 0.0, "tokens": 0})
        d["n"] += 1
        d["seg"] += c.get("total_s") or c.get("seconds") or 0
        d["tokens"] += c.get("output_tokens") or 0
    # energia: integra a potência da GPU (amostras de 2 s do monitor) dentro da janela de cada chamada
    wh, tok_and = 0.0, 0
    for c in ok:
        start, end = c["t"] - (c.get("total_s") or c.get("seconds") or 0), c["t"]
        samples = [h["gpu_w"] for h in hist_monitor if h.get("gpu_w") and start - 1 <= h["t"] <= end + 1]
        if samples:
            wh += statistics.mean(samples) * (end - start) / 3600
            tok_and += (c.get("input_tokens") or 0) + (c.get("output_tokens") or 0)
    return {
        "n": len(calls), "ok_pct": round(100 * len(ok) / len(calls)), "tentativas_extra": sum(1 for c in calls if (c.get("params") or {}).get("attempt", 1) > 1),
        "tokens_entrada": sum(tin), "tokens_saida": sum(tout),
        "media_entrada": round(statistics.mean(tin)) if tin else None, "media_saida": round(statistics.mean(tout)) if tout else None,
        "tok_s": round(statistics.median(tok_s), 1) if tok_s else None, "prefill_tok_s": round(statistics.median(pre)) if pre else None,
        "lat_p50": _pct(lat, .5), "lat_p95": _pct(lat, .95), "custo_usd": round(sum(c.get("cost_usd") or 0 for c in calls), 4),
        "wh": round(wh, 3) if wh else None, "wh_por_mil_tokens": round(wh / tok_and * 1000, 4) if tok_and else None,
        "por_prompt": sorted(({"nome": k, **v, "seg": round(v["seg"], 1)} for k, v in by_prompt.items()), key=lambda x: -x["n"])[:8],
        "serie": [{"t": c["t"], "tok_s": c.get("tok_s"), "seg": c.get("total_s") or c.get("seconds"),
                   "tokens": c.get("output_tokens"), "ok": c.get("ok")} for c in calls[-40:]],
    }


def card_model(name):
    """Metadados do GGUF pelo llama-server (`/props`; só com o modelo carregado) e o tamanho em disco."""
    def read_part():
        from esteira.ai import llama
        m = next((m for m in llama.models() or [] if m["id"] == name), None)
        if m is None:
            return None
        card = {"formato": "gguf", "gb": llama.gb(name), "visao": llama.vision(m), "estado": m["status"]["value"]}
        if card["estado"] == "loaded":
            try:
                req = urllib.request.Request(f"{llama.HOST}/props?model={urllib.parse.quote(name)}")
                with urllib.request.urlopen(req, timeout=3) as r:
                    p = json.load(r)
                ger = p.get("default_generation_settings") or {}
                card |= {"contexto_max": ger.get("n_ctx"), "familia": (p.get("model_alias") or name),
                          "arquivo": Path(p.get("model_path") or "").name or None}
            except (OSError, ValueError):
                pass
        return card
    return _stored(f"ficha:{name}", 600, read_part)


def history_events_llm(model):
    """Chamadas antigas (antes do rastro) gravadas como eventos `llm` nos episódios: ms e tokens gerados."""
    def read_part():
        regs = []
        for file in PROJECTS.glob("*/*/log/events.jsonl"):
            for e in _tail(file, 800_000):
                if e.get("message") == "llm" and e.get("modelo") in (model, OLD.get(model)):
                    regs.append({"ms": e.get("ms"), "tokens": e.get("tokens"), "etapa": e.get("stage"), "ep": e.get("ep")})
        if not regs:
            return None
        ms = [r["ms"] for r in regs if r["ms"]]
        tk = [r["tokens"] for r in regs if r["tokens"]]
        by_choice = {}
        for r in regs:
            by_choice[r["etapa"]] = by_choice.get(r["etapa"], 0) + 1
        return {"n": len(regs), "lat_p50": _pct([m / 1000 for m in ms], .5), "lat_p95": _pct([m / 1000 for m in ms], .95),
                "tokens_saida": sum(tk), "tok_s_aprox": round(sum(tk) / (sum(ms) / 1000), 1) if ms and tk else None,
                "por_etapa": sorted(by_choice.items(), key=lambda x: -x[1])}
    return _stored(f"evllm:{model}", 15, read_part)


def cache_llm():
    def read_part():
        file = CACHE / "llm.jsonl"
        if not file.exists():
            return None
        with open(file, "rb") as f:
            n = sum(1 for _ in f)
        return {"respostas": n, "mb": round(file.stat().st_size / 2**20, 1)}
    return _stored("cache_llm", 30, read_part)


def prompts(id_node):
    output = []
    for name in PROMPTS_DO_NODE.get(id_node, []):
        p = PROMPTS / f"{name}.md"
        if p.exists():
            output.append({"nome": name, "texto": p.read_text()[:6000]})
    return output


# ---------- Claude ----------

def claude():
    def read_part():
        file = CACHE / "claude.jsonl"
        regs = list(_tail(file, 2_000_000)) if file.exists() else []
        today, month = date.today().isoformat(), date.today().isoformat()[:7]
        c = _cfg().get("claude", {})
        by_choice = {}
        for r in regs:
            m = (r.get("motivo") or "?").split(":")[0]
            d = by_choice.setdefault(m, {"n": 0, "custo": 0.0})
            d["n"] += 1
            d["custo"] += r.get("custo") or 0
        return {"hoje": round(sum(r["custo"] for r in regs if r["t"].startswith(today)), 4),
                "mes": round(sum(r["custo"] for r in regs if r["t"].startswith(month)), 4),
                "chamadas": len(regs), "chamadas_hoje": sum(1 for r in regs if r["t"].startswith(today)),
                "teto_dia": c.get("teto_dia_usd"), "teto_episodio": c.get("teto_episodio_usd"), "teto_chamada": c.get("teto_chamada_usd"),
                "modelo": c.get("modelo"), "ativo": c.get("ativo", True),
                "por_motivo": sorted(({"motivo": k, "n": v["n"], "custo": round(v["custo"], 4)} for k, v in by_choice.items()), key=lambda x: -x["custo"])[:8],
                "ultimas": [{"t": r["t"], "ep": r.get("ep"), "motivo": r.get("motivo"), "custo": r.get("custo"), "ok": r.get("resposta") is not None} for r in regs[-8:][::-1]]}
    return _stored("claude", 15, read_part)


# ---------- etapas dos episódios ----------

def executions(stage):
    """Últimas execuções da etapa em todos os episódios + mensagens, avisos e chamadas registradas nelas."""
    def read_part():
        runs, msgs, n_llm, n_claude = [], [], 0, 0
        for file in PROJECTS.glob("*/*/log/events.jsonl"):
            current = None
            for e in _tail(file, 800_000):
                if e.get("stage") != stage:
                    continue
                kind = e.get("kind")
                if kind == "start":
                    current = {"ep": e["ep"], "inicio": e["t"], "status": "rodando", "avisos": 0, "dur": None, "ultima": ""}
                    runs.append(current)
                elif current is None:
                    continue
                elif kind in ("end", "error"):
                    current.update(status="ok" if kind == "end" else "erro", dur=e.get("duration"), ultima=e.get("message") or current["ultima"])
                elif kind == "warning":
                    current["avisos"] += 1
                    msgs.append({"t": e["t"], "ep": e["ep"], "tipo": "aviso", "msg": e.get("message")})
                elif kind == "output":
                    current["ultima"] = e.get("message")
                    msgs.append({"t": e["t"], "ep": e["ep"], "tipo": "saida", "msg": e.get("message")})
                elif kind == "claude":
                    n_claude += 1
                    msgs.append({"t": e["t"], "ep": e["ep"], "tipo": "claude", "msg": f"{e.get('message')} · US$ {e.get('cost', 0):.4f}"})
                elif kind == "debug" and e.get("message") == "llm":
                    n_llm += 1
        runs.sort(key=lambda r: r["inicio"])
        durs = [r["dur"] for r in runs if r["status"] == "ok" and r["dur"]]
        return {"execucoes": runs[-10:][::-1], "n": len(runs), "ok": sum(r["status"] == "ok" for r in runs),
                "erros": sum(r["status"] == "erro" for r in runs), "dur_media": round(statistics.mean(durs)) if durs else None,
                "chamadas_llm": n_llm, "chamadas_claude": n_claude,
                "mensagens": sorted(msgs, key=lambda m: m["t"])[-12:][::-1]}
    return _stored(f"exec:{stage}", 15, read_part)


# ---------- arquivos produzidos ----------

def _vault():
    return Path(_cfg().get("fontes", {}).get("vault", "~/Documents/github/obsidian")).expanduser()


def _when(ts):
    return datetime.fromtimestamp(ts).strftime("%d/%m %H:%M")


def files(id_node):
    v = _vault()
    if id_node in ("r_pdf", "openalex", "r_trechos", "r_citar"):
        def pdfs():
            ind = v / "Referências/Artigos/indice.json"
            d = json.loads(ind.read_text()) if ind.exists() else {}
            items = []
            for r in d.values():
                p = v / r.get("arquivo", "")
                if p.exists():
                    items.append((p.stat().st_mtime, r))
            items.sort(key=lambda x: -x[0])
            return {"titulo": f"PDFs no índice ({len(d)} no total)", "itens": [
                {"quando": _when(m), "nome": f"{r.get('autores', '?').split(',')[0]} ({r.get('ano', '?')}) · {r.get('titulo', '')[:90]}",
                 "extra": f"{r.get('paginas', '?')} p. · {r.get('revista', '')[:40]}"} for m, r in items[:10]]}
        return _stored("arq:pdfs", 15, pdfs)
    if id_node in ("r_montar", "r_checar", "r_partes", "r_validar", "r_plano"):
        def scripts_node():
            fs = sorted(v.glob("Notas/Empreendimento/YouTube/*/Roteiros/Roteiro — *.md"), key=lambda p: -p.stat().st_mtime)[:10]
            items = []
            for f in fs:
                txt = f.read_text()
                status = next((l.split(":", 1)[1].strip() for l in txt.splitlines()[:20] if l.startswith("status:")), "?")
                items.append({"quando": _when(f.stat().st_mtime), "nome": f.stem.replace("Roteiro — ", ""),
                              "extra": f"{status} · {txt.count('[!cite]')} citações · {len(txt.split())} palavras · {f.parent.parent.name}"})
            return {"titulo": "Roteiros mais recentes no vault", "itens": items}
        return _stored("arq:roteiros", 15, scripts_node)
    if id_node in ("graficos", "chromium"):
        fs = sorted(PROJECTS.glob("*/*/graficos/*.mov"), key=lambda p: -p.stat().st_mtime)[:10]
        return {"titulo": "Gráficos renderizados", "itens": [{"quando": _when(f.stat().st_mtime), "nome": f.name,
                "extra": f"{f.parent.parent.parent.name}-{f.parent.parent.name} · {f.stat().st_size / 2**20:.0f} MB"} for f in fs]}
    if id_node in ("thumb", "sdxl"):
        fs = sorted(PROJECTS.glob("*/*/thumbs/*.png"), key=lambda p: -p.stat().st_mtime)[:10]
        return {"titulo": "Thumbs e fundos gerados", "itens": [{"quando": _when(f.stat().st_mtime), "nome": f.name,
                "extra": f"{f.parent.parent.parent.name}-{f.parent.parent.name}"} for f in fs]}
    if id_node in ("buscar", "bancos", "avaliar", "qwen_vl"):
        try:
            from esteira import library
            e = library.call_statistics()
            return {"titulo": "Acervo de mídia", "itens": [{"quando": "", "nome": f"{e['itens']} itens · {e['videos']} vídeos · {e['imagens']} imagens",
                    "extra": f"{e['descritos']} descritos pelo modelo de visão · {e['usos']} usos · {e['gb']:.2f} GB"}]}
        except Exception:
            return None
    if id_node in ("montar", "filmcraft"):
        fs = sorted(PROJECTS.glob("*/*/final.mp4"), key=lambda p: -p.stat().st_mtime)[:10]
        return {"titulo": "Vídeos exportados", "itens": [{"quando": _when(f.stat().st_mtime), "nome": f"{f.parent.parent.name}-{f.parent.name}",
                "extra": f"{f.stat().st_size / 2**20:.0f} MB"} for f in fs]}
    if id_node in ("transcrever", "whisper"):
        fs = sorted(PROJECTS.glob("*/*/transcricao.json"), key=lambda p: -p.stat().st_mtime)[:10]
        return {"titulo": "Transcrições", "itens": [{"quando": _when(f.stat().st_mtime), "nome": f"{f.parent.parent.name}-{f.parent.name}",
                "extra": f"{f.stat().st_size / 1024:.0f} KB"} for f in fs]}
    return None


def openalex():
    env = ROOT / ".env"
    has = env.exists() and any(l.startswith("OPENALEX_API_KEY=") and l.strip() != "OPENALEX_API_KEY=" for l in env.read_text().splitlines())
    return {"chave": has}


def extras(id_node, calls, hist_monitor):
    """Tudo o que a gaveta mostra além do básico, conforme o tipo do nó."""
    e = {"estat": call_statistics(calls, hist_monitor), "prompts": prompts(id_node), "arquivos": files(id_node)}
    if id_node in MODELS:
        e["ficha"] = card_model(MODELS[id_node])
        e["antigo"] = history_events_llm(MODELS[id_node])
        e["cache"] = cache_llm()
    if id_node == "claude" or id_node == "editor":
        e["claude"] = claude()
    if id_node in STAGES:
        e["execucoes"] = executions(id_node)
    if id_node in ("openalex", "r_openalex"):
        e["openalex"] = openalex()
    return e
