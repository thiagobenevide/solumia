"""Etapa thumb: thumbnails agressivas com teste A/B.

1. LLM local: ~8 conceitos (emoção, gatilho, texto de 2–4 palavras que completa o título, cena de fundo).
2. RealVisXL na GPU (`.venv-img`): um fundo por conceito.
3. Modelo HTML `thumb` → PNG 1280×720 (texto gigante com contorno, cor de alerta, selo, seta).
4. Visão local: nota de impacto vendo a thumb no tamanho do celular (168×94 ampliado).
5. Claude: uma folha com as 6 melhores → escolhe 3 para o "Testar e comparar" do YouTube.
Saída: thumbs/*.png (todas), thumb_1..3.png e thumb.png (= thumb_1).
"""
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from pydantic import BaseModel, Field

from esteira.core import events
from esteira.curadoria import ESTILOS
from esteira.graficos import render
from esteira.ai import local
from esteira.projeto import RAIZ

PY_IMG = RAIZ / ".venv-img" / "bin" / "python"


class Conceito(BaseModel):
    emocao: str = Field(max_length=20)
    gatilho: str = Field(max_length=120)
    texto: str = Field(max_length=40)
    destaque: str = Field(min_length=1, max_length=20)
    cena_en: str = Field(max_length=300)
    layout: str = Field(pattern="^(rosto_direita|rosto_esquerda|numero)$")
    seta: bool = False


class Conceitos(BaseModel):
    conceitos: list[Conceito] = Field(max_length=10)


class Impacto(BaseModel):
    impacto: int = Field(ge=1, le=10)
    legivel: bool
    problema: str = Field("", max_length=80)


def _contexto(projeto):
    rot = json.loads(projeto.caminho("roteiro.json").read_text()) if projeto.caminho("roteiro.json").exists() else {}
    md = projeto.caminho("roteiro_original.md")
    promessa = ""
    if md.exists():
        m = re.search(r"\*\*Pergunta:\*\*(.+?)\n.*?\*\*Promessa:\*\*(.+?)\n", md.read_text(), re.S)
        promessa = " ".join(x.strip() for x in m.groups()) if m else ""
    texto = projeto.roteiro().read_text()
    falas = [l for l in texto.splitlines()[1:] if l.strip()]
    numeros = sorted(set(re.findall(r"\d[\d.,]*\s*(?:%|mil|milhão|milhões|bilhões)|R\$\s*[\d.,]+", texto)))[:8]
    return {"titulo": rot.get("titulo") or texto.splitlines()[0].lstrip("# "), "promessa": promessa or "-",
            "gancho": " ".join(falas[:3])[:500].replace("*", ""), "numeros": ", ".join(numeros) or "nenhum"}


def _palavras(texto, destaque):
    """Palavras em maiúsculas; a de destaque (ou o número, ou a última) vai na cor de alerta."""
    ps = texto.upper().split()
    alvo = {w for w in destaque.upper().split()} & set(ps) or {next((w for w in ps if re.search(r"\d", w)), ps[-1])}
    return [{"t": p, "d": p in alvo} for p in ps]


def _valido(c, roteiro):
    """Até 4 palavras (sem contar "R$") e todo número do texto presente no roteiro (nada de "R$ 400%")."""
    palavras = [w for w in c.texto.split() if w.upper() != "R$"]
    if len(palavras) > 4:
        return False
    rot = roteiro.lower()
    for num, unidade in re.findall(r"(\d[\d.,]*)\s*(%|mil\w*|milh\w*|bilh\w*|vezes|anos?)?", c.texto.lower()):
        # o número com a mesma unidade tem de estar no roteiro ("1,4 mil" ≠ "1,4 milhão")
        un = {"mil": r"mil\b", "%": "%"}.get(unidade, re.escape(unidade[:4]))
        if not re.search(re.escape(num) + (r"\s*" + un if unidade else r"(?![\d,])"), rot):
            return False
    return not ("%" in c.texto and "R$" in c.texto.upper())


def dados_thumb(e, fundo_uri, cfg):
    """Dados do modelo `thumb` a partir dos campos editáveis `e` (texto, destaque, layout, seta e, opcionais,
    selo, tamanho, cor_d, alerta, caixas). Usado pela etapa e pelo editor do painel."""
    t = cfg.get("thumb", {})
    palavras = _palavras(e["texto"], e.get("destaque") or "") if e.get("texto", "").strip() else []
    numero = e["layout"] == "numero"
    n = len(palavras)
    tamanho = e.get("tamanho") or (230 if numero and n <= 2 else 150 if n <= 2 else 132 if n == 3 else 112)
    seta_pos = ("left: 660px; top: 150px" if e["layout"] != "rosto_esquerda"
                else "right: 660px; top: 150px; transform: scaleX(-1)")
    return dict(fundo=fundo_uri, layout=e["layout"], palavras=palavras, tamanho=tamanho,
                cor_d=e.get("cor_d") or t.get("cor_texto", "#ffd400"), alerta=e.get("alerta") or t.get("alerta", "#ff2d2d"),
                seta=bool(e.get("seta")) and not numero, seta_pos=seta_pos, selo=e.get("selo", ""),
                caixas=e.get("caixas") or [])


def compor_arquivo(e, fundo, destino, cfg):
    """Campos editáveis `e` → `destino` (.png). Com o PhotoCraft (`[thumb] motor`, padrão), grava também o
    `.pcraft` em camadas ao lado do PNG, para edição manual."""
    from esteira import photocraft
    t = cfg.get("thumb", {})
    w, h = t.get("largura", 1280), t.get("altura", 720)
    dados = dados_thumb(e, Path(fundo).resolve().as_uri(), cfg)
    if t.get("motor", "photocraft") == "photocraft" and photocraft.disponivel():
        photocraft.compor(dados, Path(destino).with_suffix(".pcraft"), w, h)
    else:
        render.imagem("thumb", dados, destino, w, h)
    return destino


def _compor(c, fundo, destino, cfg):
    return compor_arquivo(c.model_dump(), fundo, destino, cfg)


def _gerar_fundos(pedidos):
    if not PY_IMG.exists():
        raise SystemExit("geração de imagem não instalada (.venv-img); veja docs/PLANO.md")
    local.free_gpu()
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(pedidos, f)
    p = subprocess.Popen([str(PY_IMG), str(RAIZ / "esteira/imagem/gerar_sdxl.py"), f.name],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    n = 0
    for linha in p.stdout:
        if linha.startswith("{"):
            n += 1
            events.progress(n, len(pedidos), f"fundo {n} ({json.loads(linha)['seg']}s)")
    if p.wait():
        raise RuntimeError(f"gerar_sdxl falhou: {p.stderr.read()[-600:]}")


def _avaliar(arq, c, ctx):
    """Visão local vê a thumb pequena (como no feed do celular) e dá o impacto."""
    pequena = arq.with_name(f".peq_{arq.stem}.jpg")
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", arq, "-vf",
                    "scale=168:94,scale=504:282:flags=neighbor", "-q:v", "3", "-update", "1", pequena], check=True)
    r = local.ask(
        f'Esta é uma thumbnail de YouTube vista no tamanho do feed do celular. Título do vídeo: "{ctx["titulo"]}". '
        f'Texto da thumb: "{c.texto}". De 1 a 10, quanto ela faz a pessoa sentir {c.emocao} e precisar clicar '
        f'AGORA (ponto focal claro, emoção forte, contraste)? O texto é legível nesse tamanho? '
        f'Responda em JSON: {{"impacto": 1-10, "legivel": true|false, "problema": "até 10 palavras"}}',
        Impacto, model=local.VISION, images=[pequena], max_tokens=100)
    pequena.unlink(missing_ok=True)
    return r


def _escolher_com_claude(projeto, ranking, ctx):
    from esteira.ai import claude
    from esteira.midia import folha

    class Escolha(BaseModel):
        escolhidas: list[int] = Field(min_length=1, max_length=3)
        motivo: str

    top = ranking[:6]
    destino = projeto.caminho("thumbs/folha_escolha.jpg")
    folha(projeto, [(r["arquivo"], None, str(k)) for k, r in enumerate(top)], destino, colunas=3, w=512, h=288)
    roteiro = projeto.roteiro().read_text()

    def contexto(texto):
        """Frase do roteiro onde está o número da thumb (para o Claude checar se a promessa é honesta)."""
        num = re.search(r"\d[\d.,]*", texto)
        if not num:
            return ""
        frase = next((f for f in re.split(r"(?<=[.!?])\s+", roteiro) if num.group() in f), "")
        return f' | no roteiro: "{frase[:200]}"'

    linhas = "\n".join(f"{k}: texto \"{r['conceito']['texto']}\", emoção {r['conceito']['emocao']}, "
                       f"gatilho: {r['conceito']['gatilho']}{contexto(r['conceito']['texto'])}"
                       for k, r in enumerate(top))
    r = claude.query(
        f"Thumbnails candidatas para o vídeo \"{ctx['titulo']}\" (número no canto). Escolha as 3 que mais fazem "
        f"a pessoa parar de rolar e clicar NA HORA, com emoções/abordagens diferentes entre si (para teste A/B), "
        f"legíveis no celular e honestas com o conteúdo: recuse a que distorce o número ou promete o que o "
        f"vídeo não diz (compare com a frase do roteiro). Ordene da melhor para a pior.\n\n{linhas}",
        Escolha, projeto.cfg, projeto.ep, "thumb: escolher 3 de 6", image=destino)
    if not r:
        return top[:3]
    return [top[k] for k in r.escolhidas if 0 <= k < len(top)] or top[:3]


def _dataset(projeto, ctx, ranking, escolhidas):
    """Cada candidata vira registro `thumb_compor` (pendente: o veredito é da pessoa, ao pôr numa vaga A/B).
    A ordem do Claude e a nota da visão entram como métricas; nunca derruba a etapa."""
    try:
        from esteira import photocraft
        from esteira.dataset import registro as R
        from esteira.n1 import photocraft as N1
        ordem = [e["arquivo"].name for e in escolhidas]
        for x in ranking:
            nome = x["arquivo"].name
            doc = photocraft.ULTIMOS.get(str(x["arquivo"]))
            R.gravar("thumb_compor", grupo=f"thumb:{projeto.ep}", origem="local:thumb_conceitos",
                     contexto={**ctx, "canal": getattr(projeto, "canal", "") or "", "fundo": x["fundo"],
                               "cena_en": x["conceito"].get("cena_en")},
                     saida=doc.model_dump(mode="json") if doc else {"conceito": x["conceito"]},
                     versoes={"n1": N1.VERSAO if doc else None, "app": "photocraft"},
                     metricas={"nota_visao": x["nota"], "problema": x["problema"],
                               "ordem_claude": ordem.index(nome) + 1 if nome in ordem else None},
                     extra={"episodio": projeto.ep, "arquivo": nome})
    except Exception as e:  # noqa: BLE001
        events.warning(f"dataset: thumbs de {projeto.ep} não gravadas ({e})")


def thumbs(projeto, n=8):
    if not projeto.cfg.get("thumb", {}).get("ativo", True):
        print("  thumbs desligadas neste formato ([thumb] ativo = false)")
        return
    for velho in projeto.caminho("thumbs").glob("thumb_*.png") if projeto.caminho("thumbs").exists() else []:
        velho.unlink()
    ctx = _contexto(projeto)
    canal = getattr(projeto, "canal", "") or ""
    roteiro = projeto.roteiro().read_text()
    prompt = local.prompt("thumb_conceitos", canal=canal or "documentário",
                          estilo=ESTILOS.get(canal, "documentário dark"), n_pedidos=n + 4, **ctx)
    # o LLM às vezes ignora o limite de palavras: pede de novo até ter ao menos 3 válidos
    conceitos, descartados, vistos = [], 0, set()
    for tentativa in range(3):
        aviso = "" if not tentativa else ("\n\nATENÇÃO: na resposta anterior quase todos os textos tinham mais de 4 "
                                          "palavras ou números que não estão no roteiro. Use NO MÁXIMO 4 palavras.")
        r = local.ask(prompt + aviso, Conceitos, temperature=0.8 + 0.1 * tentativa, max_tokens=3000)
        for c in (r.conceitos if r else []):
            if c.texto.upper() in vistos:
                continue
            vistos.add(c.texto.upper())
            if _valido(c, roteiro):
                conceitos.append(c)
            else:
                descartados += 1
        if len(conceitos) >= 3:
            break
    conceitos = conceitos[:n]
    if not conceitos:
        raise SystemExit(f"o LLM local não gerou conceitos de thumbnail válidos em 3 tentativas "
                         f"({descartados} descartados: número fora do roteiro ou texto longo)")
    print(f"  {len(conceitos)} conceitos" + (f" ({descartados} descartados: número fora do roteiro ou texto longo)"
                                             if descartados else "") + ": " + " | ".join(c.texto for c in conceitos))

    pasta = projeto.caminho("thumbs")
    pasta.mkdir(exist_ok=True)
    estilo = ", cinematic photo, dramatic lighting, high contrast, shallow depth of field, 8k, sharp focus"
    fundos = [pasta / f"fundo_{hashlib.sha1(c.cena_en.encode()).hexdigest()[:8]}.png" for c in conceitos]
    pedidos = [{"prompt": c.cena_en + estilo, "semente": 1000 + k, "saida": str(f)}
               for k, (c, f) in enumerate(zip(conceitos, fundos)) if not f.exists()]
    if pedidos:
        _gerar_fundos(pedidos)

    ranking = []
    for k, c in enumerate(conceitos):
        arq = _compor(c, fundos[k], pasta / f"thumb_{k}.png", projeto.cfg)
        av = _avaliar(arq, c, ctx)
        nota = (av.impacto if av else 5) - (3 if av and not av.legivel else 0)
        ranking.append({"arquivo": arq, "nota": nota, "conceito": c.model_dump(), "fundo": fundos[k].name,
                        "problema": av.problema if av else ""})
        events.debug(f"thumb {k}: {c.texto}", nota=nota, problema=av.problema if av else "")
    ranking.sort(key=lambda x: -x["nota"])
    escolhidas = _escolher_com_claude(projeto, ranking, ctx)
    for k, e in enumerate(escolhidas, 1):
        shutil.copy2(e["arquivo"], projeto.caminho(f"thumb_{k}.png"))
    shutil.copy2(escolhidas[0]["arquivo"], projeto.caminho("thumb.png"))
    projeto.salvar_json("thumbs/ranking.json", [dict(x, arquivo=str(x["arquivo"].name)) for x in ranking])
    _dataset(projeto, ctx, ranking, escolhidas)
    print(f"  thumb_1..{len(escolhidas)}.png para o teste A/B: " + " | ".join(e["conceito"]["texto"] for e in escolhidas))
