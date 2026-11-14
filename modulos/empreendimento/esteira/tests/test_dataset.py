"""Registro canônico e índice do dataset (docs/PLANO-DATASET.md §4)."""
import pytest

from esteira.dataset import index
from esteira.dataset import registry as R


def test_ulid_ordenavel_e_unico():
    ids = [R.ulid() for _ in range(200)]
    assert len(set(ids)) == 200 and all(len(i) == 26 for i in ids)


def test_gravar_avaliar_e_uso():
    a = R.write("thumb_compor", grupo="thumb:x-001", contexto={"titulo": "T"}, saida={"conceito": {"texto": "A"}},
                 origem="local:teste", extra={"arquivo": "thumb_0.png"})
    b = R.write("thumb_compor", grupo="thumb:x-001", contexto={"titulo": "T"}, saida={"conceito": {"texto": "B"}},
                 origem="local:teste", extra={"arquivo": "thumb_1.png"})
    R.evaluate(b, "escolhida")
    regs = {r["id"]: r for r in R.records("thumb_compor")}
    assert regs[a]["uso"] == "pendente" and regs[b]["uso"] == "sft"
    assert R.read_artifact(regs[b]["saida"]["n1"]) == {"conceito": {"texto": "B"}}
    assert R.last("thumb:x-001", arquivo="thumb_0.png")["id"] == a


def test_portao_reprovado_e_veredito_invalido():
    r = R.write("peca_html", grupo="peca:p", contexto={}, saida={"id": "p"}, origem="claude",
                 portao={"ok": False, "erros": ["lint"]})
    assert next(R.records("peca_html"))["uso"] == "descartar"
    R.evaluate(r, "descartada", motivo="lint")
    assert next(R.records("peca_html"))["uso"] == "dpo_ruim"
    with pytest.raises(ValueError):
        R.evaluate(r, "talvez")
    with pytest.raises(ValueError):
        R.write("inexistente", grupo="g", contexto={}, saida={}, origem="x")


def test_contexto_grande_vai_para_artefato_e_linha_truncada_e_ignorada():
    R.write("montar", grupo="ep:a", contexto={"texto": "x" * 20_000}, saida=[], origem="traducao")
    arq = next(R.RECORD.glob("**/montar/*.jsonl"))
    with open(arq, "a") as f:
        f.write('{"id": "rg_quebrado", "t"')  # escrita interrompida
    regs = list(R.records("montar"))
    assert len(regs) == 1 and "ref" in regs[0]["contexto"]
    assert R.read_artifact(regs[0]["contexto"]["ref"])["texto"] == "x" * 20_000


def test_indice_reconstroi_e_conta():
    for k in range(3):
        rg = R.write("foto_tratar", grupo=f"foto:{k}", contexto={}, saida={"foco": "sujeito"}, origem="local:t")
        if k:
            R.evaluate(rg, "aprovada")
    assert index.reindex() == 3
    s = index.status()["foto_tratar"]
    assert s["total"] == 3 and s["sft"] == 2 and s["pendente"] == 1 and not s["pronta"]
    assert len(index.query(tarefa="foto_tratar", uso="sft")) == 2
