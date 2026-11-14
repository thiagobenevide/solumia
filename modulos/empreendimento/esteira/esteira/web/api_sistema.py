"""API do que não é de um episódio: monitor da máquina e grafo da operação, processos, opções de IA (e
download de modelos do Ollama), custos do Claude e acervo de mídia. Para o app Flutter.
"""
import json
import re
import threading
from datetime import datetime

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from esteira.web import app as painel
from esteira.web import fila

router = APIRouter(prefix="/api/v1", tags=["sistema"])


def _corpo(resposta):
    """Dados de uma rota JSON do painel (`/api/grafo`, `/api/processos/…`), sem repetir a lógica dela."""
    return json.loads(resposta.body)


# ---------- Monitor e grafo da operação ----------

@router.get("/monitor")
def monitor():
    from esteira import monitor as m
    e = m.estado(painel._cfg().get("monitor", {}).get("tarifa_kwh", 0.85))
    atual = e.get("atual") or {}
    return {"gpu": atual.get("gpu"), "cpu": atual.get("cpu"), "ram": atual.get("ram"), "ollama": atual.get("ollama"),
            "esteira": atual.get("esteira") or [], "grupos": atual.get("grupos") or [],
            "arquivos": e.get("arquivos") or [], "energia": e.get("energia"), "hist": e.get("hist") or [],
            "erro": e.get("erro"), "fila": [t for t in fila.listar() if t["estado"] in ("rodando", "na fila")]}


@router.get("/grafo")
def grafo():
    return _corpo(painel.api_grafo())


@router.get("/grafo/no/{id_no}")
def grafo_no(id_no: str):
    return _corpo(painel.api_grafo_no(id_no))


# ---------- Processos ----------

@router.get("/processos")
def processos(limite: int = 300):
    from esteira.nucleo import processos as P
    from esteira.nucleo import travas
    return {"processos": P.listar(limite), "vagas": {v: travas.dono(v) for v in travas.VAGAS}}


@router.get("/processos/{pid_id}")
def processo(pid_id: str):
    return _corpo(painel.api_processo(pid_id))


@router.post("/processos/{pid_id}/parar")
def parar(pid_id: str):
    """Para o processo (e o que ele abriu), venha da fila ou do terminal."""
    from esteira.nucleo import processos as P
    if not P.obter(pid_id):
        raise HTTPException(404, "processo não encontrado")
    painel.parar_processo(pid_id)
    return {"ok": True}


# ---------- Opções de IA ----------

@router.get("/opcoes")
def opcoes():
    from esteira.ia import local
    from esteira.nucleo import opcoes as O
    return {"opcoes": O.ler(), "claude": O.claude(painel._cfg().get("claude", {})),
            "operacoes": [{"id": k, "nome": nome, "descricao": desc, "tipos": tipos, "atual": O.operacao(k)}
                          for k, (nome, desc, tipos) in O.OPERACOES.items()],
            "modelos_claude": [{"id": i, "nome": n, "descricao": d} for i, n, d in O.MODELOS],
            "sugestoes": [{"nome": n, "tipo": t, "descricao": d} for n, t, d in O.SUGESTOES],
            "locais": painel._modelos_locais(), "padrao": {"texto": local.TEXTO, "visao": local.VISAO}}


class Operacao(BaseModel):
    motor: str = "padrao"
    texto: str | None = None
    visao: str | None = None


class Opcoes(BaseModel):
    motor: str = "local"
    modelo_claude: str | None = None
    teto_episodio_usd: float | None = None
    teto_dia_usd: float | None = None
    operacoes: dict[str, Operacao] = {}
    socorro_claude: bool = False


@router.post("/opcoes")
def salvar_opcoes(corpo: Opcoes):
    from esteira.nucleo import opcoes as O
    if corpo.motor not in ("local", "claude"):
        raise HTTPException(400, "motor deve ser local ou claude")
    ops = {}
    for k, (_, _, tipos) in O.OPERACOES.items():
        o = corpo.operacoes.get(k) or Operacao()
        ops[k] = {"motor": o.motor if o.motor in ("padrao", "local", "claude") else "padrao"} | {
            t: getattr(o, t) or None for t in tipos}
    O.salvar(motor=corpo.motor, modelo_claude=corpo.modelo_claude or None, teto_episodio_usd=corpo.teto_episodio_usd,
             teto_dia_usd=corpo.teto_dia_usd, operacoes=ops, socorro_claude=corpo.socorro_claude)
    return opcoes()


class Baixar(BaseModel):
    nome: str


@router.post("/opcoes/baixar")
def baixar(corpo: Baixar):
    """Baixa um modelo (`usuario/repo:QUANT` do Hugging Face) para o llama.cpp em segundo plano; o andamento
    sai em `/opcoes/baixando`."""
    nome = corpo.nome.strip()
    if not re.fullmatch(r"[\w.\-/]+(:[\w.\-]+)?", nome):
        raise HTTPException(400, "nome de modelo inválido (ex.: unsloth/Qwen3-8B-GGUF:Q4_K_M)")
    if painel._baixando.get(nome, {}).get("estado") != "baixando":
        painel._baixando[nome] = {"estado": "baixando", "feito": 0, "total": 0, "msg": "começando"}
        threading.Thread(target=painel._baixar, args=(nome,), daemon=True).start()
    return painel._baixando[nome]


@router.get("/opcoes/baixando")
def baixando():
    return painel._baixando


# ---------- Custos do Claude ----------

@router.get("/custos")
def custos():
    from esteira.ia import claude
    regs = list(reversed(claude._registros()))
    por_ep = {}
    for r in regs:
        por_ep[r["ep"]] = por_ep.get(r["ep"], 0) + r["custo"]
    hoje = datetime.now().date().isoformat()
    cfg = painel._cfg().get("claude", {})
    return {"registros": regs[:200], "n_registros": len(regs), "total": sum(por_ep.values()),
            "hoje": sum(r["custo"] for r in regs if r["t"].startswith(hoje)),
            "por_episodio": [{"ep": ep, "custo": v} for ep, v in sorted(por_ep.items(), key=lambda x: -x[1])],
            "teto_dia_usd": cfg.get("teto_dia_usd", 3), "teto_episodio_usd": cfg.get("teto_episodio_usd", 1),
            "modelo": cfg.get("modelo", "")}


# ---------- Acervo de mídia ----------

@router.get("/acervo")
def acervo(q: str = "", tipo: str = "", limite: int = 180):
    from esteira import acervo as A
    itens = [dict(it, mini=f"/acervo/mini/{it['id']}") for it in A.listar(q, tipo, limite=min(limite, 500))]
    return {"itens": itens, "estatisticas": A.estatisticas()}


# ---------- Backup e dataset das Craft Apps (docs/PLANO-DATASET.md) ----------

@router.get("/backup")
def backup():
    """Estado do backup no Google Drive (`infra/scripts/backup` grava `plataforma/backup.json`)."""
    from esteira.projeto import DADOS
    arq = DADOS.parent / "plataforma" / "backup.json"
    if not arq.exists():
        return {"configurado": False, "modulos": [], "ultimo": None, "teste": None}
    d = json.loads(arq.read_text())
    mods = d.get("modulos") or {}
    agora = datetime.now()

    def horas(t):
        return round((agora - datetime.fromisoformat(t)).total_seconds() / 3600, 1) if t else None
    linhas = [{"modulo": m, "estado": r.get("estado"), "erro": r.get("erro"), "ultimo_ok": r.get("ultimo_ok"),
               "horas": horas(r.get("ultimo_ok"))} for m, r in sorted(mods.items()) if not m.startswith("teste:")]
    teste = next(({"modulo": m[6:], **r} for m, r in sorted(mods.items(), key=lambda x: x[1].get("fim") or "",
                                                           reverse=True) if m.startswith("teste:")), None)
    return {"configurado": True, "ultimo": d.get("ultimo"), "modulos": linhas, "teste": teste,
            "atrasado": any((x["horas"] or 999) > 36 for x in linhas), "erros": sum(x["estado"] == "erro" for x in linhas)}


@router.get("/dataset")
def dataset():
    """Por tarefa: registros, exemplos de treino × mínimo; adaptadores (promovido ou não) e a última bancada N1."""
    from esteira import bancada
    from esteira.dataset import indice, treino_app
    situ = indice.situacao()
    tarefas = [{"tarefa": t, "app": treino_app.R.TAREFAS[t], **x} for t, x in situ.items() if t != "peca_html"]
    adaptadores = []
    pasta = treino_app._pasta()
    for m in sorted(pasta.glob("*.json")) if pasta.exists() else []:
        try:
            adaptadores.append(json.loads(m.read_text()))
        except ValueError:
            continue
    notas = {}
    for modelo, info in ((bancada.ultimo() or {}).get("modelos") or {}).items():
        for t, x in (info.get("tarefas") or {}).items():
            if t.startswith("n1_"):
                notas.setdefault(t[3:], {})[modelo] = {"nota": x.get("nota"), "json_ok": x.get("json_ok")}
    return {"tarefas": tarefas, "adaptadores": adaptadores, "bancada": notas,
            "promovidos": {app: treino_app.promovido(app) for app in treino_app.TAREFAS_APP}}


class Veredito(BaseModel):
    veredito: str
    comentario: str = ""


@router.post("/dataset/montagem/{ep}")
def veredito_montagem(ep: str, v: Veredito):
    """A pessoa aprova (ou não) a montagem gerada de um episódio: veredito no registro `montar` mais recente."""
    from esteira.dataset import registro as R
    if v.veredito not in ("aprovada", "reprovada", "ajuste"):
        raise HTTPException(422, "veredito: aprovada | reprovada | ajuste")
    r = R.ultimo(f"ep:{ep}", "montar")
    if not r:
        raise HTTPException(404, f"sem montagem registrada para {ep}")
    R.avaliar(r["id"], v.veredito, comentario=v.comentario or None,
              motivo=v.comentario or None if v.veredito == "reprovada" else None)
    return {"ok": True, "registro": r["id"]}
