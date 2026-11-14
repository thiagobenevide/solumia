"""Cria um projeto a partir de um roteiro do vault: roteiro.txt, roteiro.json (capítulos, notas de cena,
fontes), narracao.wav e config.toml com o canal (que puxa perfis/<canal>.toml)."""
import json
import shutil
import tomllib
from pathlib import Path

from esteira import production
from esteira.sources import recordings, obsidian
from esteira.project import ROOT, ep_id, folder_ep


def name_project(channel, number, title, letter=""):
    return f"{channel}-{number:03d}{letter}" if number else f"{channel}-{obsidian._norm_slug(title)}"


def _cross_check_quotes(quotes, cfg):
    """Caminho absoluto do PDF de cada [!cite] e se o trecho está mesmo na página indicada."""
    from esteira.graphics import pdf as P
    vault = Path(cfg["vault"]).expanduser()
    for c in quotes:
        file = vault / c["arquivo"]
        if not file.exists():
            file = next(Path(cfg["artigos"]).expanduser().rglob(Path(c["arquivo"]).name), file)
        c["arquivo"] = str(file)
        found = P.locate(file, c["en"], c["pagina"] - 1) if file.exists() else None
        c["ok"] = bool(found and found["nota"] >= 0.85)
        if not c["ok"]:
            print(f"  ! citação da fala {c['fala'] + 1} ({c.get('autores', '?')}): "
                  + ("trecho não achado na p. %d" % c["pagina"] if file.exists() else f"PDF ausente: {file.name}")
                  + " — rode `artigo checar` no vault")
    return quotes


def run_import(md, audio=None, name=None, camera=None, mode=None):
    """`modo`: "dark" (só narração + bancos de imagens) ou "apresentador" (vídeo da câmera + B-roll); padrão:
    `modo:` do frontmatter do roteiro, senão `[producao] modo` do perfil do canal."""
    cfg = tomllib.loads((ROOT / "config.toml").read_text())["fontes"]
    md = Path(md)
    channel = md.parent.parent.name
    text = md.read_text()
    title, lines, notes, sources, quotes = obsidian.convert(text)
    quotes = _cross_check_quotes(quotes, cfg)
    import frontmatter
    meta = frontmatter.loads(text).metadata
    number, letter = obsidian._number(md.name, meta), obsidian.short(md.name, meta)
    fmt = "9:16" if letter else "16:9"
    folder = folder_ep(name or name_project(channel, number, title, letter))
    folder.mkdir(parents=True, exist_ok=True)

    shutil.copy2(md, folder / "roteiro_original.md")
    (folder / "roteiro.txt").write_text(obsidian.script_txt(title, lines))
    (folder / "roteiro.json").write_text(json.dumps(
        {"canal": channel, "numero": number, "short": letter, "formato": fmt, "titulo": title, "origem": str(md),
         "capitulos": obsidian.chapters(lines), "notas": notes, "fontes": sources, "citacoes": quotes},
        ensure_ascii=False, indent=2))
    mode = mode or str(meta.get("modo") or "").strip().lower() or None
    if mode not in (None, "dark", "apresentador"):  # "a-definir": usa o padrão do perfil, avisando
        print(f"  ! roteiro com modo '{mode}': usando o padrão do perfil; defina dark ou apresentador no roteiro")
        mode = None
    if not (folder / "config.toml").exists():
        (folder / "config.toml").write_text(f'canal = "{channel}"\n\n[video]\nformato = "{fmt}"\n'
                                           + (f'\n[producao]\nmodo = "{mode}"\n' if mode else ""))
    from esteira.project import Project
    mode = Project(folder).cfg.get("producao", {}).get("modo", "dark")

    if not audio:
        cands = recordings.candidates(cfg["gravacoes"], channel, number, title, short=bool(letter))
        if (not cands or cands[0]["nota"] < 0.5) and mode != "apresentador":
            print(f"  ! áudio não identificado com segurança: {[c['caminho'] for c in cands[:3]]}; use --audio")
        audio = cands[0]["caminho"] if cands and (cands[0]["nota"] >= 0.5 or mode != "apresentador") else None

    if mode == "apresentador" and not production.camera(Project(folder)):
        if not camera:
            cands = recordings.candidates(cfg["gravacoes"], channel, number, title, short=bool(letter),
                                         exts=production.VIDEO_EXT)
            camera = cands[0]["caminho"] if cands and cands[0]["nota"] >= 0.5 else None
        if camera:
            audio = production.prepare_camera(folder, camera, audio)  # WAV sincronizado ou som da câmera
            info = production.info_camera(Project(folder))
            print(f"  câmera: {Path(camera).name}" + (f" (WAV sincronizado, offset {info['offset']:+.2f}s, "
                                                      f"confiança {info.get('confianca_sync')})" if "confianca_sync" in info
                                                      else " (áudio extraído da câmera)"))
        else:
            print("  ! modo apresentador sem vídeo da câmera: use --camera arquivo.mp4 (sem ele, sai como dark)")
    if audio and not any(folder.glob("narracao*")):
        shutil.copy2(audio, folder / f"narracao{Path(audio).suffix.lower()}")
        st = Path(audio).stat()
        (folder / "origem_audio.json").write_text(json.dumps(
            {"caminho": str(audio), "tamanho": st.st_size, "modificado": st.st_mtime}, ensure_ascii=False))
        if Path(audio).parent == folder:
            Path(audio).unlink()  # narracao_camera.wav já copiada como narracao.wav
    speeches = sum("fala" in l for l in lines)
    print(f"  {ep_id(folder)} [{mode}]: {speeches} falas, {len(notes)} notas de cena, {len(sources)} fontes, "
          f"{sum(c['ok'] for c in quotes)}/{len(quotes)} citações com PDF conferido"
          + (f", áudio {Path(audio).name}" if audio else ", SEM áudio"))
    return folder


def update_script(project):
    """Antes do limpar: o roteiro no vault mudou desde a importação (texto ≠ roteiro_original.md)? Importa de
    novo (roteiro.txt, roteiro.json, citações; o áudio já copiado fica). True se atualizou."""
    rot = project.path_of("roteiro.json")
    if not rot.exists():
        return False
    origin = Path(json.loads(rot.read_text()).get("origem") or "")
    copy = project.path_of("roteiro_original.md")
    if not origin.is_file() or (copy.exists() and copy.read_text() == origin.read_text()):
        return False
    run_import(origin, name=project.ep)
    return True
