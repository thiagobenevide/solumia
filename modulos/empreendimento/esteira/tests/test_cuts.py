"""Casos dourados de cortes (gravação real do ep003, sem LLM): o que já funciona não pode quebrar."""
import json
from pathlib import Path

import pytest

from esteira import cuts as C

DADOS = Path(__file__).parent / "dados"


@pytest.fixture(scope="module")
def resultado():
    sentences = C.sentences_of_script((DADOS / "ep003_roteiro.txt").read_text())
    pal = json.loads((DADOS / "ep003_transcricao_bruta.json").read_text())["palavras"]
    spans, missing = C.decide(sentences, pal)
    return spans, missing


def _em(trechos, t):
    return next(x for x in trechos if x["ini"] <= t < x["fim"] + 0.01)


def test_quase_todas_as_frases_tem_tomada(resultado):
    _, missing = resultado
    assert len(missing) <= 2


def test_bastidor_sai(resultado):
    assert not _em(resultado[0], 2.5)["manter"]          # "Ok, vamos fazer agora uma nova gravação."
    assert not _em(resultado[0], 9.0)["manter"]          # "Dá um pouquinho d'água, né?"


def test_tomada_final_fica_e_retake_sai(resultado):
    t = resultado[0]
    assert not _em(t, 173.5)["manter"]                   # 1ª versão de "O juros é cobrado…"
    assert _em(t, 190.5)["manter"]                       # versão final
    assert not _em(t, 391.5)["manter"] and _em(t, 416.5)["manter"]   # regravado depois do "Droga."


def test_continuacao_e_reformulacao(resultado):
    t = resultado[0]
    assert _em(t, 432.5)["tipo"] == "continuacao"        # "fecha aspas."
    assert _em(t, 781.0)["tipo"] == "reformulada"        # "Faça uma lista." ≈ "faz a lista."


def test_retake_juntado_pelo_whisper_e_partido(resultado):
    t = resultado[0]
    assert not _em(t, 829.5)["manter"]                   # "paga o mínimo em todas…" repetido dentro de outra fala


def test_improviso_regravado_sai(resultado):
    t = resultado[0]
    assert not _em(t, 386.0)["manter"]                   # "Os autores chamam isso de..." (abandonado)
