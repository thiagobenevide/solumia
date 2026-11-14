"""LLM local (llama.cpp na GPU, `ia/llama.py`) para decisões operacionais: JSON validado por pydantic, com cache.

`perguntar(prompt, Modelo)` → instância do modelo pydantic, ou None se o LLM não estiver disponível ou não
der uma resposta válida em 2 tentativas (quem chama decide o plano B: regra fixa ou escalonar ao Claude).
Respostas ficam em cache (`cache/llm.jsonl`, chave = hash de modelo+prompt+esquema): refazer uma etapa não
repete chamadas. `liberar_gpu()` descarrega os modelos antes do Whisper/difusão.
"""
import base64
import hashlib
import json
import mimetypes
import os
import time
from pathlib import Path

import requests
from pydantic import BaseModel, ValidationError

from esteira.ia import llama
from esteira.nucleo import eventos, rastro
from esteira.projeto import CACHE, RAIZ

# ids no roteador do llama.cpp (arquivo/pasta em ~/agent-data/modelos)
# Gemma 4 12B: melhor ou igual ao qwen3-14b/qwen2.5vl-7b em todas as tarefas da bancada (out/2026) e lê imagens,
# então um modelo só na VRAM serve texto e visão
TEXTO = VISAO = "gemma-4-12b-it-ud-q4_k_xl"
HOST = llama.HOST
# nomes do Ollama que podem estar salvos nas Opções
LEGADO = {"qwen3:14b": TEXTO, "qwen2.5vl:7b": VISAO}
CACHE = CACHE / "llm.jsonl"
PROMPTS = Path(__file__).parent / "prompts"
_mem = None


def _cache():
    global _mem
    if _mem is None:
        _mem = {}
        if CACHE.exists():
            for linha in CACHE.read_text().splitlines():
                reg = json.loads(linha)
                _mem[reg["k"]] = reg["r"]
    return _mem


def _servidor():
    """Garante o roteador do llama.cpp no ar (sobe em segundo plano se preciso)."""
    return llama.servidor()


class Prompt(str):
    """Texto do prompt que lembra o nome do modelo de prompt (aparece no grafo do Monitor)."""
    nome = "livre"


def prompt(nome, **campos):
    """Carrega `prompts/<nome>.md` e preenche {campos}."""
    p = Prompt((PROMPTS / f"{nome}.md").read_text().format(**campos))
    p.nome = nome
    return p


def _metricas(t, inicio, primeiro=None):
    """Tempos do llama.cpp (`timings`, ms → s): prefill (lê o prompt) e geração (token a token); a carga do
    modelo é a espera até o primeiro pedaço menos o prefill."""
    t = t or {}
    s = lambda v: round((v or 0) / 1000, 3)
    m = {"tokens_entrada": t.get("prompt_n"), "tokens_saida": t.get("predicted_n"),
         "prefill_s": s(t.get("prompt_ms")), "geracao_s": s(t.get("predicted_ms")),
         "carga_s": max(0.0, round((primeiro or inicio) - inicio - s(t.get("prompt_ms")), 3)),
         "total_s": round(time.monotonic() - inicio, 2)}
    if m["tokens_saida"] and m["geracao_s"]:
        m["tok_s"] = round(m["tokens_saida"] / m["geracao_s"], 1)
    if m["tokens_entrada"] and m["prefill_s"]:
        m["prefill_tok_s"] = round(m["tokens_entrada"] / m["prefill_s"], 1)
    return m


def _operacao(texto, operacao):
    """Qual operação pergunta: explícita, pelo nome do prompt ou pela etapa em andamento."""
    nome = getattr(texto, "nome", "")
    if operacao:
        return operacao
    if nome.startswith("acervo"):
        return "acervo"
    if nome.startswith("roteiro"):
        return "roteiro"
    return eventos._atual.nome if eventos._atual else None


def perguntar(texto, esquema: type[BaseModel], modelo=TEXTO, imagens=None, pensar=False, temperatura=0.1,
              max_tokens=600, operacao=None):
    # modelo e motor escolhidos no painel (Opções) para esta operação
    from esteira.nucleo import opcoes
    op = opcoes.operacao(_operacao(texto, operacao) or "")
    tipo = "visao" if modelo == VISAO or imagens else "texto"
    modelo = LEGADO.get(op[tipo] or modelo, op[tipo] or modelo)
    motor = os.environ.get("ESTEIRA_MOTOR", "local")
    if op["motor"] != "padrao" and not os.environ.get("ESTEIRA_MOTOR_FIXO") and os.environ.get("ESTEIRA_VAGA") != "claude":
        motor = op["motor"]  # sem a vaga da máquina (processo na pista do Claude) não dá para usar a GPU
    # imagens entram na chave pelo conteúdo (a mídia de uma cena muda sem mudar o caminho)
    assinaturas = [hashlib.sha1(Path(i).read_bytes()).hexdigest() for i in imagens or []]
    k = hashlib.sha1(json.dumps([modelo, texto, esquema.model_json_schema(), assinaturas, pensar],
                                ensure_ascii=False).encode()).hexdigest()
    nome = getattr(texto, "nome", "livre")
    c = _cache()
    if k in c:
        rastro.cache(nome, modelo)
        return esquema.model_validate(c[k])
    if motor == "claude":
        r = _pelo_claude(texto, esquema, nome, imagens)
        # sem resposta (teto de custo, erro): quem tem a vaga da máquina cai no LLM local
        if r is not None or os.environ.get("ESTEIRA_VAGA") != "maquina":
            return r
    if not _servidor():
        eventos.debug("llm indisponível")
        return None
    if modelo not in {m["id"] for m in llama.modelos() or []}:
        eventos.debug("llm: modelo ausente, usando o padrão", modelo=modelo)
        modelo = VISAO if tipo == "visao" else TEXTO
    msg = {"role": "user", "content": str(texto)}
    if imagens:
        msg["content"] = [{"type": "text", "text": str(texto)}] + [
            {"type": "image_url", "image_url": {"url": _data_url(i)}} for i in imagens]
    for tentativa in (1, 2):
        t = time.monotonic()
        temp = temperatura if tentativa == 1 else 0.5
        rastro.chamada_inicio("local", nome, modelo, str(texto), esquema=esquema.__name__,
                          esquema_json=esquema.model_json_schema(), temperatura=temp,
                              num_ctx=16384, num_predict=max_tokens, pensar=pensar, imagens=len(imagens or []),
                              tentativa=tentativa)
        conteudo, pensamento, timings, primeiro, n_tok = "", "", None, None, 0
        corpo = {"model": modelo, "messages": [msg], "stream": True, "temperature": temp, "max_tokens": max_tokens,
                 # JSON forçado pelo esquema (gramática): o modelo só gera tokens que formam um JSON válido
                 "response_format": {"type": "json_object", "schema": esquema.model_json_schema()},
                 "chat_template_kwargs": {"enable_thinking": pensar}}
        try:
            # stream: o Monitor mostra o texto sendo gerado; o último pedaço traz as métricas (timings)
            with requests.post(f"{HOST}/v1/chat/completions", json=corpo, stream=True, timeout=(10, 600)) as r:
                r.raise_for_status()
                # SSE sem charset no cabeçalho: decodifica em UTF-8 (o requests assumiria Latin-1)
                for linha in (b.decode("utf-8") for b in r.iter_lines()):
                    if not linha.startswith("data: ") or linha == "data: [DONE]":
                        continue
                    pedaco = json.loads(linha[6:])
                    timings = pedaco.get("timings") or timings
                    delta = (pedaco.get("choices") or [{}])[0].get("delta") or {}
                    if delta.get("content") or delta.get("reasoning_content"):
                        primeiro = primeiro or time.monotonic()
                        conteudo += delta.get("content") or ""
                        pensamento += delta.get("reasoning_content") or ""
                        n_tok += 1
                        rastro.chamada_parcial((f"[pensando] {pensamento}\n\n" if pensamento else "") + conteudo,
                                               n_tok)
            obj = esquema.model_validate_json(conteudo)
        except (ValidationError, ValueError) as e:
            rastro.chamada_fim(conteudo, ok=False, erro=f"resposta inválida: {str(e)[:200]}",
                               **_metricas(timings, t, primeiro))
            eventos.debug("llm resposta inválida", modelo=modelo, erro=str(e)[:200], tentativa=tentativa)
            continue
        except Exception as e:  # servidor caiu, modelo ausente…
            rastro.chamada_fim(conteudo, ok=False, erro=str(e)[:200])
            eventos.debug("llm erro", modelo=modelo, erro=str(e)[:200])
            return None
        rastro.chamada_fim(conteudo, ok=True, pensamento=pensamento[:3000], **_metricas(timings, t, primeiro))
        eventos.debug("llm", modelo=modelo, ms=round((time.monotonic() - t) * 1000),
                      tokens=(timings or {}).get("predicted_n"))
        CACHE.parent.mkdir(exist_ok=True)
        with open(CACHE, "a") as f:
            f.write(json.dumps({"k": k, "r": obj.model_dump()}, ensure_ascii=False) + "\n")
        c[k] = obj.model_dump()
        return obj
    return None


def _pelo_claude(texto, esquema, nome, imagens):
    """Processo com `--motor claude`: a mesma pergunta vai ao Claude (sem GPU), com o teto de [claude]."""
    import tomllib
    from esteira.ia import claude
    from esteira.projeto import Projeto, pasta_ep
    ep = os.environ.get("ESTEIRA_EP")
    try:
        cfg = Projeto(pasta_ep(ep)).cfg if ep else tomllib.loads((RAIZ / "config.toml").read_text())
    except (OSError, ValueError):
        cfg = tomllib.loads((RAIZ / "config.toml").read_text())
    return claude.consultar(str(texto), esquema, cfg, ep, nome, imagem=str(imagens[0]) if imagens else None)


def _data_url(caminho):
    """Imagem como data URL (o llama-server recebe a imagem dentro da mensagem)."""
    tipo = mimetypes.guess_type(str(caminho))[0] or "image/jpeg"
    return f"data:{tipo};base64,{base64.b64encode(Path(caminho).read_bytes()).decode()}"


def liberar_gpu():
    """Descarrega os modelos do llama.cpp (o Whisper e a difusão precisam da VRAM)."""
    antes = llama.carregados()
    llama.descarregar()
    for m in antes:
        eventos.debug("gpu: descarregado", modelo=m)
