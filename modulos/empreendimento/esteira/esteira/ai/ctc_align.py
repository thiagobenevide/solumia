"""Forced alignment (runs in `.venv-img`, which has PyTorch): known text + audio → start/end of each word with an
error of ~20–40 ms (Whisper misses by 100–300 ms). Portuguese CTC model (wav2vec2) and Viterbi over the CTC
topology (with blanks); the audio goes in chunks of up to MAX_CHUNK s around the Whisper times.

Usage: python ctc_align.py request.json → JSON on standard output: [[start, end] | null] per word.
request: {"audio": path (raw 16 kHz mono f32le), "words": [[start, end, text]], "model": Hugging Face id}
"""
import json
import sys
import unicodedata

import numpy as np
import torch
from transformers import AutoModelForCTC, Wav2Vec2Processor

SR = 16000
MAX_CHUNK, MARGIN, GAP = 25.0, 0.5, 1.2   # s


def _clean(text, vocab):
    t = text.lower()
    output = "".join(c for c in t if c in vocab)
    if not output:  # accent outside the vocabulary: try without it
        t = "".join(c for c in unicodedata.normalize("NFD", t) if not unicodedata.combining(c))
        output = "".join(c for c in t if c in vocab)
    return output


def _viterbi(lp, labels, blank):
    """lp: (T, V) log-probabilities; labels: ids. → state (index in the extended sequence) per frame, or None."""
    z = [blank]
    for r in labels:
        z += [r, blank]
    T, S = lp.shape[0], len(z)
    if len(labels) > T:
        return None
    z = np.array(z)
    skip = np.zeros(S, bool)
    skip[2:] = (z[2:] != blank) & (z[2:] != z[:-2])
    neg = -1e30
    a = np.full(S, neg)
    a[0], a[1] = lp[0, z[0]], lp[0, z[1]]
    back = np.zeros((T, S), np.int8)
    for t in range(1, T):
        stay, one = a, np.concatenate([[neg], a[:-1]])
        two = np.where(skip, np.concatenate([[neg, neg], a[:-2]]), neg)
        op = np.stack([stay, one, two])
        k = op.argmax(0)
        back[t] = k
        a = op[k, np.arange(S)] + lp[t, z]
    s = S - 1 if a[S - 1] >= a[S - 2] else S - 2
    path = np.empty(T, int)
    for t in range(T - 1, -1, -1):
        path[t] = s
        s -= int(back[t, s])  # int8 with a Python int overflows on NumPy 2
    return path


def _chunks(words, duration):
    group = []
    for k, (start, end, _) in enumerate(words):
        if group and (end - words[group[0]][0] > MAX_CHUNK or start - words[group[-1]][1] > GAP):
            yield group
            group = []
        group.append(k)
    if group:
        yield group


def align(x, words, model, process, device):
    vocab = process.tokenizer.get_vocab()
    blank = process.tokenizer.pad_token_id
    sep = vocab.get("|")
    output = [None] * len(words)
    duration = len(x) / SR
    for group in _chunks(words, duration):
        t0 = max(0.0, words[group[0]][0] - MARGIN)
        t1 = min(duration, words[group[-1]][1] + MARGIN)
        y = x[int(t0 * SR):int(t1 * SR)]
        if len(y) < SR // 10:
            continue
        inputs = process(y, sampling_rate=SR, return_tensors="pt").input_values.to(device, next(model.parameters()).dtype)
        with torch.inference_mode():
            lp = torch.log_softmax(model(inputs).logits[0].float(), -1).cpu().numpy()
        step = (t1 - t0) / lp.shape[0]
        labels, owner = [], []
        for k in group:
            letters = _clean(words[k][2], vocab)
            if not letters:
                continue
            if labels and sep is not None:
                labels.append(sep)
                owner.append(None)
            for c in letters:
                labels.append(vocab[c])
                owner.append(k)
        if not labels:
            continue
        path = _viterbi(lp, labels, blank)
        if path is None:
            continue
        frames = {}
        for t, s in enumerate(path):
            if s % 2 and owner[(s - 1) // 2] is not None:
                frames.setdefault(owner[(s - 1) // 2], []).append(t)
        for k, qs in frames.items():
            output[k] = [round(t0 + qs[0] * step, 3), round(t0 + (qs[-1] + 1) * step, 3)]
    return output


# Only known models are downloaded from Hugging Face; the name comes from the request file.
ALLOWED_MODELS = {"jonatasgrosman/wav2vec2-large-xlsr-53-portuguese"}


def main():
    with open(sys.argv[1]) as f:
        request = json.load(f)
    name = request["model"]
    if name not in ALLOWED_MODELS:
        allowed = ", ".join(sorted(ALLOWED_MODELS))
        sys.exit(f"model not allowed: {name} (allowed: {allowed})")
    device = "cuda" if torch.cuda.is_available() else "cpu"
    process = Wav2Vec2Processor.from_pretrained(name)  # the Auto class picks ProcessorWithLM (pyctcdecode)
    model = AutoModelForCTC.from_pretrained(name, trust_remote_code=False).to(device).eval()
    if device == "cuda":
        model = model.half()
    x = np.fromfile(request["audio"], np.float32)
    print(json.dumps(align(x, request["words"], model, process, device)))


if __name__ == "__main__":
    main()
