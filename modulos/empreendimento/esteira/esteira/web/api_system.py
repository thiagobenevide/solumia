"""API do que não é de um episódio: monitor da máquina e grafo da operação, processos, opções de IA (e
download de modelos do Ollama), custos do Claude e acervo de mídia. Para o app Flutter.
"""
import json
import re
import threading
from datetime import datetime

from esteira.web import app as painel
from esteira.web import queue
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

router = APIRouter(prefix="/api/v1", tags=["sistema"])


def _body(answer):
    """Dados de uma rota JSON do painel (`/api/grafo`, `/api/processos/…`), sem repetir a lógica dela."""
    return json.loads(answer.body)


# ---------- Monitor e grafo da operação ----------

@router.get("/monitor")
def monitor():
    from esteira import monitor as m
    e = m.state(painel._cfg().get("monitor", {}).get("tarifa_kwh", 0.85))
    current = e.get("atual") or {}
    return {"gpu": current.get("gpu"), "cpu": current.get("cpu"), "ram": current.get("ram"), "ollama": current.get("ollama"),
            "esteira": current.get("esteira") or [], "grupos": current.get("grupos") or [],
            "arquivos": e.get("arquivos") or [], "energia": e.get("energia"), "hist": e.get("hist") or [],
            "erro": e.get("erro"), "fila": [t for t in queue.list_all() if t["estado"] in ("rodando", "na fila")]}


@router.get("/grafo")
def graph():
    return _body(painel.api_graph())


@router.get("/grafo/no/{id_no}")
def graph_node(id_no: str):
    return _body(painel.api_graph_node(id_no))


# ---------- Processos ----------

@router.get("/processos")
def processes(limite: int = 300):
    from esteira.core import locks, processes
    return {"processos": processes.list_recent(limite), "vagas": {v: locks.owner(v) for v in locks.SLOTS}}


@router.get("/processos/{pid_id}")
def process(pid_id: str):
    return _body(painel.api_process(pid_id))


@router.post("/processos/{pid_id}/parar")
def stop(pid_id: str):
    """Para o processo (e o que ele abriu), venha da fila ou do terminal."""
    from esteira.core import processes
    if not processes.get(pid_id):
        raise HTTPException(404, "processo não encontrado")
    painel.stop_process(pid_id)
    return {"ok": True}


# ---------- Opções de IA ----------

@router.get("/opcoes")
def read_options():
    from esteira.core import options
    from esteira.ai import local
    return {"opcoes": options.read(), "claude": options.claude(painel._cfg().get("claude", {})),
            "operacoes": [{"id": k, "nome": name, "descricao": desc, "tipos": kinds, "atual": options.operation(k)}
                          for k, (name, desc, kinds) in options.OPERATIONS.items()],
            "modelos_claude": [{"id": i, "nome": n, "descricao": d} for i, n, d in options.MODELS],
            "sugestoes": [{"nome": n, "tipo": t, "descricao": d} for n, t, d in options.SUGGESTIONS],
            "locais": painel._local_models(), "padrao": {"text": local.TEXT, "vision": local.VISION}}


class Operation(BaseModel):
    engine: str = "default"
    text: str | None = None
    vision: str | None = None


class Options(BaseModel):
    engine: str = "local"
    claude_model: str | None = None
    episode_cap_usd: float | None = None
    daily_cap_usd: float | None = None
    operations: dict[str, Operation] = {}
    claude_fallback: bool = False


@router.post("/opcoes")
def save_options(corpo: Options):
    from esteira.core import options
    if corpo.engine not in ("local", "claude"):
        raise HTTPException(400, "engine must be local or claude")
    ops = {}
    for k, (_, _, kinds) in options.OPERATIONS.items():
        chosen = corpo.operations.get(k) or Operation()
        entry = {"engine": "default"}
        if chosen.engine in ("default", "local", "claude"):
            entry["engine"] = chosen.engine
        for kind in kinds:
            entry[kind] = getattr(chosen, kind) or None
        ops[k] = entry
    options.save(engine=corpo.engine, claude_model=corpo.claude_model or None, episode_cap_usd=corpo.episode_cap_usd,
                 daily_cap_usd=corpo.daily_cap_usd, operations=ops, claude_fallback=corpo.claude_fallback)
    return read_options()


class Download(BaseModel):
    nome: str


@router.post("/opcoes/baixar")
def download(corpo: Download):
    """Baixa um modelo (`usuario/repo:QUANT` do Hugging Face) para o llama.cpp em segundo plano; o andamento
    sai em `/opcoes/baixando`."""
    name = corpo.nome.strip()
    if not re.fullmatch(r"[\w.\-/]+(:[\w.\-]+)?", name):
        raise HTTPException(400, "nome de modelo inválido (ex.: unsloth/Qwen3-8B-GGUF:Q4_K_M)")
    if painel._downloading.get(name, {}).get("estado") != "baixando":
        painel._downloading[name] = {"estado": "baixando", "feito": 0, "total": 0, "msg": "começando"}
        threading.Thread(target=painel._download, args=(name,), daemon=True).start()
    return painel._downloading[name]


@router.get("/opcoes/baixando")
def downloading():
    return painel._downloading


# ---------- Custos do Claude ----------

@router.get("/custos")
def costs():
    from esteira.ai import claude
    regs = list(reversed(claude._records()))
    by_ep = {}
    for r in regs:
        by_ep[r["ep"]] = by_ep.get(r["ep"], 0) + (r.get("cost") or 0)
    today = datetime.now().date().isoformat()
    cfg = painel._cfg().get("claude", {})
    return {"registros": regs[:200], "n_registros": len(regs), "total": sum(by_ep.values()),
            "hoje": sum((r.get("cost") or 0) for r in regs if r["t"].startswith(today)),
            "por_episodio": [{"ep": ep, "custo": v} for ep, v in sorted(by_ep.items(), key=lambda x: -x[1])],
            "teto_dia_usd": cfg.get("teto_dia_usd", 3), "teto_episodio_usd": cfg.get("teto_episodio_usd", 1),
            "modelo": cfg.get("modelo", "")}


# ---------- Acervo de mídia ----------

@router.get("/acervo")
def library(q: str = "", tipo: str = "", limite: int = 180):
    from esteira import library as A
    items = [dict(it, mini=f"/acervo/mini/{it['id']}") for it in A.list_all(q, tipo, limite=min(limite, 500))]
    return {"itens": items, "estatisticas": A.call_statistics()}


# ---------- Backup e dataset das Craft Apps (docs/PLANO-DATASET.md) ----------

@router.get("/backup")
def backup():
    """Estado do backup no Google Drive (`infra/scripts/backup` grava `plataforma/backup.json`)."""
    from esteira.project import DATA
    file = DATA.parent / "plataforma" / "backup.json"
    if not file.exists():
        return {"configurado": False, "modulos": [], "ultimo": None, "teste": None}
    d = json.loads(file.read_text())
    mods = d.get("modulos") or {}
    now = datetime.now()

    def horas(t):
        return round((now - datetime.fromisoformat(t)).total_seconds() / 3600, 1) if t else None
    lines = [{"modulo": m, "estado": r.get("estado"), "erro": r.get("erro"), "ultimo_ok": r.get("ultimo_ok"),
               "horas": horas(r.get("ultimo_ok"))} for m, r in sorted(mods.items()) if not m.startswith("teste:")]
    teste = next(({"modulo": m[6:], **r} for m, r in sorted(mods.items(), key=lambda x: x[1].get("fim") or "",
                                                           reverse=True) if m.startswith("teste:")), None)
    return {"configurado": True, "ultimo": d.get("ultimo"), "modulos": lines, "teste": teste,
            "atrasado": any((x["horas"] or 999) > 36 for x in lines), "erros": sum(x["estado"] == "erro" for x in lines)}


@router.get("/dataset")
def dataset():
    """Por tarefa: registros, exemplos de treino × mínimo; adaptadores (promovido ou não) e a última bancada N1."""
    from esteira import bench
    from esteira.dataset import index, app_training
    situ = index.status()
    tasks = [{"tarefa": t, "app": app_training.R.TAREFAS[t], **x} for t, x in situ.items() if t != "peca_html"]
    adaptadores = []
    folder = app_training._folder()
    for m in sorted(folder.glob("*.json")) if folder.exists() else []:
        try:
            adaptadores.append(json.loads(m.read_text()))
        except ValueError:
            continue
    notes = {}
    for model, info in ((bench.last() or {}).get("modelos") or {}).items():
        for t, x in (info.get("tarefas") or {}).items():
            if t.startswith("n1_"):
                notes.setdefault(t[3:], {})[model] = {"nota": x.get("nota"), "json_ok": x.get("json_ok")}
    return {"tarefas": tasks, "adaptadores": adaptadores, "bancada": notes,
            "promovidos": {app: app_training.promoted(app) for app in app_training.TASKS_APP}}


class Verdict(BaseModel):
    veredito: str
    comentario: str = ""


@router.post("/dataset/montagem/{ep}")
def verdict_assembly(ep: str, v: Verdict):
    """A pessoa aprova (ou não) a montagem gerada de um episódio: veredito no registro `montar` mais recente."""
    from esteira.dataset import registry as R
    if v.veredito not in ("aprovada", "reprovada", "ajuste"):
        raise HTTPException(422, "veredito: aprovada | reprovada | ajuste")
    r = R.last(f"ep:{ep}", "montar")
    if not r:
        raise HTTPException(404, f"sem montagem registrada para {ep}")
    R.evaluate(r["id"], v.veredito, comentario=v.comentario or None,
              motivo=v.comentario or None if v.veredito == "reprovada" else None)
    return {"ok": True, "registro": r["id"]}
