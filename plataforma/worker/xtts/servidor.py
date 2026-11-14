"""Fala com XTTS-v2 num processo à parte (venv próprio: o torch dele fixa um cuDNN diferente do
faster-whisper do worker). Protocolo por linhas JSON: entra {"texto", "saida"}, sai {"ok"} ou
{"erro"}; a primeira linha de saída, {"pronto": true}, avisa que o modelo carregou.

Uso: servidor.py <locutora> <idioma> [referencia.wav]: com a gravação de referência (10–30 s de
uma voz brasileira) a fala clona esse sotaque em vez do da locutora embutida."""

import json
import os
import re
import sys

os.environ.setdefault("COQUI_TOS_AGREED", "1")  # licença CPML: uso pessoal, não comercial


# Temperatura baixa: entonação e sotaque estáveis (o padrão 0,75 oscila entre pt-BR e pt-PT).
_AJUSTES = {"temperature": 0.45, "top_p": 0.8, "top_k": 30, "repetition_penalty": 8.0}


def frases(texto: str) -> list[str]:
    """Uma frase por vez e sem o ponto final: o XTTS lê o "." do fim como "ponto"."""
    return [f.rstrip(".").strip() for f in re.split(r"(?<=[.!?])\s+", texto) if f.strip(" .")]


def main() -> None:
    voz, idioma = sys.argv[1], sys.argv[2]
    referencia = sys.argv[3] if len(sys.argv) > 3 and os.path.isfile(sys.argv[3]) else None
    # O stdout é o canal do protocolo: o que a biblioteca imprime vai para o stderr.
    canal, sys.stdout = sys.stdout, sys.stderr
    import torch
    from TTS.api import TTS

    tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(
        "cuda" if torch.cuda.is_available() else "cpu"
    )
    print(json.dumps({"pronto": True}), file=canal, flush=True)
    import numpy as np

    taxa = tts.synthesizer.output_sample_rate
    pausa = np.zeros(int(taxa * 0.18), dtype=np.float32)
    locutor = {"speaker_wav": referencia} if referencia else {"speaker": voz}
    for linha in sys.stdin:
        try:
            pedido = json.loads(linha)
            partes: list[np.ndarray] = []
            for frase in frases(pedido["texto"]) or ["Pronto"]:
                wav = tts.tts(frase, language=idioma, split_sentences=False, **locutor, **_AJUSTES)
                partes += [np.asarray(wav, dtype=np.float32), pausa]
            tts.synthesizer.save_wav(np.concatenate(partes[:-1]), pedido["saida"])
            resposta = {"ok": True}
        except Exception as e:
            resposta = {"erro": str(e)}
        print(json.dumps(resposta), file=canal, flush=True)


if __name__ == "__main__":
    main()
