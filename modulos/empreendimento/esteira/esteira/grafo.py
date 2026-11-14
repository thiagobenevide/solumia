"""Grafo da operação para o Monitor: nós (passos do roteiro, etapas do episódio e recursos: modelos, APIs,
programas), arestas e o estado de cada nó a partir do rastro (`core/trace.py`) e dos processos vivos.
Cada nó traz um "como funciona" para quem está aprendendo como a operação com LLM acontece por baixo.
"""
import json
import time
from pathlib import Path

import psutil

from esteira import grafo_dados
from esteira.core import trace

# (id, rótulo, faixa, motor, explicação)
_R, _E, _S, _X = "roteiro", "episodio", "estudio", "recurso"
NOS = [
    ("r_plano", "Plano (Arco)", _R, "py", "Python lê a linha do vídeo na tabela do Arco no vault: título, gancho, artigos-base, busca em inglês, formato (M/L/D). Nenhum modelo envolvido."),
    ("r_openalex", "Busca OpenAlex", _R, "py", "Python consulta a API do OpenAlex (com a sua chave) filtrando is_oa=true: primeiro os artigos-base do plano, depois a busca em inglês. Volta uma lista de estudos de acesso aberto com DOI."),
    ("r_pdf", "Baixar PDF", _R, "py", "`artigo baixar <doi>` procura o PDF aberto (OpenAlex, Semantic Scholar, citation_pdf_url), recusa apêndices e cópias de terceiros, grava em Referências/Artigos e no indice.json."),
    ("r_trechos", "Frases c/ números", _R, "py", "PyMuPDF extrai o texto de até 25 páginas e o Python separa as frases que têm números e palavras da busca. Isso reduz um PDF de 40 páginas a ~14 frases: o LLM só lê o que importa (menos tokens, menos alucinação)."),
    ("r_fatos", "Escolher fatos", _R, "local", "LLM local (qwen3-14b) recebe as frases numeradas e devolve JSON com as que provam algo do tema + tradução. O JSON é forçado por esquema (structured output): o modelo só pode gerar tokens que formam um JSON válido."),
    ("r_citar", "Conferir trecho", _R, "py", "`artigo citar` procura o trecho EN no PDF, corrige a página e gera o bloco [!cite]. Se o trecho não estiver no PDF, o fato é descartado: é a trava contra alucinação."),
    ("r_partes", "Escrever partes", _R, "local", "LLM local escreve cada Parte (gancho, contexto, prova…) com temperatura 0.4, recebendo só os fatos conferidos. Uma chamada por parte; a resposta é JSON com as falas."),
    ("r_validar", "Validar números", _R, "py", "Python compara cada número das falas com os fatos: fala com número sem fonte sai; parte curta é refeita (até 3 tentativas, com aviso no prompt)."),
    ("r_montar", "Montar markdown", _R, "py", "Python junta frontmatter, partes, blocos [!cite] e lista de fontes no formato do vault."),
    ("r_checar", "artigo checar", _R, "py", "Confere de novo cada bloco [!cite] contra o PDF e se todas as fontes são abertas (✓/✗)."),
    ("transcribe", "Transcrever", _E, "gpu", "faster-whisper large-v3 na GPU transforma o WAV em texto com o tempo de cada palavra. Não é um LLM de chat: é um modelo de fala (encoder-decoder) que roda em lotes de 30 s de áudio."),
    ("clean", "Cortes", _E, "local", "Python acha repetições e erros de gravação comparando a fala com o roteiro; o LLM local decide os casos ambíguos; o Claude só entra se o local não tiver confiança."),
    ("scenes", "Cenas", _E, "py", "Python divide a narração em cenas pelo alinhamento palavra a palavra com o roteiro."),
    ("curate", "Curadoria", _E, "local", "LLM local lê cada cena e devolve o termo de busca em inglês, o tipo de mídia (vídeo/foto) e o clima."),
    ("fetch", "Buscar mídia", _E, "py", "Python consulta primeiro o acervo local (SQLite/FTS5) e depois as APIs dos bancos de imagem/vídeo; baixa e registra crédito e licença."),
    ("evaluate", "Avaliar mídia", _E, "local", "Modelo de visão local (qwen2.5vl-7b) olha um quadro da mídia de cada cena e dá nota de adequação; a imagem vira tokens visuais (patches) antes do texto."),
    ("graphics", "Gráficos", _E, "local", "LLM local escreve o conteúdo de cada gráfico (número, legenda, lista); Python agenda sem sobrepor; cada peça vira um projeto .ecproj do EffectCraft (camadas nomeadas, editável à mão) e a engine renderiza ProRes com alfa. Um .ecproj salvo à mão é renderizado como está."),
    ("assemble", "Montagem", _E, "py", "Python monta a linha do tempo no FilmCraft (V1 cenas, V4 gráficos, A1 narração, A2 trilha) e exporta."),
    ("thumb", "Thumbnails", _E, "gpu", "LLM local cria conceitos, RealVisXL (difusão) gera os fundos na GPU, o PhotoCraft monta cada thumb em camadas (.pcraft editável: fundo, ajustes, vinheta, título, selo, seta) e exporta o PNG; o modelo de visão dá nota e o Claude escolhe as 3 do teste A/B."),
    ("editor", "Editor (painel)", _E, "claude", "Assistente do editor de gráficos/thumbs: manda o estado atual + fala + fontes e recebe um estado novo em JSON validado."),
    ("estudio_dirigir", "Dirigir", _S, "local", "O diretor do Estúdio lê cada bloco do roteiro e escolhe a peça de motion do acervo (gatilhos da fala, embeddings e LLM local); a 2ª falha vai ao Claude em lote."),
    ("estudio_compilar", "Compilar", _S, "py", "Python junta o mapa de cenas, o kit (estudio.js/css), as peças e a mídia curada num projeto HyperFrames; peças do motor EffectCraft viram WebM com alfa."),
    ("estudio_render", "Render", _S, "gpu", "O HyperFrames abre a composição no Chromium e grava cada quadro; o ffmpeg codifica na GPU."),
    ("estudio_audio", "Áudio", _S, "py", "ffmpeg normaliza o som em −14 LUFS (loudnorm) e junta ao vídeo."),
    ("estudio_verificar", "Verificar", _S, "local", "Folha de quadros do vídeo final avaliada pelo modelo de visão local."),
    ("fabrica", "Fábrica de peças", _S, "claude", "O Claude escreve peça + ficha (HTML ou EffectCraft); o portão confere o código, renderiza a prova e o modelo de visão local olha os quadros. Aprovada, a peça vai à sua revisão."),
    ("openalex", "API OpenAlex", _X, "py", "Base aberta de ~250 milhões de trabalhos científicos. A esteira usa a API com chave própria (cota diária)."),
    ("qwen3", "qwen3-14b", _X, "local", "LLM de texto, 14 bilhões de parâmetros, quantizado (~9 GB na VRAM) no llama.cpp. Cada chamada tem 2 fases: PREFILL (lê o prompt inteiro de uma vez, em paralelo: milhares de tokens/s) e GERAÇÃO (um token por vez, cada um exige ler todos os pesos da VRAM: dezenas de tokens/s, o gargalo). contexto de 16384 tokens; o roteador descarrega o modelo após 10 min parado; respostas iguais vêm do cache da esteira sem gastar GPU."),
    ("qwen_vl", "qwen2.5vl-7b", _X, "local", "Modelo de visão + texto (7 B). A imagem é cortada em patches que viram tokens visuais e entram no prefill junto com o texto; depois gera a resposta token a token."),
    ("whisper", "Whisper", _X, "gpu", "faster-whisper large-v3 (CTranslate2, CUDA). Antes dele a esteira descarrega o llama.cpp da VRAM (`liberar_gpu`)."),
    ("sdxl", "RealVisXL", _X, "gpu", "Modelo de difusão (SDXL) em .venv-img: parte de ruído e remove ruído em ~30 passos guiados pelo texto. Usa quase toda a VRAM."),
    ("claude", "Claude", _X, "claude", "`claude -p` pela assinatura, sem ferramentas, com resposta em JSON por esquema. Só é chamado quando o código e o LLM local não resolvem; cada chamada respeita os tetos de [claude]."),
    ("bancos", "Bancos de mídia", _X, "py", "APIs do Openverse, Pexels e Pixabay (se houver chave)."),
    ("chromium", "Chromium", _X, "py", "Playwright abre o HTML do gráfico e congela cada quadro com seek(t); o ffmpeg junta os PNGs em ProRes 4444."),
    ("effectcraft", "EffectCraft", _X, "py", "Motion graphics no estilo After Effects controlado por `effectcraft-cli`: um script monta as comps Conteúdo e Peça (texto, formas, keyframes, expressões) e a engine renderiza ProRes 4444 com alfa. O painel abre o .ecproj de cada peça."),
    ("photocraft", "PhotoCraft", _X, "py", "Editor de imagem em camadas controlado por `photocraft-cli`: monta a thumb (.pcraft) com objeto inteligente, ajustes, estilos de camada e texto editável, e exporta o PNG."),
    ("edicao_manual", "Edição manual", _E, "py", "Você abre pelo painel o projeto do vídeo (.fcproj no FilmCraft), de cada gráfico (.ecproj no EffectCraft) ou de cada thumb (.pcraft no PhotoCraft), ajusta e salva. O painel percebe o arquivo salvo: reexporta o vídeo, renderiza a peça editada ou refaz o PNG, e o replanejamento não desfaz a edição."),
    ("filmcraft", "FilmCraft", _X, "py", "Editor de vídeo controlado por `filmcraft-cli mcp`: importa mídia, posiciona clipes e exporta."),
]
SEQ = [("r_plano", "r_openalex"), ("r_openalex", "r_pdf"), ("r_pdf", "r_trechos"), ("r_trechos", "r_fatos"),
       ("r_fatos", "r_citar"), ("r_citar", "r_partes"), ("r_partes", "r_validar"), ("r_validar", "r_montar"),
       ("r_montar", "r_checar"),
       ("transcribe", "clean"), ("clean", "scenes"), ("scenes", "curate"), ("curate", "fetch"),
       ("fetch", "evaluate"), ("evaluate", "graphics"), ("graphics", "assemble"), ("assemble", "thumb"),
       ("thumb", "edicao_manual"), ("estudio_dirigir", "estudio_compilar"), ("estudio_compilar", "estudio_render"),
       ("estudio_render", "estudio_audio"), ("estudio_audio", "estudio_verificar")]
USA = [("r_openalex", "openalex"), ("r_pdf", "openalex"), ("r_fatos", "qwen3"), ("r_partes", "qwen3"),
       ("transcribe", "whisper"), ("clean", "qwen3"), ("clean", "claude"), ("curate", "qwen3"),
       ("fetch", "bancos"), ("evaluate", "qwen_vl"), ("evaluate", "claude"), ("graphics", "qwen3"),
       ("graphics", "effectcraft"), ("graphics", "chromium"), ("assemble", "filmcraft"), ("thumb", "photocraft"),
       ("edicao_manual", "filmcraft"), ("edicao_manual", "effectcraft"), ("edicao_manual", "photocraft"), ("thumb", "qwen3"), ("thumb", "sdxl"),
       ("thumb", "qwen_vl"), ("thumb", "claude"), ("editor", "claude"), ("editor", "qwen3"), ("editor", "chromium"),
       ("estudio_dirigir", "qwen3"), ("estudio_dirigir", "claude"), ("estudio_compilar", "effectcraft"),
       ("estudio_render", "chromium"), ("estudio_verificar", "qwen_vl"), ("fabrica", "claude"), ("fabrica", "effectcraft"),
       ("fabrica", "chromium"), ("fabrica", "qwen_vl")]
IDS = {n[0] for n in NOS}


def no_id(fluxo, no):
    if not no:
        return None
    if fluxo and fluxo.startswith("roteiro:"):
        return f"r_{no}" if f"r_{no}" in IDS else None
    if fluxo and fluxo.startswith("editor:"):
        return "editor"
    if fluxo and fluxo.startswith("fabrica:"):
        return "fabrica"
    if no.startswith("estudio-"):  # etapas do Estúdio: estudio-<etapa>[-<formato>]
        return f"estudio_{no.split('-')[1]}" if f"estudio_{no.split('-')[1]}" in IDS else None
    return no if no in IDS else None


def recurso_do_modelo(motor, modelo):
    if motor == "claude":
        return "claude"
    return "qwen_vl" if modelo and "vl" in modelo else "qwen3"


def _externas(pid):
    """Barras gravadas por subprocessos (ex.: download do `artigo baixar`) ligadas ao processo `pid`."""
    saida = {}
    for arq in trace.DIR.glob(f"{pid}.ext-*.json"):
        try:
            t = json.loads(arq.read_text())
        except (OSError, ValueError):
            continue
        if time.time() - t.get("t", 0) < 15:
            saida[arq.stem.split(".ext-", 1)[1]] = _tarefa_externa(t)
    return saida


def _tarefa_externa(t):
    """The vault script (`artigo`) still writes its bar with the old keys; the panel reads the core ones."""
    nova = dict(t)
    for antiga, chave in (("rotulo", "label"), ("feito", "done"), ("unidade", "unit"), ("inicio", "start")):
        if antiga in nova:
            nova[chave] = nova.pop(antiga)
    return nova


def vivos():
    saida = []
    for arq in trace.DIR.glob("*.json") if trace.DIR.exists() else []:
        if ".ext-" in arq.name:
            if not psutil.pid_exists(int(arq.name.split(".", 1)[0])):
                arq.unlink(missing_ok=True)
            continue
        try:
            v = json.loads(arq.read_text())
        except (OSError, ValueError):
            continue
        v["tasks"] = {**v.get("tasks", {}), **_externas(v.get("pid"))}
        if not psutil.pid_exists(v.get("pid", -1)):
            arq.unlink(missing_ok=True)
            continue
        v["id_no"] = no_id(v.get("flow"), v.get("node"))
        if v["id_no"]:
            saida.append(v)
    return saida


def historico(limite_bytes=600_000):
    if not trace.LOG.exists():
        return []
    with open(trace.LOG, "rb") as f:
        f.seek(max(0, trace.LOG.stat().st_size - limite_bytes))
        linhas = f.read().decode("utf-8", "replace").splitlines()[1:]
    regs = []
    for l in linhas:
        try:
            r = json.loads(l)
        except ValueError:
            continue
        r["id_no"] = no_id(r.get("flow"), r.get("node"))
        regs.append(r)
    return regs


def estado(monitor_atual):
    """Estado de cada nó: ativo/recente/parado, contadores e o que o processo faz agora."""
    agora = time.time()
    vv, hist = vivos(), historico()
    nos = {i: {"ativo": False, "recente": None, "chamadas": 0, "cache": 0, "tok_s": [], "agora": None} for i in IDS}
    for r in hist:
        alvos = [r["id_no"]] if r["id_no"] else []
        if r.get("kind") in ("call", "cache"):
            alvos.append(recurso_do_modelo(r.get("engine", "local"), r.get("model")))
        for a in alvos:
            n = nos.get(a)
            if not n:
                continue
            n["recente"] = max(n["recente"] or 0, r["t"])
            if r["kind"] == "call":
                n["chamadas"] += 1
                if r.get("tok_s"):
                    n["tok_s"].append(r["tok_s"])
            elif r["kind"] == "cache":
                n["cache"] += 1
    for v in vv:
        n = nos[v["id_no"]]
        n["ativo"] = True
        c = v.get("call")
        n["agora"] = {"detalhe": v.get("detail"), "progresso": v.get("progress"), "desde": v.get("since"),
                      "tarefas": list(v.get("tasks", {}).values()),
                      "chamada": c and {"nome": c["name"], "modelo": c["model"], "tokens": c["tokens"],
                                        "max": (c.get("params") or {}).get("num_predict"),
                                        "seg": round(agora - c["start"], 1)}}
        if c:
            nos[recurso_do_modelo(c["engine"], c["model"])]["ativo"] = True
    # processos sem rastro (iniciados antes dele) e programas auxiliares
    rastreados = {v["pid"] for v in vv}
    legado = []
    for p in monitor_atual.get("esteira", []):
        sub = (p.get("comando") or "").split()
        if p["pid"] in rastreados or not sub or sub[0] == "painel":
            continue
        legado.append({"pid": p["pid"], "comando": p["comando"], "linhas": p.get("linhas", [])})
        if sub[0] in IDS:
            nos[sub[0]]["ativo"] = True
        for cmd, alvo in (("artigo baixar", "r_pdf"), ("artigo citar", "r_citar"), ("artigo checar", "r_checar")):
            if cmd in p["comando"]:
                nos[alvo]["ativo"] = True
    gpu = monitor_atual.get("gpu") or {}
    for o in monitor_atual.get("ollama") or []:
        if (gpu.get("uso") or 0) > 40:
            nos[recurso_do_modelo("local", o["modelo"])]["ativo"] = True
    for g in monitor_atual.get("grupos", []):
        alvo = {"Chromium (gráficos)": "chromium", "RealVisXL (thumbs)": "sdxl", "FilmCraft": "filmcraft",
                "EffectCraft": "effectcraft", "PhotoCraft": "photocraft"}.get(g["rotulo"])
        if alvo and g["cpu"] > 5:
            nos[alvo]["ativo"] = True
    for n in nos.values():
        ts = n.pop("tok_s")
        n["tok_s"] = round(sum(ts[-20:]) / len(ts[-20:]), 1) if ts else None
        n["recente"] = round(agora - n["recente"]) if n["recente"] else None
    return {"nos": nos, "legado": legado}


def detalhe(id_no, monitor_atual, hist_monitor=()):
    info = next(n for n in NOS if n[0] == id_no)
    recurso = info[2] == _X
    vv = [v for v in vivos() if v["id_no"] == id_no or
          (recurso and v.get("call") and recurso_do_modelo(v["call"]["engine"], v["call"]["model"]) == id_no)]
    hist = historico()
    if recurso:
        chamadas = [r for r in hist if r.get("kind") == "call" and recurso_do_modelo(r.get("engine"), r.get("model")) == id_no]
        caches = sum(1 for r in hist if r.get("kind") == "cache" and recurso_do_modelo(r.get("engine", "local"), r.get("model")) == id_no)
    else:
        chamadas = [r for r in hist if r.get("kind") == "call" and r["id_no"] == id_no]
        caches = sum(1 for r in hist if r.get("kind") == "cache" and r["id_no"] == id_no)
    passos = [r for r in hist if r.get("kind") == "node" and r["id_no"] == id_no][-8:]
    return {"id": id_no, "rotulo": info[1], "faixa": info[2], "motor": info[3], "como": info[4],
            "usa": [b for a, b in USA if a == id_no], "usado_por": [a for a, b in USA if b == id_no],
            "vivos": vv, "chamadas": chamadas[-8:][::-1], "n_chamadas": len(chamadas), "n_cache": caches,
            "passos": [{"t": r["t"], "detalhe": r.get("detail"), "fluxo": r.get("flow")} for r in passos][::-1],
            "gpu": monitor_atual.get("gpu") if id_no in ("qwen3", "qwen_vl", "whisper", "sdxl") else None,
            "extras": grafo_dados.extras(id_no, chamadas, hist_monitor),
            "ollama": monitor_atual.get("ollama") if id_no in ("qwen3", "qwen_vl") else None}
