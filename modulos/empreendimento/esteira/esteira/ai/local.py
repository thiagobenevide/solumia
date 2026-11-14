"""Local LLM (llama.cpp on the GPU, `ai/llama.py`) for operational decisions: JSON validated by pydantic, cached.

`ask(prompt, Model)` → instance of the pydantic model, or None if the LLM is unavailable or gives no valid
answer in 2 attempts (the caller decides plan B: fixed rule or escalating to Claude). Answers are cached
(`cache/llm.jsonl`, key = hash of model+prompt+schema): redoing a stage does not repeat calls. `free_gpu()`
unloads the models before Whisper/diffusion.
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

from esteira.ai import llama
from esteira.core import events, trace
from esteira.projeto import CACHE, RAIZ

# ids in the llama.cpp router (file/folder in ~/agent-data/modelos)
# Gemma 4 12B: better than or equal to qwen3-14b/qwen2.5vl-7b on every bench task (Oct 2026) and reads images,
# so a single model in VRAM serves text and vision
TEXT = VISION = "gemma-4-12b-it-ud-q4_k_xl"
HOST = llama.HOST
# Ollama names that may still be saved in the Options
LEGACY = {"qwen3:14b": TEXT, "qwen2.5vl:7b": VISION}
CACHE_FILE = CACHE / "llm.jsonl"
PROMPTS = Path(__file__).parent / "prompts"
_memory = None


def _cache():
    global _memory
    if _memory is None:
        _memory = {}
        if CACHE_FILE.exists():
            for line in CACHE_FILE.read_text().splitlines():
                record = json.loads(line)
                _memory[record["k"]] = record["r"]
    return _memory


def _server():
    """Makes sure the llama.cpp router is up (starts it in the background if needed)."""
    return llama.server()


class Prompt(str):
    """Prompt text that remembers the name of its prompt template (shown in the Monitor graph)."""
    name = "free"


def prompt(name, **fields):
    """Loads `prompts/<name>.md` and fills in {fields}."""
    p = Prompt((PROMPTS / f"{name}.md").read_text().format(**fields))
    p.name = name
    return p


def _seconds(milliseconds):
    return round((milliseconds or 0) / 1000, 3)


def _metrics(timings, start, first=None):
    """llama.cpp timings (`timings`, ms → s): prefill (reads the prompt) and generation (token by token); the
    load is what is left between the request and the first token."""
    timings = timings or {}
    prefill = _seconds(timings.get("prompt_ms"))
    metrics = {"input_tokens": timings.get("prompt_n"), "output_tokens": timings.get("predicted_n"),
               "prefill_s": prefill, "generation_s": _seconds(timings.get("predicted_ms")),
               "load_s": max(0.0, round((first or start) - start - prefill, 3)),
               "total_s": round(time.monotonic() - start, 2)}
    if metrics["output_tokens"] and metrics["generation_s"]:
        metrics["tok_s"] = round(metrics["output_tokens"] / metrics["generation_s"], 1)
    if metrics["input_tokens"] and metrics["prefill_s"]:
        metrics["prefill_tok_s"] = round(metrics["input_tokens"] / metrics["prefill_s"], 1)
    return metrics


def _operation(text, operation):
    """Which operation is asking: explicit, by the prompt name or by the stage in progress."""
    name = getattr(text, "name", "")
    if operation:
        return operation
    if name.startswith("acervo"):
        return "library"
    if name.startswith("roteiro"):
        return "script"
    if events._current:
        return events._current.name
    return None


def _image_signatures(images):
    signatures = []
    for image in images or []:
        signatures.append(hashlib.sha1(Path(image).read_bytes()).hexdigest())
    return signatures


def _message(text, images):
    if not images:
        return {"role": "user", "content": str(text)}
    content = [{"type": "text", "text": str(text)}]
    for image in images:
        content.append({"type": "image_url", "image_url": {"url": _data_url(image)}})
    return {"role": "user", "content": content}


def _available(model):
    for m in llama.models() or []:
        if m["id"] == model:
            return True
    return False


def ask(text, schema: type[BaseModel], model=TEXT, images=None, think=False, temperature=0.1,
        max_tokens=600, operation=None):
    # model and engine chosen in the panel (Options) for this operation
    from esteira.core import options
    op = options.operation(_operation(text, operation) or "")
    kind = "vision" if model == VISION or images else "text"
    model = op[kind] or model
    model = LEGACY.get(model, model)
    engine = os.environ.get("ESTEIRA_ENGINE", "local")
    if op["engine"] != "default" and not os.environ.get("ESTEIRA_ENGINE_FIXED") and os.environ.get("ESTEIRA_SLOT") != "claude":
        engine = op["engine"]  # without the machine slot (process on the Claude lane) the GPU cannot be used
    # images enter the key by content (the media of a scene changes without the path changing)
    key = hashlib.sha1(json.dumps([model, text, schema.model_json_schema(), _image_signatures(images), think],
                                  ensure_ascii=False).encode()).hexdigest()
    name = getattr(text, "name", "free")
    cache = _cache()
    if key in cache:
        trace.cache(name, model)
        return schema.model_validate(cache[key])
    if engine == "claude":
        answer = _via_claude(text, schema, name, images)
        # no answer (cost cap, error): whoever holds the machine slot falls back to the local LLM
        if answer is not None or os.environ.get("ESTEIRA_SLOT") != "machine":
            return answer
    if not _server():
        events.debug("llm unavailable")
        return None
    if not _available(model):
        events.debug("llm: model missing, using the default", model=model)
        model = VISION if kind == "vision" else TEXT
    message = _message(text, images)
    for attempt in (1, 2):
        start = time.monotonic()
        attempt_temperature = temperature if attempt == 1 else 0.5
        trace.call_start("local", name, model, str(text), schema_name=schema.__name__,
                         json_schema=schema.model_json_schema(), temperature=attempt_temperature,
                         num_ctx=16384, num_predict=max_tokens, think=think, images=len(images or []),
                         attempt=attempt)
        content, thinking, timings, first, token_count = "", "", None, None, 0
        body = {"model": model, "messages": [message], "stream": True, "temperature": attempt_temperature,
                "max_tokens": max_tokens,
                # JSON forced by the schema (grammar): the model only generates tokens that form valid JSON
                "response_format": {"type": "json_object", "schema": schema.model_json_schema()},
                "chat_template_kwargs": {"enable_thinking": think}}
        try:
            # stream: the Monitor shows the text being generated; the last chunk carries the metrics (timings)
            with requests.post(f"{HOST}/v1/chat/completions", json=body, stream=True, timeout=(10, 600)) as r:
                r.raise_for_status()
                for raw in r.iter_lines():
                    # SSE without charset in the header: decode as UTF-8 (requests would assume Latin-1)
                    line = raw.decode("utf-8")
                    if not line.startswith("data: ") or line == "data: [DONE]":
                        continue
                    chunk = json.loads(line[6:])
                    timings = chunk.get("timings") or timings
                    delta = (chunk.get("choices") or [{}])[0].get("delta") or {}
                    if delta.get("content") or delta.get("reasoning_content"):
                        first = first or time.monotonic()
                        content += delta.get("content") or ""
                        thinking += delta.get("reasoning_content") or ""
                        token_count += 1
                        partial = content
                        if thinking:
                            partial = f"[thinking] {thinking}\n\n{content}"
                        trace.call_partial(partial, token_count)
            answer = schema.model_validate_json(content)
        except (ValidationError, ValueError) as e:
            trace.call_end(content, ok=False, error=f"invalid answer: {str(e)[:200]}",
                           **_metrics(timings, start, first))
            events.debug("llm invalid answer", model=model, error=str(e)[:200], attempt=attempt)
            continue
        except Exception as e:  # server died, model missing…
            trace.call_end(content, ok=False, error=str(e)[:200])
            events.debug("llm error", model=model, error=str(e)[:200])
            return None
        trace.call_end(content, ok=True, thinking=thinking[:3000], **_metrics(timings, start, first))
        events.debug("llm", model=model, ms=round((time.monotonic() - start) * 1000),
                     tokens=(timings or {}).get("predicted_n"))
        CACHE_FILE.parent.mkdir(exist_ok=True)
        with open(CACHE_FILE, "a") as f:
            f.write(json.dumps({"k": key, "r": answer.model_dump()}, ensure_ascii=False) + "\n")
        cache[key] = answer.model_dump()
        return answer
    return None


def _root_config():
    import tomllib
    return tomllib.loads((RAIZ / "config.toml").read_text())


def _via_claude(text, schema, name, images):
    """Process with `--engine claude`: the same question goes to Claude (no GPU), under the [claude] cap."""
    from esteira.ai import claude
    from esteira.projeto import Projeto, pasta_ep
    ep = os.environ.get("ESTEIRA_EP")
    try:
        cfg = Projeto(pasta_ep(ep)).cfg if ep else _root_config()
    except (OSError, ValueError):
        cfg = _root_config()
    image = None
    if images:
        image = str(images[0])
    return claude.query(str(text), schema, cfg, ep, name, image=image)


def _data_url(path):
    """Image as a data URL (llama-server receives the image inside the message)."""
    mime = mimetypes.guess_type(str(path))[0] or "image/jpeg"
    return f"data:{mime};base64,{base64.b64encode(Path(path).read_bytes()).decode()}"


def free_gpu():
    """Unloads the llama.cpp models (Whisper and diffusion need the VRAM)."""
    before = llama.loaded()
    llama.unload()
    for model in before:
        events.debug("gpu: unloaded", model=model)
