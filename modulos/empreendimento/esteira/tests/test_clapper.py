"""Claquete falada: "Corte parte N" confirma a leitura da parte, "Cancela parte N" descarta, sem marcador não usa."""
from esteira import clapper as K

SCRIPT = "# Título\n\nOito em cada dez famílias estão endividadas. Isso assusta.\n\nMas quase ninguém explica o motivo."


def _p(text, t0=0.0, step=0.4):
    return [{"p": w, "ini": round(t0 + k * step, 3), "fim": round(t0 + k * step + 0.3, 3)}
            for k, w in enumerate(text.split())]


def _mantido(segments):
    return " ".join(t["texto"] for t in sorted(segments, key=lambda t: t["i"]) if t["manter"])


def test_parts_numbered_by_paragraph():
    parts = K.parts_of_script(SCRIPT)
    assert [p["n"] for p in parts] == [1, 2] and parts[1]["f0"] == 2


def test_placeholder_variations():
    m = K.markers(_p("bla Corte, parte 1. bla corta a parte catorze bla Cancela parte vinte e dois bla "
                        "corte-parte 3"))
    assert [(x["tipo"], x["parte"]) for x in m] == [("corte", 1), ("corte", 14), ("cancela", 22), ("corte", 3)]


def test_last_cut_wins_and_cancel_discards():
    parts = K.parts_of_script(SCRIPT)
    speech = ("Vamos lá. Oito em cada dez famílias estão endividadas. Isso assusta. Corte parte um. "
            "Mas quase ninguém sabe. Cancela parte dois. "
            "Oito em cada dez famílias estão endividadas. Isso assusta muito. Corte parte um. "
            "Mas quase ninguém explica o motivo. Corte parte dois. Ok, acabou.")
    spans, missing, warnings = K.decide(parts, _p(speech))
    assert _mantido(spans) == ("Oito em cada dez famílias estão endividadas. Isso assusta muito. "
                                 "Mas quase ninguém explica o motivo.")
    assert not missing


def test_cancel_right_after_undoes_cut():
    parts = K.parts_of_script(SCRIPT)
    speech = ("Oito em cada dez famílias estão endividadas. Isso assusta. Corte parte um. Cancela parte um. "
            "Mas quase ninguém explica o motivo. Corte parte dois.")
    spans, missing, warnings = K.decide(parts, _p(speech))
    assert "Oito" not in _mantido(spans)
    assert any("parte 1" in a for a in warnings)


def test_without_markers_uses_old_flow():
    assert K.decide(K.parts_of_script(SCRIPT), _p("Oito em cada dez famílias estão endividadas.")) is None
