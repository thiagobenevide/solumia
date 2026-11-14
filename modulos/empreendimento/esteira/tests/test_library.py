"""Acervo de mídia (registro, busca, filtros de reuso) e sincronia WAV × câmera do modo apresentador."""
import subprocess

import numpy as np
import pytest

from esteira import library, production


@pytest.fixture
def acervo_tmp(tmp_path, monkeypatch):
    monkeypatch.setattr(library, "pasta", lambda: tmp_path)
    library._conexoes.clear()
    yield tmp_path
    library._conexoes.clear()


def _imagem(destino, w=1920, h=1080):
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", f"color=c=blue:s={w}x{h}",
                    "-frames:v", "1", str(destino)], check=True)


def test_registra_busca_e_filtra(acervo_tmp, tmp_path):
    for k, termo in enumerate(["credit card debt", "city skyline night", "credit card payment terminal"]):
        arq = tmp_path / f"bruto{k}.jpg"
        _imagem(arq)
        library.registrar({"id": f"pexels-f{k}", "tipo": "imagem", "credito": "x", "tags": "money"}, arq, termo)
    achados = [r["id"] for r in library.procurar(["credit card"], "imagem", "paisagem")]
    assert set(achados) == {"pexels-f0", "pexels-f2"}
    assert library.procurar(["credit card"], "imagem", "retrato") == []  # orientação errada
    assert library.procurar(["credit card"], "video", "paisagem") == []  # tipo errado
    # usado 2x no canal: sai; reprovado pelo modelo de visão para o termo: sai
    library.marcar_uso("pexels-f0", "finlumia", "finlumia-001", 1)
    library.marcar_uso("pexels-f0", "finlumia", "finlumia-002", 4)
    library.salvar_avaliacao("pexels-f2", "credit card", 2)
    assert library.procurar(["credit card"], "imagem", "paisagem", canal="finlumia") == []
    assert [r["id"] for r in library.procurar(["credit card"], "imagem", "paisagem", canal="outro")] == ["pexels-f0"]
    # o mesmo id registrado de novo só acrescenta o termo
    _imagem(tmp_path / "de_novo.jpg")
    library.registrar({"id": "pexels-f1", "tipo": "imagem"}, tmp_path / "de_novo.jpg", "urban lights")
    assert library.item("pexels-f1")["termos"].count("urban lights") == 1
    assert [r["id"] for r in library.procurar(["urban lights"], "imagem", "paisagem")] == ["pexels-f1"]


def test_sincronia_acha_o_atraso(tmp_path):
    rng = np.random.default_rng(1)
    voz = np.repeat(rng.random(400) > 0.6, 800).astype(np.float32) * rng.standard_normal(320000).astype(np.float32)
    atraso = 13600  # 1,7 s a 8 kHz
    cam = np.concatenate([np.zeros(atraso, np.float32), voz])[:len(voz)]
    for nome, x in (("wav.wav", voz), ("cam.wav", cam)):
        subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-f", "f32le", "-ar", "8000", "-ac", "1",
                        "-i", "-", str(tmp_path / nome)], input=(x * 0.3).tobytes(), check=True)
    offset, conf = production.sincronizar(tmp_path / "wav.wav", tmp_path / "cam.wav")
    assert offset == pytest.approx(1.7, abs=0.02) and conf > 0.5
