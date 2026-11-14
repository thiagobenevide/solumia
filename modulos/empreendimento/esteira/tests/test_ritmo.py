"""Etapa 5 do acervo: perfis de ritmo longo e curto (dado), aplicados ao estilo e ao mapa do diretor."""
import json

from esteira.estudio import diretor, ritmo
from esteira.estudio import estilo as E

LONGO, CURTO = ritmo.carregar("longo"), ritmo.carregar("curto")


class _Proj:
    def __init__(self, pasta, vertical=False):
        self.pasta, self.vertical = pasta, vertical


def _c(t, cena, ate=None, **mais):
    return {"t": t, "ate": ate or t + 2.0, "cena": cena, "titulo": "x", "valores": [], "por": "local", **mais}


def test_perfil_vem_do_roteiro_senao_do_short(tmp_path):
    p = _Proj(tmp_path)
    assert ritmo.id_do(p) == "longo"
    (tmp_path / "roteiro.json").write_text(json.dumps({"short": "a"}))
    assert ritmo.id_do(p) == "curto"
    (tmp_path / "roteiro_original.md").write_text("---\ntitulo: X\nritmo: longo\n---\ntexto")
    assert ritmo.id_do(p) == "longo"
    (tmp_path / "roteiro.json").unlink()
    (tmp_path / "roteiro_original.md").write_text("---\ntitulo: X\n---\n")
    assert ritmo.id_do(_Proj(tmp_path, vertical=True)) == "curto"


def test_aplicar_perfil_no_estilo_sem_mudar_o_salvo():
    est = E.Estilo(id="t-dark", nome="T", canal="t")
    c = ritmo.aplicar(est, CURTO)
    assert c.regras.trecho_max_s == 3.0 and c.regras.legenda_visual.tamanho == 1.3 and c.presenca.peca_parada_s == 3.0
    assert est.regras.trecho_max_s != 3.0 and est.regras.legenda_visual.tamanho == 1.0
    alto = E.Estilo(id="t-dark", nome="T", canal="t", regras=E.aplicar_niveis(E.Regras()))
    assert ritmo.aplicar(alto, LONGO).regras.takeover_max == 0.5   # longo só reduz o motion (teto)
    baixo = E.Estilo(id="t-dark", nome="T", canal="t", regras=E.aplicar_niveis(E.Regras(), {"motion": "baixa"}))
    assert ritmo.aplicar(baixo, LONGO).regras.takeover_max == baixo.regras.takeover_max


def test_gancho_so_no_curto_e_so_sem_peca_no_comeco():
    frases = [{"texto": "Oito em cada dez famílias brasileiras estão endividadas.", "ini": 0.2, "fim": 3.0}]
    cenas = ritmo.gancho([_c(5.0, "contador")], CURTO, frases)
    assert cenas[0]["por"] == "ritmo" and cenas[0]["t"] == 0.0 and cenas[0]["titulo"].endswith("*brasileiras*")
    assert len(ritmo.gancho([_c(1.0, "contador")], CURTO, frases)) == 1
    assert len(ritmo.gancho([_c(5.0, "contador")], LONGO, frases)) == 1


def test_anti_repeticao_troca_ou_tira_so_quando_colada():
    trocas = {"frase_destaque": "lettering"}
    cs = ritmo.anti_repeticao([_c(1, "frase_destaque"), _c(10, "frase_destaque")], LONGO, trocas)
    assert cs[1]["cena"] == "lettering" and cs[1]["repeticao"] == "trocada"
    cs = ritmo.anti_repeticao([_c(1, "frase_destaque"), _c(10, "frase_destaque")], LONGO)
    assert cs[1]["cena"] == "midia"                                      # colada e sem alternativa
    cs = ritmo.anti_repeticao([_c(1, "frase_destaque"), _c(5, "cta"), _c(10, "frase_destaque")], LONGO)
    assert cs[2]["cena"] == "frase_destaque"                             # não colada: fica (a conferência avisa)
    cs = ritmo.anti_repeticao([_c(1, "contador", valores=[1]), _c(10, "contador", valores=[2])], LONGO)
    assert cs[1]["cena"] == "contador"                                   # dado nunca vira só mídia
    cs = ritmo.anti_repeticao([_c(1, "cta"), _c(10, "cta", por="voce")], LONGO)
    assert cs[1]["cena"] == "cta"                                        # a pessoa manda
    cs = ritmo.anti_repeticao([_c(1, "frase_destaque"), _c(25, "frase_destaque")], CURTO)
    assert cs[1]["cena"] == "frase_destaque"                             # fora da janela do curto (20 s)


def test_curto_sem_capitulos():
    assert ritmo.sem_capitulos([_c(1, "titulo_capitulo")], CURTO)[0]["cena"] == "frase_destaque"
    assert ritmo.sem_capitulos([_c(1, "titulo_capitulo")], LONGO)[0]["cena"] == "titulo_capitulo"


def test_conferencia_de_ritmo():
    cenas = [_c(6.0, "frase_destaque", 12.0), _c(13.0, "cta"), _c(16, "cta"), _c(19, "cta")]
    avisos = ritmo.conferir(cenas, [{"ini": 0.0}, {"ini": 25.0}], 40.0, CURTO)
    tipos = {a["tipo"] for a in avisos}
    assert {"sem_virada", "gancho", "peca_longa", "repeticao"} <= tipos and "duracao" not in tipos
    assert any(a["tipo"] == "duracao" for a in ritmo.conferir([], [], 40.0, LONGO))


def test_ritmar_no_diretor_recontagem_e_takeover():
    est = E.Estilo(id="t-dark", nome="T", canal="t")
    frases = [{"texto": "Você sabia disso?", "ini": 0.1, "fim": 1.5}]
    cenas, avisos = diretor.ritmar([_c(4.0, "titulo_capitulo"), _c(8.0, "contador", valores=[1])], frases, est, CURTO,
                                   [], 30.0)
    assert [c["cena"] for c in cenas] == ["frase_destaque", "frase_destaque", "contador"]
    assert [c["id"] for c in cenas] == [0, 1, 2] and cenas[2]["takeover"] and not cenas[0]["takeover"]
    assert isinstance(avisos, list)
