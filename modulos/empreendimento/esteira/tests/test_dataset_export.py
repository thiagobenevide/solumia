"""Exportação: trechos da montagem, divisão por grupo, ouro fora do treino e pares DPO."""
import json

from esteira import bench
from esteira.dataset import export as X
from esteira.dataset import registry as R


def _montagem(dur=120):
    ops = [{"op": "sequencia", "nome": "e"}, {"op": "colocar", "id": "narracao", "midia": "narracao",
                                               "trilha": "narracao", "em": 0}]
    for k in range(0, int(dur), 10):
        ops += [{"op": "colocar", "id": f"c{k}", "midia": f"cena:{k}", "trilha": "base", "em": k, "dur": 10},
                {"op": "ken_burns", "alvo": f"c{k}", "movimento": "zoom_in", "zoom": 8}]
    return {"versao": 1, "ops": ops}


def test_trechos_da_montagem_cobrem_tudo_sem_repetir():
    doc = _montagem()
    ctx = {"duracao": 120, "cenas": [{"id": k, "inicio": k} for k in range(0, 120, 10)], "graficos": [], "chaves": []}
    parts = X.spans_assembly(ctx, doc)
    assert len(parts) == 3 and parts[0][0]["trecho"] == [0.0, 45.0]
    everything = [json.dumps(o, sort_keys=True) for _, d in parts for o in d["ops"]]
    assert sorted(everything) == sorted(json.dumps(o, sort_keys=True) for o in doc["ops"])
    assert parts[0][1]["ops"][0]["op"] == "sequencia" and all(c["inicio"] >= 45 for c in parts[1][0]["cenas"])


def test_exportar_divide_por_grupo_tira_o_ouro_e_monta_dpo():
    for g in range(12):
        for v in ("escolhida", None):
            rg = R.write("foto_tratar", grupo=f"foto:{g}", contexto={"g": g}, origem="t",
                          saida={"foco": [0.5, 0.5], "recortar": v is None, "separar_planos": False})
            if v:
                R.evaluate(rg, v)
            else:
                R.evaluate(rg, "reprovada", motivo="recorte desnecessário")
    r = X.export(["foto_tratar"])
    t = r["tarefas"]["foto_tratar"]
    assert t["sft"] + t["val"] + t["eval"] == 12 and t["eval"] >= 1 and t["dpo"] == 12
    folder = X.last()
    line = json.loads((folder / "sft/foto_tratar.train.jsonl").read_text().splitlines()[0])
    assert [m["role"] for m in line["messages"]] == ["system", "user", "assistant"]
    assert json.loads(line["messages"][2]["content"])["recortar"] is False
    assert "manifesto" in json.loads((folder / "manifesto.json").read_text())
    cases = bench.cases("n1_foto_tratar")
    assert cases and bench.score_n1("foto_tratar", cases[0],
                                     X.schema("foto_tratar").model_validate(cases[0]["referencia"])) == 1.0
