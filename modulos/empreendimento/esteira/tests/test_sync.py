"""Regras novas dos cortes e dos gráficos tiradas dos erros do ep004: número partido pelo Whisper, borda do corte
no silêncio, começo abandonado, retake que sobrou na narração editada, número ancorado na fala e fila de números."""
import numpy as np

from esteira import cuts as C
from esteira.graphics import plan


def _p(texto, t0=0.0, passo=0.4):
    return [{"p": w, "ini": round(t0 + k * passo, 3), "fim": round(t0 + k * passo + 0.3, 3)}
            for k, w in enumerate(texto.split())]


def test_numero_partido_pelo_whisper_casa_com_o_roteiro():
    # roteiro "12,5%" × Whisper "12" ",5" "%": antes a tomada começava em "das" e o número era cortado
    sentences = C.sentences_of_script("Hoje 12,5% das famílias dizem que não vão pagar.")
    pal = _p("Hoje 12 ,5 % das famílias dizem que não vão pagar.")
    choices, _, _ = C.choose(sentences, pal)
    i, j, note, _ = choices[0]
    assert i == 0 and note > 0.9


def _env(pedacos, total=4.0):
    """Envelope sintético: fala (-20 dB) nos intervalos dados, silêncio (-70 dB) no resto."""
    db = np.full(int(total / C.Q), -70.0)
    for a, b in pedacos:
        db[int(a / C.Q):int(b / C.Q)] = -20.0
    return {"db": db, "lim": -48.0}


def test_borda_do_fim_vai_ate_o_silencio_real():
    # o Whisper diz que a palavra acaba em 1.0, mas a voz vai até 1.25 ("porcen|to"): o corte não pode ser em 1.0
    env = _env([(0.2, 1.25)])
    end = C._edge_end(env, 1.0, 3.0, 0.2)
    assert 1.25 <= end <= 1.5


def test_fecho_de_consoante_nao_e_pausa():
    # 60 ms de silêncio no meio da palavra (fecho do "t") não conta como pausa
    env = _env([(0.2, 1.0), (1.06, 1.3)])
    assert C._edge_end(env, 0.95, 3.0, 0.2) >= 1.3


def test_borda_do_inicio_recua_ate_o_silencio():
    env = _env([(1.0, 2.0)])
    start = C._edge_start(env, 1.15, 0.0, 0.15)  # Whisper atrasou o começo da palavra
    assert 0.8 <= start <= 1.0


def test_comeco_abandonado_sai_sem_llm():
    spans = [{"ini": 0, "fim": 1, "i": 0, "j": 4, "manter": True, "tipo": "improviso", "confianca": 0.5,
                "texto": "Resumindo, 81...", "motivo": ""},
               {"ini": 1.5, "fim": 4, "i": 4, "j": 12, "manter": True, "tipo": "tomada", "confianca": 1.0,
                "texto": "Resumindo. 81% de pessoas endividadas realmente assusta.", "motivo": ""}]
    C._starts_abandoned(spans)
    assert not spans[0]["manter"] and spans[0]["tipo"] == "retake"


def test_retake_que_sobrou_na_narracao_editada():
    sentences = C.sentences_of_script("Segundo motivo, entender o crédito é difícil e a pesquisa também mede isso.")
    pal = _p("Segundo motivo, entender o crédito é difícil. Segundo motivo, entender o crédito é difícil e a "
             "pesquisa também mede isso.")
    r = C.repetitions(pal, sentences)
    assert len(r) == 1 and r[0]["i"] == 0 and r[0]["j"] == 7


def test_repeticao_natural_da_frase_nao_e_retake():
    sentences = C.sentences_of_script("Quem respondeu antes, com o dinheiro mais curto, ficou impaciente com o dinheiro.")
    pal = _p("Quem respondeu antes, com o dinheiro mais curto, ficou impaciente com o dinheiro.")
    assert C.repetitions(pal, sentences) == []


def test_numero_ancorado_na_fala():
    pal = _p("Hoje quase 84 milhões de brasileiros estão negativados", t0=10.0)
    assert plan._instant_number("84 milhões", pal, 9, 20) == 10.8
    pal = _p("eram 81 ,7% das famílias", t0=5.0)
    assert plan._instant_number("81,7%", pal, 0, 20) == 5.4


def test_numeros_em_fila_nao_empurram_o_seguinte():
    a = {"modelo": "numero", "origem": "numero", "impacto": 4, "dados": {}, "inicio": 10.0, "ancora": 10.35}
    b = {"modelo": "numero", "origem": "numero", "impacto": 5, "dados": {}, "inicio": 13.0, "ancora": 13.35}
    agenda = plan.schedule([a, b], 100.0)
    assert [c["inicio"] for c in agenda] == [10.0, 13.0]  # cada um na hora da fala
    assert agenda[0]["inicio"] + agenda[0]["dur"] <= 13.0    # o anterior sai antes do próximo entrar


def test_pedaco_do_numero_fica_na_tomada():
    sentences = C.sentences_of_script("Em setembro eram 81,7%. E o cartão é a dívida mais comum.")
    pal = _p("Em setembro eram 81 ,7%. E o cartão é a dívida mais comum.")
    spans, _ = C.decide(sentences, pal)
    assert all(t["manter"] for t in spans if ",7%" in t["texto"])


def test_gaguejo_sai():
    sentences = C.sentences_of_script("O cartão é de longe a dívida mais comum.")
    pal = _p("O cartão é é de longe a dívida mais comum.")
    spans, _ = C.decide(sentences, pal)
    outside = [t for t in spans if not t["manter"]]
    assert len(outside) == 1 and outside[0]["i"] == 2


def test_gaguejo_de_duas_palavras_sai():
    sentences = C.sentences_of_script("Não vão ter condições de pagar o que está atrasado.")
    pal = _p("Não vão ter condições de pagar o que está que está atrasado.")
    spans, _ = C.decide(sentences, pal)
    outside = [t for t in spans if not t["manter"]]
    assert len(outside) == 1 and (outside[0]["i"], outside[0]["j"]) == (7, 9)


def test_todo_numero_com_unidade_vira_grafico():
    assert plan._numbers_of_sentence("quase 84 milhões de brasileiros, sendo 24 milhões no Sudeste.") == [
        ("84 milhões", "de brasileiros, sendo"), ("24 milhões", "no Sudeste")]
    assert plan._numbers_of_sentence("Em 2019, três motivos.") == []


def test_palavra_chave_achada_na_fala():
    from esteira.graphics import keywords
    pal = _p("Oito em cada dez famílias brasileiras estão endividadas.", t0=3.0)
    assert keywords._find("endividadas", pal, 3.0, 8.0)[0] == 5.8
    assert keywords._find("famílias brasileiras", pal, 3.0, 8.0) == (4.6, 5.3)


def _trecho(texto, tipo="tomada", manter=True, **k):
    return {"texto": texto, "tipo": tipo, "manter": manter, "motivo": "m", "ini": 0.0, "fim": 5.0, **k}


def test_unica_leitura_da_frase_nao_sai():
    ts = [_trecho("e quase ninguém", frase=7),
          _trecho("segue. Entretanto, tem um estudo,", "reformulada", False, frase=8),
          _trecho("nesse caso, possa auxiliar.", "improviso", False),
          _trecho("uma matéria que é uma matéria que é uma matéria que é uma", "reformulada", False, frase=9)]
    C._reading_single(ts)
    assert ts[1]["manter"] and ts[2]["manter"] and not ts[3]["manter"]
    laco = [_trecho("a matéria é uma matéria que é uma matéria que é uma diz avalanche", "reformulada", False, frase=9, fim=2.1)]
    C._reading_single(laco)  # 14 palavras em 2,1 s: alucinação do Whisper sobre uma fala boa
    assert laco[0]["manter"]


def test_reformulada_com_outra_leitura_sai():
    ts = [_trecho("Cerca da", "reformulada", False, frase=5), _trecho("Cerca de metade.", frase=5)]
    C._reading_single(ts)
    assert not ts[0]["manter"]


def test_retake_sem_outra_tomada_nao_e_retake():
    pal = _p("Eles olharam para onde ia o dinheiro. Sabe quanto as pessoas colocavam? Eles olharam para onde ia o dinheiro.")
    t = {"ini": pal[0]["ini"], "fim": pal[6]["fim"], "texto": "Eles olharam para onde ia o dinheiro."}
    assert C._other_take(t, pal)
    assert not C._other_take(t, pal[:12])
