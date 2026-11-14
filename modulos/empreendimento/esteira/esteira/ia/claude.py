"""Escalonamento ao Claude (`claude -p`, sem ferramentas, sem CLAUDE.md): só para o que o código e o LLM
local não resolveram com confiança. Recebe um dossiê compacto montado pelo código e responde em JSON
validado. Roda pela assinatura do Claude (sem chave de API): o "custo" é o equivalente em preço de API que o
`claude -p` informa, usado só como medida de consumo. Cada chamada vai para `cache/claude.jsonl` (custo,
episódio, motivo). O freio é a cota da assinatura: o `rate_limit_event` de cada chamada grava o uso das janelas
(5 h e semanal) em `cache/cota_claude.json`; com qualquer janela em LIMITE_COTA ou mais, devolve None até ela
virar, e quem chamou fica com a decisão do LLM local.
"""
import hashlib
import json
import os
import subprocess
import time
from datetime import date, datetime
from pathlib import Path

from pydantic import BaseModel, ValidationError

from esteira.nucleo import eventos, rastro
from esteira.projeto import CACHE

LIVRO = CACHE / "claude.jsonl"
COTA = CACHE / "cota_claude.json"
LIMITE_COTA = 0.90  # fração da cota da assinatura em que o sistema para de chamar o Claude
SISTEMA = ("Você resolve casos difíceis de uma esteira automática de edição de vídeos em pt-BR. "
           "Responda só no formato JSON pedido, com decisões objetivas.")


def _env_assinatura():
    """Ambiente sem chave de API: o `claude -p` usa o login da assinatura (Pro/Max), que não cobra por
    chamada. Com ANTHROPIC_API_KEY no ambiente ele cobraria na conta de API, por isso a chave é retirada."""
    return {k: v for k, v in os.environ.items() if k not in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")}


def _registros():
    if not LIVRO.exists():
        return []
    return [json.loads(l) for l in LIVRO.read_text().splitlines() if l.strip()]


def gasto(ep=None):
    """(gasto do episódio, gasto de hoje) em US$."""
    hoje = date.today().isoformat()
    regs = _registros()
    return (sum(r["custo"] for r in regs if ep and r["ep"] == ep),
            sum(r["custo"] for r in regs if r["t"].startswith(hoje)))


def _gravar_cota(info):
    janelas = info.get("unifiedWindows") or {}
    if janelas:
        COTA.parent.mkdir(exist_ok=True)
        COTA.write_text(json.dumps(janelas))


def cota():
    """Maior uso (0–1) entre as janelas da assinatura que ainda não viraram; 0 sem leitura."""
    try:
        janelas = json.loads(COTA.read_text())
    except (OSError, ValueError):
        return 0.0
    agora = time.time()
    return max((j.get("utilization") or 0.0 for j in janelas.values() if (j.get("resetsAt") or 0) > agora),
               default=0.0)


def limite_cota():
    from esteira.nucleo import opcoes
    v = opcoes.ler().get("limite_cota")
    return LIMITE_COTA if v is None else float(v)


def cota_cheia():
    return cota() >= limite_cota()


def consultar(dossie, esquema: type[BaseModel], cfg, ep, motivo, imagem=None):
    """`imagem`: caminho de UMA imagem (folha) que o Claude lê com a ferramenta Read."""
    from esteira.nucleo import opcoes
    c = opcoes.claude(cfg.get("claude", {}))
    if not c.get("ativo", True):
        return None
    assinatura = hashlib.sha1(open(imagem, "rb").read()).hexdigest() if imagem else None
    modelo = c.get("modelo", "claude-sonnet-5-5")
    k = hashlib.sha1(json.dumps([dossie, esquema.model_json_schema(), assinatura]
                                + ([modelo] if modelo != "claude-sonnet-5-5" else []),
                                ensure_ascii=False).encode()).hexdigest()
    for r in _registros():
        if r.get("k") == k and r.get("resposta") is not None:
            return esquema.model_validate(r["resposta"])
    if cota_cheia():
        eventos.aviso(f"Claude não consultado ({motivo}): cota da assinatura em {cota():.0%}")
        return None
    if imagem:
        dossie = f"Leia a imagem {imagem} (uma única vez) e então responda.\n\n" + dossie
    ferramentas = ["--tools", "Read", "--allowedTools", "Read"] if imagem else ["--tools", ""]
    cmd = ["claude", "-p", dossie, "--model", c.get("modelo", "claude-sonnet-5-5"), "--output-format", "stream-json",
           "--verbose", *ferramentas, "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config",
           "--system-prompt", SISTEMA, "--json-schema", json.dumps(esquema.model_json_schema()),
           "--max-budget-usd", f"{c.get('teto_chamada_usd', 0.30):.2f}"]
    t = time.monotonic()
    rastro.chamada_inicio("claude", motivo, c.get("modelo", "claude-sonnet-5-5"), dossie, esquema=esquema.__name__,
                          esquema_json=esquema.model_json_schema(),
                          imagem=bool(imagem))
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=300, env=_env_assinatura(),
                             cwd=str(Path(imagem).parent) if imagem else "/tmp")
        res = None
        for linha in out.stdout.splitlines():
            ev = json.loads(linha) if linha.startswith("{") else {}
            if ev.get("type") == "rate_limit_event":
                _gravar_cota(ev.get("rate_limit_info") or {})
            elif ev.get("type") == "result":
                res = ev
        if res is None:
            raise ValueError(f"sem resultado: {out.stderr[-120:]}")
    except (subprocess.TimeoutExpired, ValueError) as e:
        rastro.chamada_fim(ok=False, erro=str(e)[:200])
        eventos.aviso(f"Claude falhou ({motivo}): {str(e)[:120]}")
        return None
    custo = res.get("total_cost_usd") or 0.0
    try:
        obj = esquema.model_validate(res.get("structured_output")) if not res.get("is_error") else None
    except ValidationError:
        obj = None
    LIVRO.parent.mkdir(exist_ok=True)
    with open(LIVRO, "a") as f:
        f.write(json.dumps({"t": datetime.now().isoformat(timespec="seconds"), "ep": ep, "motivo": motivo,
                            "custo": custo, "k": k, "resposta": obj.model_dump() if obj else None},
                           ensure_ascii=False) + "\n")
    u = res.get("usage") or {}
    rastro.chamada_fim(json.dumps(obj.model_dump(), ensure_ascii=False) if obj else str(res.get("result", ""))[:2000],
                       ok=obj is not None, custo_usd=custo, tokens_entrada=u.get("input_tokens"),
                       tokens_saida=u.get("output_tokens"), cache_lido=u.get("cache_read_input_tokens"),
                       total_s=round(time.monotonic() - t, 2))
    eventos.gravar_claude(motivo, custo, round(time.monotonic() - t, 1), ok=obj is not None)
    return obj
