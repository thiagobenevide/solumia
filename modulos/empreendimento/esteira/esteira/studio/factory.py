"""Fábrica de peças (`docs/PLANO-ACERVO.md`): o Claude gera peças, o portão confere e a pessoa revisa. É o único
lugar em que o Claude trabalha no Estúdio; depois, a produção de cada vídeo usa só a IA local.

- Pedido (app → Estúdio → Fábrica): `livre` ("3 linhas do tempo com fotos de época"), `referencia` (imagem
  enviada) ou `lacunas` (o código conta o acervo por intenção × peso e pede o que falta); quantidade (o freio é a cota da assinatura, `claude.QUOTA_LIMIT`).
- `./dark studio-factory fabrica:<pedido>` (fila, vaga "claude"): primeiro as tarefas pedidas na revisão (ajuste,
  variação), depois gera até o pedido ter `quantidade` peças aprovadas + em revisão, ou até a cota do Claude chegar a 90%.
- Cada geração: Claude (`ai/claude.query`) escreve peça + ficha seguindo `pecas/GUIA.md` → portão de entrada
  (`peca.portao`) + checagem visual local nos quadros da prova → reprovou: volta ao Claude uma vez com o erro;
  reprovou de novo: descartada com o motivo.
- Revisão (app): aprovar (entra no acervo), pedir ajuste (nova rodada na mesma peça), variação (irmã com outro
  visual), reprovar (motivo vira lição no guia e o pedido volta à fila para repor).
Dados em `$AGENT_DATA/empreendimento/estudio/fabrica/` (pedidos, registro, referências, reprovadas).
"""
import copy
import itertools
import json
import os
import re
import shutil
import time
from datetime import date, datetime
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field, ValidationError

from esteira.core import events, trace
from esteira.studio import piece as P
from esteira.ai import claude
from esteira.project import DATA, ROOT

FOLDER = DATA / "estudio" / "fabrica"
REQUESTS = FOLDER / "pedidos.json"
RECORD = FOLDER / "registro.jsonl"
REFS = FOLDER / "referencias"
REJECTED = FOLDER / "reprovadas"
GUIDE = P.FOLDER / "GUIA.md"
GUIDE_EC = P.FOLDER / "GUIA_EC.md"
GUIDE_N1_EC = P.FOLDER / "GUIA_N1_EC.md"
ENGINES = FOLDER / "motores.json"
EXPANSION = FOLDER / "ampliacao.json"  # ampliação contínua do acervo pelas lacunas (ligada pela pessoa no app)  # decisão de motor por intenção (aplicada pela pessoa a partir da comparação)
REFERENCE = "numero_impacto"   # peça mostrada ao Claude como exemplo do formato
REFERENCE_EC = "numero_impacto_ec"
EXAMPLE_BOXES = P.FOLDER / "_ec" / "exemplo_caixas.n1.json"  # exemplo da LLM local: layout só por caixas
# o guia vai inteiro em todo prompt da LLM local (contexto de 16k): as lições têm teto; as antigas vão para o arquivo
LESSONS_MAX_CAR = 6000
LESSONS_FILE = P.FOLDER / "_ec" / "licoes_arquivo.md"
LESSON_SIMILAR = 0.5  # semelhança (palavras em comum ÷ todas) a partir da qual a regra nova repete uma do guia
LESSONS_PER_PIECE = 3  # teto de regras de uma mesma peça (guia + arquivo)
# prompt da LLM local: 16384 tokens de contexto − 7000 da resposta ≈ 9300 tokens ≈ 28 mil caracteres (~3,2 car/token)
DOSSIER_MAX_CAR = 28000
SAMPLE_MIN = 3                 # peças revisadas por motor para a comparação sugerir um motor numa intenção
META_GAP = 2                 # peças por intenção × peso para a lacuna fechar
WEIGHTS_GAP = ("2d", "2_5d")
MODEL_LOCAL = "gemma-4-26b-a4b-it-ud-q3_k_xl"  # ia "local": MoE, ~50 tok/s; só motor html (EC não cabe em 16k)
CAP_CALL = 0.8              # US$ por geração (peça inteira com ficha é a resposta mais longa do sistema)
STANDALONE = "avulso"               # pedido das peças que não vieram de um pedido (ajuste/variação delas)


class Task(BaseModel):
    tipo: Literal["ajuste", "variacao"]
    alvo: str
    comentario: str = ""


class Request(BaseModel):
    id: str = Field(pattern=r"^[a-z0-9-]{3,40}$")
    tipo: Literal["livre", "referencia", "lacunas", "porte", "ideias"] = "livre"
    alvos: list[str] = Field(default_factory=list)  # porte: peças HTML a portar para EffectCraft (N1), na ordem
    feitos: list[str] = Field(default_factory=list)  # porte: alvos já tentados (portados ou descartados)
    texto: str = ""
    referencia: str = ""                    # arquivo em REFS (imagem)
    quantidade: int = Field(3, ge=0, le=50)
    # html | effectcraft | ambos (o mesmo pedido nos dois motores, para comparar) | auto (decisão por intenção)
    motor: Literal["html", "effectcraft", "ambos", "auto"] = "html"
    # quem escreve as peças: "local" não gasta a cota; "hibrido" = o Claude só cria (ideias em lote) ou socorre e a
    # LLM local faz o pesado (porte HTML → N1, ideia → N1, correções)
    ia: Literal["claude", "local", "hibrido"] = "claude"
    conceitos: list[dict] = Field(default_factory=list)  # ideias: fila de {ficha, conceito} criados pelo Claude
    locais: int = 0       # peças feitas só pela LLM local
    socorros: int = 0     # peças em que o Claude precisou entrar
    teto_dia_usd: float = Field(3.0, ge=0.1, le=50)
    estado: Literal["ativo", "pausado", "concluido"] = "ativo"
    criado: str = ""
    pecas: list[str] = Field(default_factory=list)       # geradas por este pedido (em revisão ou aprovadas)
    tarefas: list[Task] = Field(default_factory=list)  # pedidas na revisão
    descartadas: int = 0
    gasto_usd: float = 0.0
    situacao: str = ""                      # última coisa que aconteceu (para o app)
    # etapa em andamento (painel da fábrica): {nome: ideias|n1|portao|revisao, peca, rodada, de, desde}
    etapa: dict = Field(default_factory=dict)
    anexos: list[str] = Field(default_factory=list)  # arquivos da esteira mostrados ao Claude como referência
    pares: list[list[str]] = Field(default_factory=list)  # motor "ambos": [peça html, peça effectcraft] do mesmo pedido


class PieceGenerated(BaseModel):
    """Resposta do Claude: os três arquivos da peça."""
    id: str = Field(description="id da peça: minúsculas, números e _ (3–40)")
    peca_js: str = Field("", description="conteúdo do peca.js (motor html)")
    peca_jsx: str = Field("", description="(antigo) conteúdo do peca.jsx; prefira peca_n1")
    peca_n1: dict[str, Any] = Field(default_factory=dict, description="peça em N1 (motor effectcraft; GUIA_N1_EC)")
    peca_css: str = Field("", description="conteúdo do peca.css (só seletores dentro de .p-<id>)")
    ficha: dict[str, Any] = Field(description="ficha.json completo (esquema no guia)")
    resumo: str = Field("", description="uma frase: o que a peça faz e o que a diferencia")


class PieceN1Local(BaseModel):
    """Resposta da LLM local no modo híbrido: só a peça em N1 (a ficha vem do HTML de partida ou da ideia do
    Claude). O esquema N1 vira gramática: a resposta sempre é um documento válido."""
    peca_n1: Any = Field(description="documento N1 da peça (GUIA_N1_EC)")
    comunica: str = Field("", description="uma frase: o que a peça comunica, se o visual mudou")


class Idea(BaseModel):
    ficha: P.Card = Field(description="ficha.json completa (estado \"rascunho\", motor \"effectcraft\")")  # esquema real
    conceito: str = Field(description="composição, hierarquia e movimento da peça em 4–8 frases, com tempos")


class Ideas(BaseModel):
    """Resposta do Claude no pedido `ideias`: só a parte criativa, várias peças por chamada."""
    itens: list[Idea]


class PieceLocal(BaseModel):
    """Resposta do LLM local (só motor html): o código vem primeiro e é obrigatório. Com os campos opcionais
    do `PecaGerada`, a gramática deixava o modelo responder só a ficha."""
    id: str = Field(description="id da peça: minúsculas, números e _ (3–40)")
    peca_js: str = Field(min_length=300, description="conteúdo COMPLETO do peca.js: ESTUDIO.peca(\"<id>\", (k, c) => {...})")
    peca_css: str = Field(description="conteúdo do peca.css (só seletores dentro de .p-<id>); pode ser vazio")
    ficha: P.Card = Field(description="ficha.json completo (esquema no guia)")  # esquema real: sem intenção inventada
    resumo: str = Field(description="uma frase: o que a peça faz e o que a diferencia")


# ---------------------------------------------------------------- pedidos

def _read():
    if not REQUESTS.exists():
        return {}
    return {p["id"]: Request.model_validate(p) for p in json.loads(REQUESTS.read_text())}


def _write(requests):
    FOLDER.mkdir(parents=True, exist_ok=True)
    REQUESTS.write_text(json.dumps([p.model_dump() for p in requests.values()], ensure_ascii=False, indent=1))


def requests():
    return sorted(_read().values(), key=lambda p: p.criado, reverse=True)


def request(pid):
    p = _read().get(pid)
    if not p:
        raise KeyError(f"pedido inexistente: {pid}")
    return p


def _change(pid, **fields):
    everything = _read()
    p = everything.get(pid) or Request(id=pid, quantidade=0, criado=_now())
    everything[pid] = p.model_copy(update=fields)
    _write(everything)
    if "situacao" in fields:
        trace.detail(f"{pid}: {fields['situacao']}")
    return everything[pid]


def _now():
    return datetime.now().isoformat(timespec="seconds")


# primeira peça da fábrica e régua de qualidade de todas (docs/PLANO-ACERVO.md, "Peça de referência")
QUOTE = (
    "Peça de CITAÇÃO DE ESTUDO (a régua de qualidade do acervo). A página do artigo aparece em perspectiva 2,5D "
    "(CSS 3D: perspective + rotateY/rotateX suaves), a câmera percorre a página e aproxima até o trecho citado, o resto "
    "da página desfoca, o marca-texto passa linha a linha sobre os grifos acompanhando a fala (batida no encaixe "
    "`trecho_en`), e ao lado (16:9) ou abaixo (9:16) entram autores, título em serifa itálica, revista/ano, o trecho "
    "original em inglês e a tradução em destaque, com o selo \"link na descrição\". Encaixes: `pagina` (tipo "
    "pagina, 1–6 grifos; a página vem de graficos/pdf.imagem_da_pagina com os retângulos em px), `autores`, `titulo`, "
    "`revista`, `trecho_en`, `traducao`. Botões: lado da ficha (direita/esquerda), intensidade da perspectiva "
    "(leve/forte), selo do link (sim/nao). Use o modelo antigo anexado como referência de ritmo e hierarquia, "
    "mas tudo pela pele (variáveis) e pelos utilitários do kit.")


def request_quote(daily_cap_usd=3.0, engine="html"):
    """Pedido pronto da primeira peça: a citação de PDF, com o modelo antigo anexado."""
    p = new_request("livre", QUOTE, 1, daily_cap_usd, engine=engine)
    return _change(p.id, anexos=["esteira/graphics/modelos/citacao.html"])


def new_request(kind, text="", quantidade=3, daily_cap_usd=3.0, reference="", engine="html", ai_mode="claude"):
    if kind == "livre" and not text.strip():
        raise ValueError("descreva o que gerar")
    if kind == "referencia" and not reference:
        raise ValueError("envie a imagem de referência")
    base = re.sub(r"[^a-z0-9]+", "-", (text or kind).lower())[:24].strip("-") or kind
    pid = f"{datetime.now():%m%d-%H%M%S}-{base}"[:40].strip("-")
    p = Request(id=pid, tipo=kind, texto=text.strip(), quantidade=quantidade, teto_dia_usd=daily_cap_usd,
               reference=reference, criado=_now(), motor="html" if ai_mode == "local" else engine, ia=ai_mode)
    everything = _read()
    everything[pid] = p
    _write(everything)
    _register("pedido", pedido=pid, tipo=kind, texto=text, quantidade=quantidade, motor=p.motor, ia=ai_mode)
    return p


def store_reference(name, data):
    REFS.mkdir(parents=True, exist_ok=True)
    name = re.sub(r"[^\w.-]+", "_", name)[-80:]
    if not re.search(r"\.(png|jpe?g|webp)$", name, re.I):
        raise ValueError("referência: imagem png, jpg ou webp")
    (REFS / name).write_bytes(data)
    return name


def enqueue(pid):
    """Põe o pedido na fila da vaga "claude" (não duplica se já está lá)."""
    from esteira.web import queue
    return queue.add(f"fabrica:{pid}", "studio-factory", [], "claude")


def pause(pid, pausado=True):
    request(pid)
    if not pausado:
        _register("retomado", pedido=pid)
    return _change(pid, estado="pausado" if pausado else "ativo", situacao="pausado" if pausado else "retomado")


def _register(event, **dados):
    FOLDER.mkdir(parents=True, exist_ok=True)
    with open(RECORD, "a") as f:
        f.write(json.dumps({"t": _now(), "evento": event, **dados}, ensure_ascii=False) + "\n")


def record(n=60):
    if not RECORD.exists():
        return []
    return [json.loads(x) for x in RECORD.read_text().splitlines()[-n:]][::-1]


# ---------------------------------------------------------------- acervo × lacunas

def _in_library():
    return [f for f in P.list_all() if f.estado in ("aprovada", "revisao")]


def gaps():
    """Intenção × peso com menos de META_LACUNA peças (aprovadas ou em revisão), as mais vazias primeiro."""
    cards = _in_library()
    output = []
    for intent in P.INTENTS:
        for weight in WEIGHTS_GAP:
            has = sum(1 for f in cards if intent in f.intencoes and f.peso == weight)
            if has < META_GAP:
                output.append({"intencao": intent, "peso": weight, "tem": has, "falta": META_GAP - has})
    return sorted(output, key=lambda x: (x["tem"], P.INTENTS.index(x["intencao"]), x["peso"]))


def spent_today():
    from esteira.ai import claude
    today = date.today().isoformat()
    return round(sum((r.get("cost") or 0) for r in claude._records()
                     if str(r.get("ep", "")).startswith("fabrica") and r["t"].startswith(today)), 4)


# ---------------------------------------------------------------- geração

def _files(id_):
    p = P.folder(id_)
    read = lambda n: (p / n).read_text() if (p / n).exists() else ""  # noqa: E731
    return {"peca.js": read("peca.js"), "peca.css": read("peca.css"), "peca.n1.json": read("peca.n1.json"),
            "peca.jsx": "" if (p / "peca.n1.json").exists() else read("peca.jsx"), "ficha.json": read("ficha.json")}


def _block(id_):
    a = _files(id_)
    return "\n".join(f"--- {n}\n{t.strip()}" for n, t in a.items() if t.strip())


def _library_summary():
    lines = [f"- {f.id}: {f.comunica} (intenções: {', '.join(f.intencoes)}; peso {f.peso}; {f.estado})"
              for f in P.list_all()]
    return "\n".join(lines) or "(vazio)"


def next_size(p: Request) -> str | None:
    """Próxima peça HTML do porte: ainda não tentada, ainda existente e sem irmã EffectCraft."""
    for a in p.alvos:
        if a in p.feitos or not (P.folder(a) / "ficha.json").exists() or (P.folder(f"{a}_ec"[:40]) / "ficha.json").exists():
            continue
        return a
    return None


def request_size(states=("aprovada", "revisao", "rascunho")) -> Request:
    """Pedido de porte de todas as peças HTML do acervo para EffectCraft em N1: aprovadas primeiro (melhor
    referência), depois as em revisão. Cada porte é 1 chamada (+1 se o portão reprovar) e herda a ficha inteira."""
    order = {e: k for k, e in enumerate(states)}
    cards = sorted((f for f in P.list_all() if f.motor == "html" and f.estado in order),
                    key=lambda f: (order[f.estado], f.id))
    p = new_request("porte", "porte das peças HTML para EffectCraft (N1)", quantidade=min(len(cards), 50),
                    daily_cap_usd=50, engine="effectcraft")
    return _change(p.id, alvos=[f.id for f in cards])


def _task_new(p: Request):
    if p.tipo == "lacunas":
        lc = gaps()
        if not lc:
            return "The library has no gaps by intent × weight: create a useful piece for a poorly covered intent."
        x = lc[0]
        return (f"Library gap: create a piece with intent '{x['intencao']}' and weight '{x['peso']}' "
                f"(there are {x['tem']} today).")
    if p.tipo == "referencia":
        return ("Create a piece inspired by the reference image (structure, rhythm and hierarchy; NEVER copy colors "
                "or fonts, the skin belongs to the channel). "
                + (f"The person's note (in Brazilian Portuguese): {p.texto}" if p.texto else ""))
    return f"The person's request (in Brazilian Portuguese): {p.texto}"


def dossier(p: Request, mode="nova", target="", comment="", errors=(), engine="html", task=None):
    """Prompt da geração. `modo`: nova | ajuste | variacao | corrigir (portão reprovou); `motor`: html | effectcraft."""
    if mode == "ajuste":
        task = (f"Rewrite the piece '{target}' following the person's adjustment request (in Brazilian "
                  f"Portuguese): {comment}\nKeep the id '{target}' and increase `versao` by 1. "
                  f"Current code:\n{_block(target)}")
    elif mode == "variacao":
        task = (f"Create a SIBLING of the piece '{target}': same intent and same slots, clearly different look and "
                  f"motion (another composition, another entrance). New id. Code of the original:\n{_block(target)}")
    elif mode == "porte":
        task = (f"EffectCraft (N1) version of the HTML piece '{target}', which already exists and was reviewed. Keep "
                  f"the CONTRACT of the ficha: intents, slots, buttons, examples and limits (only `motor` becomes "
                  f"\"effectcraft\"). The look and the motion may bring NEW PATTERNS: use what EffectCraft does "
                  f"better than HTML (2.5D depth, blur, growing strokes, counters, camera) for a richer piece than "
                  f"the original, without losing readability. Adjust `comunica` (in Brazilian Portuguese) if the look "
                  f"changes. Id: {target}_ec. Starting HTML piece:\n{_block(target)}")
    elif mode == "corrigir":
        task = ("The piece below was REJECTED by the automatic gate. Fix every error, keeping the idea and the "
                  "id.\nErrors:\n" + "\n".join(f"- {e}" for e in errors) + f"\nCode:\n{_block(target)}")
    else:
        task = task or _task_new(p)
    if engine == "effectcraft":
        from esteira.n1 import effectcraft as N1EC
        head = ("You write motion graphics pieces for the Studio library (YouTube videos in Brazilian Portuguese) in "
                  "the EffectCraft engine. The piece is an N1 document (JSON of elements and animations), NOT code: the "
                  "compiler generates the script. Follow the guides and the schema to the letter; the automatic gate "
                  "rejects whatever strays from them. The guides below are in Portuguese.\n\n"
                  f"=== EFFECTCRAFT N1 GUIDE ===\n{GUIDE_N1_EC.read_text()}\n\n"
                  f"=== N1 SCHEMA (JSON Schema) ===\n{json.dumps(N1EC.Piece.model_json_schema(), ensure_ascii=False)}\n\n"
                  f"=== GENERAL GUIDE (ficha, slots, maximum text, lessons) ===\n{GUIDE.read_text()}\n\n"
                  f"=== EFFECTCRAFT ENGINE LESSONS ===\n{GUIDE_EC.read_text()}\n\n"
                  f"=== FORMAT REFERENCE PIECE ({REFERENCE_EC}) ===\n{_block(REFERENCE_EC)}\n\n")
        answer = ("Respond with id, peca_n1 (the N1 document), ficha (complete object, estado \"rascunho\", motor "
                    "\"effectcraft\") and resumo. ")
    else:
        head = ("You write motion graphics pieces for the Studio library (YouTube videos in Brazilian Portuguese, "
                  "HyperFrames + GSAP). Follow the guide to the letter; the automatic gate rejects whatever strays from "
                  "it. The guide below is in Portuguese.\n\n"
                  f"=== PIECE WRITING GUIDE ===\n{GUIDE.read_text()}\n\n"
                  f"=== FORMAT REFERENCE PIECE ({REFERENCE}) ===\n{_block(REFERENCE)}\n\n")
        answer = ("Respond with id, peca_js, peca_css, ficha (complete object, estado \"rascunho\", motor \"html\") "
                  "and resumo. ")
    return (
        head +
        f"=== CURRENT LIBRARY (do not duplicate; complement it) ===\n{_library_summary()}\n\n"
        + "".join(f"=== ATTACHMENT {a} ===\n{(ROOT / a).read_text()}\n\n" for a in p.anexos if (ROOT / a).is_file())
        + f"=== TASK ===\n{task}\n\n" + answer +
        "Slots with honest limits and real examples; 5–10 exemplos_sim and 3–5 exemplos_nao taken from scripts in "
        "Brazilian Portuguese. Every text of the piece and of the ficha (descricao, comunica, sample texts) stays in "
        "Brazilian Portuguese.\n"
        f"(request {p.id} · {_now()})"
    )


def _id_free(base):
    base = re.sub(r"[^a-z0-9_]", "_", base.lower()).strip("_")[:36] or "peca"
    if not re.match(r"[a-z]", base):
        base = "p_" + base
    if len(base) < 3:
        base = (base + "_peca")[:36]
    id_, n = base, 2
    while P.folder(id_).exists():
        id_, n = f"{base}_{n}", n + 1
    return id_


def _compose(g: PieceGenerated, id_, version=None, engine="html"):
    d = P.folder(id_)
    d.mkdir(parents=True, exist_ok=True)
    if engine == "effectcraft":
        for n in ("peca.js", "peca.css"):
            if (d / n).exists():
                (d / n).unlink()
        if g.peca_n1:  # N1: o compilador gera o script; um .jsx antigo da mesma peça sai
            (d / "peca.n1.json").write_text(json.dumps(g.peca_n1, ensure_ascii=False, indent=1) + "\n")
            if (d / "peca.jsx").exists():
                (d / "peca.jsx").unlink()
        else:
            (d / "peca.jsx").write_text((g.peca_jsx or g.peca_js).strip() + "\n")
        card = {**g.ficha, "id": id_, "estado": "rascunho", "motor": "effectcraft"}
        if version:
            card["versao"] = version
        card.setdefault("origem", "fabrica")
        (d / "ficha.json").write_text(json.dumps(card, ensure_ascii=False, indent=1) + "\n")
        return
    for n in ("peca.jsx", "peca.n1.json"):
        if (d / n).exists():
            (d / n).unlink()
    js = re.sub(r"ESTUDIO\.peca\(\s*[\"'][^\"']+[\"']", f'ESTUDIO.peca("{id_}"', g.peca_js, count=1)
    css = re.sub(r"\.p-[a-z0-9_]+", f".p-{id_}", g.peca_css) if g.peca_css else ""
    (d / "peca.js").write_text(js.strip() + "\n")
    if css.strip():
        (d / "peca.css").write_text(css.strip() + "\n")
    elif (d / "peca.css").exists():
        (d / "peca.css").unlink()
    card = {**g.ficha, "id": id_, "estado": "rascunho", "motor": "html"}
    if version:
        card["versao"] = version
    card.setdefault("origem", "fabrica")
    (d / "ficha.json").write_text(json.dumps(card, ensure_ascii=False, indent=1) + "\n")


def check_visual(id_):
    """IA local olha os quadros da prova (texto cortado, sobreposição, ilegível). Sem modelo de visão: pula."""
    from esteira.bench import Vision
    from esteira.ai import local
    problems = []
    # o processo roda com `--motor claude`: sem fixar, a visão iria ao Claude e gastaria a cota da assinatura
    before = {k: os.environ.get(k) for k in ("ESTEIRA_ENGINE", "ESTEIRA_ENGINE_FIXED")}
    os.environ.update(ESTEIRA_ENGINE="local", ESTEIRA_ENGINE_FIXED="1")
    try:
        return _check_frames(id_, Vision, local, problems)
    finally:
        for k, v in before.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def _check_frames(id_, Vision, local, problems):
    for q in sorted((P.folder(id_) / "prova").glob("*.jpg")):
        try:
            r = local.ask(local.prompt("studio_vision_proof"), Vision, model=local.VISION, images=[str(q)],
                                max_tokens=200, operation="studio_vision")
        except Exception as e:  # noqa: BLE001 — llama fora do ar não pode travar a fábrica
            events.warning(f"checagem visual pulada: {str(e)[:100]}")
            return []
        if r:
            bad = [k for k, v in r.model_dump().items() if v and k != "rosto_coberto"]
            if bad:
                problems.append(f"visão local em {q.stem}: {', '.join(bad)}")
    return problems


def _gate(id_, visual=True):
    r = P.gate(id_)
    if r["ok"] and visual and (vis := check_visual(id_)):
        r = {**r, "ok": False, "erros": vis}
        card = P.load(id_)
        P.save(card.model_copy(update={"estado": "rascunho"}))
        (P.folder(id_) / "prova" / "portao.json").write_text(json.dumps(r, ensure_ascii=False, indent=1))
    return r


def _discard(id_, reason):
    destination = REJECTED / f"{id_}-{datetime.now():%Y%m%d%H%M%S}"
    REJECTED.mkdir(parents=True, exist_ok=True)
    if P.folder(id_).exists():
        shutil.move(str(P.folder(id_)), destination)
        (destination / "motivo.txt").write_text(reason)


def _query(p: Request, text, image=None):
    if p.ia == "local":
        return _query_local(text), 0.0
    from esteira.ai import claude
    ep = f"fabrica-{date.today().isoformat()}"
    before = claude.spent(ep)[0]
    cfg = {"claude": {"teto_chamada_usd": CAP_CALL}}  # sem teto diário: o limite é a cota da assinatura (90%)
    g = claude.query(text, PieceGenerated, cfg, ep, "fabrica_peca", image=image)
    return g, round(claude.spent(ep)[0] - before, 4)


def _query_local(text):
    """A peça pelo LLM local (JSON forçado pelo esquema). Sem imagem de referência. O processo da fábrica
    roda na vaga "claude" com `--motor claude`: aqui o motor local é fixado só durante a chamada."""
    from esteira.ai import local
    before = {k: os.environ.get(k) for k in ("ESTEIRA_ENGINE", "ESTEIRA_ENGINE_FIXED")}
    os.environ.update(ESTEIRA_ENGINE="local", ESTEIRA_ENGINE_FIXED="1")
    try:
        # o número da tentativa muda o texto: sem ele o cache devolveria a mesma peça descartada
        r = local.ask(f"{text}\n\n(attempt {time.time_ns()})", PieceLocal, model=MODEL_LOCAL,
                            temperature=0.5, max_tokens=9000, operation="factory")
        return r and PieceGenerated(**r.model_dump(mode="json"))
    finally:
        for k, v in before.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def generate(p: Request, mode="nova", target="", comment="", visual=True, engine=None, task=None, idea=None):
    """Uma peça (nova, ajuste ou variação) com uma rodada de correção. → {"id", "ok", "custo", "motivo", "motor"}.
    Motor: o da peça-alvo (ajuste/variação), senão `motor`, senão o do pedido (resolvido por `motor_do_pedido`).
    Híbrido (porte e ideias): a LLM local faz a peça em N1 (duas rodadas); se o portão reprovar as duas, o Claude
    socorre com o caminho normal (`quem` no resultado: local | socorro)."""
    if p.ia == "hibrido" and mode in ("porte", "conceito"):
        r = _generate_local_n1(p, mode, target, idea, visual)
        if r["ok"]:
            return {**r, "quem": "local"}
        if claude.quota_full() or mode == "porte" or not FALLBACK_IDEAS:  # o Claude fica só com o criativo
            return {**r, "quem": "local"}
        if mode == "conceito":  # socorro: o Claude escreve a peça da própria ideia
            task = (f"Write the piece for this idea (the local LLM could not: {r['motivo'][:200]}).\n"
                      f"Ficha: {json.dumps(idea['ficha'], ensure_ascii=False)}\nConcept: {idea['conceito']}")
            mode, target = "nova", ""
        fallback = generate(p.model_copy(update={"ia": "claude"}), mode, target, comment, visual, "effectcraft", task)
        return {**fallback, "custo": fallback["custo"], "quem": "socorro"}
    if mode == "porte":
        engine = "effectcraft"
    elif target and (P.folder(target) / "ficha.json").exists():
        engine = P.load(target).motor
    engine = engine or engine_of_request(p)
    start = time.monotonic()
    image = str(REFS / p.referencia) if p.tipo == "referencia" and p.referencia and mode == "nova" else None
    text = dossier(p, mode, target, comment, engine=engine, task=task)
    g, cost = _query(p, text, image)
    if not g:
        who = "o LLM local" if p.ia == "local" else "o Claude"
        return {"id": target or None, "ok": False, "custo": cost, "motivo": f"{who} não respondeu (teto ou erro)",
                "motor": engine}
    copy = None
    if mode == "ajuste":
        id_ = target
        version = P.load(target).versao + 1
        copy = FOLDER / "copias" / f"{target}-{datetime.now():%Y%m%d%H%M%S}"  # volta se o ajuste não passar
        shutil.copytree(P.folder(target), copy, ignore=shutil.ignore_patterns("prova"))
    elif mode == "porte":
        id_, version = _id_free(f"{target}_ec"[:40]), None
    else:
        id_, version = _id_free(g.id), None
    _compose(g, id_, version, engine)
    r = _gate(id_, visual)
    rounds = 1
    ctx = {"pedido": {"tipo": p.tipo, "texto": p.texto, "referencia": p.referencia}, "modo": mode, "alvo": target,
           "comentario": comment, "motor": engine, "tarefa": str(task or "")}
    rg = _dataset(p, ctx, text, g, r, id_, target if mode in ("ajuste", "variacao", "porte") else id_, engine)
    if not r["ok"]:
        events.warning(f"fábrica: {id_} reprovada no portão; volta ao Claude uma vez")
        text2 = dossier(p, "corrigir", id_, errors=r["erros"], engine=engine)
        g2, c2 = _query(p, text2)
        cost += c2
        rounds = 2
        if g2:
            _compose(g2, id_, version, engine)
            r = _gate(id_, visual)
            rg = _dataset(p, {**ctx, "modo": "corrigir", "erros": r.get("erros", [])}, text2, g2, r, id_,
                          target if mode in ("ajuste", "variacao", "porte") else id_, engine, parent=rg)
    base = {"pedido": p.id, "peca": id_, "modo": mode, "motor": engine, "rodadas": rounds, "custo": cost,
            "segundos": round(time.monotonic() - start, 1), "render_s": r.get("render_s"),
            "intencoes": _intents(id_)}
    if not r["ok"]:
        reason = "; ".join(r["erros"][:4])
        if copy:  # o ajuste não passou: a versão anterior volta para a revisão, com o motivo nas notas
            shutil.rmtree(P.folder(id_))
            shutil.copytree(copy, P.folder(id_))
            P.gate(id_)  # refaz a prova da versão anterior
            card = P.load(id_)
            P.save(card.model_copy(update={"estado": "revisao", "notas": f"ajuste reprovado: {reason}"[:400]}))
        else:
            _discard(id_, reason)
        _evaluate_dataset(rg, "descartada", motivo=reason)
        _register("descartada", **base, motivo=reason)
        return {"id": id_, "ok": False, "custo": cost, "motivo": reason, "motor": engine}
    if copy:
        shutil.rmtree(copy, ignore_errors=True)
    _register("gerada", **base, resumo=g.resumo)
    return {"id": id_, "ok": True, "custo": cost, "motivo": "", "motor": engine}


def _dataset(p: Request, ctx, text, g, r, id_, group, engine, parent=None):
    """Rodada da fábrica no registro do dataset (falha aqui nunca derruba a fábrica). → id do registro."""
    try:
        from esteira.dataset import registry as R
        return R.write(
            "peca_animar" if engine == "effectcraft" else "peca_html", group=f"peca:{group}", parent=parent,
            context=ctx, output=g.model_dump(mode="json"),
            origin="claude" if p.ia == "claude" else f"local:{MODEL_LOCAL}",
            gate={"ok": bool(r.get("ok")), "erros": r.get("erros", [])[:8], "render_s": r.get("render_s")},
            versions={"guia": _sha_guide(engine)}, extra={"peca": id_, "pedido": p.id, "prompt": R.artifact(text)})
    except Exception as e:  # noqa: BLE001
        events.warning(f"dataset: rodada de {id_} não gravada ({e})")
        return None


def _evaluate_dataset(rg, verdict, **kw):
    if not rg:
        return
    try:
        from esteira.dataset import registry as R
        R.evaluate(rg, verdict, **kw)
    except Exception as e:  # noqa: BLE001
        events.warning(f"dataset: veredito de {rg} não gravado ({e})")


def _verdict_piece(id_, verdict, **kw):
    """Decisão da pessoa vai para a última rodada da peça no dataset."""
    try:
        from esteira.dataset import registry as R
        rg = R.last(peca=id_)
    except Exception:  # noqa: BLE001
        rg = None
    _evaluate_dataset(rg and rg["id"], verdict, **kw)


def _sha_guide(engine):
    import hashlib
    guide = P.FOLDER / ("GUIA_EC.md" if engine == "effectcraft" else "GUIA.md")
    return hashlib.sha1(guide.read_bytes()).hexdigest()[:10] if guide.exists() else None


BATCH_IDEAS = 8  # ideias por chamada do Claude (a parte criativa é curta; o pesado fica com a LLM local)
FALLBACK_IDEAS = False  # socorro do Claude custa ~2x um lote de 8 ideias por peça: desligado (o lote rende mais)
ROUNDS_LOCALS = 4  # tentativas da LLM local com o erro do portão (de graça) antes de desistir ou do socorro


def _compact(x):
    """N1 sem os campos vazios/padrão (None, {}, [], False): a versão anterior cabe no prompt da LLM local."""
    if isinstance(x, dict):
        return {k: _compact(v) for k, v in x.items() if v not in (None, {}, [], False)}
    return [_compact(v) for v in x] if isinstance(x, list) else x


def _dossier_local(mode, card, target="", idea=None, errors=(), draft=None, previous=None, already_seen=()):
    """Prompt compacto para a LLM local (cabe em 16k com a resposta): guia N1, a ficha, a origem e o RASCUNHO do
    molde (N1 que já compila e passa no portão). A LLM adapta o rascunho; não monta a peça do zero. Depois de uma
    reprovação, a base é a VERSÃO ANTERIOR dela com os erros e as causas: corrige o que foi apontado, não refaz."""
    base = ("Start from the DRAFT below: it is already right (boxes, regions, slots of the ficha, animations) and "
            "only needs to take on the look of the idea." if previous is None else
            "Below is YOUR PREVIOUS VERSION, rejected for the errors listed at the end. Fix ONLY what the errors and "
            "the causes point out, in the field indicated, and keep everything else the same; do not redo the piece "
            "from scratch.")
    base += " Keep the `nome` of each element: the code matches your version to the draft by it."
    parts = ["You adapt an EffectCraft motion graphics piece in N1 (JSON). Respond with peca_n1 (the complete "
              f"document) and comunica (in Brazilian Portuguese). {base} You may: change levels, weights, "
              "fonts and colors (by role only), timings and the entrance type of the animations; add shapes INSIDE "
              "the existing boxes; create variants with `se` for the ficha's buttons (`{\"botao\": nome, "
              "\"igual\": valor}`, only values the button has; each value changes something visible). You may "
              "not: remove elements that show slots, leave a box empty, create top-level boxes in regions already "
              "used, write x/y/w/h/d/tam, use a slot or button name the ficha does not declare. A button you do "
              "not use is removed from the ficha automatically (better than a variant that changes nothing). The "
              "guide below is in Portuguese.",
              f"=== N1 GUIDE ===\n{GUIDE_N1_EC.read_text()}",
              f"=== FICHA (contract: slots, buttons, intents) ===\n{json.dumps(card, ensure_ascii=False)}"]
    if previous is not None:
        parts.append(f"=== YOUR PREVIOUS VERSION (rejected; fix only what was pointed out) ===\n"
                      f"{json.dumps(_compact(previous), ensure_ascii=False)}")
    elif draft is not None:
        parts.append(f"=== DRAFT (template filled in by the code; start from it) ===\n"
                      f"{json.dumps(draft, ensure_ascii=False)}")
    else:
        parts.append(f"=== N1 EXAMPLE (donut with caption, boxes only) ===\n"
                      f"{json.dumps(json.loads(EXAMPLE_BOXES.read_text()), ensure_ascii=False)}")
    if mode == "porte":
        # o que sobra do orçamento vai para o código de partida (o guia, a ficha e o rascunho não podem ser cortados)
        free = (DOSSIER_MAX_CAR - sum(len(x) for x in parts) - 1500
                 - sum(len(e) + 3 for e in [*errors, *already_seen]))
        js = (P.folder(target) / "peca.js").read_text()[:max(1000, min(6000, free))]
        parts.append(f"=== STARTING HTML PIECE (the same idea; use it only as inspiration for rhythm and highlight) ===\n{js}")
    else:
        parts.append(f"=== IDEA (from the creative director) ===\n{idea['conceito']}")
    if errors:
        parts.append("=== ERRORS OF THE PREVIOUS VERSION (fix each one in the N1) ===\n" + "\n".join(f"- {e}" for e in errors))
    if already_seen:
        parts.append("=== ALREADY POINTED OUT IN EARLIER ROUNDS (do not go back to them) ===\n"
                      + "\n".join(f"- {e}" for e in already_seen))
    return "\n\n".join(parts)


def _query_n1_local(text):
    from esteira.ai import local
    from esteira.n1 import effectcraft as N1EC

    class Answer(BaseModel):
        piece_n1: N1EC.Piece
        comunica: str = ""
    before = {k: os.environ.get(k) for k in ("ESTEIRA_ENGINE", "ESTEIRA_ENGINE_FIXED")}
    os.environ.update(ESTEIRA_ENGINE="local", ESTEIRA_ENGINE_FIXED="1")
    try:
        r = local.ask(f"{text}\n\n(attempt {time.time_ns()})", Answer, model=MODEL_LOCAL, temperature=0.4,
                            max_tokens=7000, operation="fabrica_n1")
        # só o que a LLM escreveu: o que ela omite vem do molde (travar_molde), não do padrão do esquema (peso 400…)
        return r and PieceN1Local(peca_n1=r.peca_n1.model_dump(mode="json", exclude_unset=True), comunica=r.comunica)
    except Exception as e:  # noqa: BLE001 — llama fora do ar ou resposta truncada: vira falha da rodada
        events.warning(f"fábrica: LLM local falhou ({str(e)[:120]})")
        return None
    finally:
        for k, v in before.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


REVIEWS_CLAUDE = 4  # uma revisão por rodada que passa no portão técnico: só a aprovação do Claude leva à pessoa


class ReviewN1(BaseModel):
    aprovada: bool = Field(description="true só se a peça está pronta para um vídeo profissional")
    problemas: list[str] = Field(default_factory=list,
                                 description="o que está errado na tela, concreto: elemento, onde, em qual formato")
    causas: list[str] = Field(default_factory=list, description="qual campo/escolha do N1 causou cada problema")
    regras: list[str] = Field(default_factory=list, description=(
        "regras GERAIS e novas para o guia do autor de N1 (valem para outras peças; imperativas, 1 frase cada); "
        "vazio se as lições atuais já cobrem"))


def _sheet_proof(id_) -> Path | None:
    """Os quadros da prova lado a lado numa imagem (o Claude lê uma imagem por chamada)."""
    qs = sorted((P.folder(id_) / "prova").glob("*.jpg"))
    if not qs:
        return None
    output = P.folder(id_) / "prova" / "folha.png"
    inputs = sum((["-i", str(q)] for q in qs), [])
    criteria = "".join(f"[{i}:v]scale=-2:540[v{i}];" for i in range(len(qs))) + \
        "".join(f"[v{i}]" for i in range(len(qs))) + f"hstack=inputs={len(qs)}"
    r = __import__("subprocess").run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", criteria,
                                      str(output)], capture_output=True)
    return output if r.returncode == 0 and output.exists() else None


def _lessons_n1() -> str:
    t = GUIDE_N1_EC.read_text()
    return t.split("## Lições", 1)[1] if "## Lições" in t else ""


def lesson_n1(rules, id_=""):
    """Regras da revisão do Claude entram no guia N1 (lido pela LLM local em toda geração), sem repetir."""
    t = GUIDE_N1_EC.read_text()
    if "## Lições" not in t:
        t = t.rstrip() + "\n\n## Lições (erros já vistos; não repita)\n"
    # compara também com o arquivo: a regra podada do guia voltava na revisão seguinte (fundo_ondas teve 10 iguais)
    file = LESSONS_FILE.read_text() if LESSONS_FILE.exists() else ""
    everything = t.split("## Lições", 1)[1] + "\n" + file
    already = [_words(x) for x in re.findall(r"^- (?:.*?: )?(.+?)(?: \(peça .*\))?$", everything, re.M)]
    if id_ and everything.count(f"(peça {id_})") >= LESSONS_PER_PIECE:
        return []  # a peça já ensinou o que tinha: mais regras dela só repetem a mesma reprovação com outras palavras
    new = []
    for x in (x.strip().rstrip(".") for x in rules if x.strip()):
        p = _words(x)
        if p and all(len(p & q) / len(p | q) < LESSON_SIMILAR for q in already):
            new.append(x)
            already.append(p)
    # uma por revisão: o 12B não segue muitas regras soltas, e várias da mesma peça diziam quase a mesma coisa
    new = new[:1]
    if new:
        GUIDE_N1_EC.write_text(t.rstrip() + "\n" + "".join(f"- {x} (peça {id_})\n" for x in new))
        prune_lessons()
    return new


def _words(x) -> set[str]:
    """Palavras de 4+ letras da regra: base da semelhança entre lições (parecida = repetida)."""
    return {w for w in re.findall(r"\w+", x.lower()) if len(w) >= 4}


def prune_lessons():
    """Mantém as lições do guia abaixo de LICOES_MAX_CAR: as de base (sem peça) ficam; das revisões, as mais novas.
    As que saem vão para LICOES_ARQUIVO (nada se perde, só sai do prompt). → quantas saíram."""
    t = GUIDE_N1_EC.read_text()
    if "## Lições" not in t:
        return 0
    header, body = t.split("## Lições", 1)
    title, _, rest = body.partition("\n")
    lines = [x for x in rest.splitlines() if x.strip()]
    base = [x for x in lines if not re.search(r"\(peça [^)]*\)\s*$", x)]
    rev = [x for x in lines if x not in base]
    ficam, total = [], sum(len(x) + 1 for x in base)
    for x in reversed(rev):
        if total + len(x) + 1 > LESSONS_MAX_CAR:
            break
        ficam.insert(0, x)
        total += len(x) + 1
    saem = rev[:len(rev) - len(ficam)]
    if saem:
        with LESSONS_FILE.open("a") as f:
            f.write("".join(x + "\n" for x in saem))
        GUIDE_N1_EC.write_text(f"{header}## Lições{title}\n" + "".join(x + "\n" for x in base + ficam))
    return len(saem)


def _review_claude(id_, card, concept, piece_n1):
    """O Claude revisa a prova que passou no portão local: aprova ou diz o problema, a causa no N1 e a regra geral
    (que vai para o guia da LLM local). → (RevisaoN1 | None, custo)."""
    sheet = _sheet_proof(id_)
    if not sheet:
        return None, 0.0
    text = ("You review motion graphics pieces made by a local LLM in N1 (EffectCraft JSON) before they go into "
             "professional YouTube videos in Brazilian Portuguese. The image is the proof sheet: the frames (light/dark "
             "skins, 16:9 and 9:16) side by side, in the middle of the animation. In the proof each text was filled "
             "with the sample REPEATED up to the maximum length: a repeated sentence is the filler, not a defect (but "
             "text going off screen, cut, overlapping, a literal {{...}} placeholder, stacked elements or a "
             "composition that does not communicate the idea are defects). Reject without mercy whatever is not good. "
             "For each problem, state its cause in the N1 and, if it is a mistake the LLM may repeat in other pieces, "
             "one new general rule for the guide (do not repeat the current lessons). The LLM builds the piece with "
             "boxes only (regions, layout, text level) and does NOT write coordinates: write the rules in that "
             "vocabulary, never in x/y/tam/passo. The N1 has NO variant per skin (`se` only tests a button or a "
             "slot; color is by role) and, inside a box, `apos` is ignored: do not propose a rule with that. In "
             "`causas`, name the exact element and field (e.g.: \"Traco: falta h\"), because the LLM fixes its own "
             "version from them. At most ONE rule, only if it is new; write it in Brazilian Portuguese, the language "
             "of the guide.\n\n"
             f"=== N1 GUIDE (current rules) ===\n{GUIDE_N1_EC.read_text()}\n\n"
             f"=== FICHA ===\n{json.dumps({k: card.get(k) for k in ('id', 'descricao', 'intencoes', 'encaixes', 'botoes', 'comunica')}, ensure_ascii=False)}\n\n"
             f"=== CONCEPT ===\n{concept or '(port of an HTML piece)'}\n\n"
             f"=== N1 ===\n{json.dumps(piece_n1, ensure_ascii=False)}")
    ep = f"fabrica-{date.today().isoformat()}"
    before = claude.spent(ep)[0]
    try:
        rev = claude.query(text, ReviewN1, {"claude": {"teto_chamada_usd": 0.3}}, ep, "fabrica_revisao",
                               image=str(sheet))
    except Exception as e:  # noqa: BLE001 — revisão indisponível não derruba a fábrica
        events.warning(f"fábrica: revisão do Claude falhou ({str(e)[:120]})")
        rev = None
    cost = round(claude.spent(ep)[0] - before, 4)
    if rev:
        new = lesson_n1(rev.regras, id_)
        _register("revisao", peca=id_, aprovada=rev.aprovada, problemas=rev.problemas[:6], causas=rev.causas[:6],
                   regras=new, custo=cost)
    return rev, cost


def _buttons_used(doc, buttons):
    """Botões da ficha que o N1 usa (em `se` ou como velocidade): o resto sai da ficha da peça gerada."""
    from esteira.n1 import effectcraft as N1EC
    nodes = list(N1EC.walk(doc.elementos))
    anims = [*doc.animacoes, *(a for e in nodes if e.tipo == "repetir" for a in e.animacoes)]
    used = {c.botao for x in [*nodes, *anims] for c in N1EC.conditions(x.se) if c.botao}
    if doc.botao_velocidade:
        used.add(doc.botao_velocidade)
    return [b for b in buttons if (b.get("nome") if isinstance(b, dict) else b.nome) in used]


def _stage(name, piece="", rounded=0):
    return {"nome": name, "peca": piece, "rodada": rounded, "de": ROUNDS_LOCALS, "desde": datetime.now().isoformat(timespec="seconds")}


LOCKED = ("w", "h", "d", "pesos", "disposicao", "regiao", "elementos")  # estrutura do molde: a LLM muda, mas não apaga (elementos = itens do `repetir`)


def lock_mold(doc: dict, mold: dict) -> dict:
    """Completa a versão da LLM com o molde, por nome do elemento: campo que ela não escreveu vem do molde (não do
    padrão do esquema: a peça perdia peso 800, raio, caps…), os estruturais apagados (vazio/None) voltam e as chaves
    do `vertical` do molde que sumiram também. Ela perdia rodadas consertando o que o molde já acertava."""
    def piece_by_name(els, output):
        for e in els or []:
            output[e.get("nome")] = e
            piece_by_name(e.get("filhos") or e.get("elementos"), output)
        return output
    base, doc = piece_by_name(mold.get("elementos"), {}), copy.deepcopy(doc)
    for name, e in piece_by_name(doc.get("elementos"), {}).items():
        if (m := base.get(name)) is None or m.get("tipo") != e.get("tipo"):
            continue
        for k, v in m.items():
            if k not in e and k not in ("filhos", "elementos"):
                e[k] = copy.deepcopy(v)
        for k in LOCKED:
            if m.get(k) is not None and e.get(k) in (None, [], ""):
                e[k] = copy.deepcopy(m[k])
        if m.get("vertical"):
            e["vertical"] = {**m["vertical"], **(e.get("vertical") or {})}
    for k, v in mold.items():  # fundo_tela_cheia, botao_velocidade, animacoes que ela não escreveu
        if k not in doc and k != "elementos":
            doc[k] = copy.deepcopy(v)
    _restore_fits(doc, mold, piece_by_name)
    _prune_blocks(doc)
    existem = set(piece_by_name(doc.get("elementos"), {}))  # animação de elemento renomeado/apagado não compilava
    doc["animacoes"] = [a for a in doc.get("animacoes") or [] if a.get("alvo") in existem]
    return doc


def _prune_blocks(doc):
    """Tira o retângulo de cor forte sozinho numa caixa (sem `w`/`h`, vira um bloco do tamanho dela) e a caixa que
    ficar vazia: a LLM insistia nele rodada após rodada. Painel em `fundo`/`fundo2` ou translúcido fica."""
    def block_of(e):
        return (e.get("tipo") == "retangulo" and not (e.get("w") and e.get("h")) and not e.get("proporcional")
                and e.get("cor", "destaque") not in ("fundo", "fundo2") and e.get("opacidade", 100) > 40)
    tirados = set()
    def prune(els):
        output = []
        for e in els:
            if e.get("tipo") == "caixa":
                children = e.get("filhos") or []
                if len(children) == 1 and block_of(children[0]):
                    tirados.add(children[0].get("nome"))
                    children = []
                e["filhos"] = prune(children)
                if not e["filhos"]:
                    tirados.add(e.get("nome"))
                    continue
            output.append(e)
        return output
    doc["elementos"] = prune(doc.get("elementos") or [])
    if tirados:
        doc["animacoes"] = [a for a in doc.get("animacoes") or [] if a.get("alvo") not in tirados]


def _fits_of(el) -> set[str]:
    txt = json.dumps(el, ensure_ascii=False)
    return ({m for m in re.findall(r"\{\{(\w+)", txt)} | set(re.findall(r'"encaixe": "(\w+)"', txt))) - {"item"}


def _marks(el) -> set[str]:
    """O que o elemento mostra: marcadores {{x}} / {{item.campo}} e o encaixe de um `repetir`."""
    txt = json.dumps(el, ensure_ascii=False)
    return set(re.findall(r"\{\{([\w.]+)\}\}", txt)) | {f"lista:{x}" for x in re.findall(r'"encaixe": "(\w+)"', txt)}


def _restore_fits(doc, mold, by_name):
    """Elemento do molde que mostra um encaixe e sumiu da versão da LLM (e o encaixe não aparece em outro lugar)
    volta, na caixa-mãe de mesmo nome ou no nível de cima, com as animações dele. Sem ele o portão reprovava e ela
    não sabia recriar (ficava presa devolvendo a mesma versão)."""
    def walk_elements(els, parent=None):
        for e in els or []:
            yield e, parent
            yield from walk_elements(e.get("filhos") or e.get("elementos"), e)
    for el, parent in walk_elements(mold.get("elementos")):
        names = by_name(doc.get("elementos"), {})
        destination = names.get(parent.get("nome")) if parent else None
        mostra = _marks(el)
        if el.get("nome") in names or not mostra:
            continue
        only_item = all(m.split(".")[0] == "item" for m in mostra)
        if only_item and destination is None:
            continue
        # campo a campo: {{item.rotulo}} que sumiu volta mesmo que o item ainda mostre {{item.valor}}
        if mostra <= _marks(destination.get("elementos") if only_item else doc.get("elementos")):
            continue
        items = (destination.setdefault("filhos" if destination.get("tipo") == "caixa" else "elementos", [])
                 if destination else doc.setdefault("elementos", []))
        items.append(copy.deepcopy(el))
        new = set(by_name([el], {}))
        doc.setdefault("animacoes", []).extend(copy.deepcopy(a) for a in mold.get("animacoes", [])
                                               if a.get("alvo") in new)


def _base_next(new, previous, mold, errors_new=(), errors_before=()):
    """Base da próxima rodada: a versão dela, salvo se empacou (devolveu igual) ou fugiu do molde (trocou os nomes
    da maior parte dos elementos, e a trava deixa de valer). → (base ou None = molde, aviso para a LLM ou "")."""
    if mold is None:
        return new, ""
    if new == previous:
        return None, ("você devolveu a mesma versão: volte ao RASCUNHO e corrija os erros a partir dele")
    if previous is not None and errors_new and set(errors_new) <= set(errors_before):
        return None, ("o mesmo erro voltou duas vezes: parta do RASCUNHO de novo e, se não souber corrigir um "
                      "elemento que você acrescentou, tire-o")
    def names_in(d):
        out = set()
        def walk_elements(els):
            for e in els or []:
                out.add(e.get("nome"))
                walk_elements(e.get("filhos") or e.get("elementos"))
        walk_elements(d.get("elementos"))
        return out
    m = names_in(mold)
    if m and len(m & names_in(new)) < len(m) / 2:
        return None, ("você trocou a estrutura e os nomes do RASCUNHO: parta dele de novo, mantenha os `nome` dos "
                      "elementos e mude só valores")
    return new, ""


def _seen(errors, already_seen, current):
    """Erros das rodadas anteriores que a versão atual não repete (até 6, os mais novos primeiro)."""
    return [e for e in dict.fromkeys([*errors, *already_seen]) if e not in current][:6]


def _generate_local_n1(p: Request, mode, target, idea, visual):
    """A LLM local faz a peça em N1 a partir do HTML (porte) ou da ideia do Claude; RODADAS_LOCAIS no portão."""
    start = time.monotonic()
    if mode == "porte":
        from esteira.studio import molds as M
        card = M.card_size({k: v for k, v in json.loads((P.folder(target) / "ficha.json").read_text()).items()
                               if k not in ("estado", "notas")})
        id_, group = _id_free(f"{target}_ec"[:40]), target
    else:
        card = dict(idea["ficha"])
        id_ = _id_free(re.sub(r"[^a-z0-9_]", "_", str(card.get("id") or "ideia").lower())[:36] or "ideia")
        group = id_
    ctx = {"pedido": {"tipo": p.tipo, "texto": p.texto}, "modo": mode, "alvo": target, "motor": "effectcraft",
           "conceito": (idea or {}).get("conceito")}
    from esteira.studio import ec as EC
    from esteira.studio import molds as M
    from esteira.n1 import effectcraft as N1EC
    # triagem: o que o N1 não desenha não vai para a LLM local (falharia sempre e gastaria revisão do Claude)
    if reason := M.unfeasible(card, ctx["conceito"] or ""):
        _register("inviavel", pedido=p.id, peca=id_, modo=mode, motor="effectcraft", ia="local", motivo=reason,
                   intencoes=card.get("intencoes", []))
        return {"id": id_, "ok": False, "custo": 0.0, "motivo": f"inviável no N1: {reason}", "motor": "effectcraft",
                "inviavel": True}
    mold, draft = M.draft(card)
    ctx["molde"] = mold
    errors, already_seen, previous, rg = [], [], None, None
    r = {"ok": False, "erros": ["a LLM local não respondeu"]}
    cost, reviews, passou = 0.0, 0, False
    for rounded in range(1, ROUNDS_LOCALS + 1):
        _change(p.id, etapa=_stage("n1", id_, rounded))
        text = _dossier_local(mode, card, target, idea, errors, draft, previous, already_seen)
        if rounded == ROUNDS_LOCALS and not passou:
            # nenhuma versão da LLM chegou à revisão: a última rodada é o próprio rascunho do molde (já testado)
            g = PieceN1Local(peca_n1=draft, comunica=card.get("comunica", ""))
        else:
            g = _query_n1_local(text)
        if not g:
            r = {"ok": False, "erros": ["a LLM local não respondeu (contexto, tempo ou JSON)"]}
            continue
        if draft is not None:
            g = g.model_copy(update={"peca_n1": lock_mold(g.peca_n1, draft)})
        f = {**card, "id": id_, "motor": "effectcraft", "origem": "fabrica_local"}
        if g.comunica:
            f["comunica"] = g.comunica
        doc = N1EC.Piece.model_validate(g.peca_n1)
        f["botoes"] = _buttons_used(doc, f.get("botoes") or [])  # o contrato só declara o que a peça faz
        pg = PieceGenerated(id=id_, peca_n1=g.peca_n1, ficha=f, resumo=g.comunica)
        try:
            structure = EC.check_structure(doc, P.Card.model_validate(f))
        except ValidationError as e:
            structure = [f"ficha fora do esquema: {str(e)[:200]}"]
        if outside := N1EC.loose(doc):
            structure.insert(0, f"elementos fora de caixa: {outside[:6]}. Ponha TUDO dentro de caixas (`regiao` + "
                                "`disposicao`) e tire x/y/w/h/tam: o compilador posiciona")
        if structure:  # sem render nem Claude: o erro de estrutura volta direto para a LLM
            r = {"ok": False, "erros": structure[:8]}
            rg = _dataset(p.model_copy(update={"ia": "local"}), {**ctx, "rodada": rounded, "erros": errors}, text, pg,
                          r, id_, group, "effectcraft", parent=rg)
            already_seen = _seen(errors, already_seen, r["erros"])
            previous, warning = _base_next(g.peca_n1, previous, draft, r["erros"], errors)
            errors = [*r["erros"], *([warning] if warning else [])]
            continue
        try:
            _compose(pg, id_, None, "effectcraft")
            _change(p.id, etapa=_stage("portao", id_, rounded))
            # com a revisão do Claude disponível, a visão local sai do caminho: o erro visual vira diagnóstico + lição
            # (a visão local só dizia sim/não e errava); sem cota, ela volta como filtro
            r = _gate(id_, False)  # técnico (esquema, compila, render, área segura); o visual é a revisão do Claude
            if r["ok"]:  # o portão marca "revisao": até o Claude aprovar, é rascunho (interrupção não vaza peça)
                P.save(P.load(id_).model_copy(update={"estado": "rascunho"}))
        except Exception as e:  # noqa: BLE001 — uma peça ruim reprova a rodada, nunca derruba o lote
            r = {"ok": False, "erros": [f"{type(e).__name__}: {str(e)[:300]}"]}
        rg = _dataset(p.model_copy(update={"ia": "local"}), {**ctx, "rodada": rounded, "erros": errors}, text, pg, r,
                      id_, group, "effectcraft", parent=rg)
        if r["ok"] and visual:  # aprovação explícita do Claude é obrigatória (sem revisão, não passa)
            passou = True
            rev = None
            if reviews < REVIEWS_CLAUDE and not claude.quota_full():
                _change(p.id, etapa=_stage("revisao", id_, rounded))
                rev, c = _review_claude(id_, f, (idea or {}).get("conceito") or "", g.peca_n1)
                cost += c
                reviews += 1
            if rev is None:
                r = {"ok": False, "erros": ["revisão do Claude indisponível (cota ou erro): a peça não vai à pessoa "
                                            "sem aprovação"], "sem_revisao": True}
            elif not rev.aprovada:
                # o sintoma (o que se vê) e a causa (o campo do N1): sem a causa a LLM só adivinhava o conserto
                r = {"ok": False, "erros": ([f"revisão: {x}" for x in rev.problemas][:6] or ["revisão: reprovada"])
                     + [f"causa no N1: {x}" for x in rev.causas][:6]}
            else:
                P.save(P.load(id_).model_copy(update={"estado": "revisao"}))
        if r.get("sem_revisao"):
            break  # sem revisão não adianta gastar mais rodadas da LLM
        if r["ok"]:
            _register("gerada", pedido=p.id, peca=id_, modo=mode, motor="effectcraft", rodadas=rounded, custo=cost,
                       segundos=round(time.monotonic() - start, 1), render_s=r.get("render_s"), ia="local",
                       intencoes=_intents(id_), resumo=g.comunica)
            return {"id": id_, "ok": True, "custo": cost, "motivo": "", "motor": "effectcraft"}
        # a próxima rodada corrige esta versão (não o molde); os erros de antes ficam como "não volte a eles"
        already_seen = _seen(errors, already_seen, r.get("erros", []))
        previous, warning = _base_next(g.peca_n1, previous, draft, r.get("erros", []), errors)
        errors = [*r.get("erros", [])[:12], *([warning] if warning else [])]
    reason = "; ".join(r.get("erros", [])[:4])
    if (P.folder(id_) / "ficha.json").exists():
        _discard(id_, f"local: {reason}")
    _evaluate_dataset(rg, "descartada", motivo=reason)
    _register("descartada", pedido=p.id, peca=id_, modo=mode, motor="effectcraft", rodadas=ROUNDS_LOCALS, custo=cost,
               segundos=round(time.monotonic() - start, 1), render_s=r.get("render_s"), ia="local",
               intencoes=[], motivo=reason)
    return {"id": id_, "ok": False, "custo": cost, "motivo": reason, "motor": "effectcraft"}


def _vocabulary_n1():
    """O que a LLM local consegue fazer em N1: os moldes e os limites (o Claude cria só ideias executáveis)."""
    from esteira.studio import molds as M
    lines = [f"- {m['id']}: {m['descricao']} (intents: {', '.join(m['intencoes'])}; slots: "
              + ", ".join(f"{s['nome']} ({'/'.join(s['tipos'])}{', required' if s.get('obrigatorio') else ''})"
                          for s in m["slots"]) + ")" for m in M.load()]
    return ("Each piece starts from ONE of these templates (the executor adapts colors, timings, emphasis and "
            "button variants):\n"
            + "\n".join(lines) + "\n2D pieces only: texts, bars, lines that draw themselves, circles/rings/slices, "
            "dot grids, cards. Slots only of the types texto, numero, itens and pares. Do NOT propose: photo or "
            "image, icon or illustration, curve/wave/line chart, perspective/horizon/road, 3D/parallax, "
            "map/orbit, free trajectory, background or transition with no content. Write the concept in the "
            "vocabulary of the chosen template and say which one it is.")


def _query_ideas(p: Request, n):
    """O Claude só cria: `n` ideias (ficha + conceito) numa chamada. → (lista de dicts, custo)."""
    from esteira.ai import claude as C
    if p.ia == "local" or C.quota_full():
        return [], 0.0
    text = ("You are the creative director of the Studio's motion graphics library (YouTube in Brazilian "
             f"Portuguese). Create {n} NEW pieces, different from each other and from the library: for each one, the "
             "complete ficha (contract: intents, slots with honest limits, buttons, real exemplos_sim/nao, motor "
             "\"effectcraft\", estado \"rascunho\"; its texts in Brazilian Portuguese) and the concept "
             "(composition, hierarchy and motion in 4–8 sentences, with timings). Do not write code or N1: another "
             "AI executes the concept. The guide below is in Portuguese.\n\n"
             f"=== WHAT THE EXECUTOR CAN DRAW (an idea outside this is discarded without trying) ===\n{_vocabulary_n1()}\n\n"
             f"=== GENERAL GUIDE (ficha, slots) ===\n{GUIDE.read_text()}\n\n"
             f"=== CURRENT LIBRARY (do not duplicate) ===\n{_library_summary()}\n\n"
             f"=== GAPS ===\n{json.dumps(gaps()[:12], ensure_ascii=False)}\n\n"
             f"=== REQUEST ===\n{p.texto or 'fill gaps in the library with pieces useful for videos about finance, history, science'}")
    ep = f"fabrica-{date.today().isoformat()}"
    before = C.spent(ep)[0]
    r = C.query(text, Ideas, {"claude": {"teto_chamada_usd": CAP_CALL}}, ep, "fabrica_ideias")
    return ([i.model_dump(mode="json") for i in r.itens] if r else []), round(C.spent(ep)[0] - before, 4)


def request_hybrid(kind="ideias", quantidade=40, text="") -> Request:
    """Pedido no modo híbrido: `porte` (as HTML → N1 pela LLM local) ou `ideias` (o Claude cria em lote)."""
    if kind == "porte":
        p = request_size()
        return _change(p.id, ia="hibrido")
    p = new_request("ideias", text, quantidade=min(quantidade, 50), daily_cap_usd=50, engine="effectcraft")
    return _change(p.id, ia="hibrido")


def _intents(id_):
    try:
        return P.load(id_).intencoes
    except (KeyError, ValidationError, FileNotFoundError):
        for d in sorted(REJECTED.glob(f"{id_}-*"), reverse=True):  # descartada: a ficha foi junto
            try:
                return json.loads((d / "ficha.json").read_text()).get("intencoes", [])
            except (OSError, ValueError):
                return []
        return []


def _active(p: Request):
    """Peças do pedido que ainda existem e não foram reprovadas."""
    live = []
    for i in p.pecas:
        try:
            if P.load(i).estado in ("revisao", "aprovada"):
                live.append(i)
        except (KeyError, ValidationError):
            continue
    return live


def clean_orphans():
    """Peça da LLM local em rascunho sem aprovação do Claude é sobra de processo interrompido (reinício no meio da
    revisão): vai para `reprovadas/`. Só roda sem fábrica em andamento (início de `rodar` e do painel)."""
    saiu = []
    for f in P.list_all("rascunho"):
        if f.origem == "fabrica_local":
            reason = "órfã: o processo parou antes da aprovação do Claude (reinício no meio da geração)"
            _discard(f.id, reason)
            _register("orfa", peca=f.id, motivo=reason)
            saiu.append(f.id)
    return saiu


def run(pid, visual=True, maximum=80):
    """Modo contínuo do pedido: tarefas da revisão primeiro, depois peças novas até a quantidade ou a cota do Claude."""
    clean_orphans()  # uma fábrica por vez (vaga "claude"): rascunho local que sobrou é de processo morto
    trace.node(f"fabrica:{pid}", "fabrica", f"pedido {pid}")  # nó "Fábrica de peças" no grafo do Monitor
    try:
        return _run(pid, visual, maximum)
    finally:
        trace.node(None, None)
        if pid in _read():
            _change(pid, etapa={})  # o processo saiu: nada em andamento


BRAKE_REQUEST = 3   # descartes seguidos do Claude no mesmo pedido → o pedido pausa
BRAKE_FACTORY = 6  # descartes seguidos do Claude somando os pedidos → todos os pedidos do Claude pausam


def _brake(pid):
    """Gasto de cota sem peça (o mesmo erro se repetindo) → motivo da parada, ou "". Só conta o Claude (custo > 0)."""
    # o freio e a retomada zeram a contagem (senão o pedido retomado pararia de novo na hora)
    recent = itertools.takewhile(lambda r: r.get("evento") not in ("freio", "retomado"), record(400))
    done = [r for r in recent if r.get("evento") in ("gerada", "descartada") and (r.get("custo") or 0) > 0]
    seguidos = list(itertools.takewhile(lambda r: r["evento"] == "descartada", done))
    of_request = list(itertools.takewhile(lambda r: r["evento"] == "descartada",
                                         (r for r in done if r.get("pedido") == pid)))
    if len(seguidos) >= BRAKE_FACTORY:
        return f"freio da fábrica: {len(seguidos)} descartes seguidos ({seguidos[0].get('motivo', '')[:120]})"
    if len(of_request) >= BRAKE_REQUEST:
        return f"freio: {len(of_request)} descartes seguidos ({of_request[0].get('motivo', '')[:120]})"
    return ""


def _apply_brake(pid, reason):
    targets = [x.id for x in requests() if x.ia == "claude" and x.estado == "ativo"] \
        if reason.startswith("freio da fábrica") else [pid]
    for a in targets:
        _change(a, estado="pausado", situacao=reason[:200])
    events.warning(f"fábrica: {reason}")
    _register("freio", pedido=pid, motivo=reason, pausados=targets)
    return request(pid)


def _run(pid, visual, maximum):
    for _ in range(maximum):
        p = request(pid)
        if p.estado == "pausado":
            _change(pid, situacao="pausado")
            return p
        if p.ia == "claude" and (reason := _brake(pid)):
            return _apply_brake(pid, reason)
        if p.ia in ("claude", "hibrido") and claude.quota_full():
            events.warning(f"fábrica: cota da assinatura em {claude.quota():.0%}")
            return _change(pid, situacao=f"cota do Claude em {claude.quota():.0%}: volta quando a janela virar")
        if p.tarefas:
            t, rest = p.tarefas[0], p.tarefas[1:]
            _change(pid, tarefas=rest, situacao=f"{t.tipo} de {t.alvo}")
            r = generate(p, t.tipo, t.alvo, t.comentario, visual)
            new = p.pecas + ([r["id"]] if r["ok"] and t.tipo == "variacao" else [])
            _change(pid, pecas=new, gasto_usd=round(p.gasto_usd + r["custo"], 4),
                   descartadas=p.descartadas + (0 if r["ok"] else 1),
                   situacao=f"{t.tipo} de {t.alvo}: " + ("em revisão" if r["ok"] else f"falhou ({r['motivo'][:80]})"))
            continue
        if p.tipo == "ideias":
            if len(p.pecas) + p.descartadas >= p.quantidade:
                return _change(pid, estado="concluido", situacao=f"ideias concluídas: {len(p.pecas)} peças em revisão")
            if not p.conceitos:
                _change(pid, situacao="o Claude está criando um lote de ideias", etapa=_stage("ideias"))
                new, cost = _query_ideas(p, min(BATCH_IDEAS, p.quantidade - len(p.pecas) - p.descartadas))
                p = _change(pid, conceitos=new, gasto_usd=round(p.gasto_usd + cost, 4))
                if not new:
                    return _change(pid, situacao="o Claude não devolveu ideias (cota ou erro)")
                continue
            idea, rest = p.conceitos[0], p.conceitos[1:]
            _change(pid, conceitos=rest, situacao=f"LLM local expandindo a ideia {idea['ficha'].get('id', '?')}")
            r = generate(p, "conceito", idea=idea, visual=visual)
            p = request(pid)
            _change(pid, pecas=p.pecas + ([r["id"]] if r["ok"] else []), gasto_usd=round(p.gasto_usd + r["custo"], 4),
                   descartadas=p.descartadas + (0 if r["ok"] or r.get("inviavel") else 1),
                   locais=p.locais + (r.get("quem") == "local"),
                   socorros=p.socorros + (r.get("quem") == "socorro"),
                   situacao=f"{r['id']} em revisão ({r.get('quem')})" if r["ok"] else
                   f"{'pulada' if r.get('inviavel') else 'descartada'}: {r['motivo'][:80]}")
            continue
        if p.tipo == "porte":
            target = next_size(p)
            if target is None:
                return _change(pid, estado="concluido", situacao=f"porte concluído: {len(p.pecas)} peças em revisão")
            _change(pid, situacao=f"portando {target} ({len(p.pecas) + p.descartadas + 1} de {len(p.alvos)})")
            r = generate(p, "porte", target, visual=visual)
            if r.get("motivo", "").startswith("o Claude não respondeu"):
                return _change(pid, gasto_usd=round(p.gasto_usd + r["custo"], 4), situacao=r["motivo"])
            p = request(pid)
            _change(pid, pecas=p.pecas + ([r["id"]] if r["ok"] else []), gasto_usd=round(p.gasto_usd + r["custo"], 4),
                   descartadas=p.descartadas + (0 if r["ok"] or r.get("inviavel") else 1), feitos=[*p.feitos, target],
                   locais=p.locais + (r.get("quem") == "local"), socorros=p.socorros + (r.get("quem") == "socorro"),
                   situacao=f"{r['id']} em revisão" if r["ok"] else
                   f"{target}: {'pulada' if r.get('inviavel') else 'descartada'} ({r['motivo'][:80]})")
            continue
        active = _active(p)
        if p.motor == "ambos" and len(active) < 2 * p.quantidade and p.estado != "concluido":
            r = _generate_pair(p, active, visual)
            if r is not None:
                return r
            continue
        active_n = len(active) // 2 if p.motor == "ambos" else len(active)  # "ambos": a quantidade é de pares
        if active_n >= p.quantidade or p.estado == "concluido":
            approved = sum(1 for i in active if P.load(i).estado == "aprovada")
            end = approved >= p.quantidade * (2 if p.motor == "ambos" else 1)
            return _change(pid, pecas=active, estado="concluido" if end else p.estado,
                          situacao="concluído" if end else "aguardando sua revisão")
        _change(pid, situacao=f"gerando peça {len(active) + 1} de {p.quantidade}")
        r = generate(p, "nova", visual=visual)
        if r.get("motivo", "").startswith("o Claude não respondeu"):
            return _change(pid, gasto_usd=round(p.gasto_usd + r["custo"], 4), situacao=r["motivo"])
        _change(pid, pecas=active + ([r["id"]] if r["ok"] else []), gasto_usd=round(p.gasto_usd + r["custo"], 4),
               descartadas=p.descartadas + (0 if r["ok"] else 1),
               situacao=f"{r['id']} em revisão" if r["ok"] else f"descartada: {r['motivo'][:100]}")
        time.sleep(0.2)
    return request(pid)


def _generate_pair(p: Request, active, visual):
    """Motor "ambos": o mesmo pedido (mesma tarefa) no HTML e no EffectCraft; o par entra junto na revisão.
    → Pedido quando o laço deve parar (Claude sem resposta), senão None."""
    task = _task_new(p)
    _change(p.id, situacao=f"gerando par {len(active) // 2 + 1} de {p.quantidade} (HTML e EffectCraft)")
    ids, cost, failures = [], 0.0, 0
    for engine in ("html", "effectcraft"):
        r = generate(p, "nova", visual=visual, engine=engine, task=task)
        cost += r["custo"]
        if r.get("motivo", "").startswith("o Claude não respondeu"):
            return _change(p.id, gasto_usd=round(p.gasto_usd + cost, 4), situacao=r["motivo"],
                          pecas=active + ids)
        if r["ok"]:
            ids.append(r["id"])
        else:
            failures += 1
    current = request(p.id)
    _change(p.id, pecas=active + ids, pares=current.pares + ([ids] if len(ids) == 2 else []),
           gasto_usd=round(current.gasto_usd + cost, 4), descartadas=current.descartadas + failures,
           situacao=f"par em revisão: {' × '.join(ids)}" if ids else "o par foi descartado no portão")
    return None


# ---------------------------------------------------------------- motores: decisão e comparação

def engines():
    """Decisão de motor por intenção (aplicada pela pessoa): {"padrao", "por_intencao": {intenção: motor}}."""
    if ENGINES.exists():
        return json.loads(ENGINES.read_text())
    return {"padrao": "html", "por_intencao": {}}


def apply_engines(by_intent, default="html"):
    FOLDER.mkdir(parents=True, exist_ok=True)
    valid = {k: v for k, v in by_intent.items() if k in P.INTENTS and v in ("html", "effectcraft")}
    d = {"padrao": default if default in ("html", "effectcraft") else "html", "por_intencao": valid, "em": _now()}
    ENGINES.write_text(json.dumps(d, ensure_ascii=False, indent=1))
    _register("motores", **d)
    return d


def engine_of_request(p: Request):
    """Motor de uma peça nova do pedido: o escolhido, ou ("auto") o decidido para a intenção da lacuna."""
    if p.motor in ("html", "effectcraft"):
        return p.motor
    m = engines()
    if p.tipo == "lacunas" and (lc := gaps()):
        return m["por_intencao"].get(lc[0]["intencao"], m["padrao"])
    return m["padrao"]


def comparison():
    """Os dois motores lado a lado, pelo registro da fábrica: geração (portão, rodadas, custo, tempo), render da
    prova, revisão da pessoa (aprovação e nota) e troca de pele; no geral e por intenção, com a sugestão de motor."""
    regs = record(100000)
    engine_of = {}
    for r in regs:
        if r.get("peca") and r.get("motor"):
            engine_of.setdefault(r["peca"], r["motor"])
    for f in P.list_all():
        engine_of.setdefault(f.id, f.motor)

    def empty():
        return {"geradas": 0, "descartadas": 0, "rodadas": 0, "custo": 0.0, "segundos": 0.0, "render_s": [],
                "aprovadas": 0, "reprovadas": 0, "notas": [], "pele_problemas": 0}
    general, by_int = {"html": empty(), "effectcraft": empty()}, {}
    ints_of = {}
    for r in regs:
        m = r.get("motor") or engine_of.get(r.get("peca"))
        if m not in general:
            continue
        ints = r.get("intencoes") or ints_of.get(r.get("peca"), [])
        if r.get("intencoes"):
            ints_of[r["peca"]] = r["intencoes"]
        targets = [general[m]] + [by_int.setdefault(i, {"html": empty(), "effectcraft": empty()})[m] for i in ints]
        for a in targets:
            if r["evento"] in ("gerada", "descartada") and r.get("modo", "nova") == "nova":
                a["geradas" if r["evento"] == "gerada" else "descartadas"] += 1
                a["rodadas"] += r.get("rodadas", 1)
                a["custo"] += r.get("custo") or 0
                a["segundos"] += r.get("segundos") or 0
                if r.get("render_s"):
                    a["render_s"].append(r["render_s"])
            elif r["evento"] in ("aprovada", "reprovada"):
                a["aprovadas" if r["evento"] == "aprovada" else "reprovadas"] += 1
                if r.get("nota"):
                    a["notas"].append(r["nota"])
    file_skin = P.previews_dir("_canais").parent / "_prova_canais" / "resultado.json"
    if file_skin.exists():
        for x in json.loads(file_skin.read_text()).get("problemas", []):
            m = engine_of.get(x["peca"])
            if m in general:
                general[m]["pele_problemas"] += 1

    def close_totals(a):
        attempts = a["geradas"] + a["descartadas"]
        revisadas = a["aprovadas"] + a["reprovadas"]
        return {"geradas": a["geradas"], "descartadas": a["descartadas"],
                "taxa_portao": round(a["geradas"] / attempts, 2) if attempts else None,
                "rodadas_media": round(a["rodadas"] / attempts, 2) if attempts else None,
                "custo_medio": round(a["custo"] / attempts, 3) if attempts else None,
                "segundos_medio": round(a["segundos"] / attempts, 1) if attempts else None,
                "render_s_medio": round(sum(a["render_s"]) / len(a["render_s"]), 2) if a["render_s"] else None,
                "aprovadas": a["aprovadas"], "reprovadas": a["reprovadas"],
                "taxa_aprovacao": round(a["aprovadas"] / revisadas, 2) if revisadas else None,
                "nota_media": round(sum(a["notas"]) / len(a["notas"]), 2) if a["notas"] else None,
                "revisadas": revisadas, "pele_problemas": a["pele_problemas"]}

    def points(c):
        """Aprovação da pessoa pesa mais; nota e portão desempatam (None = sem dado)."""
        if c["revisadas"] < SAMPLE_MIN:
            return None
        return (0.5 * (c["taxa_aprovacao"] or 0) + 0.3 * ((c["nota_media"] or 3) / 5) + 0.2 * (c["taxa_portao"] or 0))

    table = {i: {m: close_totals(v) for m, v in d.items()} for i, d in sorted(by_int.items())}
    suggestion = {}
    for i, d in table.items():
        ph, pe = points(d["html"]), points(d["effectcraft"])
        if ph is None or pe is None:
            suggestion[i] = {"motor": None, "motivo": f"amostra pequena (mínimo {SAMPLE_MIN} revisadas por motor)"}
        else:
            vence = "effectcraft" if pe > ph + 0.05 else "html"
            suggestion[i] = {"motor": vence, "motivo": f"pontos html {ph:.2f} × effectcraft {pe:.2f}"
                           + ("" if vence == "effectcraft" else " (empate fica no html, o motor atual)")}
    return {"geral": {m: close_totals(v) for m, v in general.items()}, "por_intencao": table, "sugestao": suggestion,
            "decisao": engines(), "amostra_min": SAMPLE_MIN,
            "pendente": "acerto da IA local ao preencher: entra com a direção nova (etapa 6)"}


# ---------------------------------------------------------------- revisão

def _request_of(id_):
    return next((p for p in _read().values() if id_ in p.pecas), None)


def queue_review():
    """Peças esperando a pessoa, com o pedido de origem."""
    output = []
    for f in P.list_all("revisao"):
        p = _request_of(f.id)
        pair = next((x for x in (p.pares if p else []) if f.id in x), None)
        output.append({"id": f.id, "pedido": p.id if p else None, "pedido_texto": p.texto if p else "",
                      "motor": f.motor, "par": [x for x in pair if x != f.id][0] if pair else None})
    return output


def lesson(text, id_="", engine="html"):
    """Acrescenta uma regra aprendida na revisão ao fim do guia do motor (lido em toda geração)."""
    file = GUIDE_EC if engine == "effectcraft" else GUIDE
    guide = file.read_text()
    line = f"- {date.today():%d/%m/%Y}: {text.strip()}" + (f" (peça {id_})" if id_ else "")
    guide = re.sub(r"\(entram aqui os motivos de reprovação e os ajustes pedidos na revisão[^)]*\)\n", "", guide)
    file.write_text(guide.rstrip() + "\n" + line + "\n")


def review(id_, action, text="", note=None):
    """Decisão da pessoa sobre uma peça: aprovar | ajuste | variacao | reprovar; `nota` 1–5 (comparação dos motores)."""
    card = P.load(id_)
    if note is not None and not (isinstance(note, int) and 1 <= note <= 5):
        raise ValueError("nota de 1 a 5")
    extra = {"motor": card.motor, "intencoes": card.intencoes, "nota": note}
    p = _request_of(id_) or _change(STANDALONE, pecas=[*(_read().get(STANDALONE) or Request(id=STANDALONE)).pecas, id_],
                                  estado="ativo", texto="ajustes e variações de peças avulsas")
    if action == "aprovar":
        P.save(card.model_copy(update={"estado": "aprovada"}))
        _verdict_piece(id_, "aprovada", nota=note)
        _register("aprovada", peca=id_, pedido=p.id, **extra)
        approved = sum(1 for i in _active(p) if P.load(i).estado == "aprovada")
        if p.id != STANDALONE and approved >= p.quantidade * (2 if p.motor == "ambos" else 1):
            _change(p.id, estado="concluido", situacao="concluído")
        return {"ok": True}
    if action in ("ajuste", "variacao"):
        if action == "ajuste" and not text.strip():
            raise ValueError("diga o que ajustar")
        _change(p.id, tarefas=[*p.tarefas, Task(tipo=action, alvo=id_, comentario=text.strip())],
               estado="ativo" if p.estado != "pausado" else "pausado")
        if action == "ajuste":
            lesson(f"ajuste pedido: {text.strip()}", id_, card.motor)
            _verdict_piece(id_, "ajuste", nota=note, comentario=text.strip())
        _register(action, peca=id_, pedido=p.id, texto=text, **extra)
        return {"ok": True, "fila": enqueue(p.id) is not None}
    if action == "reprovar":
        if card.origem == "kit":
            raise ValueError("peça migrada do kit: o diretor atual ainda a usa; peça um ajuste em vez de reprovar")
        if not text.strip():
            raise ValueError("diga o motivo da reprovação (vira regra para as próximas)")
        lesson(f"reprovada: {text.strip()}", id_, card.motor)
        _verdict_piece(id_, "reprovada", nota=note, motivo=text.strip())
        _discard(id_, text.strip())
        _register("reprovada", peca=id_, pedido=p.id, motivo=text, **extra)
        restantes = [i for i in p.pecas if i != id_]
        reabrir = p.id != STANDALONE and p.estado != "pausado"
        _change(p.id, pecas=restantes, estado="ativo" if reabrir else p.estado)
        return {"ok": True, "fila": (enqueue(p.id) is not None) if reabrir else False}
    raise ValueError(f"ação inválida: {action}")


# ---------------------------------------------------------------- ampliação contínua

class Expansion(BaseModel):
    """O acervo cresce sozinho pelas lacunas (intenção × peso, inclusive 2,5D), um pedido por dia, dentro do teto e
    só enquanto a fila de revisão não acumula (a pessoa continua aprovando tudo)."""
    ativo: bool = False
    pecas_por_dia: int = Field(3, ge=1, le=20)
    teto_dia_usd: float = Field(2.0, ge=0.1, le=50)
    motor: Literal["html", "effectcraft", "ambos", "auto"] = "auto"
    revisao_max: int = Field(8, ge=1, le=100)


def expansion():
    return Expansion.model_validate_json(EXPANSION.read_text()) if EXPANSION.exists() else Expansion()


def save_expansion(**fields):
    a = Expansion.model_validate({**expansion().model_dump(), **fields})
    FOLDER.mkdir(parents=True, exist_ok=True)
    EXPANSION.write_text(a.model_dump_json(indent=1))
    _register("ampliacao", **a.model_dump())
    return a


def expand():
    """Chamado pelo relógio da fila: cria (ou retoma) o pedido de lacunas do dia se a ampliação está ligada, há
    lacuna, sobra teto e a fila de revisão não passou do limite. → (pedido ou None, motivo)."""
    a = expansion()
    if not a.ativo:
        return None, "desligada"
    if claude.quota_full():
        return None, f"cota do Claude em {claude.quota():.0%}"
    if len(queue_review()) >= a.revisao_max:
        return None, f"{a.revisao_max}+ peças esperando revisão"
    if not gaps():
        return None, "sem lacunas"
    today = date.today().isoformat()
    of_day = next((p for p in _read().values() if p.texto == f"ampliação contínua {today}"), None)
    if of_day:
        if of_day.estado == "ativo":
            enqueue(of_day.id)
        return of_day, "pedido do dia"
    p = new_request("lacunas", "", a.pecas_por_dia, a.teto_dia_usd, engine=a.motor)
    p = _change(p.id, texto=f"ampliação contínua {today}")
    enqueue(p.id)
    return p, "pedido criado"


def resume():
    """Relógio da fila: com a cota abaixo do limite, volta à fila todo pedido do Claude ativo que ainda não
    terminou (parado pela cota, ou interrompido por reinício do painel). Os pausados (pessoa ou freio) ficam."""
    if claude.quota_full():
        return []
    voltaram = []
    for p in requests():
        if p.ia != "claude" or p.id == STANDALONE or p.estado != "ativo" or p.situacao == "aguardando sua revisão":
            continue
        enqueue(p.id)  # não duplica se já está na fila
        voltaram.append(p.id)
    return voltaram


def summary():
    """Estado da fábrica para o app."""
    return {"pedidos": [p.model_dump() for p in requests() if p.id != STANDALONE or p.tarefas],
            "revisao": queue_review(), "lacunas": gaps()[:12], "gasto_hoje": spent_today(),
            "acervo": {"aprovadas": len(P.list_all("aprovada")), "revisao": len(P.list_all("revisao"))},
            "registro": record(30), "motores": engines(), "ampliacao": expansion().model_dump()}


# ── painel ao vivo (app → Empreendimento → Fábrica): ideias → N1 → portão → revisão → acervo/dataset ──

def _who(r):
    """Quem fez o evento do registro: claude | local | voce | sistema."""
    if r.get("evento") in ("aprovada", "reprovada", "ajuste", "variacao", "retomado"):
        return "voce"
    if r.get("evento") == "revisao" or (r.get("custo") or 0) > 0 or r.get("ia") == "claude":
        return "claude"
    if r.get("ia") == "local":
        return "local"
    return "sistema"


CATEGORIES = [("revisão do Claude", r"^revisão"), ("texto fora da área segura", r"área segura"),
              ("visão local (cortado, sobreposto, ilegível)", r"visão local"), ("LLM local não respondeu", r"não respondeu"),
              ("N1 não compila", r"não compila|ErroN1|marcador"), ("N1 fora do esquema", r"fora do esquema|ficha:"),
              ("itens empilhados (repetir)", r"repetir"), ("encaixe/botão não declarado", r"não declara")]


def _category(reason) -> str:
    m = str(reason or "")
    return next((name for name, rx in CATEGORIES if re.search(rx, m)), "outro")


def _calls_live():
    """Chamadas de LLM em andamento nos processos da fábrica (rastro ao vivo)."""
    output = []
    for file in trace.DIR.glob("*.json"):
        try:
            v = json.loads(file.read_text())
        except (OSError, ValueError):
            continue
        c = v.get("call")
        if not c or not str(v.get("flow") or "").startswith("fabrica"):
            continue
        output.append({"pedido": str(v["flow"]).split(":", 1)[-1], "motor": c.get("engine"), "nome": c.get("name"),
                      "modelo": c.get("model"), "tokens": c.get("tokens") or 0,
                      "segundos": round(time.time() - (c.get("start") or time.time()), 1),
                      "parcial": (c.get("partial") or "")[-400:]})
    return output


def _windows_quota():
    try:
        j = json.loads(claude.QUOTA_FILE.read_text())
    except (OSError, ValueError):
        j = {}
    now = time.time()
    return {k: {"uso": (v.get("utilization") or 0.0) if (v.get("resetsAt") or 0) > now else 0.0,
                "vira": datetime.fromtimestamp(v["resetsAt"]).isoformat(timespec="minutes") if v.get("resetsAt") else None}
            for k, v in j.items()}


def panel():
    """Estado da fábrica para o painel ao vivo: o que está em andamento (etapa, peça, chamada do Claude ou da LLM
    local), cota, números de hoje por quem fez, fila de ideias, acervo, dataset das tarefas e linha do tempo."""
    from collections import Counter

    from esteira.dataset import index
    from esteira.web import queue
    today = date.today().isoformat()
    ps = [p for p in requests() if p.id != STANDALONE]
    hibridos = [p for p in ps if p.ia == "hibrido" and p.estado != "concluido"]
    tasks = queue.list_all()
    running = {t["ep"].split(":", 1)[1] for t in tasks if t["ep"].startswith("fabrica:") and t["estado"] == "rodando"}
    in_queue = {t["ep"].split(":", 1)[1] for t in tasks if t["ep"].startswith("fabrica:") and t["estado"] == "na fila"}
    reg = [r for r in record(2000) if str(r.get("t", "")).startswith(today)]
    done = [r for r in reg if r.get("evento") in ("gerada", "descartada") and r.get("motor") == "effectcraft"]
    motivos = Counter(_category(r.get("motivo")) for r in done if r["evento"] == "descartada")
    revs = [r for r in reg if r.get("evento") == "revisao"]
    gastos = Counter()
    for r in claude._records():
        if str(r.get("ep", "")) == f"fabrica-{today}":
            gastos[r.get("reason") or "outro"] += r.get("cost") or 0
    library = Counter((f.motor, f.estado) for f in P.list_all())
    sit = index.status()
    thumbs = [{"ep": t["ep"], "estado": t["estado"], "inicio": t.get("inicio")} for t in tasks
              if t.get("comando") in ("thumb", "thumbs") and t["estado"] in ("rodando", "na fila")]
    lessons = [x[2:] for x in _lessons_n1().strip().splitlines() if x.startswith("- ")]
    return {
        "agora": [{"pedido": p.id, "tipo": p.tipo, "estado": p.estado, "rodando": p.id in running,
                   "na_fila": p.id in in_queue, "etapa": p.etapa if p.id in running else {}, "situacao": p.situacao}
                  for p in hibridos],
        "chamadas": _calls_live(),
        "cota": {"janelas": _windows_quota(), "limite": claude.quota_limit(), "cheia": claude.quota_full()},
        "pedidos": [{"id": p.id, "tipo": p.tipo, "texto": p.texto[:120], "estado": p.estado, "quantidade": p.quantidade,
                     "pecas": len(p.pecas), "descartadas": p.descartadas, "ideias_na_fila": len(p.conceitos),
                     "alvos": len(p.alvos), "feitos": len(p.feitos), "gasto_usd": p.gasto_usd,
                     "rodando": p.id in running, "na_fila": p.id in in_queue} for p in hibridos],
        "ideias_na_fila": [{"pedido": p.id, "id": (c.get("ficha") or {}).get("id"),
                            "descricao": (c.get("ficha") or {}).get("descricao") or "",
                            "intencoes": (c.get("ficha") or {}).get("intencoes") or [], "conceito": c.get("conceito", "")[:300]}
                           for p in hibridos for c in p.conceitos],
        "hoje": {
            "ideias": {"lotes": sum(1 for r in claude._records() if r.get("ep") == f"fabrica-{today}"
                                    and r.get("reason") == "fabrica_ideias"),
                       "custo": round(gastos["fabrica_ideias"], 3)},
            "motion": {"tentativas": len(done), "geradas": sum(r["evento"] == "gerada" for r in done),
                       "descartadas": sum(r["evento"] == "descartada" for r in done),
                       "puladas": sum(r.get("evento") == "inviavel" for r in reg),
                       "local": sum(r.get("ia") == "local" for r in done),
                       "revisoes": len(revs), "aprovadas_claude": sum(bool(r.get("aprovada")) for r in revs),
                       "custo_revisao": round(gastos["fabrica_revisao"], 3),
                       "motivos": [{"motivo": m or "?", "n": n} for m, n in motivos.most_common(6)]},
            "gasto": {k: round(v, 3) for k, v in gastos.items()}, "gasto_total": round(sum(gastos.values()), 3),
        },
        "revisao": len(queue_review()),
        "acervo": {m: {e: library[(m, e)] for e in ("aprovada", "revisao", "rascunho")} for m in ("html", "effectcraft")},
        "dataset": {t: sit.get(t, {}) for t in ("peca_animar", "peca_html", "thumb_compor", "foto_tratar")},
        "thumbs": {"tarefas": thumbs},
        "licoes": {"total": len(lessons), "ultimas": lessons[-5:]},
        "eventos": [{"t": r.get("t"), "quem": _who(r), "evento": r.get("evento"), "peca": r.get("peca"),
                     "texto": str(r.get("motivo") or "; ".join(r.get("problemas") or []) or r.get("resumo") or "")[:220],
                     "custo": r.get("custo"), "aprovada": r.get("aprovada")} for r in record(40)],
    }
