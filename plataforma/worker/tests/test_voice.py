from worker.voice import _HALLUCINATIONS, choose_language, divide_spans, text_to_speech


def test_speech_text_strips_markdown_links_and_emojis() -> None:
    md = (
        "## Hoje\n- **Academia** às 7h 💪\n"
        "- Ver [[Meta 1|a meta]] e [o link](http://x.com)\n1. `Estudar`"
    )
    assert text_to_speech(md, 500) == (
        "Hoje. Primeiro, Academia às 7 horas. Segundo, Ver a meta e o link. Primeiro, Estudar."
    )


def test_speech_text_without_symbols_read_aloud() -> None:
    md = "Reunião 12/11 às 14:30 (sala 2); custa R$ 50,00 ou 10%... *ok* / #fim"
    t = text_to_speech(md, 500)
    assert t == "Reunião 12 de novembro às 14 e 30, sala 2, custa 50 reais ou 10 por cento, ok fim."


def test_headings_become_topics() -> None:
    t = text_to_speech("## Treino\nPeito.\n## Estudo\n- Inglês\n- Python", 500)
    assert t == "Tópico 1, Treino. Peito. Tópico 2, Estudo. Primeiro, Inglês. Segundo, Python."


def test_split_chunks_starts_short() -> None:
    sentences = "Primeira frase da resposta, já com um bom tamanho. "
    sentences += "Outra frase do meio da fala. " * 12
    spans = divide_spans(sentences.strip())
    assert spans[0] == "Primeira frase da resposta, já com um bom tamanho."
    assert len(spans) > 2 and all(len(t) < 300 for t in spans)


def test_speech_text_cuts_at_sentence_end() -> None:
    t = text_to_speech("Primeira frase. " * 50, 100)
    assert len(t) <= 100 and t.endswith(".")


def test_whisper_hallucinations() -> None:
    assert _HALLUCINATIONS.search("Legendas pela comunidade Amara.org")
    assert _HALLUCINATIONS.search("Obrigado.")
    assert not _HALLUCINATIONS.search("Obrigado pela ajuda com a agenda")
    assert _HALLUCINATIONS.search("Thanks for watching!")
    assert not _HALLUCINATIONS.search("Thank you for the help with the schedule")


def test_language_only_among_accepted() -> None:
    # Brazilian Portuguese detected as Galician: the most likely between pt and en stays.
    probs = [("gl", 0.5), ("pt", 0.3), ("en", 0.1), ("es", 0.05)]
    assert choose_language(probs, ["pt", "en"], "pt") == "pt"
    assert choose_language([("en", 0.9), ("pt", 0.05)], ["pt", "en"], "pt") == "en"
    assert choose_language([("ja", 1.0)], ["pt", "en"], "pt") == "pt"


def test_without_kokoro_files_falls_back_to_piper(tmp_path) -> None:
    from worker.core.config import WorkerSettings
    from worker.voice import Voice

    s = WorkerSettings(kokoro_modelo=str(tmp_path / "x.onnx"), kokoro_vozes=str(tmp_path / "v.bin"))
    assert Voice(s)._kokoro() is None


def test_without_xtts_venv_falls_back_to_kokoro(tmp_path) -> None:
    from worker.core.config import WorkerSettings
    from worker.voice import Voice

    assert Voice(WorkerSettings(xtts_python=str(tmp_path / "python")))._xtts() is None
