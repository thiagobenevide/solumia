"""Etapa 2 do acervo: fábrica de peças com o Claude simulado (nenhuma chamada real ao `claude -p`)."""
import json
import shutil

import pytest
from esteira.dataset import registro as R
from esteira.estudio import fabrica as F
from esteira.estudio import peca as P

REF = P.pasta("numero_impacto")


@pytest.fixture
def ambiente(tmp_path, monkeypatch):
    """Acervo e dados da fábrica em pastas temporárias, só com a peça de referência e o guia."""
    pecas = tmp_path / "pecas"
    pecas.mkdir()
    shutil.copytree(REF, pecas / "numero_impacto", ignore=shutil.ignore_patterns("prova"))
    shutil.copy(P.PASTA / "GUIA.md", pecas / "GUIA.md")
    dados = tmp_path / "fabrica"
    monkeypatch.setattr(P, "PASTA", pecas)
    for nome, valor in {"PASTA": dados, "PEDIDOS": dados / "pedidos.json", "REGISTRO": dados / "registro.jsonl",
                        "REFS": dados / "referencias", "REPROVADAS": dados / "reprovadas",
                        "GUIA": pecas / "GUIA.md"}.items():
        monkeypatch.setattr(F, nome, valor)
    monkeypatch.setattr(F, "enfileirar", lambda pid: {"id": 1})
    monkeypatch.setattr(F, "gasto_hoje", lambda: 0.0)
    monkeypatch.setattr(F, "checagem_visual", lambda id_: [])
    monkeypatch.setattr(P, "provar", lambda id_, ficha: ([], []))  # prova no Chromium tem teste próprio
    return pecas


def _resposta(id_="linha_tempo", **mudar):
    """Peça válida (derivada da referência) como o Claude devolveria."""
    js = (REF / "peca.js").read_text().replace("numero_impacto", "qualquer").replace("ni-", "lt-")
    css = (REF / "peca.css").read_text().replace("numero_impacto", "qualquer").replace("ni-", "lt-")
    ficha = json.loads((REF / "ficha.json").read_text())
    ficha.update(id="qualquer", comunica="uma linha do tempo com marcos e datas", intencoes=["dado_temporal"])
    g = {"id": id_, "peca_js": js, "peca_css": css, "ficha": ficha, "resumo": "linha do tempo"}
    g.update(mudar)
    return F.PecaGerada.model_validate(g)


def _claude(monkeypatch, respostas):
    pedidos_vistos = []

    def falso(p, texto, imagem=None):
        pedidos_vistos.append(texto)
        return (respostas.pop(0) if respostas else None), 0.25
    monkeypatch.setattr(F, "_consultar", falso)
    return pedidos_vistos


def test_pedido_livre_gera_ate_a_quantidade_e_espera_revisao(ambiente, monkeypatch):
    vistos = _claude(monkeypatch, [_resposta("linha_tempo"), _resposta("linha_tempo")])
    p = F.novo_pedido("livre", "linhas do tempo com fotos de época", quantidade=2)
    r = F.rodar(p.id, visual=False)
    assert r.pecas == ["linha_tempo", "linha_tempo_2"] and r.situacao == "aguardando sua revisão"
    assert P.carregar("linha_tempo").estado == "revisao" and r.gasto_usd == 0.5
    assert 'ESTUDIO.peca("linha_tempo_2"' in (ambiente / "linha_tempo_2" / "peca.js").read_text()
    assert ".p-linha_tempo_2" in (ambiente / "linha_tempo_2" / "peca.css").read_text()
    assert "GUIA DE ESCRITA" in vistos[0] and "linhas do tempo com fotos" in vistos[0]
    assert "linha_tempo:" in vistos[1]  # o acervo atual entra no dossiê para não duplicar


def test_reprovada_no_portao_volta_ao_claude_uma_vez(ambiente, monkeypatch):
    ruim = _resposta(peca_css=".p-qualquer .lt-n { color: #ff0000; }")
    vistos = _claude(monkeypatch, [ruim, _resposta()])
    p = F.novo_pedido("livre", "x", quantidade=1)
    r = F.rodar(p.id, visual=False)
    assert r.pecas == ["linha_tempo"] and "REPROVADA no portão" in vistos[1] and "cor fixa" in vistos[1]


def test_reprovada_duas_vezes_e_descartada_com_motivo(ambiente, monkeypatch):
    ruim = _resposta(peca_css=".p-qualquer .lt-n { color: #ff0000; }")
    _claude(monkeypatch, [ruim, ruim])
    p = F.novo_pedido("livre", "x", quantidade=1)
    r = F.gerar(F.pedido(p.id), visual=False)
    assert not r["ok"] and "cor fixa" in r["motivo"] and not (ambiente / "linha_tempo").exists()
    assert any((F.REPROVADAS).glob("linha_tempo-*/motivo.txt"))
    regs = list(R.registros("peca_html"))  # as duas rodadas no dataset; a 2ª é filha da 1ª e fica descartada
    assert len(regs) == 2 and regs[1]["pai"] == regs[0]["id"] and regs[1]["humano"]["veredito"] == "descartada"


def test_revisao_aprovar_ajuste_variacao_reprovar(ambiente, monkeypatch):
    _claude(monkeypatch, [_resposta(), _resposta(), _resposta(comunica="x")])
    p = F.novo_pedido("livre", "x", quantidade=1)
    F.rodar(p.id, visual=False)
    # ajuste: nova versão da mesma peça, comentário vira lição
    F.revisar("linha_tempo", "ajuste", "deixe a entrada mais lenta")
    assert F.pedido(p.id).tarefas[0].tipo == "ajuste"
    F.rodar(p.id, visual=False)
    assert P.carregar("linha_tempo").versao == 2 and P.carregar("linha_tempo").estado == "revisao"
    assert "deixe a entrada mais lenta" in F.GUIA.read_text()
    # variação: irmã com id novo, entra no pedido
    F.revisar("linha_tempo", "variacao")
    F.rodar(p.id, visual=False)
    assert "linha_tempo_2" in F.pedido(p.id).pecas
    # aprovar a original fecha o pedido (quantidade 1); reprovar a irmã guarda o motivo no guia
    F.revisar("linha_tempo", "aprovar")
    assert P.carregar("linha_tempo").estado == "aprovada" and F.pedido(p.id).estado == "concluido"
    F.revisar("linha_tempo_2", "reprovar", "movimento rápido demais para o tom didático")
    assert not (ambiente / "linha_tempo_2").exists() and "rápido demais" in F.GUIA.read_text()
    with pytest.raises(ValueError):
        F.revisar("linha_tempo", "reprovar", "")
    vered = {(r["extra"]["peca"], (r["humano"] or {}).get("veredito")) for r in R.registros("peca_html")}
    assert ("linha_tempo", "aprovada") in vered and ("linha_tempo_2", "reprovada") in vered
    assert {r["grupo"] for r in R.registros("peca_html")} == {"peca:linha_tempo"}  # irmã no grupo da mãe


def test_ajuste_que_nao_passa_devolve_a_versao_anterior(ambiente, monkeypatch):
    ruim = _resposta(peca_css=".p-qualquer .lt-n { color: #ff0000; }")
    _claude(monkeypatch, [_resposta(), ruim, ruim])
    p = F.novo_pedido("livre", "x", quantidade=1)
    F.rodar(p.id, visual=False)
    antes = (ambiente / "linha_tempo" / "peca.css").read_text()
    F.revisar("linha_tempo", "ajuste", "mais contraste")
    F.rodar(p.id, visual=False)
    f = P.carregar("linha_tempo")
    assert f.versao == 1 and f.estado == "revisao" and "ajuste reprovado" in f.notas
    assert (ambiente / "linha_tempo" / "peca.css").read_text() == antes


def test_cota_da_assinatura_para_a_fabrica(ambiente, monkeypatch):
    _claude(monkeypatch, [_resposta()])
    monkeypatch.setattr(F.claude, "cota", lambda: 0.92)
    p = F.novo_pedido("livre", "x", quantidade=1)
    assert "cota do Claude em 92%" in F.rodar(p.id, visual=False).situacao and not F.pedido(p.id).pecas


def test_lacunas_e_pedido_de_lacunas(ambiente, monkeypatch):
    assert F.lacunas()[0]["tem"] == 0
    assert not any(x["intencao"] == "numero" and x["peso"] == "2d" and x["tem"] == 0 for x in F.lacunas())
    vistos = _claude(monkeypatch, [_resposta()])
    p = F.novo_pedido("lacunas", quantidade=1)
    F.rodar(p.id, visual=False)
    assert "Lacuna do acervo" in vistos[0]


def test_citacao_anexa_o_modelo_antigo(ambiente, monkeypatch):
    vistos = _claude(monkeypatch, [None])
    p = F.pedido_citacao()
    r = F.rodar(p.id, visual=False)
    assert "CITAÇÃO DE ESTUDO" in vistos[0] and "ANEXO esteira/graficos/modelos/citacao.html" in vistos[0]
    assert "não respondeu" in r.situacao


def test_pagina_valida_grifos_dentro():
    e = P.Encaixe(nome="pagina", tipo="pagina", max_itens=4)
    f = P.carregar("numero_impacto").model_copy(update={"encaixes": [e], "batidas": []})
    a = P.amostra_pagina()
    ok = {"src": "x.png", "w": a["w"], "h": a["h"], "grifos": a["grifos"]}
    assert P.validar_dados(f, {"pagina": ok}) == []
    assert P.validar_dados(f, {"pagina": {**ok, "grifos": [[0, 0, a["w"] + 10, 5]]}})
    assert P.validar_dados(f, {"pagina": "x.png"})


def test_freio_pausa_o_pedido_apos_descartes_seguidos(ambiente, monkeypatch):
    ruim = _resposta(peca_css=".p-qualquer .lt-n { color: #ff0000; }")
    _claude(monkeypatch, [ruim] * 6)
    monkeypatch.setattr(F, "_descartar", lambda id_, motivo: shutil.rmtree(P.pasta(id_), ignore_errors=True))
    p = F.novo_pedido("livre", "x", quantidade=5)
    r = F.rodar(p.id, visual=False)
    assert r.estado == "pausado" and r.situacao.startswith("freio: 3 descartes seguidos") and r.descartadas == 3
    F.pausar(p.id, False)  # a retomada zera a contagem: volta a tentar
    _claude(monkeypatch, [_resposta()])
    assert F.rodar(p.id, visual=False).pecas == ["linha_tempo"]


def test_retomar_volta_a_fila_quando_a_cota_libera(ambiente, monkeypatch):
    a = F.novo_pedido("livre", "a", quantidade=1)
    b = F.novo_pedido("livre", "b", quantidade=1)
    F._mudar(a.id, situacao="cota do Claude em 90%: volta quando a janela virar")
    F.pausar(b.id)
    monkeypatch.setattr(F.claude, "cota", lambda: 0.95)
    assert F.retomar() == []
    monkeypatch.setattr(F.claude, "cota", lambda: 0.10)
    assert F.retomar() == [a.id]  # o pausado fica parado


def test_painel_mostra_etapa_quem_fez_e_categorias(ambiente, monkeypatch, tmp_path):
    from esteira.core import trace
    from esteira.ia import claude
    from esteira.web import fila
    monkeypatch.setattr(F, "GUIA_N1_EC", ambiente / "GUIA_N1_EC.md")
    (ambiente / "GUIA_N1_EC.md").write_text("# guia\n\n## Lições\n- não empilhe itens (peça x)\n")
    monkeypatch.setattr(trace, "DIR", tmp_path / "live")
    monkeypatch.setattr(claude, "_registros", lambda: [])
    p = F.pedido_hibrido("ideias", 8, "finanças")
    F._mudar(p.id, conceitos=[{"ficha": {"id": "ideia_a", "descricao": "uma ideia"}, "conceito": "c"}],
             etapa=F._etapa("n1", "ideia_a", 2))
    monkeypatch.setattr(fila, "listar", lambda: [{"ep": f"fabrica:{p.id}", "estado": "rodando", "comando": "estudio-fabrica"}])
    F._registrar("descartada", pedido=p.id, peca="ideia_a", motor="effectcraft", ia="local", custo=0.0,
                 motivo="escura 16:9: sai da área segura com o texto máximo: ['T']")
    F._registrar("revisao", peca="ideia_b", aprovada=False, problemas=["itens empilhados"], custo=0.05)
    d = F.painel()
    assert d["agora"][0]["etapa"]["nome"] == "n1" and d["agora"][0]["etapa"]["rodada"] == 2
    assert d["ideias_na_fila"][0]["id"] == "ideia_a" and d["licoes"]["total"] == 1
    assert d["hoje"]["motion"]["motivos"] == [{"motivo": "texto fora da área segura", "n": 1}]
    assert [e["quem"] for e in d["eventos"][:2]] == ["claude", "local"]


def test_licoes_tem_teto_e_vao_para_o_arquivo(monkeypatch, tmp_path):
    guia, arq = tmp_path / "g.md", tmp_path / "arq.md"
    monkeypatch.setattr(F, "GUIA_N1_EC", guia)
    monkeypatch.setattr(F, "LICOES_ARQUIVO", arq)
    monkeypatch.setattr(F, "LICOES_MAX_CAR", 300)
    guia.write_text("# Guia\n\n## Lições (erros já vistos; não repita)\n- regra de base\n")
    for i in range(20):  # palavras distintas: parecidas seriam barradas como repetidas
        F.licao_n1([f"regra{i}a regra{i}b regra{i}c numero {i} " + "x" * 20], f"p{i}")
    t = guia.read_text()
    assert len(t.split("## Lições", 1)[1].partition("\n")[2]) <= 300 and "regra de base" in t and "numero 19" in t
    assert "numero 0 " in arq.read_text() and "numero 0 " not in t


def test_licao_uma_por_revisao_e_sem_repetir(monkeypatch, tmp_path):
    guia = tmp_path / "g.md"
    monkeypatch.setattr(F, "GUIA_N1_EC", guia)
    monkeypatch.setattr(F, "LICOES_ARQUIVO", tmp_path / "arq.md")
    guia.write_text("# Guia\n\n## Lições\n- Ponha o traço decorativo numa célula de peso mínimo (peça a)\n")
    assert F.licao_n1(["Ponha sempre o traço decorativo numa célula de peso mínimo", "Regra bem diferente sobre "
                       "títulos longos", "Outra regra distinta qualquer"], "b") == ["Regra bem diferente sobre títulos longos"]


def test_licao_podada_nao_volta_e_peca_tem_teto(monkeypatch, tmp_path):
    guia, arq = tmp_path / "g.md", tmp_path / "arq.md"
    monkeypatch.setattr(F, "GUIA_N1_EC", guia)
    monkeypatch.setattr(F, "LICOES_ARQUIVO", arq)
    guia.write_text("# Guia\n\n## Lições\n")
    arq.write_text("- Fundo de ondas: monte várias caixas linha com barras finas (peça ondas)\n")
    assert F.licao_n1(["Fundo de ondas: monte várias caixas linha com barras finas e pesos"], "ondas2") == []
    for i in range(F.LICOES_POR_PECA):
        assert F.licao_n1([f"regra{i}a regra{i}b regra{i}c distinta"], "p")
    assert F.licao_n1(["regra nova totalmente diferente das outras"], "p") == []


def test_portao_tela_nomeia_a_caixa_sem_regiao():
    from esteira.estudio import ec as EC
    from esteira.n1 import effectcraft as N1
    doc = N1.Peca.model_validate({"elementos": [
        {"tipo": "caixa", "nome": "Cena", "filhos": [{"tipo": "texto", "nome": "T", "conteudo": "x"}]},
        {"tipo": "caixa", "nome": "Base", "regiao": "base", "filhos": [{"tipo": "texto", "nome": "B", "conteudo": "y"}]}]})
    erro = next(e for e in EC.checar_estrutura(doc, P.carregar("numero_impacto"))
                if "junto de outras" in e)
    assert "['Cena']" in erro and "sem `regiao`" in erro


def test_portao_pega_traco_bloco_contraste_e_coluna_sem_pesos():
    from esteira.estudio import ec as EC
    from esteira.n1 import effectcraft as N1
    doc = N1.Peca.model_validate({"elementos": [
        {"tipo": "caixa", "nome": "C", "regiao": "centro", "disposicao": "linha", "pesos": [0.3, 1], "filhos": [
            {"tipo": "caixa", "nome": "B", "disposicao": "camadas", "filhos": [
                {"tipo": "retangulo", "nome": "F", "cor": "destaque"},
                {"tipo": "texto", "nome": "N", "conteudo": "{{numero}}", "nivel": "numero", "cor": "texto"}]},
            {"tipo": "caixa", "nome": "T", "disposicao": "coluna", "filhos": [
                {"tipo": "texto", "nome": "K", "conteudo": "x", "nivel": "rotulo"},
                {"tipo": "texto", "nome": "Ti", "conteudo": "{{rotulo}}", "nivel": "titulo"},
                {"tipo": "retangulo", "nome": "Tr", "cor": "destaque"}]}]},
        {"tipo": "caixa", "nome": "S", "regiao": "tela", "filhos": [{"tipo": "texto", "nome": "Z", "conteudo": "z"}]}]})
    erros = " | ".join(EC.checar_estrutura(doc, P.carregar("numero_impacto")))
    assert "'F' sem `w` e `h`" in erros and "texto 'N' em cor `texto`" in erros
    assert "'Tr' sem `h`" in erros and "coluna 'T'" in erros and "caixa 'S' só de texto" in erros


def test_rodada_seguinte_corrige_a_versao_anterior_com_a_causa():
    t = F._dossie_local("ideia", {"id": "x"}, ideia={"conceito": "c"}, erros=["causa no N1: Traco: falta h"],
                        rascunho={"molde": 1}, anterior={"elementos": [{"nome": "Traco", "h": None, "se": None}]},
                        ja_vistos=["erro velho"])
    assert "SUA VERSÃO ANTERIOR" in t and '{"nome": "Traco"}' in t and '"molde"' not in t
    assert "Traco: falta h" in t and "erro velho" in t


def test_capitulo_usa_o_molde_proprio():
    from esteira.estudio import moldes as M
    assert M.rascunho(P.carregar("capitulo_faixa").model_dump(mode="json"))[0] == "capitulo"


def test_moldes_servem_as_fichas_do_acervo_e_passam_no_portao_estrutural():
    """Toda ficha viável vira rascunho N1 válido, que compila e passa no portão estrutural (é a última rodada)."""
    from esteira.estudio import ec as EC
    from esteira.estudio import moldes as M
    from esteira.n1 import effectcraft as N1
    usados = set()
    for f in P.listar():
        fi = f.model_dump(mode="json")
        if M.inviavel(fi):
            continue
        mid, n1 = M.rascunho(fi)
        usados.add(mid)
        doc = N1.Peca.model_validate(n1)
        assert EC.checar_estrutura(doc, f) == [], (f.id, mid)
        enc = {e.nome: {"numero": "34%", "pares": [{"rotulo": "A", "valor": "8%"}] * 3, "itens": ["A"] * 3}
               .get(e.tipo, "A") for e in f.encaixes}
        N1.compilar(doc, {"encaixes": enc, "botoes": {b.nome: b.padrao for b in f.botoes}, "batidas": {}, "t0": 0.3,
                          "dur": 6, "w": 1920, "h": 1080, "fps": 30, "tela_cheia": True})
    assert {"numero", "frase", "barras", "lista"} <= usados


def test_portao_estrutural_pega_o_que_compila_mas_sai_quebrado():
    from esteira.estudio import ec as EC
    from esteira.n1 import effectcraft as N1
    ficha = P.carregar("numero_impacto")
    doc = N1.Peca.model_validate({"elementos": [
        {"tipo": "caixa", "nome": "A", "regiao": "centro", "filhos": []},
        {"tipo": "caixa", "nome": "B", "regiao": "esquerda", "filhos": [
            {"tipo": "texto", "nome": "T", "conteudo": "{{rotulo}}", "se": {"botao": "enfase", "igual": "brilho"}},
            {"tipo": "texto", "nome": "U", "conteudo": "x", "se": {"botao": "anel"}},
            {"tipo": "repetir", "nome": "Bolas", "quantidade": 8, "elementos": [{"tipo": "elipse", "nome": "Bola"}]}]}]})
    erros = " | ".join(EC.checar_estrutura(doc, ficha))
    assert "caixa 'A' sem filhos" in erros and "'numero' não aparece" in erros
    assert "igual a 'brilho'" in erros and "'anel' é valor do botão 'enfase'" in erros
    assert "fileira" in erros and "esquerda/direita" in erros


def test_triagem_pula_o_que_o_n1_nao_desenha():
    from esteira.estudio import moldes as M
    base = P.carregar("numero_impacto").model_dump(mode="json")
    assert M.inviavel(base) == ""
    assert "curva" in M.inviavel({**base, "comunica": "duas curvas de juros que se afastam"})
    assert "imagem" in M.inviavel({**base, "encaixes": [*base["encaixes"], {"nome": "foto", "tipo": "imagem"}]})
    assert "fundo" in M.inviavel({**base, "intencoes": ["fundo"]})


def test_orfas_da_llm_local_saem_ao_iniciar(ambiente, monkeypatch):
    f = P.carregar("numero_impacto")
    destino = P.pasta("orfa_teste")
    shutil.copytree(P.pasta("numero_impacto"), destino)
    P.salvar(f.model_copy(update={"id": "orfa_teste", "origem": "fabrica_local", "estado": "rascunho"}))
    assert F.limpar_orfas() == ["orfa_teste"] and not destino.exists()


def test_trava_repoe_o_que_a_llm_apagou_do_molde():
    molde = {"elementos": [{"tipo": "caixa", "nome": "C", "pesos": [0.36, 1], "vertical": {"disposicao": "coluna"},
                            "filhos": [{"tipo": "retangulo", "nome": "F", "w": 0.39, "h": 0.39}]}]}
    llm = {"elementos": [{"tipo": "caixa", "nome": "C", "pesos": None, "vertical": {"pesos": [1, 2]}, "filhos": [
        {"tipo": "retangulo", "nome": "F", "w": 0.5, "h": None, "cor": "acento"}]}]}
    d = F.travar_molde(llm, molde)
    c, f = d["elementos"][0], d["elementos"][0]["filhos"][0]
    assert c["pesos"] == [0.36, 1] and c["vertical"] == {"disposicao": "coluna", "pesos": [1, 2]}
    assert f == {"tipo": "retangulo", "nome": "F", "w": 0.5, "h": 0.39, "cor": "acento"}  # muda, mas não apaga
    assert llm["elementos"][0]["pesos"] is None


def test_campo_que_a_llm_nao_escreveu_vem_do_molde_e_nao_do_padrao():
    from esteira.n1 import effectcraft as N1
    molde = {"fundo_tela_cheia": "tela", "elementos": [{"tipo": "caixa", "nome": "C", "filhos": [
        {"tipo": "texto", "nome": "N", "conteudo": "{{numero}}", "peso": 800, "cor": "fundo", "caps": True}]}]}
    resposta = N1.Peca.model_validate({"elementos": [{"tipo": "caixa", "nome": "C", "filhos": [
        {"tipo": "texto", "nome": "N", "conteudo": "{{numero}}", "cor": "texto"}]}]})
    d = F.travar_molde(resposta.model_dump(mode="json", exclude_unset=True), molde)
    n = d["elementos"][0]["filhos"][0]
    assert n["peso"] == 800 and n["caps"] is True and n["cor"] == "texto"  # o que ela escreveu fica
    assert d["fundo_tela_cheia"] == "tela"


def test_trava_repoe_elemento_com_encaixe_que_a_llm_apagou():
    molde = {"elementos": [{"tipo": "caixa", "nome": "Base", "filhos": [
        {"tipo": "repetir", "nome": "Itens", "encaixe": "valores", "elementos": [
            {"tipo": "texto", "nome": "Item", "conteudo": "{{item}}"}]}]}],
        "animacoes": [{"anim": "entrar", "alvo": "Item", "t": 0}]}
    d = F.travar_molde({"elementos": [{"tipo": "caixa", "nome": "Base", "filhos": [
        {"tipo": "texto", "nome": "T", "conteudo": "x"}]}], "animacoes": []}, molde)
    assert [x["nome"] for x in d["elementos"][0]["filhos"]] == ["T", "Itens"]
    assert [a["alvo"] for a in d["animacoes"]] == ["Item"]


def test_base_volta_ao_molde_quando_empaca_ou_foge_dos_nomes():
    molde = {"elementos": [{"nome": "A"}, {"nome": "B"}]}
    v = {"elementos": [{"nome": "A"}, {"nome": "B"}, {"nome": "C"}]}
    assert F._base_seguinte(v, None, molde) == (v, "")
    assert F._base_seguinte(v, v, molde)[0] is None  # devolveu igual
    fugiu = {"elementos": [{"nome": "Cena"}, {"nome": "Outro"}]}
    assert F._base_seguinte(fugiu, None, molde)[0] is None and "nome" in F._base_seguinte(fugiu, None, molde)[1]


def test_triagem_pula_ficha_que_o_molde_espreme():
    from esteira.estudio import moldes as M
    assert "não comporta" in M.inviavel(P.carregar("comparacao_atributos").model_dump(mode="json"))


def test_mesmo_erro_duas_vezes_volta_ao_molde():
    molde = {"elementos": [{"nome": "A"}]}
    v1, v2 = {"elementos": [{"nome": "A", "x": 1}]}, {"elementos": [{"nome": "A", "x": 2}]}
    assert F._base_seguinte(v2, v1, molde, ["erro x"], ["erro x", "outro"])[0] is None
    assert F._base_seguinte(v2, v1, molde, ["erro novo"], ["erro x"])[0] == v2


def test_trava_tira_bloco_de_cor_sozinho_e_mantem_painel_de_fundo():
    d = F.travar_molde({"elementos": [
        {"tipo": "caixa", "nome": "Fundo", "filhos": [{"tipo": "retangulo", "nome": "BG", "cor": "destaque"}]},
        {"tipo": "caixa", "nome": "Painel", "filhos": [{"tipo": "retangulo", "nome": "P", "cor": "fundo2"}]}],
        "animacoes": [{"anim": "entrar", "alvo": "BG", "t": 0}]}, {"elementos": []})
    assert [e["nome"] for e in d["elementos"]] == ["Painel"] and d["animacoes"] == []


def test_trava_repoe_os_itens_de_um_repetir_esvaziado():
    molde = {"elementos": [{"tipo": "repetir", "nome": "Barras", "encaixe": "valores", "elementos": [
        {"tipo": "retangulo", "nome": "Barra", "proporcional": True},
        {"tipo": "texto", "nome": "Valor", "conteudo": "{{item.valor}}"}]}]}
    d = F.travar_molde({"elementos": [{"tipo": "repetir", "nome": "Barras", "encaixe": "valores", "elementos": []}]},
                       molde)
    assert [x["nome"] for x in d["elementos"][0]["elementos"]] == ["Barra", "Valor"]


def test_trava_repoe_rotulo_do_item_mesmo_com_o_valor_presente():
    molde = {"elementos": [{"tipo": "repetir", "nome": "Barras", "encaixe": "valores", "elementos": [
        {"tipo": "texto", "nome": "Valor", "conteudo": "{{item.valor}}"},
        {"tipo": "texto", "nome": "Rotulo", "conteudo": "{{item.rotulo}}"}]}]}
    d = F.travar_molde({"elementos": [{"tipo": "repetir", "nome": "Barras", "encaixe": "valores", "elementos": [
        {"tipo": "texto", "nome": "V", "conteudo": "{{item.valor}}"}]}]}, molde)
    assert [x["nome"] for x in d["elementos"][0]["elementos"]] == ["V", "Rotulo"]


def test_trava_tira_animacao_de_elemento_que_nao_existe():
    d = F.travar_molde({"elementos": [{"tipo": "texto", "nome": "T", "conteudo": "x"}],
                        "animacoes": [{"anim": "entrar", "alvo": "Barra", "t": 0}, {"anim": "entrar", "alvo": "T", "t": 0}]},
                       {"elementos": []})
    assert [a["alvo"] for a in d["animacoes"]] == ["T"]


def test_kit_porta_com_encaixes_reais_e_molde_proprio():
    """Peça do kit (titulo + valores) sai pelo mapa: molde certo e rascunho que passa no portão; sem mapa, triagem."""
    from esteira.estudio import ec as EC
    from esteira.estudio import moldes as M
    from esteira.n1 import effectcraft as N1
    mapa = json.loads(M.KIT.read_text())
    for kid, k in mapa.items():
        fp = M.ficha_porte(json.loads((P.pasta(kid) / "ficha.json").read_text()))
        assert not M.inviavel(fp), kid
        mid, n1 = M.rascunho(fp)
        assert mid == k["molde"], kid
        assert EC.checar_estrutura(N1.Peca.model_validate(n1), P.Ficha.model_validate({**fp, "id": f"{kid}_ec"})) == [], kid
    assert "kit sem molde" in M.inviavel(json.loads((P.pasta("lettering") / "ficha.json").read_text()))
