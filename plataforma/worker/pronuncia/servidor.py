"""Pronúncia por fonema num processo à parte (o torch vive no venv do XTTS, que fixa um cuDNN
diferente do faster-whisper do worker). Modelo wav2vec2 que ouve fonemas do espeak (IPA).

Protocolo por linhas JSON: entra {"audio": <.npy float32 16 kHz>, "ipa": [IPA esperado de cada
palavra]}, sai {"palavras": [{"esperado", "ouvido", "acerto"}]} ou {"erro"}; a primeira linha,
{"pronto": true}, avisa que o modelo carregou."""

import difflib
import json
import sys

MODELO = "facebook/wav2vec2-lv-60-espeak-cv-ft"


def tokenizar(ipa: str, simbolos: list[str]) -> list[str]:
    """IPA → fonemas do vocabulário do modelo, pelo mais longo que casa (tônicas e espaços saem)."""
    saida, i = [], 0
    while i < len(ipa):
        achou = next((s for s in simbolos if ipa.startswith(s, i)), None)
        if achou:
            saida.append(achou)
            i += len(achou)
        else:
            i += 1
    return saida


def comparar(esperados: list[list[str]], ouvidos: list[str]) -> list[dict[str, object]]:
    """Acerto de cada palavra: fonemas esperados que o modelo ouviu na mesma ordem."""
    plano = [(w, f) for w, fonemas in enumerate(esperados) for f in fonemas]
    acertos = [0] * len(esperados)
    ouvido: list[list[str]] = [[] for _ in esperados]
    matcher = difflib.SequenceMatcher(None, [f for _, f in plano], ouvidos, autojunk=False)
    for op, i1, i2, j1, j2 in matcher.get_opcodes():
        if op == "equal":
            for k in range(i2 - i1):
                acertos[plano[i1 + k][0]] += 1
                ouvido[plano[i1 + k][0]].append(ouvidos[j1 + k])
        elif op in ("replace", "insert") and j2 > j1 and plano:
            dono = plano[min(i1, len(plano) - 1)][0]
            ouvido[dono] += ouvidos[j1:j2]
    return [
        {
            "esperado": "".join(f),
            "ouvido": "".join(ouvido[w]),
            "acerto": round(acertos[w] / len(f), 2) if f else 1.0,
        }
        for w, f in enumerate(esperados)
    ]


def main() -> None:
    canal, sys.stdout = sys.stdout, sys.stderr
    import numpy as np
    import torch
    from huggingface_hub import hf_hub_download
    from transformers import AutoModelForCTC, Wav2Vec2FeatureExtractor

    dispositivo = "cuda" if torch.cuda.is_available() else "cpu"
    modelo = AutoModelForCTC.from_pretrained(MODELO).to(dispositivo).eval()
    extrator = Wav2Vec2FeatureExtractor.from_pretrained(MODELO)
    with open(hf_hub_download(MODELO, "vocab.json"), encoding="utf-8") as f:
        vocab: dict[str, int] = json.load(f)
    por_id = {i: t for t, i in vocab.items()}
    especiais = {t for t in vocab if t.startswith("<") or t in ("|", " ", "")}
    simbolos = sorted((t for t in vocab if t not in especiais), key=len, reverse=True)
    print(json.dumps({"pronto": True}), file=canal, flush=True)
    for linha in sys.stdin:
        try:
            pedido = json.loads(linha)
            audio = np.load(pedido["audio"])
            entrada = extrator(audio, sampling_rate=16000, return_tensors="pt").input_values
            with torch.inference_mode():
                ids = modelo(entrada.to(dispositivo)).logits.argmax(-1)[0].tolist()
            ouvidos, anterior = [], None
            for i in ids:  # CTC: junta repetidos e tira o vazio
                if i != anterior and por_id.get(i, "<pad>") not in especiais:
                    ouvidos.append(por_id[i])
                anterior = i
            esperados = [tokenizar(ipa, simbolos) for ipa in pedido["ipa"]]
            resposta: dict[str, object] = {"palavras": comparar(esperados, ouvidos)}
        except Exception as e:
            resposta = {"erro": str(e)}
        print(json.dumps(resposta, ensure_ascii=False), file=canal, flush=True)


if __name__ == "__main__":
    main()
