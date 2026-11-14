"""Corte do áudio: palavra nunca é comida (docs/PLANO-ACERVO.md). Sinais sintéticos com os finais difíceis:
fricativa surda no fim ("mais", "isso"), volume que cai ao longo da gravação, palavra pela metade na máscara,
borda que caía dentro da palavra e retake colado."""
import numpy as np

from esteira import edges as B

SR = B.SR


def _voice(seg, amp=0.3):
    t = np.arange(int(seg * SR)) / SR
    return amp * (np.sin(2 * np.pi * 140 * t) + 0.5 * np.sin(2 * np.pi * 280 * t) + 0.3 * np.sin(2 * np.pi * 420 * t))


def _fric(seg, amp=0.05):
    from numpy.fft import irfft, rfft, rfftfreq
    x = np.random.default_rng(3).standard_normal(int(seg * SR))
    X = rfft(x)
    X[(rfftfreq(len(x), 1 / SR) < 3500)] = 0
    y = irfft(X, len(x))
    return amp * y / (np.abs(y).max() + 1e-9)


def _noise(seg, amp=0.002):
    return amp * np.random.default_rng(7).standard_normal(int(seg * SR))


def _build(parts, total):
    x = _noise(total)
    for t0, signal in parts:
        i = int(t0 * SR)
        x[i:i + len(signal)] += signal
    return x.astype(np.float32)


def test_final_fricative_counts_as_speech():
    # "mais": vogal 1,0–1,3 s + "s" 1,3–1,45 s; o detector antigo (graves > agudos) tirava o "s"
    x = _build([(1.0, _voice(0.3)), (1.3, _fric(0.15))], 3.0)
    speech = B.analysis(x)["fala"]
    assert speech[int(1.33 / B.Q):int(1.42 / B.Q)].mean() > 0.8


def test_isolated_breath_is_not_speech():
    x = _build([(0.5, _voice(0.3)), (1.6, _fric(0.3, 0.02))], 3.0)  # sopro 1 s depois da voz
    assert B.analysis(x)["fala"][int(1.65 / B.Q):int(1.85 / B.Q)].mean() < 0.2


def test_local_floor_follows_falling_volume():
    # 20 s alto, 20 s baixo (microfone mais longe): o fim fraco da palavra baixa ainda é fala
    parts = [(t, _voice(0.4, 0.3)) for t in np.arange(1, 19, 2.0)]
    parts += [(t, _voice(0.4, 0.02)) for t in np.arange(21, 39, 2.0)]
    parts.append((31.4, _fric(0.12, 0.03)))  # "s" final fraco da palavra em 31,0–31,4
    x = _build(parts, 40.0)
    speech = B.analysis(x)["fala"]
    assert speech[int(31.05 / B.Q):int(31.35 / B.Q)].mean() > 0.8
    assert speech[int(31.42 / B.Q):int(31.5 / B.Q)].mean() > 0.5


def test_edge_inside_word_moves_out():
    # mantido [0, 1.1] e [1.6, 3]; a palavra mantida "casa" vai até 1.25: a borda não pode ficar em 1.1
    out = B.validate([[0.0, 1.1], [1.6, 3.0]], [(0.8, 1.25), (1.7, 2.0)])
    assert out[0][1] >= 1.25 + B.AFTER - 1e-9
    assert all(not B.inside(t, B.zones([(0.8, 1.25), (1.7, 2.0)])) for iv in out for t in iv)


def test_no_gap_between_words_does_not_cut():
    out = B.validate([[0.0, 1.0], [1.05, 2.0]], [(0.7, 1.02), (1.04, 1.5)])
    assert out == [[0.0, 2.0]]


def test_kept_word_left_out_comes_back():
    out = B.validate([[0.0, 1.0], [2.0, 3.0]], [(1.3, 1.6)])
    assert any(a <= 1.3 and b >= 1.6 for a, b in out)


def test_core_extends_to_real_end_and_stops_at_retake():
    sound = np.zeros(400, bool)
    sound[100:150] = True    # "casa" com som até 1,5 s; o Whisper disse 1,0–1,3
    sound[150:200] = True    # retake colado começa em 1,5 (Whisper: 1,5–2,0) e sai
    n = B.cores([(1.0, 1.3)], sound, [(1.0, 1.3), (1.5, 2.0)])[0]
    assert n[1] >= 1.5 - 1e-9 and n[1] <= 1.5 + B.NEIGHBOR_CUT + 1e-9


def test_silent_word_is_not_protected():
    sound = np.zeros(300, bool)
    assert B.cores([(1.0, 1.4)], sound, [(1.0, 1.4)]) == []


def test_losses_finds_word_cut_in_half():
    alerts = B.losses([(1.0, 1.4), (2.0, 2.4)], [[0.0, 1.2], [1.9, 3.0]], ["casa", "mais"])
    assert [a["texto"] for a in alerts] == ["casa"] and alerts[0]["perdeu"] == 0.5


def test_studio_cut_keeps_half_word_in_mask():
    from esteira.studio import cut as C
    sp = np.zeros(400, bool)
    sp[50:100] = True                         # "Oi" 0,5–1,0
    sp[200:225] = True                        # "casa" 2,0–2,5: só metade na máscara (o "sa" fraco saiu)
    ws = [[0.5, 1.0, "Oi"], [2.0, 2.5, "casa."]]
    segs, _, _ = C.segments(sp, ws, [], dur=4.0)
    assert any(a <= 2.0 and b >= 2.5 for a, b, _ in segs)
    assert not B.losses([(w[0], w[1]) for w in ws], [s[:2] for s in segs])


def test_stretched_filler_does_not_take_next_start():
    from esteira.studio import cut as C
    sp = np.zeros(500, bool)
    sp[100:260] = True                        # "e" esticado 1,0–1,9 (o Whisper estica até 2,0) + "sempre" 1,9–2,6
    ws = [[1.0, 2.0, "e"], [1.9, 2.6, "sempre"]]
    cuts = C.fillers(ws)
    assert cuts and cuts[0][2].endswith("(esticado)")
    segs, _, _ = C.segments(sp, ws, cuts, dur=5.0)
    assert any(a <= 1.9 - B.BEFORE + 1e-9 and b >= 2.6 for a, b, _ in segs)


def test_pipeline_edges_never_inside_word():
    from esteira import cuts as C
    db = np.full(400, -70.0)
    db[100:142] = -20.0                       # "porcento": a voz vai até 1,42; Whisper disse fim em 1,2
    db[150:180] = -20.0                       # retake colado logo depois (sai)
    db[250:300] = -20.0                       # próxima palavra mantida
    env = {"db": db, "lim": np.full(400, -48.0)}
    pal = [{"p": "porcento", "ini": 1.0, "fim": 1.2}, {"p": "porcento", "ini": 1.5, "fim": 1.8},
           {"p": "agora.", "ini": 2.5, "fim": 3.0}]
    spans = [{"i": 0, "j": 1, "manter": True}, {"i": 1, "j": 2, "manter": False}, {"i": 2, "j": 3, "manter": True}]
    ivs = C._intervals(spans, pal, [], env)
    assert any(a <= 1.0 and b >= 1.42 for a, b in ivs)          # o fim real ficou
    assert not any(a < 1.55 < b for a, b in ivs)                # o retake saiu


def test_combine_alignment_discards_absurd_time():
    from esteira import alignment as A
    ws = [[1.0, 1.4, "casa"], [1.5, 1.9, "mais"], [2.0, 2.3, "fez"]]
    out = A.combine(ws, [[1.05, 1.38], None, [5.0, 5.3]])
    assert out[0][:2] == [1.05, 1.38] and out[1][:2] == [1.5, 1.9] and out[2][:2] == [2.0, 2.3]
