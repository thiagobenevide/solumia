"""Alinhamento forçado (roda no `.venv-img`, que tem PyTorch): texto conhecido + áudio → início/fim de cada palavra
com erro de ~20–40 ms (o Whisper erra 100–300 ms). Modelo CTC de português (wav2vec2) e Viterbi sobre a topologia
CTC (com brancos); o áudio vai em trechos de até MAX_TRECHO s em volta dos tempos do Whisper.

Uso: python alinhar_ctc.py pedido.json → JSON na saída padrão: [[ini, fim] | null] por palavra.
pedido: {"audio": caminho (16 kHz mono f32le cru), "palavras": [[ini, fim, texto]], "modelo": id do Hugging Face}
"""
import json
import sys
import unicodedata

import numpy as np
import torch
from transformers import AutoModelForCTC, Wav2Vec2Processor

SR = 16000
MAX_TRECHO, MARGEM, VAO = 25.0, 0.5, 1.2   # s


def _limpo(texto, vocab):
    t = texto.lower()
    saida = "".join(c for c in t if c in vocab)
    if not saida:  # acento fora do vocabulário: tenta sem acento
        t = "".join(c for c in unicodedata.normalize("NFD", t) if not unicodedata.combining(c))
        saida = "".join(c for c in t if c in vocab)
    return saida


def _viterbi(lp, rotulos, branco):
    """lp: (T, V) log-probabilidades; rotulos: ids. → estado (índice na sequência estendida) por quadro, ou None."""
    z = [branco]
    for r in rotulos:
        z += [r, branco]
    T, S = lp.shape[0], len(z)
    if len(rotulos) > T:
        return None
    z = np.array(z)
    pula = np.zeros(S, bool)
    pula[2:] = (z[2:] != branco) & (z[2:] != z[:-2])
    neg = -1e30
    a = np.full(S, neg)
    a[0], a[1] = lp[0, z[0]], lp[0, z[1]]
    volta = np.zeros((T, S), np.int8)
    for t in range(1, T):
        fica, um = a, np.concatenate([[neg], a[:-1]])
        dois = np.where(pula, np.concatenate([[neg, neg], a[:-2]]), neg)
        op = np.stack([fica, um, dois])
        k = op.argmax(0)
        volta[t] = k
        a = op[k, np.arange(S)] + lp[t, z]
    s = S - 1 if a[S - 1] >= a[S - 2] else S - 2
    caminho = np.empty(T, int)
    for t in range(T - 1, -1, -1):
        caminho[t] = s
        s -= int(volta[t, s])  # int8 com int do Python estoura no NumPy 2
    return caminho


def _trechos(palavras, dur):
    grupo = []
    for k, (ini, fim, _) in enumerate(palavras):
        if grupo and (fim - palavras[grupo[0]][0] > MAX_TRECHO or ini - palavras[grupo[-1]][1] > VAO):
            yield grupo
            grupo = []
        grupo.append(k)
    if grupo:
        yield grupo


def alinhar(x, palavras, modelo, proc, disp):
    vocab = proc.tokenizer.get_vocab()
    branco = proc.tokenizer.pad_token_id
    sep = vocab.get("|")
    saida = [None] * len(palavras)
    dur = len(x) / SR
    for grupo in _trechos(palavras, dur):
        t0 = max(0.0, palavras[grupo[0]][0] - MARGEM)
        t1 = min(dur, palavras[grupo[-1]][1] + MARGEM)
        y = x[int(t0 * SR):int(t1 * SR)]
        if len(y) < SR // 10:
            continue
        ent = proc(y, sampling_rate=SR, return_tensors="pt").input_values.to(disp, next(modelo.parameters()).dtype)
        with torch.inference_mode():
            lp = torch.log_softmax(modelo(ent).logits[0].float(), -1).cpu().numpy()
        passo = (t1 - t0) / lp.shape[0]
        rotulos, dono = [], []
        for k in grupo:
            letras = _limpo(palavras[k][2], vocab)
            if not letras:
                continue
            if rotulos and sep is not None:
                rotulos.append(sep)
                dono.append(None)
            for c in letras:
                rotulos.append(vocab[c])
                dono.append(k)
        if not rotulos:
            continue
        caminho = _viterbi(lp, rotulos, branco)
        if caminho is None:
            continue
        quadros = {}
        for t, s in enumerate(caminho):
            if s % 2 and dono[(s - 1) // 2] is not None:
                quadros.setdefault(dono[(s - 1) // 2], []).append(t)
        for k, qs in quadros.items():
            saida[k] = [round(t0 + qs[0] * passo, 3), round(t0 + (qs[-1] + 1) * passo, 3)]
    return saida


# Só modelos conhecidos são baixados do Hugging Face; o nome vem do arquivo de pedido.
MODELOS_PERMITIDOS = {"jonatasgrosman/wav2vec2-large-xlsr-53-portuguese"}


def main():
    with open(sys.argv[1]) as f:
        pedido = json.load(f)
    nome = pedido["modelo"]
    if nome not in MODELOS_PERMITIDOS:
        permitidos = ", ".join(sorted(MODELOS_PERMITIDOS))
        sys.exit(f"modelo não permitido: {nome} (permitidos: {permitidos})")
    disp = "cuda" if torch.cuda.is_available() else "cpu"
    proc = Wav2Vec2Processor.from_pretrained(nome)  # o Auto pega o ProcessorWithLM (pyctcdecode)
    modelo = AutoModelForCTC.from_pretrained(nome, trust_remote_code=False).to(disp).eval()
    if disp == "cuda":
        modelo = modelo.half()
    x = np.fromfile(pedido["audio"], np.float32)
    print(json.dumps(alinhar(x, pedido["palavras"], modelo, proc, disp)))


if __name__ == "__main__":
    main()
