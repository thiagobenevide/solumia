"""Casos dourados de cortes (gravação real do ep003, sem LLM): o que já funciona não pode quebrar."""
import json
from pathlib import Path

import pytest

from esteira import cuts as C

DATA_DIR = Path(__file__).parent / "dados"


@pytest.fixture(scope="module")
def result():
    sentences = C.sentences_of_script((DATA_DIR / "ep003_roteiro.txt").read_text())
    pal = json.loads((DATA_DIR / "ep003_transcricao_bruta.json").read_text())["palavras"]
    spans, missing = C.decide(sentences, pal)
    return spans, missing


def _at(segments, t):
    return next(x for x in segments if x["ini"] <= t < x["fim"] + 0.01)


def test_almost_every_sentence_has_take(result):
    _, missing = result
    assert len(missing) <= 2


def test_backstage_talk_goes(result):
    assert not _at(result[0], 2.5)["manter"]          # "Ok, vamos fazer agora uma nova gravação."
    assert not _at(result[0], 9.0)["manter"]          # "Dá um pouquinho d'água, né?"


def test_final_take_stays_and_retake_goes(result):
    t = result[0]
    assert not _at(t, 173.5)["manter"]                   # 1ª versão de "O juros é cobrado…"
    assert _at(t, 190.5)["manter"]                       # versão final
    assert not _at(t, 391.5)["manter"] and _at(t, 416.5)["manter"]   # regravado depois do "Droga."


def test_continuacao_e_reformulacao(result):
    t = result[0]
    assert _at(t, 432.5)["tipo"] == "continuacao"        # "fecha aspas."
    assert _at(t, 781.0)["tipo"] == "reformulada"        # "Faça uma lista." ≈ "faz a lista."


def test_retake_merged_by_whisper_is_split(result):
    t = result[0]
    assert not _at(t, 829.5)["manter"]                   # "paga o mínimo em todas…" repetido dentro de outra fala


def test_improviso_regravado_sai(result):
    t = result[0]
    assert not _at(t, 386.0)["manter"]                   # "Os autores chamam isso de..." (abandonado)
