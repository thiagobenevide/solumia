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
LESSONS_POR_PIECE = 3  # teto de regras de uma mesma peça (guia + arquivo)
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


def _write(pedidos):
    FOLDER.mkdir(parents=True, exist_ok=True)
    REQUESTS.write_text(json.dumps([p.model_dump() for p in pedidos.values()], ensure_ascii=False, indent=1))


def requests():
    return sorted(_read().values(), key=lambda p: p.criado, reverse=True)


def request(pid):
    p = _read().get(pid)
    if not p:
        raise KeyError(f"pedido inexistente: {pid}")
    return p


def _change(pid, **campos):
    todos = _read()
    p = todos.get(pid) or Request(id=pid, quantidade=0, criado=_now())
    todos[pid] = p.model_copy(update=campos)
    _write(todos)
    if "situacao" in campos:
        trace.detail(f"{pid}: {campos['situacao']}")
    return todos[pid]


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


def request_quote(teto_dia_usd=3.0, motor="html"):
    """Pedido pronto da primeira peça: a citação de PDF, com o modelo antigo anexado."""
    p = new_request("livre", QUOTE, 1, teto_dia_usd, motor=motor)
    return _change(p.id, anexos=["esteira/graphics/modelos/citacao.html"])


def new_request(tipo, texto="", quantidade=3, teto_dia_usd=3.0, referencia="", motor="html", ia="claude"):
    if tipo == "livre" and not texto.strip():
        raise ValueError("descreva o que gerar")
    if tipo == "referencia" and not referencia:
        raise ValueError("envie a imagem de referência")
    base = re.sub(r"[^a-z0-9]+", "-", (texto or tipo).lower())[:24].strip("-") or tipo
    pid = f"{datetime.now():%m%d-%H%M%S}-{base}"[:40].strip("-")
    p = Request(id=pid, tipo=tipo, texto=texto.strip(), quantidade=quantidade, teto_dia_usd=teto_dia_usd,
               referencia=referencia, criado=_now(), motor="html" if ia == "local" else motor, ia=ia)
    todos = _read()
    todos[pid] = p
    _write(todos)
    _register("pedido", pedido=pid, tipo=tipo, texto=texto, quantidade=quantidade, motor=p.motor, ia=ia)
    return p


def store_reference(nome, dados):
    REFS.mkdir(parents=True, exist_ok=True)
    nome = re.sub(r"[^\w.-]+", "_", nome)[-80:]
    if not re.search(r"\.(png|jpe?g|webp)$", nome, re.I):
        raise ValueError("referência: imagem png, jpg ou webp")
    (REFS / nome).write_bytes(dados)
    return nome


def enqueue(pid):
    """Põe o pedido na fila da vaga "claude" (não duplica se já está lá)."""
    from esteira.web import queue
    return queue.add(f"fabrica:{pid}", "studio-factory", [], "claude")


def pause(pid, pausado=True):
    request(pid)
    if not pausado:
        _register("retomado", pedido=pid)
    return _change(pid, estado="pausado" if pausado else "ativo", situacao="pausado" if pausado else "retomado")


def _register(evento, **dados):
    FOLDER.mkdir(parents=True, exist_ok=True)
    with open(RECORD, "a") as f:
        f.write(json.dumps({"t": _now(), "evento": evento, **dados}, ensure_ascii=False) + "\n")


def record(n=60):
    if not RECORD.exists():
        return []
    return [json.loads(x) for x in RECORD.read_text().splitlines()[-n:]][::-1]


# ---------------------------------------------------------------- acervo × lacunas

def _in_library():
    return [f for f in P.list_all() if f.estado in ("aprovada", "revisao")]


def gaps():
    """Intenção × peso com menos de META_LACUNA peças (aprovadas ou em revisão), as mais vazias primeiro."""
    fichas = _in_library()
    saida = []
    for intencao in P.INTENTS:
        for peso in WEIGHTS_GAP:
            tem = sum(1 for f in fichas if intencao in f.intencoes and f.peso == peso)
            if tem < META_GAP:
                saida.append({"intencao": intencao, "peso": peso, "tem": tem, "falta": META_GAP - tem})
    return sorted(saida, key=lambda x: (x["tem"], P.INTENTS.index(x["intencao"]), x["peso"]))


def spent_today():
    from esteira.ai import claude
    hoje = date.today().isoformat()
    return round(sum((r.get("cost") or 0) for r in claude._records()
                     if str(r.get("ep", "")).startswith("fabrica") and r["t"].startswith(hoje)), 4)


# ---------------------------------------------------------------- geração

def _files(id_):
    p = P.folder(id_)
    ler = lambda n: (p / n).read_text() if (p / n).exists() else ""  # noqa: E731
    return {"peca.js": ler("peca.js"), "peca.css": ler("peca.css"), "peca.n1.json": ler("peca.n1.json"),
            "peca.jsx": "" if (p / "peca.n1.json").exists() else ler("peca.jsx"), "ficha.json": ler("ficha.json")}


def _block(id_):
    a = _files(id_)
    return "\n".join(f"--- {n}\n{t.strip()}" for n, t in a.items() if t.strip())


def _library_summary():
    linhas = [f"- {f.id}: {f.comunica} (intenções: {', '.join(f.intencoes)}; peso {f.peso}; {f.estado})"
              for f in P.list_all()]
    return "\n".join(linhas) or "(vazio)"


def next_size(p: Request) -> str | None:
    """Próxima peça HTML do porte: ainda não tentada, ainda existente e sem irmã EffectCraft."""
    for a in p.alvos:
        if a in p.feitos or not (P.folder(a) / "ficha.json").exists() or (P.folder(f"{a}_ec"[:40]) / "ficha.json").exists():
            continue
        return a
    return None


def request_size(estados=("aprovada", "revisao", "rascunho")) -> Request:
    """Pedido de porte de todas as peças HTML do acervo para EffectCraft em N1: aprovadas primeiro (melhor
    referência), depois as em revisão. Cada porte é 1 chamada (+1 se o portão reprovar) e herda a ficha inteira."""
    ordem = {e: k for k, e in enumerate(estados)}
    fichas = sorted((f for f in P.list_all() if f.motor == "html" and f.estado in ordem),
                    key=lambda f: (ordem[f.estado], f.id))
    p = new_request("porte", "porte das peças HTML para EffectCraft (N1)", quantidade=min(len(fichas), 50),
                    teto_dia_usd=50, motor="effectcraft")
    return _change(p.id, alvos=[f.id for f in fichas])


def _task_new(p: Request):
    if p.tipo == "lacunas":
        lc = gaps()
        if not lc:
            return "O acervo não tem lacunas por intenção × peso: crie uma peça útil de uma intenção pouco coberta."
        x = lc[0]
        return (f"Lacuna do acervo: crie uma peça de intenção '{x['intencao']}' com peso '{x['peso']}' "
                f"(hoje há {x['tem']}).")
    if p.tipo == "referencia":
        return ("Crie uma peça inspirada na imagem de referência (estrutura, ritmo e hierarquia; NUNCA copie cores nem "
                "fontes, a pele é do canal). " + (f"Observação da pessoa: {p.texto}" if p.texto else ""))
    return f"Pedido da pessoa: {p.texto}"


def dossier(p: Request, modo="nova", alvo="", comentario="", erros=(), motor="html", tarefa=None):
    """Prompt da geração. `modo`: nova | ajuste | variacao | corrigir (portão reprovou); `motor`: html | effectcraft."""
    if modo == "ajuste":
        tarefa = (f"Reescreva a peça '{alvo}' atendendo ao pedido de ajuste da pessoa: {comentario}\n"
                  f"Mantenha o id '{alvo}' e aumente `versao` em 1. Código atual:\n{_block(alvo)}")
    elif modo == "variacao":
        tarefa = (f"Crie uma IRMÃ da peça '{alvo}': mesma intenção e mesmos encaixes, visual e movimento claramente "
                  f"diferentes (outra composição, outra entrada). Id novo. Código da original:\n{_block(alvo)}")
    elif modo == "porte":
        tarefa = (f"Versão EffectCraft (N1) da peça HTML '{alvo}', que já existe e foi revisada. Mantenha o CONTRATO "
                  f"da ficha: intenções, encaixes, botões, exemplos e limites (só `motor` vira \"effectcraft\"). O "
                  f"visual e o movimento podem trazer PADRÕES NOVOS: use o que o EffectCraft faz melhor que o HTML "
                  f"(profundidade 2,5D, desfoque, traços que crescem, contagens, câmera) para uma peça mais rica que a "
                  f"original, sem perder a leitura. Ajuste `comunica` se o visual mudar. Id: {alvo}_ec. "
                  f"Peça HTML de partida:\n{_block(alvo)}")
    elif modo == "corrigir":
        tarefa = ("A peça abaixo foi REPROVADA no portão automático. Corrija todos os erros mantendo a ideia e o id.\n"
                  "Erros:\n" + "\n".join(f"- {e}" for e in erros) + f"\nCódigo:\n{_block(alvo)}")
    else:
        tarefa = tarefa or _task_new(p)
    if motor == "effectcraft":
        from esteira.n1 import effectcraft as N1EC
        cabeca = ("Você escreve peças de motion graphics para o acervo do Estúdio (vídeos de YouTube em pt-BR) no motor "
                  "EffectCraft. A peça é um documento N1 (JSON de elementos e animações), NÃO código: o compilador gera "
                  "o script. Siga os guias e o esquema à risca; o portão automático reprova o que fugir deles.\n\n"
                  f"=== GUIA DO N1 DO EFFECTCRAFT ===\n{GUIDE_N1_EC.read_text()}\n\n"
                  f"=== ESQUEMA N1 (JSON Schema) ===\n{json.dumps(N1EC.Piece.model_json_schema(), ensure_ascii=False)}\n\n"
                  f"=== GUIA GERAL (ficha, encaixes, texto máximo, lições) ===\n{GUIDE.read_text()}\n\n"
                  f"=== LIÇÕES DO MOTOR EFFECTCRAFT ===\n{GUIDE_EC.read_text()}\n\n"
                  f"=== PEÇA DE REFERÊNCIA DO FORMATO ({REFERENCE_EC}) ===\n{_block(REFERENCE_EC)}\n\n")
        resposta = ("Responda com id, peca_n1 (o documento N1), ficha (objeto completo, estado \"rascunho\", motor "
                    "\"effectcraft\") e resumo. ")
    else:
        cabeca = ("Você escreve peças de motion graphics para o acervo do Estúdio (vídeos de YouTube em pt-BR, HyperFrames "
                  "+ GSAP). Siga o guia à risca; o portão automático reprova o que fugir dele.\n\n"
                  f"=== GUIA DE ESCRITA DE PEÇAS ===\n{GUIDE.read_text()}\n\n"
                  f"=== PEÇA DE REFERÊNCIA DO FORMATO ({REFERENCE}) ===\n{_block(REFERENCE)}\n\n")
        resposta = "Responda com id, peca_js, peca_css, ficha (objeto completo, estado \"rascunho\", motor \"html\") e resumo. "
    return (
        cabeca +
        f"=== ACERVO ATUAL (não duplique; complemente) ===\n{_library_summary()}\n\n"
        + "".join(f"=== ANEXO {a} ===\n{(ROOT / a).read_text()}\n\n" for a in p.anexos if (ROOT / a).is_file())
        + f"=== TAREFA ===\n{tarefa}\n\n" + resposta +
        "Encaixes com limites honestos e exemplos reais; 5–10 exemplos_sim e 3–5 exemplos_nao de roteiros em pt-BR.\n"
        f"(pedido {p.id} · {_now()})"
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


def _compose(g: PieceGenerated, id_, versao=None, motor="html"):
    d = P.folder(id_)
    d.mkdir(parents=True, exist_ok=True)
    if motor == "effectcraft":
        for n in ("peca.js", "peca.css"):
            if (d / n).exists():
                (d / n).unlink()
        if g.peca_n1:  # N1: o compilador gera o script; um .jsx antigo da mesma peça sai
            (d / "peca.n1.json").write_text(json.dumps(g.peca_n1, ensure_ascii=False, indent=1) + "\n")
            if (d / "peca.jsx").exists():
                (d / "peca.jsx").unlink()
        else:
            (d / "peca.jsx").write_text((g.peca_jsx or g.peca_js).strip() + "\n")
        ficha = {**g.ficha, "id": id_, "estado": "rascunho", "motor": "effectcraft"}
        if versao:
            ficha["versao"] = versao
        ficha.setdefault("origem", "fabrica")
        (d / "ficha.json").write_text(json.dumps(ficha, ensure_ascii=False, indent=1) + "\n")
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
    ficha = {**g.ficha, "id": id_, "estado": "rascunho", "motor": "html"}
    if versao:
        ficha["versao"] = versao
    ficha.setdefault("origem", "fabrica")
    (d / "ficha.json").write_text(json.dumps(ficha, ensure_ascii=False, indent=1) + "\n")


def check_visual(id_):
    """IA local olha os quadros da prova (texto cortado, sobreposição, ilegível). Sem modelo de visão: pula."""
    from esteira.bench import Vision
    from esteira.ai import local
    problemas = []
    # o processo roda com `--motor claude`: sem fixar, a visão iria ao Claude e gastaria a cota da assinatura
    antes = {k: os.environ.get(k) for k in ("ESTEIRA_ENGINE", "ESTEIRA_ENGINE_FIXED")}
    os.environ.update(ESTEIRA_ENGINE="local", ESTEIRA_ENGINE_FIXED="1")
    try:
        return _check_frames(id_, Vision, local, problemas)
    finally:
        for k, v in antes.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def _check_frames(id_, Visao, local, problemas):
    for q in sorted((P.folder(id_) / "prova").glob("*.jpg")):
        try:
            r = local.ask(local.prompt("estudio_visao_prova"), Visao, model=local.VISION, images=[str(q)],
                                max_tokens=200, operation="studio_vision")
        except Exception as e:  # noqa: BLE001 — llama fora do ar não pode travar a fábrica
            events.warning(f"checagem visual pulada: {str(e)[:100]}")
            return []
        if r:
            ruins = [k for k, v in r.model_dump().items() if v and k != "rosto_coberto"]
            if ruins:
                problemas.append(f"visão local em {q.stem}: {', '.join(ruins)}")
    return problemas


def _gate(id_, visual=True):
    r = P.gate(id_)
    if r["ok"] and visual and (vis := check_visual(id_)):
        r = {**r, "ok": False, "erros": vis}
        ficha = P.load(id_)
        P.save(ficha.model_copy(update={"estado": "rascunho"}))
        (P.folder(id_) / "prova" / "portao.json").write_text(json.dumps(r, ensure_ascii=False, indent=1))
    return r


def _discard(id_, motivo):
    destino = REJECTED / f"{id_}-{datetime.now():%Y%m%d%H%M%S}"
    REJECTED.mkdir(parents=True, exist_ok=True)
    if P.folder(id_).exists():
        shutil.move(str(P.folder(id_)), destino)
        (destino / "motivo.txt").write_text(motivo)


def _query(p: Request, texto, imagem=None):
    if p.ia == "local":
        return _query_local(texto), 0.0
    from esteira.ai import claude
    ep = f"fabrica-{date.today().isoformat()}"
    antes = claude.spent(ep)[0]
    cfg = {"claude": {"teto_chamada_usd": CAP_CALL}}  # sem teto diário: o limite é a cota da assinatura (90%)
    g = claude.query(texto, PieceGenerated, cfg, ep, "fabrica_peca", image=imagem)
    return g, round(claude.spent(ep)[0] - antes, 4)


def _query_local(texto):
    """A peça pelo LLM local (JSON forçado pelo esquema). Sem imagem de referência. O processo da fábrica
    roda na vaga "claude" com `--motor claude`: aqui o motor local é fixado só durante a chamada."""
    from esteira.ai import local
    antes = {k: os.environ.get(k) for k in ("ESTEIRA_ENGINE", "ESTEIRA_ENGINE_FIXED")}
    os.environ.update(ESTEIRA_ENGINE="local", ESTEIRA_ENGINE_FIXED="1")
    try:
        # o número da tentativa muda o texto: sem ele o cache devolveria a mesma peça descartada
        r = local.ask(f"{texto}\n\n(tentativa {time.time_ns()})", PieceLocal, model=MODEL_LOCAL,
                            temperature=0.5, max_tokens=9000, operation="factory")
        return r and PieceGenerated(**r.model_dump(mode="json"))
    finally:
        for k, v in antes.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def generate(p: Request, modo="nova", alvo="", comentario="", visual=True, motor=None, tarefa=None, ideia=None):
    """Uma peça (nova, ajuste ou variação) com uma rodada de correção. → {"id", "ok", "custo", "motivo", "motor"}.
    Motor: o da peça-alvo (ajuste/variação), senão `motor`, senão o do pedido (resolvido por `motor_do_pedido`).
    Híbrido (porte e ideias): a LLM local faz a peça em N1 (duas rodadas); se o portão reprovar as duas, o Claude
    socorre com o caminho normal (`quem` no resultado: local | socorro)."""
    if p.ia == "hibrido" and modo in ("porte", "conceito"):
        r = _generate_local_n1(p, modo, alvo, ideia, visual)
        if r["ok"]:
            return {**r, "quem": "local"}
        if claude.quota_full() or modo == "porte" or not FALLBACK_IDEAS:  # o Claude fica só com o criativo
            return {**r, "quem": "local"}
        if modo == "conceito":  # socorro: o Claude escreve a peça da própria ideia
            tarefa = (f"Escreva a peça desta ideia (a LLM local não conseguiu: {r['motivo'][:200]}).\n"
                      f"Ficha: {json.dumps(ideia['ficha'], ensure_ascii=False)}\nConceito: {ideia['conceito']}")
            modo, alvo = "nova", ""
        socorro = generate(p.model_copy(update={"ia": "claude"}), modo, alvo, comentario, visual, "effectcraft", tarefa)
        return {**socorro, "custo": socorro["custo"], "quem": "socorro"}
    if modo == "porte":
        motor = "effectcraft"
    elif alvo and (P.folder(alvo) / "ficha.json").exists():
        motor = P.load(alvo).motor
    motor = motor or engine_of_request(p)
    inicio = time.monotonic()
    imagem = str(REFS / p.referencia) if p.tipo == "referencia" and p.referencia and modo == "nova" else None
    texto = dossier(p, modo, alvo, comentario, motor=motor, tarefa=tarefa)
    g, custo = _query(p, texto, imagem)
    if not g:
        quem = "o LLM local" if p.ia == "local" else "o Claude"
        return {"id": alvo or None, "ok": False, "custo": custo, "motivo": f"{quem} não respondeu (teto ou erro)",
                "motor": motor}
    copia = None
    if modo == "ajuste":
        id_ = alvo
        versao = P.load(alvo).versao + 1
        copia = FOLDER / "copias" / f"{alvo}-{datetime.now():%Y%m%d%H%M%S}"  # volta se o ajuste não passar
        shutil.copytree(P.folder(alvo), copia, ignore=shutil.ignore_patterns("prova"))
    elif modo == "porte":
        id_, versao = _id_free(f"{alvo}_ec"[:40]), None
    else:
        id_, versao = _id_free(g.id), None
    _compose(g, id_, versao, motor)
    r = _gate(id_, visual)
    rodadas = 1
    ctx = {"pedido": {"tipo": p.tipo, "texto": p.texto, "referencia": p.referencia}, "modo": modo, "alvo": alvo,
           "comentario": comentario, "motor": motor, "tarefa": str(tarefa or "")}
    rg = _dataset(p, ctx, texto, g, r, id_, alvo if modo in ("ajuste", "variacao", "porte") else id_, motor)
    if not r["ok"]:
        events.warning(f"fábrica: {id_} reprovada no portão; volta ao Claude uma vez")
        texto2 = dossier(p, "corrigir", id_, erros=r["erros"], motor=motor)
        g2, c2 = _query(p, texto2)
        custo += c2
        rodadas = 2
        if g2:
            _compose(g2, id_, versao, motor)
            r = _gate(id_, visual)
            rg = _dataset(p, {**ctx, "modo": "corrigir", "erros": r.get("erros", [])}, texto2, g2, r, id_,
                          alvo if modo in ("ajuste", "variacao", "porte") else id_, motor, pai=rg)
    base = {"pedido": p.id, "peca": id_, "modo": modo, "motor": motor, "rodadas": rodadas, "custo": custo,
            "segundos": round(time.monotonic() - inicio, 1), "render_s": r.get("render_s"),
            "intencoes": _intents(id_)}
    if not r["ok"]:
        motivo = "; ".join(r["erros"][:4])
        if copia:  # o ajuste não passou: a versão anterior volta para a revisão, com o motivo nas notas
            shutil.rmtree(P.folder(id_))
            shutil.copytree(copia, P.folder(id_))
            P.gate(id_)  # refaz a prova da versão anterior
            ficha = P.load(id_)
            P.save(ficha.model_copy(update={"estado": "revisao", "notas": f"ajuste reprovado: {motivo}"[:400]}))
        else:
            _discard(id_, motivo)
        _evaluate_dataset(rg, "descartada", motivo=motivo)
        _register("descartada", **base, motivo=motivo)
        return {"id": id_, "ok": False, "custo": custo, "motivo": motivo, "motor": motor}
    if copia:
        shutil.rmtree(copia, ignore_errors=True)
    _register("gerada", **base, resumo=g.resumo)
    return {"id": id_, "ok": True, "custo": custo, "motivo": "", "motor": motor}


def _dataset(p: Request, ctx, texto, g, r, id_, grupo, motor, pai=None):
    """Rodada da fábrica no registro do dataset (falha aqui nunca derruba a fábrica). → id do registro."""
    try:
        from esteira.dataset import registry as R
        return R.write(
            "peca_animar" if motor == "effectcraft" else "peca_html", grupo=f"peca:{grupo}", pai=pai,
            contexto=ctx, saida=g.model_dump(mode="json"),
            origem="claude" if p.ia == "claude" else f"local:{MODEL_LOCAL}",
            portao={"ok": bool(r.get("ok")), "erros": r.get("erros", [])[:8], "render_s": r.get("render_s")},
            versoes={"guia": _sha_guide(motor)}, extra={"peca": id_, "pedido": p.id, "prompt": R.artifact(texto)})
    except Exception as e:  # noqa: BLE001
        events.warning(f"dataset: rodada de {id_} não gravada ({e})")
        return None


def _evaluate_dataset(rg, veredito, **kw):
    if not rg:
        return
    try:
        from esteira.dataset import registry as R
        R.evaluate(rg, veredito, **kw)
    except Exception as e:  # noqa: BLE001
        events.warning(f"dataset: veredito de {rg} não gravado ({e})")


def _verdict_piece(id_, veredito, **kw):
    """Decisão da pessoa vai para a última rodada da peça no dataset."""
    try:
        from esteira.dataset import registry as R
        rg = R.last(peca=id_)
    except Exception:  # noqa: BLE001
        rg = None
    _evaluate_dataset(rg and rg["id"], veredito, **kw)


def _sha_guide(motor):
    import hashlib
    guia = P.FOLDER / ("GUIA_EC.md" if motor == "effectcraft" else "GUIA.md")
    return hashlib.sha1(guia.read_bytes()).hexdigest()[:10] if guia.exists() else None


BATCH_IDEAS = 8  # ideias por chamada do Claude (a parte criativa é curta; o pesado fica com a LLM local)
FALLBACK_IDEAS = False  # socorro do Claude custa ~2x um lote de 8 ideias por peça: desligado (o lote rende mais)
ROUNDS_LOCALS = 4  # tentativas da LLM local com o erro do portão (de graça) antes de desistir ou do socorro


def _compact(x):
    """N1 sem os campos vazios/padrão (None, {}, [], False): a versão anterior cabe no prompt da LLM local."""
    if isinstance(x, dict):
        return {k: _compact(v) for k, v in x.items() if v not in (None, {}, [], False)}
    return [_compact(v) for v in x] if isinstance(x, list) else x


def _dossier_local(modo, ficha, alvo="", ideia=None, erros=(), rascunho=None, anterior=None, ja_vistos=()):
    """Prompt compacto para a LLM local (cabe em 16k com a resposta): guia N1, a ficha, a origem e o RASCUNHO do
    molde (N1 que já compila e passa no portão). A LLM adapta o rascunho; não monta a peça do zero. Depois de uma
    reprovação, a base é a VERSÃO ANTERIOR dela com os erros e as causas: corrige o que foi apontado, não refaz."""
    base = ("Parta do RASCUNHO abaixo: ele já está certo (caixas, regiões, encaixes da ficha, animações) e só "
            "precisa ficar com a cara da ideia." if anterior is None else
            "Abaixo está a SUA VERSÃO ANTERIOR, reprovada pelos erros listados no fim. Corrija SÓ o que os erros e "
            "as causas apontam, no campo indicado, e mantenha todo o resto igual; não refaça a peça do zero.")
    base += " Mantenha o `nome` de cada elemento: o código casa a sua versão com o rascunho por ele."
    partes = ["Você adapta uma peça de motion graphics do EffectCraft em N1 (JSON). Responda com peca_n1 (o "
              f"documento completo) e comunica. {base} Pode: trocar níveis, pesos, "
              "fontes e cores (só por papel), tempos e o tipo de entrada das animações; acrescentar formas DENTRO "
              "das caixas existentes; criar variantes com `se` para os botões da ficha (`{\"botao\": nome, "
              "\"igual\": valor}`, só valores que o botão tem; cada valor muda algo visível). Não pode: tirar "
              "elementos que mostram encaixes, deixar caixa vazia, criar caixas de nível de cima em regiões já "
              "usadas, escrever x/y/w/h/d/tam, usar nome de encaixe ou botão que a ficha não declara. Botão que "
              "você não usar sai da ficha sozinho (melhor do que variante que não muda nada).",
              f"=== GUIA N1 ===\n{GUIDE_N1_EC.read_text()}",
              f"=== FICHA (contrato: encaixes, botões, intenções) ===\n{json.dumps(ficha, ensure_ascii=False)}"]
    if anterior is not None:
        partes.append(f"=== SUA VERSÃO ANTERIOR (reprovada; corrija só o apontado) ===\n"
                      f"{json.dumps(_compact(anterior), ensure_ascii=False)}")
    elif rascunho is not None:
        partes.append(f"=== RASCUNHO (molde preenchido pelo código; parta dele) ===\n"
                      f"{json.dumps(rascunho, ensure_ascii=False)}")
    else:
        partes.append(f"=== EXEMPLO N1 (rosca com legenda, só caixas) ===\n"
                      f"{json.dumps(json.loads(EXAMPLE_BOXES.read_text()), ensure_ascii=False)}")
    if modo == "porte":
        # o que sobra do orçamento vai para o código de partida (o guia, a ficha e o rascunho não podem ser cortados)
        livre = (DOSSIER_MAX_CAR - sum(len(x) for x in partes) - 1500
                 - sum(len(e) + 3 for e in [*erros, *ja_vistos]))
        js = (P.folder(alvo) / "peca.js").read_text()[:max(1000, min(6000, livre))]
        partes.append(f"=== PEÇA HTML DE PARTIDA (a mesma ideia; use só como inspiração de ritmo e destaque) ===\n{js}")
    else:
        partes.append(f"=== IDEIA (do diretor criativo) ===\n{ideia['conceito']}")
    if erros:
        partes.append("=== ERROS DA VERSÃO ANTERIOR (corrija cada um no N1) ===\n" + "\n".join(f"- {e}" for e in erros))
    if ja_vistos:
        partes.append("=== JÁ APONTADOS EM RODADAS ANTES (não volte a eles) ===\n"
                      + "\n".join(f"- {e}" for e in ja_vistos))
    return "\n\n".join(partes)


def _query_n1_local(texto):
    from esteira.ai import local
    from esteira.n1 import effectcraft as N1EC

    class Resposta(BaseModel):
        peca_n1: N1EC.Piece
        comunica: str = ""
    antes = {k: os.environ.get(k) for k in ("ESTEIRA_ENGINE", "ESTEIRA_ENGINE_FIXED")}
    os.environ.update(ESTEIRA_ENGINE="local", ESTEIRA_ENGINE_FIXED="1")
    try:
        r = local.ask(f"{texto}\n\n(tentativa {time.time_ns()})", Resposta, model=MODEL_LOCAL, temperature=0.4,
                            max_tokens=7000, operation="fabrica_n1")
        # só o que a LLM escreveu: o que ela omite vem do molde (travar_molde), não do padrão do esquema (peso 400…)
        return r and PieceN1Local(peca_n1=r.peca_n1.model_dump(mode="json", exclude_unset=True), comunica=r.comunica)
    except Exception as e:  # noqa: BLE001 — llama fora do ar ou resposta truncada: vira falha da rodada
        events.warning(f"fábrica: LLM local falhou ({str(e)[:120]})")
        return None
    finally:
        for k, v in antes.items():
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
    saida = P.folder(id_) / "prova" / "folha.png"
    entradas = sum((["-i", str(q)] for q in qs), [])
    filtro = "".join(f"[{i}:v]scale=-2:540[v{i}];" for i in range(len(qs))) + \
        "".join(f"[v{i}]" for i in range(len(qs))) + f"hstack=inputs={len(qs)}"
    r = __import__("subprocess").run(["ffmpeg", "-y", "-loglevel", "error", *entradas, "-filter_complex", filtro,
                                      str(saida)], capture_output=True)
    return saida if r.returncode == 0 and saida.exists() else None


def _lessons_n1() -> str:
    t = GUIDE_N1_EC.read_text()
    return t.split("## Lições", 1)[1] if "## Lições" in t else ""


def lesson_n1(regras, id_=""):
    """Regras da revisão do Claude entram no guia N1 (lido pela LLM local em toda geração), sem repetir."""
    t = GUIDE_N1_EC.read_text()
    if "## Lições" not in t:
        t = t.rstrip() + "\n\n## Lições (erros já vistos; não repita)\n"
    # compara também com o arquivo: a regra podada do guia voltava na revisão seguinte (fundo_ondas teve 10 iguais)
    arq = LESSONS_FILE.read_text() if LESSONS_FILE.exists() else ""
    todas = t.split("## Lições", 1)[1] + "\n" + arq
    ja = [_words(x) for x in re.findall(r"^- (?:.*?: )?(.+?)(?: \(peça .*\))?$", todas, re.M)]
    if id_ and todas.count(f"(peça {id_})") >= LESSONS_POR_PIECE:
        return []  # a peça já ensinou o que tinha: mais regras dela só repetem a mesma reprovação com outras palavras
    novas = []
    for x in (x.strip().rstrip(".") for x in regras if x.strip()):
        p = _words(x)
        if p and all(len(p & q) / len(p | q) < LESSON_SIMILAR for q in ja):
            novas.append(x)
            ja.append(p)
    # uma por revisão: o 12B não segue muitas regras soltas, e várias da mesma peça diziam quase a mesma coisa
    novas = novas[:1]
    if novas:
        GUIDE_N1_EC.write_text(t.rstrip() + "\n" + "".join(f"- {x} (peça {id_})\n" for x in novas))
        prune_lessons()
    return novas


def _words(x) -> set[str]:
    """Palavras de 4+ letras da regra: base da semelhança entre lições (parecida = repetida)."""
    return {w for w in re.findall(r"\w+", x.lower()) if len(w) >= 4}


def prune_lessons():
    """Mantém as lições do guia abaixo de LICOES_MAX_CAR: as de base (sem peça) ficam; das revisões, as mais novas.
    As que saem vão para LICOES_ARQUIVO (nada se perde, só sai do prompt). → quantas saíram."""
    t = GUIDE_N1_EC.read_text()
    if "## Lições" not in t:
        return 0
    cab, corpo = t.split("## Lições", 1)
    titulo, _, resto = corpo.partition("\n")
    linhas = [x for x in resto.splitlines() if x.strip()]
    base = [x for x in linhas if not re.search(r"\(peça [^)]*\)\s*$", x)]
    rev = [x for x in linhas if x not in base]
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
        GUIDE_N1_EC.write_text(f"{cab}## Lições{titulo}\n" + "".join(x + "\n" for x in base + ficam))
    return len(saem)


def _review_claude(id_, ficha, conceito, peca_n1):
    """O Claude revisa a prova que passou no portão local: aprova ou diz o problema, a causa no N1 e a regra geral
    (que vai para o guia da LLM local). → (RevisaoN1 | None, custo)."""
    folha = _sheet_proof(id_)
    if not folha:
        return None, 0.0
    texto = ("Você revisa peças de motion graphics feitas por uma LLM local em N1 (JSON do EffectCraft) antes de irem "
             "para vídeos profissionais do YouTube. A imagem é a folha da prova: os quadros (peles clara/escura, 16:9 "
             "e 9:16) lado a lado, no meio da animação. Na prova cada texto foi preenchido com o exemplo REPETIDO até "
             "o tamanho máximo: repetição de frase é o enchimento, não defeito (mas texto saindo da tela, cortado, "
             "sobreposto, marcador {{...}} literal, elementos empilhados ou composição que não comunica a ideia são "
             "defeitos). Reprove sem dó o que não estiver bom. Para cada problema, diga a causa no N1 e, se for um "
             "erro que a LLM pode repetir em outras peças, uma regra geral e nova para o guia (não repita as lições "
             "atuais). A LLM monta a peça só com caixas (regiões, disposição, nível do texto) e NÃO escreve "
             "coordenadas: escreva as regras nesse vocabulário, nunca em x/y/tam/passo. O N1 NÃO tem variante por "
             "pele (`se` só testa botão ou encaixe; a cor é por papel) e, dentro de caixa, `apos` é ignorado: não "
             "proponha regra com isso. Em `causas`, diga o elemento e o campo exatos (ex.: \"Traco: falta h\"), "
             "porque a LLM corrige a própria versão a partir delas. No máximo UMA regra, só se for nova.\n\n"
             f"=== GUIA N1 (regras atuais) ===\n{GUIDE_N1_EC.read_text()}\n\n"
             f"=== FICHA ===\n{json.dumps({k: ficha.get(k) for k in ('id', 'descricao', 'intencoes', 'encaixes', 'botoes', 'comunica')}, ensure_ascii=False)}\n\n"
             f"=== CONCEITO ===\n{conceito or '(porte de peça HTML)'}\n\n"
             f"=== N1 ===\n{json.dumps(peca_n1, ensure_ascii=False)}")
    ep = f"fabrica-{date.today().isoformat()}"
    antes = claude.spent(ep)[0]
    try:
        rev = claude.query(texto, ReviewN1, {"claude": {"teto_chamada_usd": 0.3}}, ep, "fabrica_revisao",
                               image=str(folha))
    except Exception as e:  # noqa: BLE001 — revisão indisponível não derruba a fábrica
        events.warning(f"fábrica: revisão do Claude falhou ({str(e)[:120]})")
        rev = None
    custo = round(claude.spent(ep)[0] - antes, 4)
    if rev:
        novas = lesson_n1(rev.regras, id_)
        _register("revisao", peca=id_, aprovada=rev.aprovada, problemas=rev.problemas[:6], causas=rev.causas[:6],
                   regras=novas, custo=custo)
    return rev, custo


def _buttons_used(doc, botoes):
    """Botões da ficha que o N1 usa (em `se` ou como velocidade): o resto sai da ficha da peça gerada."""
    from esteira.n1 import effectcraft as N1EC
    nos = list(N1EC.walk(doc.elementos))
    anims = [*doc.animacoes, *(a for e in nos if e.tipo == "repetir" for a in e.animacoes)]
    usados = {c.botao for x in [*nos, *anims] for c in N1EC.conditions(x.se) if c.botao}
    if doc.botao_velocidade:
        usados.add(doc.botao_velocidade)
    return [b for b in botoes if (b.get("nome") if isinstance(b, dict) else b.nome) in usados]


def _stage(nome, peca="", rodada=0):
    return {"nome": nome, "peca": peca, "rodada": rodada, "de": ROUNDS_LOCALS, "desde": datetime.now().isoformat(timespec="seconds")}


LOCKED = ("w", "h", "d", "pesos", "disposicao", "regiao", "elementos")  # estrutura do molde: a LLM muda, mas não apaga (elementos = itens do `repetir`)


def lock_mold(doc: dict, molde: dict) -> dict:
    """Completa a versão da LLM com o molde, por nome do elemento: campo que ela não escreveu vem do molde (não do
    padrão do esquema: a peça perdia peso 800, raio, caps…), os estruturais apagados (vazio/None) voltam e as chaves
    do `vertical` do molde que sumiram também. Ela perdia rodadas consertando o que o molde já acertava."""
    def por_nome(els, saida):
        for e in els or []:
            saida[e.get("nome")] = e
            por_nome(e.get("filhos") or e.get("elementos"), saida)
        return saida
    base, doc = por_nome(molde.get("elementos"), {}), copy.deepcopy(doc)
    for nome, e in por_nome(doc.get("elementos"), {}).items():
        if (m := base.get(nome)) is None or m.get("tipo") != e.get("tipo"):
            continue
        for k, v in m.items():
            if k not in e and k not in ("filhos", "elementos"):
                e[k] = copy.deepcopy(v)
        for k in LOCKED:
            if m.get(k) is not None and e.get(k) in (None, [], ""):
                e[k] = copy.deepcopy(m[k])
        if m.get("vertical"):
            e["vertical"] = {**m["vertical"], **(e.get("vertical") or {})}
    for k, v in molde.items():  # fundo_tela_cheia, botao_velocidade, animacoes que ela não escreveu
        if k not in doc and k != "elementos":
            doc[k] = copy.deepcopy(v)
    _restore_fits(doc, molde, por_nome)
    _prune_blocks(doc)
    existem = set(por_nome(doc.get("elementos"), {}))  # animação de elemento renomeado/apagado não compilava
    doc["animacoes"] = [a for a in doc.get("animacoes") or [] if a.get("alvo") in existem]
    return doc


def _prune_blocks(doc):
    """Tira o retângulo de cor forte sozinho numa caixa (sem `w`/`h`, vira um bloco do tamanho dela) e a caixa que
    ficar vazia: a LLM insistia nele rodada após rodada. Painel em `fundo`/`fundo2` ou translúcido fica."""
    def bloco(e):
        return (e.get("tipo") == "retangulo" and not (e.get("w") and e.get("h")) and not e.get("proporcional")
                and e.get("cor", "destaque") not in ("fundo", "fundo2") and e.get("opacidade", 100) > 40)
    tirados = set()
    def podar(els):
        saida = []
        for e in els:
            if e.get("tipo") == "caixa":
                filhos = e.get("filhos") or []
                if len(filhos) == 1 and bloco(filhos[0]):
                    tirados.add(filhos[0].get("nome"))
                    filhos = []
                e["filhos"] = podar(filhos)
                if not e["filhos"]:
                    tirados.add(e.get("nome"))
                    continue
            saida.append(e)
        return saida
    doc["elementos"] = podar(doc.get("elementos") or [])
    if tirados:
        doc["animacoes"] = [a for a in doc.get("animacoes") or [] if a.get("alvo") not in tirados]


def _fits_of(el) -> set[str]:
    txt = json.dumps(el, ensure_ascii=False)
    return ({m for m in re.findall(r"\{\{(\w+)", txt)} | set(re.findall(r'"encaixe": "(\w+)"', txt))) - {"item"}


def _marks(el) -> set[str]:
    """O que o elemento mostra: marcadores {{x}} / {{item.campo}} e o encaixe de um `repetir`."""
    txt = json.dumps(el, ensure_ascii=False)
    return set(re.findall(r"\{\{([\w.]+)\}\}", txt)) | {f"lista:{x}" for x in re.findall(r'"encaixe": "(\w+)"', txt)}


def _restore_fits(doc, molde, por_nome):
    """Elemento do molde que mostra um encaixe e sumiu da versão da LLM (e o encaixe não aparece em outro lugar)
    volta, na caixa-mãe de mesmo nome ou no nível de cima, com as animações dele. Sem ele o portão reprovava e ela
    não sabia recriar (ficava presa devolvendo a mesma versão)."""
    def andar(els, mae=None):
        for e in els or []:
            yield e, mae
            yield from andar(e.get("filhos") or e.get("elementos"), e)
    for el, mae in andar(molde.get("elementos")):
        nomes = por_nome(doc.get("elementos"), {})
        destino = nomes.get(mae.get("nome")) if mae else None
        mostra = _marks(el)
        if el.get("nome") in nomes or not mostra:
            continue
        so_item = all(m.split(".")[0] == "item" for m in mostra)
        if so_item and destino is None:
            continue
        # campo a campo: {{item.rotulo}} que sumiu volta mesmo que o item ainda mostre {{item.valor}}
        if mostra <= _marks(destino.get("elementos") if so_item else doc.get("elementos")):
            continue
        lista = (destino.setdefault("filhos" if destino.get("tipo") == "caixa" else "elementos", [])
                 if destino else doc.setdefault("elementos", []))
        lista.append(copy.deepcopy(el))
        novos = set(por_nome([el], {}))
        doc.setdefault("animacoes", []).extend(copy.deepcopy(a) for a in molde.get("animacoes", [])
                                               if a.get("alvo") in novos)


def _base_next(novo, anterior, molde, erros_novos=(), erros_antes=()):
    """Base da próxima rodada: a versão dela, salvo se empacou (devolveu igual) ou fugiu do molde (trocou os nomes
    da maior parte dos elementos, e a trava deixa de valer). → (base ou None = molde, aviso para a LLM ou "")."""
    if molde is None:
        return novo, ""
    if novo == anterior:
        return None, ("você devolveu a mesma versão: volte ao RASCUNHO e corrija os erros a partir dele")
    if anterior is not None and erros_novos and set(erros_novos) <= set(erros_antes):
        return None, ("o mesmo erro voltou duas vezes: parta do RASCUNHO de novo e, se não souber corrigir um "
                      "elemento que você acrescentou, tire-o")
    def nomes(d):
        out = set()
        def andar(els):
            for e in els or []:
                out.add(e.get("nome"))
                andar(e.get("filhos") or e.get("elementos"))
        andar(d.get("elementos"))
        return out
    m = nomes(molde)
    if m and len(m & nomes(novo)) < len(m) / 2:
        return None, ("você trocou a estrutura e os nomes do RASCUNHO: parta dele de novo, mantenha os `nome` dos "
                      "elementos e mude só valores")
    return novo, ""


def _seen(erros, ja_vistos, atuais):
    """Erros das rodadas anteriores que a versão atual não repete (até 6, os mais novos primeiro)."""
    return [e for e in dict.fromkeys([*erros, *ja_vistos]) if e not in atuais][:6]


def _generate_local_n1(p: Request, modo, alvo, ideia, visual):
    """A LLM local faz a peça em N1 a partir do HTML (porte) ou da ideia do Claude; RODADAS_LOCAIS no portão."""
    inicio = time.monotonic()
    if modo == "porte":
        from esteira.studio import molds as M
        ficha = M.card_size({k: v for k, v in json.loads((P.folder(alvo) / "ficha.json").read_text()).items()
                               if k not in ("estado", "notas")})
        id_, grupo = _id_free(f"{alvo}_ec"[:40]), alvo
    else:
        ficha = dict(ideia["ficha"])
        id_ = _id_free(re.sub(r"[^a-z0-9_]", "_", str(ficha.get("id") or "ideia").lower())[:36] or "ideia")
        grupo = id_
    ctx = {"pedido": {"tipo": p.tipo, "texto": p.texto}, "modo": modo, "alvo": alvo, "motor": "effectcraft",
           "conceito": (ideia or {}).get("conceito")}
    from esteira.studio import ec as EC
    from esteira.studio import molds as M
    from esteira.n1 import effectcraft as N1EC
    # triagem: o que o N1 não desenha não vai para a LLM local (falharia sempre e gastaria revisão do Claude)
    if motivo := M.unfeasible(ficha, ctx["conceito"] or ""):
        _register("inviavel", pedido=p.id, peca=id_, modo=modo, motor="effectcraft", ia="local", motivo=motivo,
                   intencoes=ficha.get("intencoes", []))
        return {"id": id_, "ok": False, "custo": 0.0, "motivo": f"inviável no N1: {motivo}", "motor": "effectcraft",
                "inviavel": True}
    molde, rascunho = M.draft(ficha)
    ctx["molde"] = molde
    erros, ja_vistos, anterior, rg = [], [], None, None
    r = {"ok": False, "erros": ["a LLM local não respondeu"]}
    custo, revisoes, passou = 0.0, 0, False
    for rodada in range(1, ROUNDS_LOCALS + 1):
        _change(p.id, etapa=_stage("n1", id_, rodada))
        texto = _dossier_local(modo, ficha, alvo, ideia, erros, rascunho, anterior, ja_vistos)
        if rodada == ROUNDS_LOCALS and not passou:
            # nenhuma versão da LLM chegou à revisão: a última rodada é o próprio rascunho do molde (já testado)
            g = PieceN1Local(peca_n1=rascunho, comunica=ficha.get("comunica", ""))
        else:
            g = _query_n1_local(texto)
        if not g:
            r = {"ok": False, "erros": ["a LLM local não respondeu (contexto, tempo ou JSON)"]}
            continue
        if rascunho is not None:
            g = g.model_copy(update={"peca_n1": lock_mold(g.peca_n1, rascunho)})
        f = {**ficha, "id": id_, "motor": "effectcraft", "origem": "fabrica_local"}
        if g.comunica:
            f["comunica"] = g.comunica
        doc = N1EC.Piece.model_validate(g.peca_n1)
        f["botoes"] = _buttons_used(doc, f.get("botoes") or [])  # o contrato só declara o que a peça faz
        pg = PieceGenerated(id=id_, peca_n1=g.peca_n1, ficha=f, resumo=g.comunica)
        try:
            estrutura = EC.check_structure(doc, P.Card.model_validate(f))
        except ValidationError as e:
            estrutura = [f"ficha fora do esquema: {str(e)[:200]}"]
        if fora := N1EC.loose(doc):
            estrutura.insert(0, f"elementos fora de caixa: {fora[:6]}. Ponha TUDO dentro de caixas (`regiao` + "
                                "`disposicao`) e tire x/y/w/h/tam: o compilador posiciona")
        if estrutura:  # sem render nem Claude: o erro de estrutura volta direto para a LLM
            r = {"ok": False, "erros": estrutura[:8]}
            rg = _dataset(p.model_copy(update={"ia": "local"}), {**ctx, "rodada": rodada, "erros": erros}, texto, pg,
                          r, id_, grupo, "effectcraft", pai=rg)
            ja_vistos = _seen(erros, ja_vistos, r["erros"])
            anterior, aviso = _base_next(g.peca_n1, anterior, rascunho, r["erros"], erros)
            erros = [*r["erros"], *([aviso] if aviso else [])]
            continue
        try:
            _compose(pg, id_, None, "effectcraft")
            _change(p.id, etapa=_stage("portao", id_, rodada))
            # com a revisão do Claude disponível, a visão local sai do caminho: o erro visual vira diagnóstico + lição
            # (a visão local só dizia sim/não e errava); sem cota, ela volta como filtro
            r = _gate(id_, False)  # técnico (esquema, compila, render, área segura); o visual é a revisão do Claude
            if r["ok"]:  # o portão marca "revisao": até o Claude aprovar, é rascunho (interrupção não vaza peça)
                P.save(P.load(id_).model_copy(update={"estado": "rascunho"}))
        except Exception as e:  # noqa: BLE001 — uma peça ruim reprova a rodada, nunca derruba o lote
            r = {"ok": False, "erros": [f"{type(e).__name__}: {str(e)[:300]}"]}
        rg = _dataset(p.model_copy(update={"ia": "local"}), {**ctx, "rodada": rodada, "erros": erros}, texto, pg, r,
                      id_, grupo, "effectcraft", pai=rg)
        if r["ok"] and visual:  # aprovação explícita do Claude é obrigatória (sem revisão, não passa)
            passou = True
            rev = None
            if revisoes < REVIEWS_CLAUDE and not claude.quota_full():
                _change(p.id, etapa=_stage("revisao", id_, rodada))
                rev, c = _review_claude(id_, f, (ideia or {}).get("conceito") or "", g.peca_n1)
                custo += c
                revisoes += 1
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
            _register("gerada", pedido=p.id, peca=id_, modo=modo, motor="effectcraft", rodadas=rodada, custo=custo,
                       segundos=round(time.monotonic() - inicio, 1), render_s=r.get("render_s"), ia="local",
                       intencoes=_intents(id_), resumo=g.comunica)
            return {"id": id_, "ok": True, "custo": custo, "motivo": "", "motor": "effectcraft"}
        # a próxima rodada corrige esta versão (não o molde); os erros de antes ficam como "não volte a eles"
        ja_vistos = _seen(erros, ja_vistos, r.get("erros", []))
        anterior, aviso = _base_next(g.peca_n1, anterior, rascunho, r.get("erros", []), erros)
        erros = [*r.get("erros", [])[:12], *([aviso] if aviso else [])]
    motivo = "; ".join(r.get("erros", [])[:4])
    if (P.folder(id_) / "ficha.json").exists():
        _discard(id_, f"local: {motivo}")
    _evaluate_dataset(rg, "descartada", motivo=motivo)
    _register("descartada", pedido=p.id, peca=id_, modo=modo, motor="effectcraft", rodadas=ROUNDS_LOCALS, custo=custo,
               segundos=round(time.monotonic() - inicio, 1), render_s=r.get("render_s"), ia="local",
               intencoes=[], motivo=motivo)
    return {"id": id_, "ok": False, "custo": custo, "motivo": motivo, "motor": "effectcraft"}


def _vocabulary_n1():
    """O que a LLM local consegue fazer em N1: os moldes e os limites (o Claude cria só ideias executáveis)."""
    from esteira.studio import molds as M
    linhas = [f"- {m['id']}: {m['descricao']} (intenções: {', '.join(m['intencoes'])}; encaixes: "
              + ", ".join(f"{s['nome']} ({'/'.join(s['tipos'])}{', obrigatório' if s.get('obrigatorio') else ''})"
                          for s in m["slots"]) + ")" for m in M.load()]
    return ("Cada peça nasce de UM destes moldes (o executor adapta cores, tempos, ênfases e variantes de botão):\n"
            + "\n".join(linhas) + "\nPeças só 2D: textos, barras, linhas que se traçam, círculos/anéis/fatias, "
            "grades de pontos, cartões. Encaixes só dos tipos texto, numero, itens e pares. NÃO proponha: foto ou "
            "imagem, ícone ou ilustração, curva/onda/gráfico de linha, perspectiva/horizonte/estrada, 3D/paralaxe, "
            "mapa/órbita, trajetória livre, fundo ou transição sem conteúdo. Escreva o conceito no vocabulário do "
            "molde escolhido e diga qual é.")


def _query_ideas(p: Request, n):
    """O Claude só cria: `n` ideias (ficha + conceito) numa chamada. → (lista de dicts, custo)."""
    from esteira.ai import claude as C
    if p.ia == "local" or C.quota_full():
        return [], 0.0
    texto = ("Você é o diretor criativo do acervo de motion graphics do Estúdio (YouTube em pt-BR). Crie "
             f"{n} peças NOVAS e diferentes entre si e do acervo: para cada uma, a ficha completa (contrato: "
             "intenções, encaixes com limites honestos, botões, exemplos_sim/nao reais, motor \"effectcraft\", estado "
             "\"rascunho\") e o conceito (composição, hierarquia e movimento em 4–8 frases, com tempos). Não escreva "
             "código nem N1: outra IA executa o conceito.\n\n"
             f"=== O QUE O EXECUTOR SABE DESENHAR (ideia fora disto é descartada sem tentar) ===\n{_vocabulary_n1()}\n\n"
             f"=== GUIA GERAL (ficha, encaixes) ===\n{GUIDE.read_text()}\n\n"
             f"=== ACERVO ATUAL (não duplique) ===\n{_library_summary()}\n\n"
             f"=== LACUNAS ===\n{json.dumps(gaps()[:12], ensure_ascii=False)}\n\n"
             f"=== PEDIDO ===\n{p.texto or 'preencher lacunas do acervo com peças úteis para vídeos de finanças, história, ciência'}")
    ep = f"fabrica-{date.today().isoformat()}"
    antes = C.gasto(ep)[0]
    r = C.query(texto, Ideas, {"claude": {"teto_chamada_usd": CAP_CALL}}, ep, "fabrica_ideias")
    return ([i.model_dump(mode="json") for i in r.itens] if r else []), round(C.gasto(ep)[0] - antes, 4)


def request_hybrid(tipo="ideias", quantidade=40, texto="") -> Request:
    """Pedido no modo híbrido: `porte` (as HTML → N1 pela LLM local) ou `ideias` (o Claude cria em lote)."""
    if tipo == "porte":
        p = request_size()
        return _change(p.id, ia="hibrido")
    p = new_request("ideias", texto, quantidade=min(quantidade, 50), teto_dia_usd=50, motor="effectcraft")
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
    vivas = []
    for i in p.pecas:
        try:
            if P.load(i).estado in ("revisao", "aprovada"):
                vivas.append(i)
        except (KeyError, ValidationError):
            continue
    return vivas


def clean_orphans():
    """Peça da LLM local em rascunho sem aprovação do Claude é sobra de processo interrompido (reinício no meio da
    revisão): vai para `reprovadas/`. Só roda sem fábrica em andamento (início de `rodar` e do painel)."""
    saiu = []
    for f in P.list_all("rascunho"):
        if f.origem == "fabrica_local":
            motivo = "órfã: o processo parou antes da aprovação do Claude (reinício no meio da geração)"
            _discard(f.id, motivo)
            _register("orfa", peca=f.id, motivo=motivo)
            saiu.append(f.id)
    return saiu


def run(pid, visual=True, maximo=80):
    """Modo contínuo do pedido: tarefas da revisão primeiro, depois peças novas até a quantidade ou a cota do Claude."""
    clean_orphans()  # uma fábrica por vez (vaga "claude"): rascunho local que sobrou é de processo morto
    trace.node(f"fabrica:{pid}", "fabrica", f"pedido {pid}")  # nó "Fábrica de peças" no grafo do Monitor
    try:
        return _run(pid, visual, maximo)
    finally:
        trace.node(None, None)
        if pid in _read():
            _change(pid, etapa={})  # o processo saiu: nada em andamento


BRAKE_REQUEST = 3   # descartes seguidos do Claude no mesmo pedido → o pedido pausa
BRAKE_FACTORY = 6  # descartes seguidos do Claude somando os pedidos → todos os pedidos do Claude pausam


def _brake(pid):
    """Gasto de cota sem peça (o mesmo erro se repetindo) → motivo da parada, ou "". Só conta o Claude (custo > 0)."""
    # o freio e a retomada zeram a contagem (senão o pedido retomado pararia de novo na hora)
    recentes = itertools.takewhile(lambda r: r.get("evento") not in ("freio", "retomado"), record(400))
    feitos = [r for r in recentes if r.get("evento") in ("gerada", "descartada") and (r.get("custo") or 0) > 0]
    seguidos = list(itertools.takewhile(lambda r: r["evento"] == "descartada", feitos))
    do_pedido = list(itertools.takewhile(lambda r: r["evento"] == "descartada",
                                         (r for r in feitos if r.get("pedido") == pid)))
    if len(seguidos) >= BRAKE_FACTORY:
        return f"freio da fábrica: {len(seguidos)} descartes seguidos ({seguidos[0].get('motivo', '')[:120]})"
    if len(do_pedido) >= BRAKE_REQUEST:
        return f"freio: {len(do_pedido)} descartes seguidos ({do_pedido[0].get('motivo', '')[:120]})"
    return ""


def _apply_brake(pid, motivo):
    alvos = [x.id for x in requests() if x.ia == "claude" and x.estado == "ativo"] \
        if motivo.startswith("freio da fábrica") else [pid]
    for a in alvos:
        _change(a, estado="pausado", situacao=motivo[:200])
    events.warning(f"fábrica: {motivo}")
    _register("freio", pedido=pid, motivo=motivo, pausados=alvos)
    return request(pid)


def _run(pid, visual, maximo):
    for _ in range(maximo):
        p = request(pid)
        if p.estado == "pausado":
            _change(pid, situacao="pausado")
            return p
        if p.ia == "claude" and (motivo := _brake(pid)):
            return _apply_brake(pid, motivo)
        if p.ia in ("claude", "hibrido") and claude.quota_full():
            events.warning(f"fábrica: cota da assinatura em {claude.quota():.0%}")
            return _change(pid, situacao=f"cota do Claude em {claude.quota():.0%}: volta quando a janela virar")
        if p.tarefas:
            t, resto = p.tarefas[0], p.tarefas[1:]
            _change(pid, tarefas=resto, situacao=f"{t.tipo} de {t.alvo}")
            r = generate(p, t.tipo, t.alvo, t.comentario, visual)
            novas = p.pecas + ([r["id"]] if r["ok"] and t.tipo == "variacao" else [])
            _change(pid, pecas=novas, gasto_usd=round(p.gasto_usd + r["custo"], 4),
                   descartadas=p.descartadas + (0 if r["ok"] else 1),
                   situacao=f"{t.tipo} de {t.alvo}: " + ("em revisão" if r["ok"] else f"falhou ({r['motivo'][:80]})"))
            continue
        if p.tipo == "ideias":
            if len(p.pecas) + p.descartadas >= p.quantidade:
                return _change(pid, estado="concluido", situacao=f"ideias concluídas: {len(p.pecas)} peças em revisão")
            if not p.conceitos:
                _change(pid, situacao="o Claude está criando um lote de ideias", etapa=_stage("ideias"))
                novas, custo = _query_ideas(p, min(BATCH_IDEAS, p.quantidade - len(p.pecas) - p.descartadas))
                p = _change(pid, conceitos=novas, gasto_usd=round(p.gasto_usd + custo, 4))
                if not novas:
                    return _change(pid, situacao="o Claude não devolveu ideias (cota ou erro)")
                continue
            ideia, resto = p.conceitos[0], p.conceitos[1:]
            _change(pid, conceitos=resto, situacao=f"LLM local expandindo a ideia {ideia['ficha'].get('id', '?')}")
            r = generate(p, "conceito", ideia=ideia, visual=visual)
            p = request(pid)
            _change(pid, pecas=p.pecas + ([r["id"]] if r["ok"] else []), gasto_usd=round(p.gasto_usd + r["custo"], 4),
                   descartadas=p.descartadas + (0 if r["ok"] or r.get("inviavel") else 1),
                   locais=p.locais + (r.get("quem") == "local"),
                   socorros=p.socorros + (r.get("quem") == "socorro"),
                   situacao=f"{r['id']} em revisão ({r.get('quem')})" if r["ok"] else
                   f"{'pulada' if r.get('inviavel') else 'descartada'}: {r['motivo'][:80]}")
            continue
        if p.tipo == "porte":
            alvo = next_size(p)
            if alvo is None:
                return _change(pid, estado="concluido", situacao=f"porte concluído: {len(p.pecas)} peças em revisão")
            _change(pid, situacao=f"portando {alvo} ({len(p.pecas) + p.descartadas + 1} de {len(p.alvos)})")
            r = generate(p, "porte", alvo, visual=visual)
            if r.get("motivo", "").startswith("o Claude não respondeu"):
                return _change(pid, gasto_usd=round(p.gasto_usd + r["custo"], 4), situacao=r["motivo"])
            p = request(pid)
            _change(pid, pecas=p.pecas + ([r["id"]] if r["ok"] else []), gasto_usd=round(p.gasto_usd + r["custo"], 4),
                   descartadas=p.descartadas + (0 if r["ok"] or r.get("inviavel") else 1), feitos=[*p.feitos, alvo],
                   locais=p.locais + (r.get("quem") == "local"), socorros=p.socorros + (r.get("quem") == "socorro"),
                   situacao=f"{r['id']} em revisão" if r["ok"] else
                   f"{alvo}: {'pulada' if r.get('inviavel') else 'descartada'} ({r['motivo'][:80]})")
            continue
        ativas = _active(p)
        if p.motor == "ambos" and len(ativas) < 2 * p.quantidade and p.estado != "concluido":
            r = _generate_pair(p, ativas, visual)
            if r is not None:
                return r
            continue
        ativas_n = len(ativas) // 2 if p.motor == "ambos" else len(ativas)  # "ambos": a quantidade é de pares
        if ativas_n >= p.quantidade or p.estado == "concluido":
            aprovadas = sum(1 for i in ativas if P.load(i).estado == "aprovada")
            fim = aprovadas >= p.quantidade * (2 if p.motor == "ambos" else 1)
            return _change(pid, pecas=ativas, estado="concluido" if fim else p.estado,
                          situacao="concluído" if fim else "aguardando sua revisão")
        _change(pid, situacao=f"gerando peça {len(ativas) + 1} de {p.quantidade}")
        r = generate(p, "nova", visual=visual)
        if r.get("motivo", "").startswith("o Claude não respondeu"):
            return _change(pid, gasto_usd=round(p.gasto_usd + r["custo"], 4), situacao=r["motivo"])
        _change(pid, pecas=ativas + ([r["id"]] if r["ok"] else []), gasto_usd=round(p.gasto_usd + r["custo"], 4),
               descartadas=p.descartadas + (0 if r["ok"] else 1),
               situacao=f"{r['id']} em revisão" if r["ok"] else f"descartada: {r['motivo'][:100]}")
        time.sleep(0.2)
    return request(pid)


def _generate_pair(p: Request, ativas, visual):
    """Motor "ambos": o mesmo pedido (mesma tarefa) no HTML e no EffectCraft; o par entra junto na revisão.
    → Pedido quando o laço deve parar (Claude sem resposta), senão None."""
    tarefa = _task_new(p)
    _change(p.id, situacao=f"gerando par {len(ativas) // 2 + 1} de {p.quantidade} (HTML e EffectCraft)")
    ids, custo, falhas = [], 0.0, 0
    for motor in ("html", "effectcraft"):
        r = generate(p, "nova", visual=visual, motor=motor, tarefa=tarefa)
        custo += r["custo"]
        if r.get("motivo", "").startswith("o Claude não respondeu"):
            return _change(p.id, gasto_usd=round(p.gasto_usd + custo, 4), situacao=r["motivo"],
                          pecas=ativas + ids)
        if r["ok"]:
            ids.append(r["id"])
        else:
            falhas += 1
    atual = request(p.id)
    _change(p.id, pecas=ativas + ids, pares=atual.pares + ([ids] if len(ids) == 2 else []),
           gasto_usd=round(atual.gasto_usd + custo, 4), descartadas=atual.descartadas + falhas,
           situacao=f"par em revisão: {' × '.join(ids)}" if ids else "o par foi descartado no portão")
    return None


# ---------------------------------------------------------------- motores: decisão e comparação

def engines():
    """Decisão de motor por intenção (aplicada pela pessoa): {"padrao", "por_intencao": {intenção: motor}}."""
    if ENGINES.exists():
        return json.loads(ENGINES.read_text())
    return {"padrao": "html", "por_intencao": {}}


def aplicar_engines(por_intencao, padrao="html"):
    FOLDER.mkdir(parents=True, exist_ok=True)
    validos = {k: v for k, v in por_intencao.items() if k in P.INTENTS and v in ("html", "effectcraft")}
    d = {"padrao": padrao if padrao in ("html", "effectcraft") else "html", "por_intencao": validos, "em": _now()}
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
    motor_da = {}
    for r in regs:
        if r.get("peca") and r.get("motor"):
            motor_da.setdefault(r["peca"], r["motor"])
    for f in P.list_all():
        motor_da.setdefault(f.id, f.motor)

    def vazio():
        return {"geradas": 0, "descartadas": 0, "rodadas": 0, "custo": 0.0, "segundos": 0.0, "render_s": [],
                "aprovadas": 0, "reprovadas": 0, "notas": [], "pele_problemas": 0}
    geral, por_int = {"html": vazio(), "effectcraft": vazio()}, {}
    ints_da = {}
    for r in regs:
        m = r.get("motor") or motor_da.get(r.get("peca"))
        if m not in geral:
            continue
        ints = r.get("intencoes") or ints_da.get(r.get("peca"), [])
        if r.get("intencoes"):
            ints_da[r["peca"]] = r["intencoes"]
        alvos = [geral[m]] + [por_int.setdefault(i, {"html": vazio(), "effectcraft": vazio()})[m] for i in ints]
        for a in alvos:
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
    arq_pele = P.previews_dir("_canais").parent / "_prova_canais" / "resultado.json"
    if arq_pele.exists():
        for x in json.loads(arq_pele.read_text()).get("problemas", []):
            m = motor_da.get(x["peca"])
            if m in geral:
                geral[m]["pele_problemas"] += 1

    def fechar(a):
        tentativas = a["geradas"] + a["descartadas"]
        revisadas = a["aprovadas"] + a["reprovadas"]
        return {"geradas": a["geradas"], "descartadas": a["descartadas"],
                "taxa_portao": round(a["geradas"] / tentativas, 2) if tentativas else None,
                "rodadas_media": round(a["rodadas"] / tentativas, 2) if tentativas else None,
                "custo_medio": round(a["custo"] / tentativas, 3) if tentativas else None,
                "segundos_medio": round(a["segundos"] / tentativas, 1) if tentativas else None,
                "render_s_medio": round(sum(a["render_s"]) / len(a["render_s"]), 2) if a["render_s"] else None,
                "aprovadas": a["aprovadas"], "reprovadas": a["reprovadas"],
                "taxa_aprovacao": round(a["aprovadas"] / revisadas, 2) if revisadas else None,
                "nota_media": round(sum(a["notas"]) / len(a["notas"]), 2) if a["notas"] else None,
                "revisadas": revisadas, "pele_problemas": a["pele_problemas"]}

    def pontos(c):
        """Aprovação da pessoa pesa mais; nota e portão desempatam (None = sem dado)."""
        if c["revisadas"] < SAMPLE_MIN:
            return None
        return (0.5 * (c["taxa_aprovacao"] or 0) + 0.3 * ((c["nota_media"] or 3) / 5) + 0.2 * (c["taxa_portao"] or 0))

    tabela = {i: {m: fechar(v) for m, v in d.items()} for i, d in sorted(por_int.items())}
    sugestao = {}
    for i, d in tabela.items():
        ph, pe = pontos(d["html"]), pontos(d["effectcraft"])
        if ph is None or pe is None:
            sugestao[i] = {"motor": None, "motivo": f"amostra pequena (mínimo {SAMPLE_MIN} revisadas por motor)"}
        else:
            vence = "effectcraft" if pe > ph + 0.05 else "html"
            sugestao[i] = {"motor": vence, "motivo": f"pontos html {ph:.2f} × effectcraft {pe:.2f}"
                           + ("" if vence == "effectcraft" else " (empate fica no html, o motor atual)")}
    return {"geral": {m: fechar(v) for m, v in geral.items()}, "por_intencao": tabela, "sugestao": sugestao,
            "decisao": engines(), "amostra_min": SAMPLE_MIN,
            "pendente": "acerto da IA local ao preencher: entra com a direção nova (etapa 6)"}


# ---------------------------------------------------------------- revisão

def _request_of(id_):
    return next((p for p in _read().values() if id_ in p.pecas), None)


def queue_review():
    """Peças esperando a pessoa, com o pedido de origem."""
    saida = []
    for f in P.list_all("revisao"):
        p = _request_of(f.id)
        par = next((x for x in (p.pares if p else []) if f.id in x), None)
        saida.append({"id": f.id, "pedido": p.id if p else None, "pedido_texto": p.texto if p else "",
                      "motor": f.motor, "par": [x for x in par if x != f.id][0] if par else None})
    return saida


def lesson(texto, id_="", motor="html"):
    """Acrescenta uma regra aprendida na revisão ao fim do guia do motor (lido em toda geração)."""
    arq = GUIDE_EC if motor == "effectcraft" else GUIDE
    guia = arq.read_text()
    linha = f"- {date.today():%d/%m/%Y}: {texto.strip()}" + (f" (peça {id_})" if id_ else "")
    guia = re.sub(r"\(entram aqui os motivos de reprovação e os ajustes pedidos na revisão[^)]*\)\n", "", guia)
    arq.write_text(guia.rstrip() + "\n" + linha + "\n")


def review(id_, acao, texto="", nota=None):
    """Decisão da pessoa sobre uma peça: aprovar | ajuste | variacao | reprovar; `nota` 1–5 (comparação dos motores)."""
    ficha = P.load(id_)
    if nota is not None and not (isinstance(nota, int) and 1 <= nota <= 5):
        raise ValueError("nota de 1 a 5")
    extra = {"motor": ficha.motor, "intencoes": ficha.intencoes, "nota": nota}
    p = _request_of(id_) or _change(STANDALONE, pecas=[*(_read().get(STANDALONE) or Request(id=STANDALONE)).pecas, id_],
                                  estado="ativo", texto="ajustes e variações de peças avulsas")
    if acao == "aprovar":
        P.save(ficha.model_copy(update={"estado": "aprovada"}))
        _verdict_piece(id_, "aprovada", nota=nota)
        _register("aprovada", peca=id_, pedido=p.id, **extra)
        aprovadas = sum(1 for i in _active(p) if P.load(i).estado == "aprovada")
        if p.id != STANDALONE and aprovadas >= p.quantidade * (2 if p.motor == "ambos" else 1):
            _change(p.id, estado="concluido", situacao="concluído")
        return {"ok": True}
    if acao in ("ajuste", "variacao"):
        if acao == "ajuste" and not texto.strip():
            raise ValueError("diga o que ajustar")
        _change(p.id, tarefas=[*p.tarefas, Task(tipo=acao, alvo=id_, comentario=texto.strip())],
               estado="ativo" if p.estado != "pausado" else "pausado")
        if acao == "ajuste":
            lesson(f"ajuste pedido: {texto.strip()}", id_, ficha.motor)
            _verdict_piece(id_, "ajuste", nota=nota, comentario=texto.strip())
        _register(acao, peca=id_, pedido=p.id, texto=texto, **extra)
        return {"ok": True, "fila": enqueue(p.id) is not None}
    if acao == "reprovar":
        if ficha.origem == "kit":
            raise ValueError("peça migrada do kit: o diretor atual ainda a usa; peça um ajuste em vez de reprovar")
        if not texto.strip():
            raise ValueError("diga o motivo da reprovação (vira regra para as próximas)")
        lesson(f"reprovada: {texto.strip()}", id_, ficha.motor)
        _verdict_piece(id_, "reprovada", nota=nota, motivo=texto.strip())
        _discard(id_, texto.strip())
        _register("reprovada", peca=id_, pedido=p.id, motivo=texto, **extra)
        restantes = [i for i in p.pecas if i != id_]
        reabrir = p.id != STANDALONE and p.estado != "pausado"
        _change(p.id, pecas=restantes, estado="ativo" if reabrir else p.estado)
        return {"ok": True, "fila": (enqueue(p.id) is not None) if reabrir else False}
    raise ValueError(f"ação inválida: {acao}")


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


def save_expansion(**campos):
    a = Expansion.model_validate({**expansion().model_dump(), **campos})
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
    hoje = date.today().isoformat()
    do_dia = next((p for p in _read().values() if p.texto == f"ampliação contínua {hoje}"), None)
    if do_dia:
        if do_dia.estado == "ativo":
            enqueue(do_dia.id)
        return do_dia, "pedido do dia"
    p = new_request("lacunas", "", a.pecas_por_dia, a.teto_dia_usd, motor=a.motor)
    p = _change(p.id, texto=f"ampliação contínua {hoje}")
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


def _category(motivo) -> str:
    m = str(motivo or "")
    return next((nome for nome, rx in CATEGORIES if re.search(rx, m)), "outro")


def _calls_live():
    """Chamadas de LLM em andamento nos processos da fábrica (rastro ao vivo)."""
    saida = []
    for arq in trace.DIR.glob("*.json"):
        try:
            v = json.loads(arq.read_text())
        except (OSError, ValueError):
            continue
        c = v.get("call")
        if not c or not str(v.get("flow") or "").startswith("fabrica"):
            continue
        saida.append({"pedido": str(v["flow"]).split(":", 1)[-1], "motor": c.get("engine"), "nome": c.get("name"),
                      "modelo": c.get("model"), "tokens": c.get("tokens") or 0,
                      "segundos": round(time.time() - (c.get("start") or time.time()), 1),
                      "parcial": (c.get("partial") or "")[-400:]})
    return saida


def _windows_quota():
    try:
        j = json.loads(claude.QUOTA_FILE.read_text())
    except (OSError, ValueError):
        j = {}
    agora = time.time()
    return {k: {"uso": (v.get("utilization") or 0.0) if (v.get("resetsAt") or 0) > agora else 0.0,
                "vira": datetime.fromtimestamp(v["resetsAt"]).isoformat(timespec="minutes") if v.get("resetsAt") else None}
            for k, v in j.items()}


def panel():
    """Estado da fábrica para o painel ao vivo: o que está em andamento (etapa, peça, chamada do Claude ou da LLM
    local), cota, números de hoje por quem fez, fila de ideias, acervo, dataset das tarefas e linha do tempo."""
    from collections import Counter

    from esteira.dataset import index
    from esteira.web import queue
    hoje = date.today().isoformat()
    ps = [p for p in requests() if p.id != STANDALONE]
    hibridos = [p for p in ps if p.ia == "hibrido" and p.estado != "concluido"]
    tarefas = queue.list_all()
    rodando = {t["ep"].split(":", 1)[1] for t in tarefas if t["ep"].startswith("fabrica:") and t["estado"] == "rodando"}
    na_fila = {t["ep"].split(":", 1)[1] for t in tarefas if t["ep"].startswith("fabrica:") and t["estado"] == "na fila"}
    reg = [r for r in record(2000) if str(r.get("t", "")).startswith(hoje)]
    feitos = [r for r in reg if r.get("evento") in ("gerada", "descartada") and r.get("motor") == "effectcraft"]
    motivos = Counter(_category(r.get("motivo")) for r in feitos if r["evento"] == "descartada")
    revs = [r for r in reg if r.get("evento") == "revisao"]
    gastos = Counter()
    for r in claude._records():
        if str(r.get("ep", "")) == f"fabrica-{hoje}":
            gastos[r.get("reason") or "outro"] += r.get("cost") or 0
    acervo = Counter((f.motor, f.estado) for f in P.list_all())
    sit = index.status()
    thumbs = [{"ep": t["ep"], "estado": t["estado"], "inicio": t.get("inicio")} for t in tarefas
              if t.get("comando") in ("thumb", "thumbs") and t["estado"] in ("rodando", "na fila")]
    licoes = [x[2:] for x in _lessons_n1().strip().splitlines() if x.startswith("- ")]
    return {
        "agora": [{"pedido": p.id, "tipo": p.tipo, "estado": p.estado, "rodando": p.id in rodando,
                   "na_fila": p.id in na_fila, "etapa": p.etapa if p.id in rodando else {}, "situacao": p.situacao}
                  for p in hibridos],
        "chamadas": _calls_live(),
        "cota": {"janelas": _windows_quota(), "limite": claude.quota_limit(), "cheia": claude.quota_full()},
        "pedidos": [{"id": p.id, "tipo": p.tipo, "texto": p.texto[:120], "estado": p.estado, "quantidade": p.quantidade,
                     "pecas": len(p.pecas), "descartadas": p.descartadas, "ideias_na_fila": len(p.conceitos),
                     "alvos": len(p.alvos), "feitos": len(p.feitos), "gasto_usd": p.gasto_usd,
                     "rodando": p.id in rodando, "na_fila": p.id in na_fila} for p in hibridos],
        "ideias_na_fila": [{"pedido": p.id, "id": (c.get("ficha") or {}).get("id"),
                            "descricao": (c.get("ficha") or {}).get("descricao") or "",
                            "intencoes": (c.get("ficha") or {}).get("intencoes") or [], "conceito": c.get("conceito", "")[:300]}
                           for p in hibridos for c in p.conceitos],
        "hoje": {
            "ideias": {"lotes": sum(1 for r in claude._records() if r.get("ep") == f"fabrica-{hoje}"
                                    and r.get("reason") == "fabrica_ideias"),
                       "custo": round(gastos["fabrica_ideias"], 3)},
            "motion": {"tentativas": len(feitos), "geradas": sum(r["evento"] == "gerada" for r in feitos),
                       "descartadas": sum(r["evento"] == "descartada" for r in feitos),
                       "puladas": sum(r.get("evento") == "inviavel" for r in reg),
                       "local": sum(r.get("ia") == "local" for r in feitos),
                       "revisoes": len(revs), "aprovadas_claude": sum(bool(r.get("aprovada")) for r in revs),
                       "custo_revisao": round(gastos["fabrica_revisao"], 3),
                       "motivos": [{"motivo": m or "?", "n": n} for m, n in motivos.most_common(6)]},
            "gasto": {k: round(v, 3) for k, v in gastos.items()}, "gasto_total": round(sum(gastos.values()), 3),
        },
        "revisao": len(queue_review()),
        "acervo": {m: {e: acervo[(m, e)] for e in ("aprovada", "revisao", "rascunho")} for m in ("html", "effectcraft")},
        "dataset": {t: sit.get(t, {}) for t in ("peca_animar", "peca_html", "thumb_compor", "foto_tratar")},
        "thumbs": {"tarefas": thumbs},
        "licoes": {"total": len(licoes), "ultimas": licoes[-5:]},
        "eventos": [{"t": r.get("t"), "quem": _who(r), "evento": r.get("evento"), "peca": r.get("peca"),
                     "texto": str(r.get("motivo") or "; ".join(r.get("problemas") or []) or r.get("resumo") or "")[:220],
                     "custo": r.get("custo"), "aprovada": r.get("aprovada")} for r in record(40)],
    }
