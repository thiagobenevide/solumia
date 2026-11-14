"""Claquete falada: "Corte parte N" confirma a leitura da parte, "Cancela parte N" descarta, sem marcador não usa."""
from esteira import clapper as K

ROTEIRO = "# Título\n\nOito em cada dez famílias estão endividadas. Isso assusta.\n\nMas quase ninguém explica o motivo."


def _p(texto, t0=0.0, passo=0.4):
    return [{"p": w, "ini": round(t0 + k * passo, 3), "fim": round(t0 + k * passo + 0.3, 3)}
            for k, w in enumerate(texto.split())]


def _mantido(trechos):
    return " ".join(t["texto"] for t in sorted(trechos, key=lambda t: t["i"]) if t["manter"])


def test_partes_numeradas_por_paragrafo():
    partes = K.partes_do_roteiro(ROTEIRO)
    assert [p["n"] for p in partes] == [1, 2] and partes[1]["f0"] == 2


def test_variacoes_do_marcador():
    m = K.marcadores(_p("bla Corte, parte 1. bla corta a parte catorze bla Cancela parte vinte e dois bla "
                        "corte-parte 3"))
    assert [(x["tipo"], x["parte"]) for x in m] == [("corte", 1), ("corte", 14), ("cancela", 22), ("corte", 3)]


def test_vale_o_ultimo_corte_e_cancela_descarta():
    partes = K.partes_do_roteiro(ROTEIRO)
    fala = ("Vamos lá. Oito em cada dez famílias estão endividadas. Isso assusta. Corte parte um. "
            "Mas quase ninguém sabe. Cancela parte dois. "
            "Oito em cada dez famílias estão endividadas. Isso assusta muito. Corte parte um. "
            "Mas quase ninguém explica o motivo. Corte parte dois. Ok, acabou.")
    trechos, faltando, avisos = K.decidir(partes, _p(fala))
    assert _mantido(trechos) == ("Oito em cada dez famílias estão endividadas. Isso assusta muito. "
                                 "Mas quase ninguém explica o motivo.")
    assert not faltando


def test_cancela_logo_depois_desfaz_o_corte():
    partes = K.partes_do_roteiro(ROTEIRO)
    fala = ("Oito em cada dez famílias estão endividadas. Isso assusta. Corte parte um. Cancela parte um. "
            "Mas quase ninguém explica o motivo. Corte parte dois.")
    trechos, faltando, avisos = K.decidir(partes, _p(fala))
    assert "Oito" not in _mantido(trechos)
    assert any("parte 1" in a for a in avisos)


def test_sem_marcadores_usa_o_fluxo_antigo():
    assert K.decidir(K.partes_do_roteiro(ROTEIRO), _p("Oito em cada dez famílias estão endividadas.")) is None
