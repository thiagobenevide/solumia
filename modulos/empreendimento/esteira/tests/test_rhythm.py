"""Etapa 5 do acervo: perfis de ritmo longo e curto (dado), aplicados ao estilo e ao mapa do diretor."""
import json

from esteira.studio import director, rhythm
from esteira.studio import style as E

LONG_PROFILE, SHORT_PROFILE = rhythm.load("longo"), rhythm.load("curto")


class _Proj:
    def __init__(self, folder, vertical=False):
        self.folder_path, self.vertical = folder, vertical


def _c(t, scene, until=None, **mais):
    return {"t": t, "ate": until or t + 2.0, "cena": scene, "titulo": "x", "valores": [], "por": "local", **mais}


def test_profile_comes_from_script_else_from_short(tmp_path):
    p = _Proj(tmp_path)
    assert rhythm.id_of(p) == "longo"
    (tmp_path / "roteiro.json").write_text(json.dumps({"short": "a"}))
    assert rhythm.id_of(p) == "curto"
    (tmp_path / "roteiro_original.md").write_text("---\ntitulo: X\nritmo: longo\n---\ntexto")
    assert rhythm.id_of(p) == "longo"
    (tmp_path / "roteiro.json").unlink()
    (tmp_path / "roteiro_original.md").write_text("---\ntitulo: X\n---\n")
    assert rhythm.id_of(_Proj(tmp_path, vertical=True)) == "curto"


def test_apply_profile_to_style_without_changing_saved_one():
    est = E.Style(id="t-dark", nome="T", canal="t")
    c = rhythm.apply(est, SHORT_PROFILE)
    assert c.regras.trecho_max_s == 3.0 and c.regras.legenda_visual.tamanho == 1.3 and c.presenca.peca_parada_s == 3.0
    assert est.regras.trecho_max_s != 3.0 and est.regras.legenda_visual.tamanho == 1.0
    alto = E.Style(id="t-dark", nome="T", canal="t", regras=E.apply_levels(E.Rules()))
    assert rhythm.apply(alto, LONG_PROFILE).regras.takeover_max == 0.5   # longo só reduz o motion (teto)
    baixo = E.Style(id="t-dark", nome="T", canal="t", regras=E.apply_levels(E.Rules(), {"motion": "baixa"}))
    assert rhythm.apply(baixo, LONG_PROFILE).regras.takeover_max == baixo.regras.takeover_max


def test_hook_only_in_short_and_only_without_piece_at_start():
    sentences = [{"texto": "Oito em cada dez famílias brasileiras estão endividadas.", "ini": 0.2, "fim": 3.0}]
    scenes = rhythm.hook([_c(5.0, "contador")], SHORT_PROFILE, sentences)
    assert scenes[0]["por"] == "ritmo" and scenes[0]["t"] == 0.0 and scenes[0]["titulo"].endswith("*brasileiras*")
    assert len(rhythm.hook([_c(1.0, "contador")], SHORT_PROFILE, sentences)) == 1
    assert len(rhythm.hook([_c(5.0, "contador")], LONG_PROFILE, sentences)) == 1


def test_anti_repetition_swaps_or_removes_only_when_adjacent():
    swaps = {"frase_destaque": "lettering"}
    cs = rhythm.anti_repetition([_c(1, "frase_destaque"), _c(10, "frase_destaque")], LONG_PROFILE, swaps)
    assert cs[1]["cena"] == "lettering" and cs[1]["repeticao"] == "trocada"
    cs = rhythm.anti_repetition([_c(1, "frase_destaque"), _c(10, "frase_destaque")], LONG_PROFILE)
    assert cs[1]["cena"] == "midia"                                      # colada e sem alternativa
    cs = rhythm.anti_repetition([_c(1, "frase_destaque"), _c(5, "cta"), _c(10, "frase_destaque")], LONG_PROFILE)
    assert cs[2]["cena"] == "frase_destaque"                             # não colada: fica (a conferência avisa)
    cs = rhythm.anti_repetition([_c(1, "contador", valores=[1]), _c(10, "contador", valores=[2])], LONG_PROFILE)
    assert cs[1]["cena"] == "contador"                                   # dado nunca vira só mídia
    cs = rhythm.anti_repetition([_c(1, "cta"), _c(10, "cta", por="voce")], LONG_PROFILE)
    assert cs[1]["cena"] == "cta"                                        # a pessoa manda
    cs = rhythm.anti_repetition([_c(1, "frase_destaque"), _c(25, "frase_destaque")], SHORT_PROFILE)
    assert cs[1]["cena"] == "frase_destaque"                             # fora da janela do curto (20 s)


def test_short_without_chapters():
    assert rhythm.without_chapters([_c(1, "titulo_capitulo")], SHORT_PROFILE)[0]["cena"] == "frase_destaque"
    assert rhythm.without_chapters([_c(1, "titulo_capitulo")], LONG_PROFILE)[0]["cena"] == "titulo_capitulo"


def test_rhythm_check():
    scenes = [_c(6.0, "frase_destaque", 12.0), _c(13.0, "cta"), _c(16, "cta"), _c(19, "cta")]
    warnings = rhythm.cross_check(scenes, [{"ini": 0.0}, {"ini": 25.0}], 40.0, SHORT_PROFILE)
    kinds = {a["tipo"] for a in warnings}
    assert {"sem_virada", "gancho", "peca_longa", "repeticao"} <= kinds and "duracao" not in kinds
    assert any(a["tipo"] == "duracao" for a in rhythm.cross_check([], [], 40.0, LONG_PROFILE))


def test_pace_in_director_recount_and_takeover():
    est = E.Style(id="t-dark", nome="T", canal="t")
    sentences = [{"texto": "Você sabia disso?", "ini": 0.1, "fim": 1.5}]
    scenes, warnings = director.pace([_c(4.0, "titulo_capitulo"), _c(8.0, "contador", valores=[1])], sentences, est, SHORT_PROFILE,
                                   [], 30.0)
    assert [c["cena"] for c in scenes] == ["frase_destaque", "frase_destaque", "contador"]
    assert [c["id"] for c in scenes] == [0, 1, 2] and scenes[2]["takeover"] and not scenes[0]["takeover"]
    assert isinstance(warnings, list)
