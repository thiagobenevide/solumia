"""Registro canônico e índice do dataset (docs/PLANO-DATASET.md §4)."""
import pytest

from esteira.dataset import index
from esteira.dataset import registry as R


def test_ulid_ordenavel_e_unico():
    ids = [R.ulid() for _ in range(200)]
    assert len(set(ids)) == 200 and all(len(i) == 26 for i in ids)


def test_gravar_avaliar_e_uso():
    a = R.gravar("thumb_compor", grupo="thumb:x-001", contexto={"titulo": "T"}, saida={"conceito": {"texto": "A"}},
                 origem="local:teste", extra={"arquivo": "thumb_0.png"})
    b = R.gravar("thumb_compor", grupo="thumb:x-001", contexto={"titulo": "T"}, saida={"conceito": {"texto": "B"}},
                 origem="local:teste", extra={"arquivo": "thumb_1.png"})
    R.avaliar(b, "escolhida")
    regs = {r["id"]: r for r in R.registros("thumb_compor")}
    assert regs[a]["uso"] == "pendente" and regs[b]["uso"] == "sft"
    assert R.ler_artefato(regs[b]["saida"]["n1"]) == {"conceito": {"texto": "B"}}
    assert R.ultimo("thumb:x-001", arquivo="thumb_0.png")["id"] == a


def test_portao_reprovado_e_veredito_invalido():
    r = R.gravar("peca_html", grupo="peca:p", contexto={}, saida={"id": "p"}, origem="claude",
                 portao={"ok": False, "erros": ["lint"]})
    assert next(R.registros("peca_html"))["uso"] == "descartar"
    R.avaliar(r, "descartada", motivo="lint")
    assert next(R.registros("peca_html"))["uso"] == "dpo_ruim"
    with pytest.raises(ValueError):
        R.avaliar(r, "talvez")
    with pytest.raises(ValueError):
        R.gravar("inexistente", grupo="g", contexto={}, saida={}, origem="x")


def test_contexto_grande_vai_para_artefato_e_linha_truncada_e_ignorada():
    R.gravar("montar", grupo="ep:a", contexto={"texto": "x" * 20_000}, saida=[], origem="traducao")
    arq = next(R.REGISTRO.glob("**/montar/*.jsonl"))
    with open(arq, "a") as f:
        f.write('{"id": "rg_quebrado", "t"')  # escrita interrompida
    regs = list(R.registros("montar"))
    assert len(regs) == 1 and "ref" in regs[0]["contexto"]
    assert R.ler_artefato(regs[0]["contexto"]["ref"])["texto"] == "x" * 20_000


def test_indice_reconstroi_e_conta():
    for k in range(3):
        rg = R.gravar("foto_tratar", grupo=f"foto:{k}", contexto={}, saida={"foco": "sujeito"}, origem="local:t")
        if k:
            R.avaliar(rg, "aprovada")
    assert index.reindexar() == 3
    s = index.situacao()["foto_tratar"]
    assert s["total"] == 3 and s["sft"] == 2 and s["pendente"] == 1 and not s["pronta"]
    assert len(index.consultar(tarefa="foto_tratar", uso="sft")) == 2
