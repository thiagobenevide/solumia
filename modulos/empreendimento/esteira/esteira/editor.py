"""Editor manual do painel: gráficos animados (dados, tempo, efeitos, caixas de texto livres) e thumbnails.

O estado de um gráfico é o próprio item do graficos.json ({modelo, inicio, dur, dados, efeito, caixas}); o
de uma thumb são os campos de `thumbs.dados_thumb` + `fundo` (arquivo em thumbs/). A prévia é o mesmo HTML
que vira o vídeo/PNG, servido ao navegador com `seek`. Gráfico salvo fica `manual: true`: o replanejamento
o mantém e só ele é renderizado de novo (o resto está em cache). O assistente de IA (Claude ou LLM local)
devolve um estado novo para a prévia; nada é salvo sem o usuário.
"""
import hashlib
import json
import re
import shutil

from pydantic import BaseModel, Field

from esteira.graphics import plan, render
from esteira.thumbs import dados_thumb

MODELOS = ("caixas", "frase", "numero", "lista", "comparacao", "capitulo", "fonte", "citacao")
NOVO = {"modelo": "caixas", "dur": 4.0, "dados": {"veu": "baixo"}, "efeito": {},
        "caixas": [dict(render.CAIXA, texto="Novo *texto*")]}
CAMPOS_THUMB = ("texto", "destaque", "layout", "seta", "selo", "tamanho", "cor_d", "alerta", "fundo", "caixas")


def _trocas(projeto, ep):
    return {render.RAIZ.as_uri(): "/graf", projeto.pasta.resolve().as_uri(): f"/arq/{ep}"}


def _dim(projeto):
    v = projeto.cfg["video"]
    return v["largura"], v["altura"]


def _dim_thumb(projeto):
    t = projeto.cfg.get("thumb", {})
    return t.get("largura", 1280), t.get("altura", 720)


# ---------- Gráficos ----------

def graficos(projeto):
    return projeto.carregar_json("graficos.json") if projeto.caminho("graficos.json").exists() else []


def estado_grafico(projeto, i, inicio=0.0):
    """Item `i` do graficos.json; i < 0 → peça nova de caixas em `inicio`."""
    if i < 0:
        return dict(json.loads(json.dumps(NOVO)), inicio=round(inicio, 2))
    g = graficos(projeto)[i]
    return {k: g.get(k) for k in ("modelo", "inicio", "dur", "dados", "efeito", "caixas", "origem")} | {
        "efeito": g.get("efeito") or {}, "caixas": g.get("caixas") or []}


def _limpo(e):
    if e.get("modelo") not in MODELOS:
        raise ValueError("modelo desconhecido")
    return {"modelo": e["modelo"], "inicio": round(float(e["inicio"]), 2), "dur": round(max(1.0, float(e["dur"])), 2),
            "dados": dict(e.get("dados") or {}), "efeito": dict(e.get("efeito") or {}),
            "caixas": [dict(c) for c in e.get("caixas") or []]}


def previa_grafico(projeto, ep, estado):
    e = _limpo(estado)
    w, h = _dim(projeto)
    pasta = projeto.caminho("graficos")
    pasta.mkdir(exist_ok=True)
    pc = plan.peca(e, pasta, w, h, pasta / "pag_editor.png")
    if not pc:
        raise ValueError("o trecho da citação não foi achado no PDF")
    return render.previa(*pc, e["dur"], w, h, projeto.cfg.get("graficos", {}).get("cor", "#ffd400"),
                         _trocas(projeto, ep))


def html_grafico(projeto, estado):
    """(HTML com caminhos file://, w, h) da peça: o que o app pede como quadro PNG (`web/frames.py`)."""
    e = _limpo(estado)
    w, h = _dim(projeto)
    pasta = projeto.caminho("graficos")
    pasta.mkdir(exist_ok=True)
    pc = plan.peca(e, pasta, w, h, pasta / "pag_editor.png")
    if not pc:
        raise ValueError("o trecho da citação não foi achado no PDF")
    return render.html(*pc, e["dur"], w, h, projeto.cfg.get("graficos", {}).get("cor", "#ffd400")), w, h


def salvar_grafico(projeto, i, estado):
    """Grava no graficos.json como `manual` (i < 0 acrescenta). Devolve o índice na lista ordenada."""
    e = _limpo(estado)
    lista = graficos(projeto)
    if i < 0:
        item = dict(e, origem="editor")
        lista.append(item)
    else:
        item = lista[i]
        item.update(e)
        # dados novos: a peça é refeita a partir deles (um .ecproj editado à mão fica em graficos/ como estava)
        for k in ("arquivo", "manual_ec", "ecproj", "ec_gerado"):
            item.pop(k, None)
    item["manual"] = True
    lista.sort(key=lambda g: g["inicio"])
    projeto.salvar_json("graficos.json", lista)
    return lista.index(item)


def excluir_grafico(projeto, i):
    lista = graficos(projeto)
    lista.pop(i)
    projeto.salvar_json("graficos.json", lista)


# ---------- Thumbnails ----------

def _edicoes(projeto):
    arq = projeto.caminho("thumbs/edicoes.json")
    return json.loads(arq.read_text()) if arq.exists() else {}


def fundos(projeto):
    pasta = projeto.caminho("thumbs")
    return sorted(p.name for p in pasta.iterdir() if p.name.startswith(("fundo_", "upload_"))
                  and p.suffix in (".png", ".jpg", ".jpeg", ".webp")) if pasta.exists() else []


def thumbs(projeto):
    """Thumbs editáveis: as da etapa (ranking.json) e as feitas no editor (edicoes.json)."""
    saida = []
    rk = projeto.caminho("thumbs/ranking.json")
    for r in json.loads(rk.read_text()) if rk.exists() else []:
        c = r["conceito"]
        fundo = r.get("fundo") or f"fundo_{hashlib.sha1(c['cena_en'].encode()).hexdigest()[:8]}.png"
        saida.append({"arquivo": r["arquivo"], "nota": r.get("nota"), "origem": "etapa",
                      "estado": {k: c.get(k) for k in ("texto", "destaque", "layout", "seta")} | {"fundo": fundo}})
    for arq, e in _edicoes(projeto).items():
        saida.append({"arquivo": arq, "nota": None, "origem": "editor", "estado": e})
    return [t for t in saida if projeto.caminho(f"thumbs/{t['arquivo']}").exists()]


def _limpo_thumb(projeto, e):
    e = {k: e[k] for k in CAMPOS_THUMB if k in e}
    if e.get("layout") not in ("rosto_direita", "rosto_esquerda", "numero"):
        e["layout"] = "rosto_direita"
    if "/" in e.get("fundo", "/") or not projeto.caminho(f"thumbs/{e['fundo']}").exists():
        raise ValueError("fundo inválido")
    return e


def previa_thumb(projeto, ep, estado):
    e = _limpo_thumb(projeto, estado)
    w, h = _dim_thumb(projeto)
    dados = dados_thumb(e, projeto.caminho(f"thumbs/{e['fundo']}").resolve().as_uri(), projeto.cfg)
    return render.previa("thumb", dados, 1, w, h, "#ffd400", _trocas(projeto, ep), estatico=True)


def html_thumb(projeto, estado):
    """(HTML com caminhos file://, w, h) da thumb, como `html_grafico`."""
    e = _limpo_thumb(projeto, estado)
    w, h = _dim_thumb(projeto)
    dados = dados_thumb(e, projeto.caminho(f"thumbs/{e['fundo']}").resolve().as_uri(), projeto.cfg)
    return render.html("thumb", dados, 1, w, h, "#ffd400", estatico=True), w, h


def salvar_thumb(projeto, estado):
    e = _limpo_thumb(projeto, estado)
    nome = f"manual_{hashlib.sha1(json.dumps(e, sort_keys=True).encode()).hexdigest()[:8]}.png"
    w, h = _dim_thumb(projeto)
    from esteira.thumbs import compor_arquivo
    compor_arquivo(e, projeto.caminho(f"thumbs/{e['fundo']}"), projeto.caminho(f"thumbs/{nome}"), projeto.cfg)
    ed = _edicoes(projeto)
    ed[nome] = e
    projeto.salvar_json("thumbs/edicoes.json", ed)
    return nome


def usar_thumb(projeto, arquivo, k):
    """Põe a thumb na vaga k (1..3) do teste A/B; a 1 também vira thumb.png."""
    origem = projeto.caminho(f"thumbs/{arquivo}")
    if "/" in arquivo or not origem.exists() or k not in (1, 2, 3):
        raise ValueError("thumb inválida")
    shutil.copy2(origem, projeto.caminho(f"thumb_{k}.png"))
    if k == 1:
        shutil.copy2(origem, projeto.caminho("thumb.png"))
    try:  # escolha da pessoa → veredito no dataset (candidata gerada pela etapa thumbs)
        from esteira.dataset import registry as R
        rg = R.ultimo(f"thumb:{projeto.ep}", "thumb_compor", arquivo=arquivo)
        if rg:
            R.avaliar(rg["id"], "escolhida", comentario=f"vaga {k}")
    except Exception:  # noqa: BLE001
        pass


def guardar_fundo(projeto, conteudo, sufixo):
    nome = f"upload_{hashlib.sha1(conteudo).hexdigest()[:8]}{sufixo}"
    projeto.caminho("thumbs").mkdir(exist_ok=True)
    projeto.caminho(f"thumbs/{nome}").write_bytes(conteudo)
    return nome


# ---------- Assistente de IA ----------

class CaixaIA(BaseModel):
    texto: str = Field(max_length=220)
    x: float = Field(ge=0, le=100)
    y: float = Field(ge=0, le=100)
    w: float = Field(ge=5, le=100)
    tam: int = Field(ge=14, le=260)
    fonte: str = Field(pattern="^(Inter|Playfair|Mono)$")
    peso: int = Field(ge=300, le=900)
    cor: str = Field(pattern=r"^#[0-9a-fA-F]{6}$")
    fundo: str = Field(pattern="^(nenhum|solido|vidro|tarja|contorno)$")
    alinhar: str = Field(pattern="^(left|center|right)$")
    maiusculas: bool = False
    entrada: str = Field("subir", pattern="^(subir|fade|zoom|esquerda|revelar|nenhuma)$")
    atraso: float = Field(0.2, ge=0, le=20)


class Sugestao(BaseModel):
    dados_json: str = Field(description="objeto JSON com as mesmas chaves de estado.dados, valores novos")
    entrada: str = Field("padrao", pattern="^(padrao|nenhuma|fade|subir|zoom|deslizar|desfoque|revelar)$")
    saida: str = Field("padrao", pattern="^(padrao|nenhuma|fade|zoom|deslizar|descer)$")
    caixas: list[CaixaIA] = Field([], max_length=8)
    explicacao: str = Field("", max_length=240)


FIXOS = {"arquivo", "trecho", "pagina", "fundo"}  # a IA não troca PDF/trecho conferido nem o fundo da thumb


def _contexto(projeto, inicio, dur):
    falas = []
    if inicio is not None and projeto.caminho("frases.json").exists():
        falas = [f["texto"] for f in projeto.carregar_json("frases.json")
                 if f.get("ini") is not None and inicio - 6 <= f["ini"] <= inicio + dur + 4]
    rot = json.loads(projeto.caminho("roteiro.json").read_text()) if projeto.caminho("roteiro.json").exists() else {}
    fontes = [f"{c.get('autores')} ({c.get('ano')}), {c.get('revista')}: \"{c.get('pt')}\"" for c in rot.get("citacoes", [])]
    return rot.get("titulo", ""), " ".join(falas), fontes


def _numeros(texto):
    return set(re.findall(r"\d+(?:[.,]\d+)?", texto))


def sugerir(projeto, ep, estado, pedido, motor="claude", tipo="grafico"):
    """Devolve (estado_novo, explicacao, avisos) ou levanta ValueError."""
    from esteira.ai import claude, local
    thumb = tipo == "thumb"
    if thumb:
        e = _limpo_thumb(projeto, estado)
        w, h = _dim_thumb(projeto)
        dados = {k: v for k, v in e.items() if k not in ("caixas", "fundo")}
        titulo, falas, fontes = _contexto(projeto, None, 0)
        alvo = f"a thumbnail ({w}x{h}) do YouTube; texto gigante, poucas palavras, layout rosto_direita|rosto_esquerda|numero"
        caixas, efeito = e.get("caixas") or [], {}
    else:
        e = _limpo(estado)
        w, h = _dim(projeto)
        dados = {k: v for k, v in e["dados"].items() if k not in FIXOS}
        titulo, falas, fontes = _contexto(projeto, e["inicio"], e["dur"])
        alvo = f"um gráfico animado ({w}x{h}, modelo {e['modelo']}, {e['dur']}s, sobreposto ao vídeo)"
        caixas, efeito = e["caixas"], e["efeito"]
    dossie = "\n".join([
        f"Você edita {alvo} do vídeo \"{titulo}\" (canal {getattr(projeto, 'canal', '')}).",
        f"Pedido do editor: {pedido}",
        f"Estado atual: {json.dumps({'dados': dados, 'efeito': efeito, 'caixas': caixas}, ensure_ascii=False)}",
        f"Fala neste trecho: {falas or '-'}",
        "Fontes do roteiro (únicos dados de estudos que podem aparecer):", *(fontes or ["-"]),
        "Regras: pt-BR, textos curtos e fortes; números, nomes e anos só se estiverem na fala, nas fontes ou no "
        "estado; *asteriscos* marcam a palavra em destaque; caixas: x, y, w em % do quadro (x, y = canto superior "
        "esquerdo), tam em px do quadro; não cubra o conteúdo principal do modelo; dados_json com as mesmas chaves "
        "de estado.dados; mantenha o que o pedido não mandou mudar."])
    from esteira.core import trace
    trace.node(f"editor:{ep}", "editor", pedido[:120])
    try:
        if motor == "local":
            r = local.ask(dossie, Sugestao, temperature=0.4, max_tokens=2500, operation="editor")
        else:
            r = claude.query(dossie, Sugestao, projeto.cfg, ep, f"editor: {pedido[:40]}")
    finally:
        trace.node(None, None)
    if not r:
        raise ValueError("a IA não respondeu (teto de custo do Claude ou falha do LLM local)")
    try:
        novos = json.loads(r.dados_json)
    except ValueError:
        novos = {}
    if not isinstance(novos, dict):
        novos = {}
    novos = {k: v for k, v in novos.items() if k in dados}
    caixas_n = [dict(render.CAIXA, **c.model_dump()) for c in r.caixas]
    base = _numeros(" ".join([falas, *fontes, json.dumps(dados, ensure_ascii=False), json.dumps(caixas, ensure_ascii=False)]))
    saida_txt = json.dumps(novos, ensure_ascii=False) + " ".join(c["texto"] for c in caixas_n)
    avisos = [f"o número {n} não aparece na fala nem nas fontes: confira" for n in sorted(_numeros(saida_txt) - base)]
    if thumb:
        novo = dict(e, **novos, caixas=caixas_n)
    else:
        novo = dict(e, dados=dict(e["dados"], **novos), caixas=caixas_n, efeito={**efeito, "entrada": r.entrada, "saida": r.saida})
    return novo, r.explicacao, avisos

