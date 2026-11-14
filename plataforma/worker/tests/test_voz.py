from worker.voice import _ALUCINACOES, dividir_trechos, escolher_idioma, texto_para_fala


def test_texto_para_fala_tira_markdown_links_e_emojis() -> None:
    md = (
        "## Hoje\n- **Academia** às 7h 💪\n"
        "- Ver [[Meta 1|a meta]] e [o link](http://x.com)\n1. `Estudar`"
    )
    assert texto_para_fala(md, 500) == (
        "Hoje. Primeiro, Academia às 7 horas. Segundo, Ver a meta e o link. Primeiro, Estudar."
    )


def test_texto_para_fala_sem_simbolos_lidos_em_voz_alta() -> None:
    md = "Reunião 12/11 às 14:30 (sala 2); custa R$ 50,00 ou 10%... *ok* / #fim"
    t = texto_para_fala(md, 500)
    assert t == "Reunião 12 de novembro às 14 e 30, sala 2, custa 50 reais ou 10 por cento, ok fim."


def test_titulos_viram_topicos() -> None:
    t = texto_para_fala("## Treino\nPeito.\n## Estudo\n- Inglês\n- Python", 500)
    assert t == "Tópico 1, Treino. Peito. Tópico 2, Estudo. Primeiro, Inglês. Segundo, Python."


def test_dividir_trechos_comeca_curto() -> None:
    frases = "Primeira frase da resposta, já com um bom tamanho. "
    frases += "Outra frase do meio da fala. " * 12
    trechos = dividir_trechos(frases.strip())
    assert trechos[0] == "Primeira frase da resposta, já com um bom tamanho."
    assert len(trechos) > 2 and all(len(t) < 300 for t in trechos)


def test_texto_para_fala_corta_no_fim_da_frase() -> None:
    t = texto_para_fala("Primeira frase. " * 50, 100)
    assert len(t) <= 100 and t.endswith(".")


def test_alucinacoes_do_whisper() -> None:
    assert _ALUCINACOES.search("Legendas pela comunidade Amara.org")
    assert _ALUCINACOES.search("Obrigado.")
    assert not _ALUCINACOES.search("Obrigado pela ajuda com a agenda")
    assert _ALUCINACOES.search("Thanks for watching!")
    assert not _ALUCINACOES.search("Thank you for the help with the schedule")


def test_idioma_so_entre_os_aceitos() -> None:
    # Português do Brasil detectado como galego: fica o mais provável entre pt e en.
    probs = [("gl", 0.5), ("pt", 0.3), ("en", 0.1), ("es", 0.05)]
    assert escolher_idioma(probs, ["pt", "en"], "pt") == "pt"
    assert escolher_idioma([("en", 0.9), ("pt", 0.05)], ["pt", "en"], "pt") == "en"
    assert escolher_idioma([("ja", 1.0)], ["pt", "en"], "pt") == "pt"


def test_sem_arquivos_do_kokoro_cai_no_piper(tmp_path) -> None:
    from worker.core.config import WorkerSettings
    from worker.voice import Voz

    s = WorkerSettings(kokoro_modelo=str(tmp_path / "x.onnx"), kokoro_vozes=str(tmp_path / "v.bin"))
    assert Voz(s)._kokoro() is None


def test_sem_venv_do_xtts_cai_no_kokoro(tmp_path) -> None:
    from worker.core.config import WorkerSettings
    from worker.voice import Voz

    assert Voz(WorkerSettings(xtts_python=str(tmp_path / "python")))._xtts() is None
