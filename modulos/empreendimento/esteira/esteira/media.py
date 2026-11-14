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

def pexels(term, tipo, env, language):
    key = env.get("PEXELS_API_KEY")
    if not key:
        return []
    h = {"Authorization": key, **UA}
    if tipo == "video":
        r = requests.get("https://api.pexels.com/videos/search", headers=h, timeout=30, params={
            "query": term, "orientation": ORIENT["pexels"], "size": "medium", "per_page": 15, "locale": language})
        r.raise_for_status()
        output = []
        for v in r.json().get("videos", []):
            files = [f for f in v["video_files"] if f.get("file_type") == "video/mp4" and (f.get("width") or 0) >= 1280]
            if not files:
                continue
            f = min(files, key=lambda f: abs(f["width"] - 1920))
            output.append({"id": f"pexels-v{v['id']}", "url": f["link"], "tipo": "video", "largura": f["width"],
                          "duracao": v["duration"], "credito": f"Vídeo de {v['user']['name']} (Pexels) {v['url']}",
                          "pagina": v["url"], "licenca": "Pexels", "tags": " ".join(v.get("tags") or []),
                          "titulo": re.sub(r"[-/]", " ", v["url"].rstrip("/").split("/")[-1])})
        return output
    r = requests.get("https://api.pexels.com/v1/search", headers=h, timeout=30, params={
        "query": term, "orientation": ORIENT["pexels"], "per_page": 15, "locale": language})
    r.raise_for_status()
    return [{"id": f"pexels-f{p['id']}", "url": p["src"]["large2x"], "tipo": "imagem", "largura": p["width"],
             "duracao": None, "credito": f"Foto de {p['photographer']} (Pexels) {p['url']}",
             "pagina": p["url"], "licenca": "Pexels", "titulo": p.get("alt") or ""}
            for p in r.json().get("photos", [])]


def _key_pixabay(env, tipo):
    """Chaves no .env: PIXABAY_API_KEY_VIDEO / PIXABAY_API_KEY_IMAGE (ou uma só, PIXABAY_API_KEY)."""
    return env.get("PIXABAY_API_KEY_VIDEO" if tipo == "video" else "PIXABAY_API_KEY_IMAGE") or env.get("PIXABAY_API_KEY")


def _pixabay_get(url, params):
    """GET com cache em disco de 24 h (exigido pela API; limite de 100 buscas/min por chave). O erro do Pixabay
    vem em texto ("[ERROR 400] ..."): vai na mensagem em vez do genérico "Bad Request"."""
    import hashlib
    import json

    from esteira.project import CACHE
    name = hashlib.sha1(json.dumps([url, sorted(params.items())]).encode()).hexdigest()[:20]
    file = CACHE / "pixabay" / f"{name}.json"
    if file.exists() and time.time() - file.stat().st_mtime < 86400:
        return json.loads(file.read_text())
    r = requests.get(url, headers=UA, timeout=30, params=params)
    if r.status_code == 429:
        time.sleep(float(r.headers.get("X-RateLimit-Reset", 30)))
        r = requests.get(url, headers=UA, timeout=30, params=params)
    if r.status_code != 200:
        raise requests.HTTPError(f"{r.status_code} {r.text.strip()[:120]}")
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(r.text)
    return r.json()


def pixabay(term, tipo, env, language):
    key = _key_pixabay(env, tipo)
    if not key:
        return []
    common = {"key": key, "q": term[:100], "lang": language.split("-")[0], "per_page": 20, "safesearch": "true"}
    if tipo == "video":
        output = []
        for v in _pixabay_get("https://pixabay.com/api/videos/", dict(common, video_type="film")).get("hits", []):
            # medium (1920x1080) basta para 1080p; large é 4K (download pesado) e pode vir vazio
            versions = [x for x in v["videos"].values() if x.get("url") and x.get("width", 0) >= 1280]
            f = min(versions, key=lambda x: abs(x["width"] - 1920), default=None)
            if not f or (ORIENT["pixabay"] == "vertical") != (f["height"] > f["width"]):
                continue  # a API de vídeos não filtra orientação
            output.append({"id": f"pixabay-v{v['id']}", "url": f["url"], "tipo": "video", "largura": f["width"],
                          "duracao": v["duration"], "credito": f"Vídeo de {v['user']} (Pixabay) {v['pageURL']}",
                          "pagina": v["pageURL"], "licenca": "Pixabay", "tags": v.get("tags", ""),
                          "titulo": re.sub(r"[-/]", " ", v["pageURL"].rstrip("/").split("/")[-1])})
        return output
    data = _pixabay_get("https://pixabay.com/api/", dict(common, image_type="photo", orientation=ORIENT["pixabay"],
                                                          min_width=1600))
    return [{"id": f"pixabay-f{p['id']}", "url": p["largeImageURL"], "tipo": "imagem",
             "largura": p["imageWidth"], "duracao": None,
             "credito": f"Imagem de {p['user']} (Pixabay) {p['pageURL']}", "pagina": p["pageURL"],
             "licenca": "Pixabay", "tags": p.get("tags", ""),
             "titulo": re.sub(r"[-/]", " ", p["pageURL"].rstrip("/").split("/")[-1])} for p in data.get("hits", [])]


def openverse(term, tipo, env, language):
    if tipo == "video":
        return []
    time.sleep(3)  # sem chave o limite é 20 buscas/min
    r = requests.get("https://api.openverse.org/v1/images/", headers=UA, timeout=30, params={
        "q": term, "license_type": "commercial,modification", "aspect_ratio": "wide",
        "page_size": 20, "mature": "false"})
    if r.status_code == 429:
        print("     openverse: limite de buscas atingido (200/dia sem chave)")
        return []
    r.raise_for_status()
    output = []
    for p in r.json().get("results", []):
        if (p.get("width") or 0) < 1280:
            continue
        author = p.get("creator") or "autor desconhecido"
        licence = f"{(p.get('license') or '').upper()} {p.get('license_version') or ''}".strip()
        url = p["url"]
        m = re.match(r"(https://upload\.wikimedia\.org/wikipedia/commons)/(\w/\w\w)/([^/]+)$", url)
        if m and p["width"] > 1920:
            # O Wikimedia bloqueia downloads de originais em série; a miniatura de 1920px é liberada.
            url = f"{m[1]}/thumb/{m[2]}/{m[3]}/1920px-{m[3]}"
        output.append({"id": f"openverse-{p['id']}", "url": url, "tipo": "imagem", "largura": p["width"],
                      "duracao": None, "credito": f"\"{p.get('title') or ''}\" de {author}, {licence} "
                                                  f"({p.get('foreign_landing_url')})",
                      "pagina": p.get("foreign_landing_url") or "", "licenca": licence, "titulo": p.get("title") or "",
                      "tags": " ".join(t.get("name", "") for t in p.get("tags") or [])})
    return output


PROVIDERS = {"pexels": pexels, "pixabay": pixabay, "openverse": openverse}


# ---------------------------------------------------------------- normalização

def _ffmpeg(*args):
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", *map(str, args)], check=True)


def duration_media(path):
    output = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                            str(path)], capture_output=True, text=True).stdout.strip()
    return float(output) if output else 0.0


def normalize_image(origem, destino, w, h):
    # Preenche o quadro (corta o excesso), sem barras pretas.
    _ffmpeg("-i", origem, "-vf", f"scale={w}:{h}:force_original_aspect_ratio=increase,crop={w}:{h}",
            "-frames:v", "1", "-q:v", 2, destino)


def normalize_video(origem, destino, w, h, fps, segundos):
    """Recorta/estica o vídeo para cobrir a cena (+1 s de folga para as transições), sem áudio."""
    target = segundos + 1.0
    duration = duration_media(origem)
    filters = [f"scale={w}:{h}:force_original_aspect_ratio=increase", f"crop={w}:{h}", f"fps={fps}"]
    entry = ["-i", origem]
    if 0 < duration < target:
        factor = target / duration
        if factor <= 2.0:
            filters.insert(0, f"setpts={factor:.4f}*PTS")  # câmera lenta, até 2×
        else:
            entry = ["-stream_loop", "-1", "-i", origem]
    elif duration > target + 2:
        entry = ["-ss", f"{min(1.0, duration - target):.2f}", "-i", origem]  # pula o começo, muitas vezes tremido
    _ffmpeg(*entry, "-t", f"{target:.3f}", "-vf", ",".join(filters), "-an", "-c:v", "libx264", "-preset",
            "veryfast", "-crf", 18, "-pix_fmt", "yuv420p", destino)


# ---------------------------------------------------------------- etapa

def _download(url, destino, attempts=4):
    for n in range(attempts):
        with requests.get(url, headers=UA, stream=True, timeout=120) as r:
            if r.status_code == 429 and n < attempts - 1:
                time.sleep(5 * (n + 1))
                continue
            r.raise_for_status()
            total, done = int(r.headers.get("Content-Length") or 0) or None, 0
            with open(destino, "wb") as f:
                for block in r.iter_content(1 << 18):
                    f.write(block)
                    done += len(block)
                    trace.task("download", f"baixando {Path(destino).name}", done, total, "B")
            trace.end_task("download")
            return


STOP = set("a an the of with at on in and or for to from by into over under is are de da do das dos e ou em no "
             "na nos nas com para por um uma uns umas os as o ao aos".split())


def _roots(texto):
    import unicodedata
    s = unicodedata.normalize("NFKD", (texto or "").lower())
    s = "".join(c for c in s if not unicodedata.combining(c))
    return {w[:5] for w in re.findall(r"[a-z]+", s) if len(w) > 2 and w not in STOP}


def key_of_scene(cena):
    """Palavras que a mídia tem de mostrar: `chave_en` da curadoria (o objeto/sujeito da fala) ou o termo."""
    return _roots(cena.get("chave_en") or cena.get("busca_en") or cena.get("busca") or "")


RELEVANT = 0.66  # "credit card" pede as duas palavras: "birthday card" não serve


def relevance(cand, chave):
    """Fração das palavras-chave da cena que aparecem nas tags/título/descrição do candidato (a descrição do
    acervo vem do modelo de visão, a mais confiável)."""
    if not chave:
        return 0.0
    target = _roots(" ".join(str(cand.get(k) or "") for k in ("tags", "titulo", "descricao")))
    # tags vêm da mais importante para a menos: a chave nas 3 primeiras vale mais ("credit card" no fim de
    # uma foto de barbearia, não)
    top = _roots(", ".join(str(cand.get("tags") or "").split(",")[:3]) + " " + str(cand.get("descricao") or ""))
    return round(len(chave & target) / len(chave) + 0.3 * (len(chave & top) / len(chave)), 2)


def terms_of_scene(cena):
    """[(termo, idioma)]: os termos em inglês com lang inglês (os bancos indexam em inglês) e o termo em
    português com o idioma do canal."""
    en = [t for t in [cena.get("busca_en"), *cena.get("alternativas", [])] if t]
    return [(t, "en-US") for t in dict.fromkeys(en)] + ([(cena["busca"], None)] if cena.get("busca") else [])


def _candidates(cena, tipo, providers, env, language, minimum=6):
    """Junta candidatos de todos os provedores, termo a termo, até ter `minimo` relevantes (a chave
    nas tags); a ordem final é por relevância (ver `ordenar`), não pela ordem em que os bancos responderam."""
    key = key_of_scene(cena)
    terms = terms_of_scene(cena)
    # sem resultado, o termo principal perde palavras do fim (escrito da mais importante para a menos)
    if terms:
        t0 = terms[0][0].split()
        terms += [(" ".join(t0[:n]), terms[0][1]) for n in range(len(t0) - 1, 1, -1)]
    output, seen = [], set()
    for term, lang in terms:
        for name in providers:
            try:
                found = PROVIDERS[name](term, tipo, env, lang or language)
            except requests.RequestException as e:
                print(f"     {name}: erro na busca ({e})")
                continue
            for a in found:
                if a["id"] not in seen:
                    seen.add(a["id"])
                    output.append(a)
        if sum(relevance(a, key) >= RELEVANT for a in output) >= minimum:
            break
    return output


def sort(cands, chave, exigir=False):
    """Mais relevante primeiro (acervo e bancos juntos; no empate, o acervo, que não gasta download). Se há
    candidatos com a chave inteira (2 de 3 palavras numa chave longa), só eles ficam (sem nenhum, fica tudo: o modelo de visão do
    avaliar confere depois). `exigir`: só os relevantes, mesmo que não sobre nenhum (vídeo sem nada relevante
    → a cena passa para foto, que acha o objeto exato com mais facilidade)."""
    for c in cands:
        c["relevancia"] = relevance(c, chave)
    if exigir or any(c["relevancia"] >= RELEVANT for c in cands):
        cands = [c for c in cands if c["relevancia"] >= RELEVANT]
    return sorted(cands, key=lambda c: (-c["relevancia"], not c.get("arquivo")))


def _prepare(cand, cena, pasta, w, h, fps, dur, term=""):
    """Baixa um candidato para o acervo (ou usa o arquivo que já está lá) e converte para a cena;
    devolve o arquivo final ou None se falhar."""
    video = cand["tipo"] == "video"
    final = pasta / f"cena_{cena['id']:03d}{'.mp4' if video else '.jpg'}"
    raw = pasta / f"bruto_{cena['id']:03d}{'.mp4' if video else '.img'}"
    try:
        if cand.get("arquivo"):  # veio do acervo: nada de rede
            origin = library.folder() / cand["arquivo"]
            library.register(cand, origin, term)  # só acrescenta o termo
        else:
            _download(cand["url"], raw)
            origin = library.register(cand, raw, term)
        if video:
            normalize_video(origin, final, w, h, fps, dur)
        else:
            normalize_image(origin, final, w, h)
        return final
    except (requests.RequestException, subprocess.CalledProcessError, OSError) as e:
        print(f"     {cand['id']}: falhou ({str(e)[:90]}); tentando o próximo")
        return None
    finally:
        raw.unlink(missing_ok=True)


def fetch(project, refazer=False, cenas=None):
    """refazer: troca a mídia das cenas (todas, ou só as de `cenas`) por outro resultado."""
    cfg = project.cfg
    w, h, fps = cfg["video"]["largura"], cfg["video"]["altura"], cfg["video"]["fps"]
    portrait = h > w
    ORIENT.update(pexels="portrait" if portrait else "landscape", pixabay="vertical" if portrait else "horizontal")
    providers = cfg["midia"]["provedores"]
    language = cfg["midia"]["idioma_busca"]
    env = project.env
    if not env.get("PEXELS_API_KEY") and not _key_pixabay(env, "video"):
        print("  aviso: sem PEXELS_API_KEY/PIXABAY_API_KEY_* no .env; só fotos do Openverse (sem vídeos)")

    ac = cfg.get("acervo", {})
    plan = project.load_json("plano.json")
    from esteira import production
    production.mark_presenter(project, plan)  # no modo apresentador, cenas de câmera não buscam mídia
    folder = project.caminho("midia")
    target = set(cenas) if cenas else {c["id"] for c in plan["cenas"]}
    for cena in plan["cenas"]:
        if refazer and cena["id"] in target and cena.get("midia_id"):
            # A mídia trocada não volta a ser escolhida para esta cena.
            cena.setdefault("rejeitados", []).append(cena.pop("midia_id"))
            cena["midia"] = None
    used = {c["midia_id"] for c in plan["cenas"] if c.get("midia_id")}

    lock = threading.Lock()
    pending = [c for c in plan["cenas"] if c["id"] in target and not c.get("camera")
                 and not (c.get("midia") and (project.pasta / c["midia"]).exists())]
    done = [0]

    def uma(cena):
        """Busca, baixa e converte a mídia de uma cena. Roda em paralelo: `usados` é reservado sob trava."""
        duration = cena["fim"] - cena["inicio"]
        order = [cena["tipo"], "imagem"] if cena["tipo"] == "video" else ["imagem"]
        chosen, failures, final = None, 0, None
        terms = [t for t, _ in terms_of_scene(cena)]
        key = key_of_scene(cena)
        for kind in order:
            # Acervo primeiro (sem rede, sem API); depois os bancos de imagens.
            of_library = library.search(terms, kind, "retrato" if portrait else "paisagem", duration,
                                        excluir=set(cena.get("rejeitados", [])) | used, canal=project.canal,
                                        max_usos_canal=ac.get("max_usos_canal", 2)) if ac.get("reaproveitar", True) else []
            cands = sort([*of_library, *_candidates(cena, kind, providers, env, language)], key,
                            exigir=kind != order[-1])
            events.debug(f"cena {cena['id']}: {len(cands)} candidatos ({kind})", chave=sorted(key),
                          melhores=[(c["id"], c["relevancia"]) for c in cands[:3]])
            for cand in cands:
                if cand["id"] in cena.get("rejeitados", []):
                    continue
                if kind == "video" and cand["duracao"] and cand["duracao"] * 2 < duration:
                    continue  # curto demais até em câmera lenta
                with lock:
                    if cand["id"] in used:
                        continue
                    used.add(cand["id"])
                final = _prepare(cand, cena, folder, w, h, fps, duration, terms[0] if terms else "")
                if final:
                    chosen = cand
                    break
                with lock:
                    used.discard(cand["id"])
                failures += 1
                if failures >= 5:
                    break
            if chosen or failures >= 5:
                break
        with lock:
            done[0] += 1
            events.progress(done[0], len(pending), f"cena {cena['id']} [{cena.get('busca_en') or cena['busca']}]")
            if not chosen:
                events.warning(f"cena {cena['id']}: nada encontrado para [{cena.get('busca_en') or cena['busca']}]")
                return
            cena.update(midia=str(final.relative_to(project.pasta)), midia_id=chosen["id"],
                        relevancia=chosen.get("relevancia"),
                        midia_tipo=chosen["tipo"], credito=chosen["credito"],
                        midia_origem="acervo" if chosen.get("arquivo") else "banco")
            library.mark_usage(chosen["id"], project.canal, project.ep, cena["id"])
            events.debug(f"cena {cena['id']} ← {chosen['id']}", midia=chosen["tipo"], busca=cena.get("busca_en"))
            project.save_json("plano.json", plan)

    with ThreadPoolExecutor(cfg["midia"].get("paralelo", 6)) as ex:
        list(ex.map(uma, pending))

    credit = sorted({c["credito"] for c in plan["cenas"] if c.get("credito")})
    project.caminho("creditos.txt").write_text("\n".join(credit) + "\n")
    missing = [c["id"] for c in plan["cenas"] if not c.get("midia") and not c.get("camera")]
    reuse = sum(1 for c in pending if c.get("midia_origem") == "acervo")
    camera = sum(1 for c in plan["cenas"] if c.get("camera"))
    print(f"  mídia pronta para {len(plan['cenas']) - len(missing)}/{len(plan['cenas'])} cenas"
          + (f" ({camera} na câmera)" if camera else "")
          + f"; {reuse}/{len(pending)} reaproveitadas do acervo" + (f"; faltam {missing}" if missing else ""))


def sheet(project, frames, destino, colunas=4, w=384, h=216):
    # 4 × 384 = 1536 px: abaixo dos 1568 px em que a imagem é reduzida antes de o Claude vê-la.
    """Grade de quadros [(arquivo, inicio_s ou None, legenda)] numa imagem só."""
    inputs, filters = [], []
    for i, (file, ss, caption) in enumerate(frames):
        inputs += (["-ss", str(ss)] if ss is not None else []) + ["-i", file]
        caption = caption.replace(":", "\\:").replace("'", "").replace(",", "\\,")
        filters.append(f"[{i}:v]scale={w}:{h},setsar=1,drawbox=y={h - 34}:w={w}:h=34:color=black@0.7:t=fill,"
                       f"drawtext=text='{caption}':x=8:y={h - 27}:fontsize=18:fontcolor=white[q{i}]")
    lines = -(-len(frames) // colunas)
    total = lines * colunas if lines > 1 else len(frames)
    for i in range(len(frames), total):  # completa a grade com quadros pretos
        inputs += ["-f", "lavfi", "-i", f"color=black:s={w}x{h}:d=1"]
        filters.append(f"[{i}:v]setsar=1[q{i}]")
    layout = "|".join(f"{(i % colunas) * w}_{(i // colunas) * h}" for i in range(total))
    filters.append("".join(f"[q{i}]" for i in range(total))
                   + (f"xstack=inputs={total}:layout={layout}" if total > 1 else "null"))
    _ffmpeg(*inputs, "-filter_complex", ";".join(filters), "-frames:v", "1", "-q:v", 4, destino)


def review(project, cenas=None, by_sheet=16):
    """Folhas de contato revisao_NN.jpg (16 cenas cada, legíveis e baratas de ler) com número e busca."""
    plan = project.load_json("plano.json")
    cenas = [c for c in plan["cenas"] if c.get("midia") and (not cenas or c["id"] in cenas)]
    if not cenas:
        raise SystemExit("nenhuma cena com mídia; rode buscar")
    for old in project.pasta.glob("revisao*.jpg"):
        old.unlink()
    for n in range(0, len(cenas), by_sheet):
        group = cenas[n:n + by_sheet]
        destination = project.caminho(f"revisao_{n // by_sheet + 1:02d}.jpg")
        sheet(project, [(project.pasta / c["midia"], 0.5 if c.get("midia_tipo") == "video" else None,
                         f"{c['id']} {c.get('busca_en') or c['busca']}") for c in group], destination)
        print(f"  {destination.name}: cenas {group[0]['id']}–{group[-1]['id']}")


def frames(project, n=8):
    """Folha quadros.jpg com n quadros do final.mp4 espalhados pela duração, para conferir a montagem."""
    final = project.caminho("final.mp4")
    if not final.exists():
        raise SystemExit("final.mp4 não existe; rode montar")
    duration = duration_media(final)
    times = [round(duration * (i + 0.5) / n, 1) for i in range(n)]
    destination = project.caminho("quadros.jpg")
    sheet(project, [(final, t, f"{t:.1f}s") for t in times], destination)
    print(f"  {destination.name}: {', '.join(f'{t:.1f}s' for t in times)}")
