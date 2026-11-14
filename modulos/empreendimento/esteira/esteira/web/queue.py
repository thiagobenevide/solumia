"""Fila de produção do painel: duas pistas, cada uma roda `./dark <comando> <ep> ...` um de cada vez.
Pista "machine" (GPU, LLM local, renders: um processo por vez) e pista "claude" (`--motor claude` em
curar/roteiro, que não usa a GPU e pode rodar junto). O próprio processo ainda toma a vaga em
`esteira.core.locks`, então a fila também espera o que foi aberto pelo terminal.

A fila fica em `cache/fila.json` (sobrevive a reinícios do painel; o que estava rodando volta como
"interrompido"). A saída de cada tarefa vai para `<ep>/log/fila_<id>.log`; o progresso fino vem do log de
eventos da própria etapa.
"""
import fcntl
import json
import os
import subprocess
import threading
import time
from datetime import datetime

import psutil
from esteira.core import locks
from esteira.project import CACHE, RAIZ, pasta_ep

ARQ = CACHE / "fila.json"
_trava = threading.Lock()
_proc = {}


def _ler():
    return json.loads(ARQ.read_text()) if ARQ.exists() else []


def _salvar(fila):
    ARQ.parent.mkdir(exist_ok=True)
    tmp = ARQ.with_suffix(f".{os.getpid()}.tmp")  # troca atômica: quem lê de outro processo nunca vê o arquivo pela metade
    tmp.write_text(json.dumps(fila, ensure_ascii=False, indent=1))
    tmp.replace(ARQ)


def listar():
    with _trava:
        return _ler()


def adicionar(ep, comando, args=(), motor="local"):
    """`ep`: episódio (canal-NNN) ou, para `roteiro`, o alvo canal:N. motor="claude" só vale em locks.CLAUDE_OK."""
    v = locks.slot(comando, motor)
    args = list(args) + (["--engine", "claude"] if v == "claude" else [])
    with _trava:
        fila = _ler()
        if any(t["ep"] == ep and t["comando"] == comando and t["estado"] in ("na fila", "rodando") for t in fila):
            return None  # já está na fila
        t = {"id": int(time.time() * 1000), "ep": ep, "comando": comando, "args": args, "vaga": v,
             "estado": "na fila", "criado": datetime.now().isoformat(timespec="seconds")}
        fila.append(t)
        _salvar(fila)
        return t


def _processos_da(t):
    """Processo da tarefa (pelo pid gravado ou, em tarefas antigas, pela linha de comando) e seus filhos."""
    raiz = None
    if t.get("pid") and psutil.pid_exists(t["pid"]):
        raiz = psutil.Process(t["pid"])
    else:
        alvo = ["esteira.py", t["comando"], t["ep"]]
        for p in psutil.process_iter(["cmdline"]):
            c = p.info["cmdline"] or []
            if any(a.endswith(alvo[0]) for a in c) and c[-len(t["args"]) - 2:][:2] == alvo[1:]:
                raiz = p
                break
    if not raiz:
        return []
    try:
        return [raiz] + raiz.children(recursive=True)
    except psutil.NoSuchProcess:
        return []


def _encerrar(t):
    """SIGTERM na tarefa e em tudo que ela abriu (ffmpeg, Chromium…); SIGKILL em quem não sair em 5 s.
    Funciona de qualquer painel: não depende do worker que iniciou a tarefa."""
    procs = _processos_da(t)
    for p in procs:
        try:
            p.terminate()
        except psutil.NoSuchProcess:
            pass
    _, vivos = psutil.wait_procs(procs, timeout=5)
    for p in vivos:
        try:
            p.kill()
        except psutil.NoSuchProcess:
            pass
    return bool(procs)


def cancelar(tid):
    with _trava:
        fila = _ler()
        alvo = next((t for t in fila if t["id"] == tid), None)
        if not alvo or alvo["estado"] not in ("na fila", "rodando"):
            return
        rodando = alvo["estado"] == "rodando"
        alvo.update(estado="cancelado", fim=datetime.now().isoformat(timespec="seconds"))
        _salvar(fila)
    if rodando:
        _encerrar(alvo)


def limpar_concluidas():
    with _trava:
        _salvar([t for t in _ler() if t["estado"] in ("na fila", "rodando")])


def _proxima(vaga):
    with _trava:
        fila = _ler()
        t = next((t for t in fila if t["estado"] == "na fila" and t.get("vaga", "machine") == vaga), None)
        if t:
            t.update(estado="rodando", inicio=datetime.now().isoformat(timespec="seconds"))
            _salvar(fila)
        return t


def _terminar(tid, codigo):
    with _trava:
        fila = _ler()
        for t in fila:
            if t["id"] == tid and t["estado"] != "cancelado":
                t.update(estado="ok" if codigo == 0 else "erro", codigo=codigo,
                         fim=datetime.now().isoformat(timespec="seconds"))
        _salvar(fila)


def _marcar_pid(tid, pid):
    with _trava:
        fila = _ler()
        for t in fila:
            if t["id"] == tid:
                t["pid"] = pid
        _salvar(fila)


def _log(t):
    # roteiro (canal:N) não tem pasta de episódio
    pasta = CACHE / "fila_logs" if ":" in t["ep"] else pasta_ep(t["ep"]) / "log"
    pasta.mkdir(parents=True, exist_ok=True)
    return pasta / f"fila_{t['id']}.log"


def _worker(vaga):
    while True:
        t = _proxima(vaga)
        if not t:
            time.sleep(1.5)
            continue
        with open(_log(t), "w") as log:
            p = subprocess.Popen([str(RAIZ / "dark"), t["comando"], t["ep"], *t["args"]], cwd=RAIZ,
                                 stdout=log, stderr=subprocess.STDOUT,
                                 env={**os.environ, "ESTEIRA_QUEUE": str(t["id"])})
            _proc[vaga] = p
            _marcar_pid(t["id"], p.pid)
            codigo = p.wait()
            _proc[vaga] = None
        _terminar(t["id"], codigo)


def iniciar():
    """Só um painel por vez roda o worker (trava em cache/fila.lock); os outros só mostram e cancelam."""
    ARQ.parent.mkdir(exist_ok=True)
    _proc["trava"] = open(ARQ.with_suffix(".lock"), "w")
    try:
        fcntl.flock(_proc["trava"], fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    with _trava:
        fila = _ler()
        for t in fila:
            if t["estado"] == "rodando" and not _processos_da(t):
                t["estado"] = "interrompido"
        _salvar(fila)
        fabrica_viva = any(t["estado"] == "rodando" and str(t.get("ep", "")).startswith("fabrica:") for t in fila)
    if not fabrica_viva:
        try:  # peças da LLM local que o reinício deixou no meio da revisão do Claude
            from esteira.studio import factory
            factory.limpar_orfas()
        except Exception as e:  # noqa: BLE001 — limpeza nunca impede o painel de subir
            print(f"  ! fila: limpeza de órfãs falhou ({e})")
    for v in locks.SLOTS:
        threading.Thread(target=_worker, args=(v,), daemon=True).start()
    threading.Thread(target=_relogio, daemon=True).start()
    return True


def _relogio(intervalo=900):
    """A cada 15 min: ampliação contínua do acervo (estudio/fabrica.ampliar; não faz nada se estiver desligada) e
    retomada dos pedidos do Claude parados pela cota (fabrica.retomar)."""
    while True:
        try:
            from esteira.studio import factory
            factory.ampliar()
            factory.retomar()  # a janela da cota virou: os pedidos do Claude voltam a trabalhar
        except Exception as e:  # noqa: BLE001 — o relógio não pode derrubar o worker da fila
            print(f"  relógio da fila: {str(e)[:200]}")
        time.sleep(intervalo)
