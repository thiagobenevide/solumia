"""Relevância da mídia para a fala: "credit card bills" no Pixabay trazia pássaros ("bill" = bico)."""
from esteira import media as M

CENA = {"busca_en": "credit card bills", "chave_en": "credit card"}


def test_passaro_nao_e_cartao():
    key = M.key_of_scene(CENA)
    passaro = {"id": "a", "tags": "bird, flamingo, beak, bill, feathers"}
    cartao = {"id": "b", "tags": "wallet, credit card, cash, money"}
    aniversario = {"id": "c", "tags": "birthday party, birthday card, congratulation"}
    assert [c["id"] for c in M.sort([passaro, aniversario, cartao], key)] == ["b"]


def test_video_sem_nada_relevante_passa_para_foto():
    assert M.sort([{"id": "a", "tags": "bird, bill"}], M.key_of_scene(CENA), exigir=True) == []


def test_termos_em_ingles_vao_com_lang_ingles():
    t = M.terms_of_scene({"busca_en": "credit card", "alternativas": ["paying card"], "busca": "cartão"})
    assert t == [("credit card", "en-US"), ("paying card", "en-US"), ("cartão", None)]
