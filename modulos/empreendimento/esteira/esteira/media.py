"""Etapa 3: busca e baixa uma imagem ou um vídeo para cada cena, já no formato da timeline.

Provedores: Pexels e Pixabay (fotos e vídeos, licença livre para YouTube; precisam de chave no .env)
e Openverse (só fotos Creative Commons de uso comercial, sem chave; os créditos vão para creditos.txt).
"""

import re
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import requests

from esteira import library
from esteira.core import events, trace

UA = {"User-Agent": "esteira-dark/1.0 (uso pessoal)"}


# ---------------------------------------------------------------- provedores
# Orientação pedida aos bancos; `buscar` troca para retrato no formato 9:16.
ORIENT = {"pexels": "landscape", "pixabay": "horizontal"}

# Cada função devolve candidatos: {"id", "url", "tipo", "largura", "duracao", "credito"}

def pexels(termo, tipo, env, idioma):
    chave = env.get("PEXELS_API_KEY")
    if not chave:
        return []
    h = {"Authorization": chave, **UA}
    if tipo == "video":
        r = requests.get("https://api.pexels.com/videos/search", headers=h, timeout=30, params={
            "query": termo, "orientation": ORIENT["pexels"], "size": "medium", "per_page": 15, "locale": idioma})
        r.raise_for_status()
        saida = []
        for v in r.json().get("videos", []):
            arquivos = [f for f in v["video_files"] if f.get("file_type") == "video/mp4" and (f.get("width") or 0) >= 1280]
            if not arquivos:
                continue
            f = min(arquivos, key=lambda f: abs(f["width"] - 1920))
            saida.append({"id": f"pexels-v{v['id']}", "url": f["link"], "tipo": "video", "largura": f["width"],
                          "duracao": v["duration"], "credito": f"Vídeo de {v['user']['name']} (Pexels) {v['url']}",
                          "pagina": v["url"], "licenca": "Pexels", "tags": " ".join(v.get("tags") or []),
                          "titulo": re.sub(r"[-/]", " ", v["url"].rstrip("/").split("/")[-1])})
        return saida
    r = requests.get("https://api.pexels.com/v1/search", headers=h, timeout=30, params={
        "query": termo, "orientation": ORIENT["pexels"], "per_page": 15, "locale": idioma})
    r.raise_for_status()
    return [{"id": f"pexels-f{p['id']}", "url": p["src"]["large2x"], "tipo": "imagem", "largura": p["width"],
             "duracao": None, "credito": f"Foto de {p['photographer']} (Pexels) {p['url']}",
             "pagina": p["url"], "licenca": "Pexels", "titulo": p.get("alt") or ""}
            for p in r.json().get("photos", [])]


def _chave_pixabay(env, tipo):
    """Chaves no .env: PIXABAY_API_KEY_VIDEO / PIXABAY_API_KEY_IMAGE (ou uma só, PIXABAY_API_KEY)."""
    return env.get("PIXABAY_API_KEY_VIDEO" if tipo == "video" else "PIXABAY_API_KEY_IMAGE") or env.get("PIXABAY_API_KEY")


def _pixabay_get(url, params):
    """GET com cache em disco de 24 h (exigido pela API; limite de 100 buscas/min por chave). O erro do Pixabay
    vem em texto ("[ERROR 400] ..."): vai na mensagem em vez do genérico "Bad Request"."""
    import hashlib
    import json

    from esteira.project import CACHE
    nome = hashlib.sha1(json.dumps([url, sorted(params.items())]).encode()).hexdigest()[:20]
    arq = CACHE / "pixabay" / f"{nome}.json"
    if arq.exists() and time.time() - arq.stat().st_mtime < 86400:
        return json.loads(arq.read_text())
    r = requests.get(url, headers=UA, timeout=30, params=params)
    if r.status_code == 429:
        time.sleep(float(r.headers.get("X-RateLimit-Reset", 30)))
        r = requests.get(url, headers=UA, timeout=30, params=params)
    if r.status_code != 200:
        raise requests.HTTPError(f"{r.status_code} {r.text.strip()[:120]}")
    arq.parent.mkdir(parents=True, exist_ok=True)
    arq.write_text(r.text)
    return r.json()


def pixabay(termo, tipo, env, idioma):
    chave = _chave_pixabay(env, tipo)
    if not chave:
        return []
    comum = {"key": chave, "q": termo[:100], "lang": idioma.split("-")[0], "per_page": 20, "safesearch": "true"}
    if tipo == "video":
        saida = []
        for v in _pixabay_get("https://pixabay.com/api/videos/", dict(comum, video_type="film")).get("hits", []):
            # medium (1920x1080) basta para 1080p; large é 4K (download pesado) e pode vir vazio
            versoes = [x for x in v["videos"].values() if x.get("url") and x.get("width", 0) >= 1280]
            f = min(versoes, key=lambda x: abs(x["width"] - 1920), default=None)
            if not f or (ORIENT["pixabay"] == "vertical") != (f["height"] > f["width"]):
                continue  # a API de vídeos não filtra orientação
            saida.append({"id": f"pixabay-v{v['id']}", "url": f["url"], "tipo": "video", "largura": f["width"],
                          "duracao": v["duration"], "credito": f"Vídeo de {v['user']} (Pixabay) {v['pageURL']}",
                          "pagina": v["pageURL"], "licenca": "Pixabay", "tags": v.get("tags", ""),
                          "titulo": re.sub(r"[-/]", " ", v["pageURL"].rstrip("/").split("/")[-1])})
        return saida
    dados = _pixabay_get("https://pixabay.com/api/", dict(comum, image_type="photo", orientation=ORIENT["pixabay"],
                                                          min_width=1600))
    return [{"id": f"pixabay-f{p['id']}", "url": p["largeImageURL"], "tipo": "imagem",
             "largura": p["imageWidth"], "duracao": None,
             "credito": f"Imagem de {p['user']} (Pixabay) {p['pageURL']}", "pagina": p["pageURL"],
             "licenca": "Pixabay", "tags": p.get("tags", ""),
             "titulo": re.sub(r"[-/]", " ", p["pageURL"].rstrip("/").split("/")[-1])} for p in dados.get("hits", [])]


def openverse(termo, tipo, env, idioma):
    if tipo == "video":
        return []
    time.sleep(3)  # sem chave o limite é 20 buscas/min
    r = requests.get("https://api.openverse.org/v1/images/", headers=UA, timeout=30, params={
        "q": termo, "license_type": "commercial,modification", "aspect_ratio": "wide",
        "page_size": 20, "mature": "false"})
    if r.status_code == 429:
        print("     openverse: limite de buscas atingido (200/dia sem chave)")
        return []
    r.raise_for_status()
    saida = []
    for p in r.json().get("results", []):
        if (p.get("width") or 0) < 1280:
            continue
        autor = p.get("creator") or "autor desconhecido"
        licenca = f"{(p.get('license') or '').upper()} {p.get('license_version') or ''}".strip()
        url = p["url"]
        m = re.match(r"(https://upload\.wikimedia\.org/wikipedia/commons)/(\w/\w\w)/([^/]+)$", url)
        if m and p["width"] > 1920:
            # O Wikimedia bloqueia downloads de originais em série; a miniatura de 1920px é liberada.
            url = f"{m[1]}/thumb/{m[2]}/{m[3]}/1920px-{m[3]}"
        saida.append({"id": f"openverse-{p['id']}", "url": url, "tipo": "imagem", "largura": p["width"],
                      "duracao": None, "credito": f"\"{p.get('title') or ''}\" de {autor}, {licenca} "
                                                  f"({p.get('foreign_landing_url')})",
                      "pagina": p.get("foreign_landing_url") or "", "licenca": licenca, "titulo": p.get("title") or "",
                      "tags": " ".join(t.get("name", "") for t in p.get("tags") or [])})
    return saida


PROVEDORES = {"pexels": pexels, "pixabay": pixabay, "openverse": openverse}


# ---------------------------------------------------------------- normalização

def _ffmpeg(*args):
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", *map(str, args)], check=True)


def duracao_midia(caminho):
    saida = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                            str(caminho)], capture_output=True, text=True).stdout.strip()
    return float(saida) if saida else 0.0


def normalizar_imagem(origem, destino, w, h):
    # Preenche o quadro (corta o excesso), sem barras pretas.
    _ffmpeg("-i", origem, "-vf", f"scale={w}:{h}:force_original_aspect_ratio=increase,crop={w}:{h}",
            "-frames:v", "1", "-q:v", 2, destino)


def normalizar_video(origem, destino, w, h, fps, segundos):
    """Recorta/estica o vídeo para cobrir a cena (+1 s de folga para as transições), sem áudio."""
    alvo = segundos + 1.0
    dur = duracao_midia(origem)
    filtros = [f"scale={w}:{h}:force_original_aspect_ratio=increase", f"crop={w}:{h}", f"fps={fps}"]
    entrada = ["-i", origem]
    if 0 < dur < alvo:
        fator = alvo / dur
        if fator <= 2.0:
            filtros.insert(0, f"setpts={fator:.4f}*PTS")  # câmera lenta, até 2×
        else:
            entrada = ["-stream_loop", "-1", "-i", origem]
    elif dur > alvo + 2:
        entrada = ["-ss", f"{min(1.0, dur - alvo):.2f}", "-i", origem]  # pula o começo, muitas vezes tremido
    _ffmpeg(*entrada, "-t", f"{alvo:.3f}", "-vf", ",".join(filtros), "-an", "-c:v", "libx264", "-preset",
            "veryfast", "-crf", 18, "-pix_fmt", "yuv420p", destino)


# ---------------------------------------------------------------- etapa

def _baixar(url, destino, tentativas=4):
    for n in range(tentativas):
        with requests.get(url, headers=UA, stream=True, timeout=120) as r:
            if r.status_code == 429 and n < tentativas - 1:
                time.sleep(5 * (n + 1))
                continue
            r.raise_for_status()
            total, feito = int(r.headers.get("Content-Length") or 0) or None, 0
            with open(destino, "wb") as f:
                for bloco in r.iter_content(1 << 18):
                    f.write(bloco)
                    feito += len(bloco)
                    trace.task("download", f"baixando {Path(destino).name}", feito, total, "B")
            trace.end_task("download")
            return


PARADA = set("a an the of with at on in and or for to from by into over under is are de da do das dos e ou em no "
             "na nos nas com para por um uma uns umas os as o ao aos".split())


def _raizes(texto):
    import unicodedata
    s = unicodedata.normalize("NFKD", (texto or "").lower())
    s = "".join(c for c in s if not unicodedata.combining(c))
    return {w[:5] for w in re.findall(r"[a-z]+", s) if len(w) > 2 and w not in PARADA}


def chave_da_cena(cena):
    """Palavras que a mídia tem de mostrar: `chave_en` da curadoria (o objeto/sujeito da fala) ou o termo."""
    return _raizes(cena.get("chave_en") or cena.get("busca_en") or cena.get("busca") or "")


RELEVANTE = 0.66  # "credit card" pede as duas palavras: "birthday card" não serve


def relevancia(cand, chave):
    """Fração das palavras-chave da cena que aparecem nas tags/título/descrição do candidato (a descrição do
    acervo vem do modelo de visão, a mais confiável)."""
    if not chave:
        return 0.0
    alvo = _raizes(" ".join(str(cand.get(k) or "") for k in ("tags", "titulo", "descricao")))
    # tags vêm da mais importante para a menos: a chave nas 3 primeiras vale mais ("credit card" no fim de
    # uma foto de barbearia, não)
    topo = _raizes(", ".join(str(cand.get("tags") or "").split(",")[:3]) + " " + str(cand.get("descricao") or ""))
    return round(len(chave & alvo) / len(chave) + 0.3 * (len(chave & topo) / len(chave)), 2)


def termos_da_cena(cena):
    """[(termo, idioma)]: os termos em inglês com lang inglês (os bancos indexam em inglês) e o termo em
    português com o idioma do canal."""
    en = [t for t in [cena.get("busca_en"), *cena.get("alternativas", [])] if t]
    return [(t, "en-US") for t in dict.fromkeys(en)] + ([(cena["busca"], None)] if cena.get("busca") else [])


def _candidatos(cena, tipo, provedores, env, idioma, minimo=6):
    """Junta candidatos de todos os provedores, termo a termo, até ter `minimo` relevantes (a chave
    nas tags); a ordem final é por relevância (ver `ordenar`), não pela ordem em que os bancos responderam."""
    chave = chave_da_cena(cena)
    termos = termos_da_cena(cena)
    # sem resultado, o termo principal perde palavras do fim (escrito da mais importante para a menos)
    if termos:
        t0 = termos[0][0].split()
        termos += [(" ".join(t0[:n]), termos[0][1]) for n in range(len(t0) - 1, 1, -1)]
    saida, vistos = [], set()
    for termo, lang in termos:
        for nome in provedores:
            try:
                achados = PROVEDORES[nome](termo, tipo, env, lang or idioma)
            except requests.RequestException as e:
                print(f"     {nome}: erro na busca ({e})")
                continue
            for a in achados:
                if a["id"] not in vistos:
                    vistos.add(a["id"])
                    saida.append(a)
        if sum(relevancia(a, chave) >= RELEVANTE for a in saida) >= minimo:
            break
    return saida


def ordenar(cands, chave, exigir=False):
    """Mais relevante primeiro (acervo e bancos juntos; no empate, o acervo, que não gasta download). Se há
    candidatos com a chave inteira (2 de 3 palavras numa chave longa), só eles ficam (sem nenhum, fica tudo: o modelo de visão do
    avaliar confere depois). `exigir`: só os relevantes, mesmo que não sobre nenhum (vídeo sem nada relevante
    → a cena passa para foto, que acha o objeto exato com mais facilidade)."""
    for c in cands:
        c["relevancia"] = relevancia(c, chave)
    if exigir or any(c["relevancia"] >= RELEVANTE for c in cands):
        cands = [c for c in cands if c["relevancia"] >= RELEVANTE]
    return sorted(cands, key=lambda c: (-c["relevancia"], not c.get("arquivo")))


def _preparar(cand, cena, pasta, w, h, fps, dur, termo=""):
    """Baixa um candidato para o acervo (ou usa o arquivo que já está lá) e converte para a cena;
    devolve o arquivo final ou None se falhar."""
    video = cand["tipo"] == "video"
    final = pasta / f"cena_{cena['id']:03d}{'.mp4' if video else '.jpg'}"
    bruto = pasta / f"bruto_{cena['id']:03d}{'.mp4' if video else '.img'}"
    try:
        if cand.get("arquivo"):  # veio do acervo: nada de rede
            origem = library.pasta() / cand["arquivo"]
            library.registrar(cand, origem, termo)  # só acrescenta o termo
        else:
            _baixar(cand["url"], bruto)
            origem = library.registrar(cand, bruto, termo)
        if video:
            normalizar_video(origem, final, w, h, fps, dur)
        else:
            normalizar_imagem(origem, final, w, h)
        return final
    except (requests.RequestException, subprocess.CalledProcessError, OSError) as e:
        print(f"     {cand['id']}: falhou ({str(e)[:90]}); tentando o próximo")
        return None
    finally:
        bruto.unlink(missing_ok=True)


def buscar(projeto, refazer=False, cenas=None):
    """refazer: troca a mídia das cenas (todas, ou só as de `cenas`) por outro resultado."""
    cfg = projeto.cfg
    w, h, fps = cfg["video"]["largura"], cfg["video"]["altura"], cfg["video"]["fps"]
    retrato = h > w
    ORIENT.update(pexels="portrait" if retrato else "landscape", pixabay="vertical" if retrato else "horizontal")
    provedores = cfg["midia"]["provedores"]
    idioma = cfg["midia"]["idioma_busca"]
    env = projeto.env
    if not env.get("PEXELS_API_KEY") and not _chave_pixabay(env, "video"):
        print("  aviso: sem PEXELS_API_KEY/PIXABAY_API_KEY_* no .env; só fotos do Openverse (sem vídeos)")

    ac = cfg.get("acervo", {})
    plano = projeto.carregar_json("plano.json")
    from esteira import production
    production.marcar_apresentador(projeto, plano)  # no modo apresentador, cenas de câmera não buscam mídia
    pasta = projeto.caminho("midia")
    alvo = set(cenas) if cenas else {c["id"] for c in plano["cenas"]}
    for cena in plano["cenas"]:
        if refazer and cena["id"] in alvo and cena.get("midia_id"):
            # A mídia trocada não volta a ser escolhida para esta cena.
            cena.setdefault("rejeitados", []).append(cena.pop("midia_id"))
            cena["midia"] = None
    usados = {c["midia_id"] for c in plano["cenas"] if c.get("midia_id")}

    trava = threading.Lock()
    pendentes = [c for c in plano["cenas"] if c["id"] in alvo and not c.get("camera")
                 and not (c.get("midia") and (projeto.pasta / c["midia"]).exists())]
    feitas = [0]

    def uma(cena):
        """Busca, baixa e converte a mídia de uma cena. Roda em paralelo: `usados` é reservado sob trava."""
        dur = cena["fim"] - cena["inicio"]
        ordem = [cena["tipo"], "imagem"] if cena["tipo"] == "video" else ["imagem"]
        escolhido, falhas, final = None, 0, None
        termos = [t for t, _ in termos_da_cena(cena)]
        chave = chave_da_cena(cena)
        for tipo in ordem:
            # Acervo primeiro (sem rede, sem API); depois os bancos de imagens.
            do_acervo = library.procurar(termos, tipo, "retrato" if retrato else "paisagem", dur,
                                        excluir=set(cena.get("rejeitados", [])) | usados, canal=projeto.canal,
                                        max_usos_canal=ac.get("max_usos_canal", 2)) if ac.get("reaproveitar", True) else []
            cands = ordenar([*do_acervo, *_candidatos(cena, tipo, provedores, env, idioma)], chave,
                            exigir=tipo != ordem[-1])
            events.debug(f"cena {cena['id']}: {len(cands)} candidatos ({tipo})", chave=sorted(chave),
                          melhores=[(c["id"], c["relevancia"]) for c in cands[:3]])
            for cand in cands:
                if cand["id"] in cena.get("rejeitados", []):
                    continue
                if tipo == "video" and cand["duracao"] and cand["duracao"] * 2 < dur:
                    continue  # curto demais até em câmera lenta
                with trava:
                    if cand["id"] in usados:
                        continue
                    usados.add(cand["id"])
                final = _preparar(cand, cena, pasta, w, h, fps, dur, termos[0] if termos else "")
                if final:
                    escolhido = cand
                    break
                with trava:
                    usados.discard(cand["id"])
                falhas += 1
                if falhas >= 5:
                    break
            if escolhido or falhas >= 5:
                break
        with trava:
            feitas[0] += 1
            events.progress(feitas[0], len(pendentes), f"cena {cena['id']} [{cena.get('busca_en') or cena['busca']}]")
            if not escolhido:
                events.warning(f"cena {cena['id']}: nada encontrado para [{cena.get('busca_en') or cena['busca']}]")
                return
            cena.update(midia=str(final.relative_to(projeto.pasta)), midia_id=escolhido["id"],
                        relevancia=escolhido.get("relevancia"),
                        midia_tipo=escolhido["tipo"], credito=escolhido["credito"],
                        midia_origem="acervo" if escolhido.get("arquivo") else "banco")
            library.marcar_uso(escolhido["id"], projeto.canal, projeto.ep, cena["id"])
            events.debug(f"cena {cena['id']} ← {escolhido['id']}", midia=escolhido["tipo"], busca=cena.get("busca_en"))
            projeto.salvar_json("plano.json", plano)

    with ThreadPoolExecutor(cfg["midia"].get("paralelo", 6)) as ex:
        list(ex.map(uma, pendentes))

    creditos = sorted({c["credito"] for c in plano["cenas"] if c.get("credito")})
    projeto.caminho("creditos.txt").write_text("\n".join(creditos) + "\n")
    faltando = [c["id"] for c in plano["cenas"] if not c.get("midia") and not c.get("camera")]
    reuso = sum(1 for c in pendentes if c.get("midia_origem") == "acervo")
    camera = sum(1 for c in plano["cenas"] if c.get("camera"))
    print(f"  mídia pronta para {len(plano['cenas']) - len(faltando)}/{len(plano['cenas'])} cenas"
          + (f" ({camera} na câmera)" if camera else "")
          + f"; {reuso}/{len(pendentes)} reaproveitadas do acervo" + (f"; faltam {faltando}" if faltando else ""))


def folha(projeto, quadros, destino, colunas=4, w=384, h=216):
    # 4 × 384 = 1536 px: abaixo dos 1568 px em que a imagem é reduzida antes de o Claude vê-la.
    """Grade de quadros [(arquivo, inicio_s ou None, legenda)] numa imagem só."""
    entradas, filtros = [], []
    for i, (arq, ss, legenda) in enumerate(quadros):
        entradas += (["-ss", str(ss)] if ss is not None else []) + ["-i", arq]
        legenda = legenda.replace(":", "\\:").replace("'", "").replace(",", "\\,")
        filtros.append(f"[{i}:v]scale={w}:{h},setsar=1,drawbox=y={h - 34}:w={w}:h=34:color=black@0.7:t=fill,"
                       f"drawtext=text='{legenda}':x=8:y={h - 27}:fontsize=18:fontcolor=white[q{i}]")
    linhas = -(-len(quadros) // colunas)
    total = linhas * colunas if linhas > 1 else len(quadros)
    for i in range(len(quadros), total):  # completa a grade com quadros pretos
        entradas += ["-f", "lavfi", "-i", f"color=black:s={w}x{h}:d=1"]
        filtros.append(f"[{i}:v]setsar=1[q{i}]")
    layout = "|".join(f"{(i % colunas) * w}_{(i // colunas) * h}" for i in range(total))
    filtros.append("".join(f"[q{i}]" for i in range(total))
                   + (f"xstack=inputs={total}:layout={layout}" if total > 1 else "null"))
    _ffmpeg(*entradas, "-filter_complex", ";".join(filtros), "-frames:v", "1", "-q:v", 4, destino)


def revisar(projeto, cenas=None, por_folha=16):
    """Folhas de contato revisao_NN.jpg (16 cenas cada, legíveis e baratas de ler) com número e busca."""
    plano = projeto.carregar_json("plano.json")
    cenas = [c for c in plano["cenas"] if c.get("midia") and (not cenas or c["id"] in cenas)]
    if not cenas:
        raise SystemExit("nenhuma cena com mídia; rode buscar")
    for antiga in projeto.pasta.glob("revisao*.jpg"):
        antiga.unlink()
    for n in range(0, len(cenas), por_folha):
        grupo = cenas[n:n + por_folha]
        destino = projeto.caminho(f"revisao_{n // por_folha + 1:02d}.jpg")
        folha(projeto, [(projeto.pasta / c["midia"], 0.5 if c.get("midia_tipo") == "video" else None,
                         f"{c['id']} {c.get('busca_en') or c['busca']}") for c in grupo], destino)
        print(f"  {destino.name}: cenas {grupo[0]['id']}–{grupo[-1]['id']}")


def quadros(projeto, n=8):
    """Folha quadros.jpg com n quadros do final.mp4 espalhados pela duração, para conferir a montagem."""
    final = projeto.caminho("final.mp4")
    if not final.exists():
        raise SystemExit("final.mp4 não existe; rode montar")
    dur = duracao_midia(final)
    tempos = [round(dur * (i + 0.5) / n, 1) for i in range(n)]
    destino = projeto.caminho("quadros.jpg")
    folha(projeto, [(final, t, f"{t:.1f}s") for t in tempos], destino)
    print(f"  {destino.name}: {', '.join(f'{t:.1f}s' for t in tempos)}")
