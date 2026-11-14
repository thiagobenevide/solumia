import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from shared.speech_text import align_word_times, compare_reading, split_words
from studies.language import Language, extract_json, note_of, review


def test_words_keep_position() -> None:
    assert split_words("Deep-learning isn't new.") == [
        ("Deep-learning", 0, 13),
        ("isn't", 14, 19),
        ("new", 20, 23),
    ]


def test_align_word_times_interpolates_what_whisper_missed() -> None:
    spoken = [
        {"palavra": "The", "inicio": 0.0, "fim": 0.2},
        {"palavra": "works.", "inicio": 0.8, "fim": 1.2},
    ]
    t = align_word_times("The method works", spoken, 1.5)
    assert [(x["inicio"], x["fim"]) for x in t] == [(0, 3), (4, 10), (11, 16)]
    assert t[1]["t0"] == pytest.approx(0.2) and t[1]["t1"] == pytest.approx(0.8)
    # nothing recognized: time proportional to length
    sem = align_word_times("ab abcd", [], 3.0)
    assert sem[0]["t1"] == pytest.approx(1.0) and sem[1]["t1"] == pytest.approx(3.0)


def test_compare_reading() -> None:
    spoken = [
        {"palavra": "The", "inicio": 0.0, "fim": 0.3, "prob": 0.9},
        {"palavra": "metod", "inicio": 0.4, "fim": 0.8, "prob": 0.4},
        {"palavra": "really", "inicio": 2.0, "fim": 2.4, "prob": 0.9},
        {"palavra": "works", "inicio": 2.5, "fim": 3.0, "prob": 0.9},
    ]
    r = compare_reading("The method works well.", spoken)
    states = [p["estado"] for p in r["palavras"]]
    assert states == ["certa", "trocada", "certa", "omitida"]
    assert r["palavras"][1]["dita"] == "metod"
    assert r["extras"] == ["really"]
    assert r["precisao"] == 50.0 and r["pausas"] == 1 and r["ppm"] == 80


def test_fsrs_grows_interval_and_miss_comes_back_soon() -> None:
    t0 = datetime(2026, 1, 1, tzinfo=UTC)
    c = review({}, 3, t0)
    assert c["proxima"] == (t0 + timedelta(days=4)).isoformat(timespec="seconds")
    c2 = review(c, 3, t0 + timedelta(days=4))
    assert c2["estabilidade"] > c["estabilidade"] * 2
    c3 = review(c2, 1, t0 + timedelta(days=20))
    assert c3["estabilidade"] < c2["estabilidade"] and c3["lapsos"] == 1
    assert note_of(40) == 1 and note_of(95) == 4


def test_extract_json_ignores_thinking() -> None:
    assert extract_json('<think>{"x": 0}</think>Aqui: {"a": 1} fim') == {"a": 1}


class _LLMFalsa:
    def __init__(self) -> None:
        self.requests: list[str] = []

    async def __call__(self, mensagens: list[dict[str, str]]) -> str:
        p = mensagens[-1]["content"]
        self.requests.append(p)
        if "Translate the excerpt" in p:
            return json.dumps(
                {
                    "traducao": "método",
                    "classe": "substantivo",
                    "ipa": "ˈmɛθəd",
                    "sentido": "forma de fazer",
                    "frase_traduzida": "O método funciona.",
                }
            )
        if "Create material" in p:
            return "Claro! " + json.dumps(
                {
                    "frases": [
                        {"texto": "This method is new.", "traducao": "Novo.", "nivel": "A2"}
                    ],
                    "exercicios": [
                        {"tipo": "lacuna", "enunciado": "The ____ works.", "resposta": "method"},
                        {"tipo": "producao", "enunciado": "Use em uma frase.", "resposta": ""},
                        {"tipo": "invalido", "enunciado": "x"},
                    ],
                }
            )
        if " exercise about " in p:
            return json.dumps({"correto": True, "nota": 75, "correcao": "ok", "explicacao": ""})
        if "writing task" in p:
            return json.dumps(
                {
                    "titulo": "Sobre o artigo",
                    "perguntas": [{"pergunta": "What is the main idea?", "tipo": "compreensao"}],
                }
            )
        return json.dumps(
            {
                "nota": 82,
                "gramatica": 80,
                "vocabulario": 90,
                "coerencia": 85,
                "adequacao": 70,
                "nivel_cefr": "B2",
                "texto_corrigido": "It works.",
                "correcoes": [{"trecho": "work", "correcao": "works", "explicacao": "3ª pessoa"}],
                "comentario": "Bom",
            }
        )


async def _worker(tarefa: str, payload: dict[str, Any]) -> dict[str, Any]:
    if tarefa == "falar_marcado":
        return {
            "audio_b64": "AAAA",
            "mime": "audio/mp4",
            "duracao": 1.0,
            "palavras": align_word_times(payload["texto"], [], 1.0),
        }
    return {
        "palavras": [
            {"palavra": "The", "inicio": 0.0, "fim": 0.3, "prob": 0.9},
            {"palavra": "method", "inicio": 0.4, "fim": 0.9, "prob": 0.8},
        ],
        "pronuncia": [
            {"indice": 0, "esperado": "ðə", "ouvido": "də", "acerto": 0.5},
            {"indice": 1, "esperado": "mɛθəd", "ouvido": "mɛθəd", "acerto": 1.0},
        ],
        "aviso": "",
    }


@pytest.fixture
def api(tmp_path: Path) -> tuple[TestClient, _LLMFalsa]:
    s = Settings(client_api_keys=CLIENT_API_KEY, estudos_dir=str(tmp_path), notas_dir=str(tmp_path))
    app = create_app(settings=s)
    llm = _LLMFalsa()
    app.state.linguagem = Language(
        tmp_path, chat=llm, worker=_worker, somar_minutos=app.state.studies.add_up_minutes
    )
    return TestClient(app, headers=AUTH_HEADERS), llm


def test_speech_and_translation_with_cache(api: tuple[TestClient, _LLMFalsa]) -> None:
    c, llm = api
    r = c.post("/api/estudos/linguagem/fala", json={"texto": "The  method", "idioma": "en"}).json()
    assert r["texto"] == "The method" and [p["inicio"] for p in r["palavras"]] == [0, 4]
    body = {"termo": "method", "frase": "The method works.", "idioma": "en"}
    assert c.post("/api/estudos/linguagem/traduzir", json=body).json()["traducao"] == "método"
    c.post("/api/estudos/linguagem/traduzir", json=body)
    assert len(llm.requests) == 1


def test_vocabulary_practice_and_review(api: tuple[TestClient, _LLMFalsa]) -> None:
    c, _ = api
    base = "/api/estudos/linguagem/vocabulario"
    new = {"termo": "method", "idioma": "en", "contexto": "The method works.", "pagina": 2}
    item = c.post(base, json=new).json()
    # generated in the background (TestClient runs the BackgroundTasks before returning)
    item = next(v for v in c.get(base).json() if v["id"] == item["id"])
    assert len(item["frases"]) == 1 and [e["tipo"] for e in item["exercicios"]] == [
        "lacuna",
        "producao",
    ]
    # the same word again merges the context
    mais = c.post(base, json={**new, "termo": "Method", "contexto": "A new method."}).json()
    assert mais["id"] == item["id"] and len(mais["contextos"]) == 2
    assert len(c.get(f"{base}?devidas=true&idioma=en").json()) == 1
    r = c.post(f"{base}/{item['id']}/responder", json={"indice": 0, "resposta": "Method"}).json()
    assert r["correcao"]["nota"] == 100 and r["item"]["cartao"]["revisoes"] == 1
    r = c.post(f"{base}/{item['id']}/responder", json={"indice": 1, "resposta": "I like it."})
    assert r.json()["correcao"]["nota"] == 75
    assert c.get(f"{base}?devidas=true").json() == []
    assert c.post(f"{base}/{item['id']}/revisar", json={"nota": 1}).status_code == 200
    assert (
        c.post(f"{base}/{item['id']}/responder", json={"indice": 9, "resposta": "x"}).status_code
        == 404
    )


def test_corrected_writing(api: tuple[TestClient, _LLMFalsa]) -> None:
    c, _ = api
    e = c.post("/api/estudos/linguagem/escritas", json={"idioma": "en", "texto": "Paper."})
    assert e.status_code == 201 and e.json()["perguntas"][0]["pergunta"].startswith("What")
    r = c.post(
        f"/api/estudos/linguagem/escritas/{e.json()['id']}/responder",
        json={"indice": 0, "resposta": "It work very well."},
    ).json()
    assert r["respostas"]["0"]["nota"] == 82 and r["respostas"]["0"]["nivel_cefr"] == "B2"
    p = c.get("/api/estudos/linguagem/progresso?idioma=en").json()
    assert p["escrita"][0]["nota"] == 82


def test_reading_aloud_and_activity(api: tuple[TestClient, _LLMFalsa]) -> None:
    c, _ = api
    r = c.post(
        "/api/estudos/linguagem/leituras-voz",
        files={"audio": ("fala.wav", b"RIFF", "audio/wav")},
        data={"idioma": "en", "referencia": "The method works.", "pagina": "3"},
    ).json()
    assert r["precisao"] == pytest.approx(66.7) and r["pronuncia"] == 75.0
    assert r["palavras"][0]["fonemas"]["ouvido"] == "də" and r["pagina"] == 3
    t = c.post(
        "/api/estudos/idiomas", json={"idioma": "en", "nivel_inicial": "B1", "nivel_alvo": "C1"}
    ).json()
    a = {"tipo": "leitura_guiada", "idioma": "en", "minutos": 12, "detalhes": {"consultas": 3}}
    assert c.post("/api/estudos/linguagem/atividades", json=a).status_code == 201
    assert c.get(f"/api/estudos/idiomas/{t['id']}").json()["sessoes_feitas"] == 1
    p = c.get("/api/estudos/linguagem/progresso?idioma=en").json()
    assert p["minutos"] == {"leitura_guiada": 12} and p["leitura_voz"][0]["pronuncia"] == 75.0


def test_without_worker_answers_503(tmp_path: Path) -> None:
    s = Settings(client_api_keys=CLIENT_API_KEY, estudos_dir=str(tmp_path), notas_dir=str(tmp_path))
    c = TestClient(create_app(settings=s), headers=AUTH_HEADERS)
    r = c.post("/api/estudos/linguagem/fala", json={"texto": "Hi", "idioma": "en"})
    assert r.status_code == 503
