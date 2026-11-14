"""Embeddings locais para a direção do Estúdio: EmbeddingGemma 300M (GGUF) num `llama-server --embeddings` próprio,
na CPU e na porta 8082 (o roteador da GPU segue só com os modelos de texto/visão e não troca de modelo por isso).
Sobe sob demanda; vetores em cache (`cache/embeddings.jsonl`). Sem o modelo: None (a direção cai na semelhança por
palavras). Baixar: Opções → modelos, `ggml-org/embeddinggemma-300M-GGUF:Q8_0`.
"""
import hashlib
import json
import math
import os
import subprocess
import time

import requests

from esteira.ia import llama
from esteira.projeto import CACHE

MODELO = os.environ.get("EMBEDDINGS_MODELO", "embeddinggemma-300m-q8_0")
HOST = os.environ.get("EMBEDDINGS_HOST", "http://127.0.0.1:8082")
ARQ = CACHE / "embeddings.jsonl"
# prefixos do EmbeddingGemma: a frase do vídeo é a "busca"; os exemplos das fichas são os "documentos"
CONSULTA, DOCUMENTO = "task: search result | query: ", "title: none | text: "
_cache = None


def _arquivo():
    return llama.MODELOS / f"{MODELO}.gguf"


def disponivel():
    return _arquivo().exists() and llama.BIN.exists()


def _no_ar():
    try:
        return requests.get(f"{HOST}/health", timeout=2).ok
    except requests.RequestException:
        return False


def servidor():
    if _no_ar():
        return True
    if not disponivel():
        return False
    porta = HOST.rsplit(":", 1)[-1]
    with open(llama.MODELOS / "embeddings-server.log", "ab") as log:
        subprocess.Popen([str(llama.BIN), "--embeddings", "-m", str(_arquivo()), "--host", "127.0.0.1", "--port", porta,
                          "-ngl", "0", "-c", "2048", "-ub", "2048", "-b", "2048"], stdout=log, stderr=log,
                         stdin=subprocess.DEVNULL, start_new_session=True)
    for _ in range(60):
        time.sleep(0.5)
        if _no_ar():
            return True
    return False


def _chave(texto):
    return hashlib.sha1(f"{MODELO}\n{texto}".encode()).hexdigest()


def _carregar_cache():
    global _cache
    if _cache is None:
        _cache = {}
        if ARQ.exists():
            for linha in ARQ.read_text().splitlines():
                try:
                    d = json.loads(linha)
                    _cache[d["k"]] = d["v"]
                except (ValueError, KeyError):
                    continue
    return _cache


def vetores(textos, prefixo=DOCUMENTO):
    """Lista de vetores (mesma ordem) ou None se o modelo não está disponível."""
    cache = _carregar_cache()
    entradas = [prefixo + t for t in textos]
    faltam = [e for e in dict.fromkeys(entradas) if _chave(e) not in cache]
    if faltam:
        if not servidor():
            return None
        novos = []
        for i in range(0, len(faltam), 64):
            r = requests.post(f"{HOST}/v1/embeddings", json={"input": faltam[i:i + 64]}, timeout=120)
            r.raise_for_status()
            novos += [x["embedding"] for x in sorted(r.json()["data"], key=lambda x: x["index"])]
        ARQ.parent.mkdir(parents=True, exist_ok=True)
        with open(ARQ, "a") as f:
            for e, v in zip(faltam, novos, strict=True):
                v = [round(x, 5) for x in v]
                cache[_chave(e)] = v
                f.write(json.dumps({"k": _chave(e), "v": v}) + "\n")
    return [cache[_chave(e)] for e in entradas]


def cosseno(a, b):
    na = math.sqrt(sum(x * x for x in a)) or 1.0
    nb = math.sqrt(sum(x * x for x in b)) or 1.0
    return sum(x * y for x, y in zip(a, b, strict=True)) / (na * nb)


def media(vs):
    if not vs:
        return None
    return [sum(c) / len(vs) for c in zip(*vs, strict=True)]
