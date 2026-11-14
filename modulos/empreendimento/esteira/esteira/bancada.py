"""Bancada de LLM: mede cada modelo local nas tarefas reais do Estúdio, contra um gabarito.

Gabarito em `$AGENT_DATA/empreendimento/bancada/gabarito/<tarefa>.jsonl` (um caso por linha). `gerar()` monta
`corte` e `legenda` a partir dos episódios produzidos (com `revisao.json`: exclusões e rótulos corrigidos);
`intencao`/`cena` vêm de rótulos feitos à mão e `visao` de quadros com defeitos conhecidos. As aprovações dos
portões do Estúdio entram aqui depois, como casos novos.
`rodar()` chama o llama-server direto (sem cache nem Opções), com o esquema forçado, e grava nota, JSON válido,
latência, tokens/s e VRAM por modelo × tarefa em `resultados/<data>.json`.
"""
import json
import re
import subprocess
import time
import unicodedata
from datetime import datetime
from difflib import SequenceMatcher
from typing import Literal

import requests
from pydantic import BaseModel, Field, ValidationError

from esteira.ia import llama
from esteira.ia.local import _data_url, prompt
from esteira.projeto import DADOS, PROJETOS

PASTA = DADOS / "bancada"
GABARITO = PASTA / "gabarito"
RESULTADOS = PASTA / "resultados"

INTENCOES = ("numero", "comparacao", "processo", "lista", "citacao", "conceito", "pergunta", "virada", "cta",
             "emocao")
# vocabulário de cenas da biblioteca (fase 4); "midia" = só imagem/vídeo de banco, sem peça
CENAS = {
    "contador": "um número dito em destaque, contando até o valor",
    "barras_comparacao": "dois ou mais valores comparados em barras",
    "versus": "duas opções lado a lado (A × B), com ou sem número",
    "passo_a_passo": "um passo, regra ou etapa de um método",
    "lista_itens": "itens enumerados entrando um a um",
    "linha_do_tempo": "datas ou anos em sequência",
    "citacao_estudo": "estudo, pesquisa ou autor citado, com ano e fonte",
    "conceito_icone": "ideia abstrata explicada com ícone e palavra-chave",
    "pergunta_destaque": "pergunta ao espectador em destaque",
    "titulo_capitulo": "virada ou início de um bloco do vídeo",
    "frase_destaque": "frase curta de impacto em tipografia grande",
    "cta": "chamada para comentar, ver outro vídeo ou seguir",
    "anel_percentual": "porcentagem ou proporção dita (81,7%; 8 em cada 10), anel que preenche junto com o número",
    "grade_proporcao": "proporção 'N em cada M' ou porcentagem como grade 10 × 10 que acende",
    "equacao": "conta ou cálculo dito (200 × 60 = 12 mil), termo a termo até o resultado",
    "grafico_linha": "evolução de um valor no tempo, linha que se desenha até o último ponto",
    "ranking": "três ou mais itens ordenados por valor, do maior para o menor",
    "termo_tecnico": "termo técnico ou nome de produto definido em cartão de dicionário",
    "alerta": "cuidado, aviso ou dica importante",
    "lettering": "frase curta de impacto em tipografia cinética, palavra a palavra, ocupando a tela",
    "riscado": "o que deixar de fazer ou de pagar, riscado na tela",
    "carimbo": "conclusão curta e firme (pronto, aprovado, proibido) carimbada",
    "midia": "só imagem ou vídeo ilustrativo, sem peça animada",
}
NUMERICAS = {"contador", "barras_comparacao", "versus", "linha_do_tempo", "anel_percentual", "grade_proporcao",
             "equacao", "grafico_linha", "ranking"}


class Intencao(BaseModel):
    intencao: Literal[INTENCOES]


class Valor(BaseModel):
    rotulo: str = Field(max_length=40)
    valor: str = Field(max_length=20)


class Cena(BaseModel):
    cena: Literal[tuple(CENAS)]
    ancora: str = Field(max_length=60)
    titulo: str = Field(max_length=60)
    valores: list[Valor] = Field(max_length=4)


class Legenda(BaseModel):
    texto: str = Field(max_length=400)


class Decisao(BaseModel):
    manter: bool
    motivo: str = Field(max_length=120)
    confianca: float = Field(ge=0, le=1)


class EscolhaPeca(BaseModel):
    """Direção por bloco: 1 das 5 candidatas (prompt `direcao_escolha`)."""
    escolha: str
    motivo: str = ""


class Visao(BaseModel):
    texto_cortado: bool
    sobreposicao: bool
    ilegivel: bool
    rosto_coberto: bool


# ── avaliação (funções puras, testadas em tests/test_bancada.py) ──

def normalizar(s):
    s = unicodedata.normalize("NFKD", s.lower())
    s = "".join(c for c in s if not unicodedata.combining(c))
    return " ".join(re.sub(r"[^\w%]+", " ", s).split())


def numeros(s):
    """Números como sequência de dígitos ("81,7%" → "817", "1.200" → "1200")."""
    return {re.sub(r"\D", "", n) for n in re.findall(r"\d[\d.,]*", s)}


def wer(a, b):
    a, b = normalizar(a).split(), normalizar(b).split()
    d = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        ant, d[0] = d[0], i
        for j, y in enumerate(b, 1):
            ant, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, ant + (x != y))
    return d[len(b)] / max(len(b), 1)


def so_trocas(dito, certo):
    """Erro de reconhecimento, não fala diferente do roteiro: só trocas de som parecido (ou número partido),
    sem palavra acrescentada nem omitida pelo narrador."""
    a, b = normalizar(dito).split(), normalizar(certo).split()
    ops = [o for o in SequenceMatcher(None, a, b, autojunk=False).get_opcodes() if o[0] != "equal"]
    if not ops:
        return False
    for op, i1, i2, j1, j2 in ops:
        x, y = " ".join(a[i1:i2]), " ".join(b[j1:j2])
        partido = x.replace(" ", "") == y.replace(" ", "")
        if not partido and (op != "replace" or SequenceMatcher(None, x, y).ratio() < 0.6):
            return False
    return True


def nota_cena(caso, r):
    frase = caso["frase"]
    n = 0.5 * (r.cena in caso["aceitas"])
    n += 0.25 * bool(r.ancora.strip() and normalizar(r.ancora) in normalizar(frase))
    ditos = numeros(frase)
    usados = set().union(*[numeros(v.valor) for v in r.valores], numeros(r.titulo))
    inventados = usados - ditos
    if r.cena in NUMERICAS and ditos:
        n += 0.25 * bool(usados & ditos and not inventados)
    else:
        n += 0.25 * (not inventados)
    return n


def nota_legenda(caso, r):
    antes, depois = wer(caso["whisper"], caso["certo"]), wer(r.texto, caso["certo"])
    return 1.0 if depois < antes else 0.5 if depois == antes else 0.0


def nota_visao(caso, r):
    certo = caso["certo"]
    return sum(getattr(r, k) == v for k, v in certo.items()) / len(certo)


# ── tarefas: caso → (prompt, esquema, imagens) e nota ──

def _catalogo():
    return "\n".join(f"- {k}: {v}" for k, v in CENAS.items())


def _prompt_n1(tarefa, caso):
    from esteira.dataset import exportar, inferir
    return inferir.prompt(tarefa, caso["contexto"], fora=exportar.ouro(tarefa))


def _esquema_n1(tarefa):
    from esteira.dataset import exportar
    return exportar.esquema(tarefa)


def _f1(a, b):
    from collections import Counter
    ca, cb = Counter(a), Counter(b)
    comum = sum((ca & cb).values())
    return 0.0 if not comum else 2 * comum / (sum(ca.values()) + sum(cb.values()))


def nota_n1(tarefa, caso, r):
    """Nota estrutural 0–1: metade "roda" (executor/compilador aceita), metade semelhança com a referência."""
    ref, d = caso["referencia"], r.model_dump(mode="json")
    if tarefa == "foto_tratar":
        perto = abs(d["foco"][0] - ref["foco"][0]) + abs(d["foco"][1] - ref["foco"][1]) < 0.3
        return (perto + (d["recortar"] == ref["recortar"]) + (d["separar_planos"] == ref["separar_planos"])) / 3
    if tarefa in ("montar", "corrigir_montagem"):
        from esteira.n1 import filmcraft as FC
        chave = lambda o: (o["op"], o.get("trilha") or o.get("tipo") or o.get("movimento"))  # noqa: E731
        try:
            class _Falso:
                def run(self, cmd, **p):
                    return {"items": [f"i{k}" for k in range(len(p.get("paths", [])))], "errors": [],
                            "clips": ["c"], "clip": "c", "item": "i"}
            midias = {o["midia"]: {"caminho": "/x", "dur": 60} for o in d["ops"] if o.get("midia")}
            midias.setdefault("legendas", {"caminho": "/x"})
            FC.Executor(_Falso(), midias, {"fonte": "x", "fonte_estilo": "x",
                                          "cores": {"texto": "#fff", "destaque": "#fff", "acento": "#fff"}}).executar(d)
            roda = 1.0
        except (FC.ErroN1, KeyError, ValueError):
            roda = 0.0
        return 0.5 * roda + 0.5 * _f1([chave(o) for o in d["ops"]], [chave(o) for o in ref["ops"]])
    if tarefa == "thumb_compor":
        tipos = lambda x: [e["tipo"] for e in x["elementos"]]  # noqa: E731
        tit = lambda x: next((e["conteudo"] for e in x["elementos"] if e["tipo"] == "titulo"), "")  # noqa: E731
        return 0.5 * _f1(tipos(d), tipos(ref)) + 0.5 * (len(tit(d).split()) <= 4 and bool(tit(d)))
    if tarefa == "peca_animar":
        from esteira.n1 import effectcraft as EC
        try:
            EC.compilar(d, {"encaixes": {}, "botoes": {}, "batidas": {}, "t0": 0.3, "dur": 6, "w": 1920, "h": 1080})
            roda = 1.0
        except (EC.ErroN1, KeyError, ValueError):
            roda = 0.0
        tipos = lambda x: [e["tipo"] for e in x["elementos"]] + [a["anim"] for a in x.get("animacoes", [])]  # noqa: E731
        return 0.5 * roda + 0.5 * _f1(tipos(d), tipos(ref))
    return 0.0


TAREFAS = {
    "intencao": (lambda c: (prompt("estudio_intencao", frase=c["frase"], antes=c.get("antes", "")), Intencao, None),
                 lambda c, r: float(r.intencao in c["aceitas"])),
    "cena": (lambda c: (prompt("estudio_cena", frase=c["frase"], antes=c.get("antes", ""), catalogo=_catalogo(),
                                       guia="", exemplos="(nenhum)"),
                        Cena, None), nota_cena),
    "legenda": (lambda c: (prompt("estudio_legenda", texto=c["whisper"], canal=c.get("canal", "")), Legenda, None),
                nota_legenda),
    "corte": (lambda c: (prompt("corte", **c["campos"]), Decisao, None),
              lambda c, r: float(r.manter == c["manter"])),
    "visao": (lambda c: (prompt("estudio_visao"), Visao, [str(GABARITO / c["imagem"])]), nota_visao),
    # direção por bloco: o momento e as 5 candidatas que o código achou → a peça que a pessoa aprovou ou trocou
    **{f"n1_{t}": (lambda c, t=t: (_prompt_n1(t, c), _esquema_n1(t), None), lambda c, r, t=t: nota_n1(t, c, r))
       for t in ("peca_animar", "montar", "corrigir_montagem", "thumb_compor", "foto_tratar")},
    "bloco_peca": (lambda c: (prompt("direcao_escolha", texto=c["texto"], intencao=c.get("intencao", ""),
                                     tom=c.get("tom", ""), tratamento=c.get("tratamento", ""),
                                     numeros=c.get("numeros", "") or "nenhum", candidatas=c["candidatas"]),
                              EscolhaPeca, None),
                   lambda c, r: float(r.escolha in c["aceitas"])),
}


def casos(tarefa):
    if tarefa.startswith("n1_"):  # tarefas das Craft Apps: o ouro do dataset (docs/PLANO-DATASET.md)
        from esteira.dataset import exportar
        return exportar.casos_eval(tarefa[3:])
    arq = GABARITO / f"{tarefa}.jsonl"
    return [json.loads(linha) for linha in arq.read_text().splitlines() if linha.strip()] if arq.exists() else []


# ── gerar corte e legenda a partir dos episódios ──

def gerar(canal="finlumia"):
    """Reescreve corte.jsonl e legenda.jsonl do canal; devolve {tarefa: n}."""
    rev = json.loads((GABARITO / "revisao.json").read_text()) if (GABARITO / "revisao.json").exists() else {}
    fora, corrigidos = set(rev.get("excluir", [])), rev.get("manter", {})
    fora_legenda = set(rev.get("excluir_legenda", []))
    corte, legenda = [], []
    for ep in sorted(p for p in (PROJETOS / canal).iterdir() if (p / "cortes.json").exists()):
        frases = json.loads((ep / "frases.json").read_text())
        trechos = json.loads((ep / "cortes.json").read_text())["trechos"]
        for k, t in enumerate(trechos):
            id_ = f"{ep.name}:{k}"
            # só o que o LLM decidiu (o resto é regra); o par A/B tem outra tarefa
            if "→" not in t["motivo"] or "(par)" in t["motivo"] or id_ in fora:
                continue
            antes = next((x["texto"] for x in reversed(trechos[:k]) if x["manter"]), "")
            depois = next((x["texto"] for x in trechos[k + 1:] if x["manter"]), "")
            ka, kb = t.get("entre", [0, 0])
            regiao = [frases[i]["texto"] for i in range(max(ka, 0), min(kb + 1, len(frases)))][:4]
            corte.append({"id": id_, "manter": corrigidos.get(id_, t["manter"]), "campos": {
                "antes": " ".join(antes.split()[-25:]), "depois": " ".join(depois.split()[:25]),
                "roteiro": json.dumps(regiao, ensure_ascii=False), "trecho": t["texto"], "tipo": t["tipo"],
                "motivo": t["motivo"].split(" → ")[0]}})
        palavras = json.loads((ep / "transcricao.json").read_text())["palavras"]
        for i, f in enumerate(frases):
            dito = " ".join(p["p"] for p in palavras if f["ini"] - 0.05 <= p["ini"] < f["fim"])
            if dito and so_trocas(dito, f["texto"]) and f"{ep.name}:{i}" not in fora_legenda:
                legenda.append({"id": f"{ep.name}:{i}", "whisper": dito, "certo": f["texto"], "canal": canal})
    GABARITO.mkdir(parents=True, exist_ok=True)
    for nome, itens in (("corte", corte), ("legenda", legenda)):
        (GABARITO / f"{nome}.jsonl").write_text("".join(json.dumps(c, ensure_ascii=False) + "\n" for c in itens))
    return {"corte": len(corte), "legenda": len(legenda)}


# ── rodar ──

def _vram_gb():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10).stdout
        return round(int(out.split()[0]) / 1024, 1)
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        return None


def _chamar(modelo, texto, esquema, imagens=None, max_tokens=1200):
    msg = {"role": "user", "content": str(texto)}
    if imagens:
        msg["content"] = [{"type": "text", "text": str(texto)}] + [
            {"type": "image_url", "image_url": {"url": _data_url(i)}} for i in imagens]
    corpo = {"model": modelo, "messages": [msg], "temperature": 0.1, "max_tokens": max_tokens,
             "response_format": {"type": "json_object", "schema": esquema.model_json_schema()},
             "chat_template_kwargs": {"enable_thinking": False, "reasoning_effort": "low"}}
    t = time.monotonic()
    r = requests.post(f"{llama.HOST}/v1/chat/completions", json=corpo, timeout=(10, 600))
    r.raise_for_status()
    d = r.json()
    tim = d.get("timings") or {}
    return d["choices"][0]["message"].get("content") or "", time.monotonic() - t, tim.get("predicted_per_second")


def rodar(modelos, tarefas=None, n=None, progresso=print):
    """Roda cada modelo em cada tarefa; devolve e grava o resultado."""
    if not llama.servidor():
        raise RuntimeError("llama-server fora do ar")
    disponiveis = {m["id"]: m for m in llama.modelos() or []}
    tarefas = tarefas or list(TAREFAS)
    res = {"data": datetime.now().isoformat(timespec="seconds"), "modelos": {}}
    for modelo in modelos:
        if modelo not in disponiveis:
            progresso(f"{modelo}: ausente no roteador, pulado")
            continue
        llama.descarregar()
        t0 = time.monotonic()
        try:
            _chamar(modelo, "Responda ok.", Legenda)  # carrega o modelo
        except requests.RequestException as e:
            progresso(f"{modelo}: não carregou ({str(e)[:120]})")
            continue
        info = {"carga_s": round(time.monotonic() - t0, 1), "vram_gb": _vram_gb(), "tarefas": {}}
        for tarefa in tarefas:
            if tarefa == "visao" and not llama.visao(disponiveis[modelo]):
                continue
            lista = casos(tarefa)[:n]
            if not lista:
                continue
            montar, avaliar = TAREFAS[tarefa]
            notas, validos, tempos, tps, respostas = [], 0, [], [], []
            for i, caso in enumerate(lista, 1):
                texto, esquema, imagens = montar(caso)
                try:
                    conteudo, dt, v = _chamar(modelo, texto, esquema, imagens,
                                              6000 if tarefa.startswith("n1_") else 1200)
                    r = esquema.model_validate_json(conteudo)
                    validos += 1
                    nota = avaliar(caso, r)
                    respostas.append({"id": caso.get("id"), "nota": nota, "r": r.model_dump()})
                except (ValidationError, ValueError, requests.RequestException) as e:
                    dt, v, nota = 0, None, 0.0
                    respostas.append({"id": caso.get("id"), "nota": 0.0, "erro": str(e)[:200]})
                notas.append(nota)
                tempos.append(dt)
                if v:
                    tps.append(v)
                if i % 10 == 0:
                    progresso(f"{modelo} · {tarefa} {i}/{len(lista)}")
            item = {"n": len(lista), "nota": round(sum(notas) / len(notas), 3),
                    "json_ok": round(validos / len(lista), 3),
                    "ms": round(1000 * sum(tempos) / max(len([t for t in tempos if t]), 1)),
                    "tok_s": round(sum(tps) / len(tps), 1) if tps else None, "respostas": respostas}
            if tarefa == "corte":  # gabarito desequilibrado (mais "sai"): acurácia balanceada
                por = {b: [r["nota"] for r, c in zip(respostas, lista, strict=True) if c["manter"] == b] for b in (True, False)}
                item["balanceada"] = round(sum(sum(v) / len(v) for v in por.values() if v) / 2, 3)
            info["tarefas"][tarefa] = item
            progresso(f"{modelo} · {tarefa}: nota {item['nota']} · json {item['json_ok']} · {item['ms']} ms")
        info["vram_gb"] = max(filter(None, [info["vram_gb"], _vram_gb()]), default=None)
        res["modelos"][modelo] = info
        # grava a cada modelo: uma falha no meio não perde o que já foi medido
        RESULTADOS.mkdir(parents=True, exist_ok=True)
        (RESULTADOS / f"{res['data'].replace(':', '-')}.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    llama.descarregar()
    return res


def ultimo():
    """A medição mais recente de cada modelo (de todas as rodadas), sem as respostas caso a caso; ou None."""
    arqs = sorted(RESULTADOS.glob("*.json")) if RESULTADOS.exists() else []
    if not arqs:
        return None
    res = {"data": None, "modelos": {}}
    for arq in arqs:
        r = json.loads(arq.read_text())
        res["data"] = r["data"]
        res["modelos"].update(r["modelos"])
    for info in res["modelos"].values():
        for item in info["tarefas"].values():
            item.pop("respostas", None)
    return res


def tabela(res=None):
    """Linhas de texto: modelo × tarefa (nota / ms), do resultado dado ou do último gravado."""
    if res is None:
        arqs = sorted(RESULTADOS.glob("*.json"))
        if not arqs:
            return ["sem resultados"]
        res = json.loads(arqs[-1].read_text())
    tarefas = list(TAREFAS)
    linhas = [f"{'modelo':34} {'VRAM':>5} " + " ".join(f"{t:>14}" for t in tarefas)]
    for m, info in res["modelos"].items():
        cel = []
        for t in tarefas:
            x = info["tarefas"].get(t)
            cel.append(f"{x.get('balanceada', x['nota']):.2f}/{x['ms']:>5}ms".rjust(14) if x else "—".rjust(14))
        linhas.append(f"{m[:34]:34} {info.get('vram_gb') or 0:>5} " + " ".join(cel))
    return linhas
