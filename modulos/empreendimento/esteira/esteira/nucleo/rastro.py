"""Rastro para o grafo do Monitor: em que nó da operação cada processo está e o que o LLM processa agora.

- `cache/ao_vivo/<pid>.json`: estado vivo do processo (fluxo, nó, progresso e a chamada de LLM em andamento,
  com o texto parcial gerado token a token). Some quando o processo termina.
- `cache/rastro.jsonl`: histórico das chamadas concluídas (prompt, resposta, tokens, tempos) e das mudanças de nó.
Só escreve arquivos pequenos; nunca levanta exceção para quem chama.
"""
import atexit
import itertools
import json
import os
import time
from pathlib import Path

from esteira.projeto import CACHE

DIR = CACHE / "ao_vivo"
LOG = CACHE / "rastro.jsonl"
MAX_LOG = 20 * 2**20
_ids = itertools.count(1)
_vivo = {"pid": os.getpid(), "fluxo": None, "no": None, "detalhe": "", "desde": time.time(), "progresso": None,
         "chamada": None, "tarefas": {}}
_ultimo = 0.0


def _gravar_vivo(forcar=True):
    global _ultimo
    _vivo["proc"] = os.environ.get("ESTEIRA_PROC")
    agora = time.time()
    if not forcar and agora - _ultimo < 0.4:
        return
    _ultimo = agora
    try:
        DIR.mkdir(parents=True, exist_ok=True)
        tmp = DIR / f".{os.getpid()}.tmp"
        tmp.write_text(json.dumps(_vivo, ensure_ascii=False, default=str))
        tmp.replace(DIR / f"{os.getpid()}.json")
    except OSError:
        pass


def _anexar(reg):
    try:
        LOG.parent.mkdir(exist_ok=True)
        if LOG.exists() and LOG.stat().st_size > MAX_LOG:  # guarda a metade mais recente
            linhas = LOG.read_text().splitlines()
            LOG.write_text("\n".join(linhas[len(linhas) // 2:]) + "\n")
        with open(LOG, "a") as f:
            f.write(json.dumps(dict(reg, t=round(time.time(), 2), pid=os.getpid(), proc=os.environ.get("ESTEIRA_PROC"),
                                    fluxo=_vivo["fluxo"],
                                    no=_vivo["no"]), ensure_ascii=False, default=str) + "\n")
    except OSError:
        pass


def no(fluxo, nome, detalhe=""):
    """Entra no nó `nome` do fluxo (`roteiro:<canal>:<N>` ou o id do episódio). nome=None: saiu do fluxo."""
    _vivo.update(fluxo=fluxo, no=nome, detalhe=detalhe, desde=time.time(), progresso=None)
    _anexar({"tipo": "no", "detalhe": detalhe})
    _gravar_vivo()


def passo(nome, detalhe=""):
    """Muda de nó dentro do fluxo atual."""
    no(_vivo["fluxo"], nome, detalhe)


def detalhe(texto):
    _vivo["detalhe"] = texto
    _gravar_vivo(False)


def progresso(i, n, msg="", resta=None):
    _vivo["progresso"] = {"i": i, "n": n, "msg": msg, "resta": resta}
    _gravar_vivo(i >= n)


def tarefa(chave, rotulo, feito, total=None, unidade=""):
    """Barra de uma subtarefa (download em bytes, quadros renderizados…); total=None = indeterminada."""
    t = _vivo["tarefas"].get(chave)
    if not t or t["rotulo"] != rotulo:
        t = _vivo["tarefas"][chave] = {"rotulo": rotulo, "inicio": time.time(), "unidade": unidade}
    t.update(feito=feito, total=total, t=time.time())
    _gravar_vivo(False)


def fim_tarefa(chave):
    if _vivo["tarefas"].pop(chave, None) is not None:
        _gravar_vivo()


def arquivo_externo(nome):
    """Caminho para um subprocesso (ex.: `artigo baixar`) gravar a própria barra, ligada a este processo."""
    DIR.mkdir(parents=True, exist_ok=True)
    return DIR / f"{os.getpid()}.ext-{nome}.json"


def chamada_inicio(motor, nome, modelo, entrada, esquema_json=None, **params):
    """motor: "local" | "claude". `esquema_json`: o JSON Schema que restringe a resposta. Devolve o id."""
    cid = f"{os.getpid()}-{next(_ids)}"
    _vivo["chamada"] = {"id": cid, "motor": motor, "nome": nome, "modelo": modelo, "entrada": entrada[:12000],
                        "params": params, "inicio": time.time(), "parcial": "", "tokens": 0,
                        "esquema": json.dumps(esquema_json, ensure_ascii=False)[:3000] if esquema_json else ""}
    _gravar_vivo()
    return cid


def chamada_parcial(texto, tokens):
    c = _vivo["chamada"]
    if c:
        if not c.get("primeiro"):
            c["primeiro"] = time.time()  # fim do prefill (+ fila/carga): começa a geração
        c["parcial"], c["tokens"] = texto[-6000:], tokens
        _gravar_vivo(False)


def chamada_fim(saida="", ok=True, erro="", **metricas):
    c = _vivo["chamada"]
    if not c:
        return
    _anexar({"tipo": "chamada", "id": c["id"], "motor": c["motor"], "nome": c["nome"], "modelo": c["modelo"],
             "entrada": c["entrada"][:8000], "saida": saida[:6000], "esquema": c.get("esquema", ""), "params": c["params"], "ok": ok, "erro": erro,
             "seg": round(time.time() - c["inicio"], 2), **metricas})
    _vivo["chamada"] = None
    _gravar_vivo()


def cache(nome, modelo):
    """Resposta veio do cache da esteira (nenhum token gasto)."""
    _anexar({"tipo": "cache", "nome": nome, "modelo": modelo})


@atexit.register
def _sair():
    try:
        (DIR / f"{os.getpid()}.json").unlink(missing_ok=True)
    except OSError:
        pass
