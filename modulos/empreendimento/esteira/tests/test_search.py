"""Relevância da mídia para a fala: "credit card bills" no Pixabay trazia pássaros ("bill" = bico)."""
from esteira import media as M

SCENE = {"busca_en": "credit card bills", "chave_en": "credit card"}


def test_bird_is_not_card():
    key = M.key_of_scene(SCENE)
    passaro = {"id": "a", "tags": "bird, flamingo, beak, bill, feathers"}
    cartao = {"id": "b", "tags": "wallet, credit card, cash, money"}
    aniversario = {"id": "c", "tags": "birthday party, birthday card, congratulation"}
    assert [c["id"] for c in M.sort([passaro, aniversario, cartao], key)] == ["b"]


def test_video_with_nothing_relevant_falls_back_to_photo():
    assert M.sort([{"id": "a", "tags": "bird, bill"}], M.key_of_scene(SCENE), require=True) == []


def test_english_terms_go_with_english_lang():
    t = M.terms_of_scene({"busca_en": "credit card", "alternativas": ["paying card"], "busca": "cartão"})
    assert t == [("credit card", "en-US"), ("paying card", "en-US"), ("cartão", None)]
