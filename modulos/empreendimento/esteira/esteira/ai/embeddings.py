"""Local embeddings for the Studio direction: EmbeddingGemma 300M (GGUF) on its own `llama-server --embeddings`,
on the CPU and on port 8082 (the GPU router keeps only the text/vision models and does not swap models for this).
Starts on demand; vectors are cached (`cache/embeddings.jsonl`). Without the model: None (the direction falls back
to word similarity). Download: Options → models, `ggml-org/embeddinggemma-300M-GGUF:Q8_0`.
"""
import hashlib
import json
import math
import os
import subprocess
import time

import requests

from esteira.ai import llama
from esteira.projeto import CACHE

MODEL = os.environ.get("EMBEDDINGS_MODEL", "embeddinggemma-300m-q8_0")
HOST = os.environ.get("EMBEDDINGS_HOST", "http://127.0.0.1:8082")
CACHE_FILE = CACHE / "embeddings.jsonl"
# EmbeddingGemma prefixes: the sentence of the video is the "query"; the examples of the piece sheets are the
# "documents"
QUERY, DOCUMENT = "task: search result | query: ", "title: none | text: "
_cache = None


def _model_file():
    return llama.MODELS_DIR / f"{MODEL}.gguf"


def available():
    return _model_file().exists() and llama.BIN.exists()


def _up():
    try:
        return requests.get(f"{HOST}/health", timeout=2).ok
    except requests.RequestException:
        return False


def server():
    if _up():
        return True
    if not available():
        return False
    port = HOST.rsplit(":", 1)[-1]
    with open(llama.MODELS_DIR / "embeddings-server.log", "ab") as log:
        subprocess.Popen([str(llama.BIN), "--embeddings", "-m", str(_model_file()), "--host", "127.0.0.1",
                          "--port", port, "-ngl", "0", "-c", "2048", "-ub", "2048", "-b", "2048"], stdout=log,
                         stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
    for _ in range(60):
        time.sleep(0.5)
        if _up():
            return True
    return False


def _key(text):
    return hashlib.sha1(f"{MODEL}\n{text}".encode()).hexdigest()


def _load_cache():
    global _cache
    if _cache is None:
        _cache = {}
        if CACHE_FILE.exists():
            for line in CACHE_FILE.read_text().splitlines():
                try:
                    record = json.loads(line)
                    _cache[record["k"]] = record["v"]
                except (ValueError, KeyError):
                    continue
    return _cache


def _index(item):
    return item["index"]


def _embed(inputs):
    """Vectors of `inputs` from the server, in the same order, in batches of 64."""
    vectors_out = []
    for i in range(0, len(inputs), 64):
        r = requests.post(f"{HOST}/v1/embeddings", json={"input": inputs[i:i + 64]}, timeout=120)
        r.raise_for_status()
        for item in sorted(r.json()["data"], key=_index):
            vectors_out.append(item["embedding"])
    return vectors_out


def vectors(texts, prefix=DOCUMENT):
    """List of vectors (same order) or None if the model is not available."""
    cache = _load_cache()
    inputs = []
    for text in texts:
        inputs.append(prefix + text)
    missing = []
    for entry in dict.fromkeys(inputs):
        if _key(entry) not in cache:
            missing.append(entry)
    if missing:
        if not server():
            return None
        new = _embed(missing)
        CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(CACHE_FILE, "a") as f:
            for entry, vector in zip(missing, new, strict=True):
                rounded = []
                for x in vector:
                    rounded.append(round(x, 5))
                cache[_key(entry)] = rounded
                f.write(json.dumps({"k": _key(entry), "v": rounded}) + "\n")
    result = []
    for entry in inputs:
        result.append(cache[_key(entry)])
    return result


def _norm(vector):
    total = 0.0
    for x in vector:
        total += x * x
    return math.sqrt(total) or 1.0


def cosine(a, b):
    dot = 0.0
    for x, y in zip(a, b, strict=True):
        dot += x * y
    return dot / (_norm(a) * _norm(b))


def mean(vector_list):
    if not vector_list:
        return None
    result = []
    for column in zip(*vector_list, strict=True):
        result.append(sum(column) / len(vector_list))
    return result
