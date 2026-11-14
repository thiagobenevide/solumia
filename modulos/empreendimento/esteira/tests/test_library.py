"""Acervo de mídia (registro, busca, filtros de reuso) e sincronia WAV × câmera do modo apresentador."""
import subprocess

import numpy as np
import pytest

from esteira import library, production


@pytest.fixture
def library_tmp(tmp_path, monkeypatch):
    monkeypatch.setattr(library, "folder", lambda: tmp_path)
    library._connections.clear()
    yield tmp_path
    library._connections.clear()


def _image(destination, w=1920, h=1080):
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", f"color=c=blue:s={w}x{h}",
                    "-frames:v", "1", str(destination)], check=True)


def test_records_search_and_filters(library_tmp, tmp_path):
    for k, term in enumerate(["credit card debt", "city skyline night", "credit card payment terminal"]):
        file = tmp_path / f"bruto{k}.jpg"
        _image(file)
        library.register({"id": f"pexels-f{k}", "tipo": "imagem", "credito": "x", "tags": "money"}, file, term)
    found = [r["id"] for r in library.search(["credit card"], "imagem", "paisagem")]
    assert set(found) == {"pexels-f0", "pexels-f2"}
    assert library.search(["credit card"], "imagem", "retrato") == []  # orientação errada
    assert library.search(["credit card"], "video", "paisagem") == []  # tipo errado
    # usado 2x no canal: sai; reprovado pelo modelo de visão para o termo: sai
    library.mark_usage("pexels-f0", "finlumia", "finlumia-001", 1)
    library.mark_usage("pexels-f0", "finlumia", "finlumia-002", 4)
    library.save_evaluation("pexels-f2", "credit card", 2)
    assert library.search(["credit card"], "imagem", "paisagem", channel="finlumia") == []
    assert [r["id"] for r in library.search(["credit card"], "imagem", "paisagem", channel="outro")] == ["pexels-f0"]
    # o mesmo id registrado de novo só acrescenta o termo
    _image(tmp_path / "de_novo.jpg")
    library.register({"id": "pexels-f1", "tipo": "imagem"}, tmp_path / "de_novo.jpg", "urban lights")
    assert library.item("pexels-f1")["termos"].count("urban lights") == 1
    assert [r["id"] for r in library.search(["urban lights"], "imagem", "paisagem")] == ["pexels-f1"]


def test_sync_finds_delay(tmp_path):
    rng = np.random.default_rng(1)
    voice = np.repeat(rng.random(400) > 0.6, 800).astype(np.float32) * rng.standard_normal(320000).astype(np.float32)
    delay = 13600  # 1,7 s a 8 kHz
    cam = np.concatenate([np.zeros(delay, np.float32), voice])[:len(voice)]
    for name, x in (("wav.wav", voice), ("cam.wav", cam)):
        subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-f", "f32le", "-ar", "8000", "-ac", "1",
                        "-i", "-", str(tmp_path / name)], input=(x * 0.3).tobytes(), check=True)
    offset, conf = production.sync(tmp_path / "wav.wav", tmp_path / "cam.wav")
    assert offset == pytest.approx(1.7, abs=0.02) and conf > 0.5
