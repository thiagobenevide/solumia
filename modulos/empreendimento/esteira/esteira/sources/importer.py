"""Cria um projeto a partir de um roteiro do vault: roteiro.txt, roteiro.json (capítulos, notas de cena,
fontes), narracao.wav e config.toml com o canal (que puxa perfis/<canal>.toml)."""
import json
import shutil
import tomllib
from pathlib import Path

from esteira import production
from esteira.sources import recordings, obsidian
from esteira.project import ROOT, ep_id, folder_ep


def name_project(canal, numero, titulo, letra=""):
    return f"{canal}-{numero:03d}{letra}" if numero else f"{canal}-{obsidian._norm_slug(titulo)}"


def _cross_check_quotes(citacoes, cfg):
    """Caminho absoluto do PDF de cada [!cite] e se o trecho está mesmo na página indicada."""
    from esteira.graphics import pdf as P
    vault = Path(cfg["vault"]).expanduser()
    for c in citacoes:
        arq = vault / c["arquivo"]
        if not arq.exists():
            arq = next(Path(cfg["artigos"]).expanduser().rglob(Path(c["arquivo"]).name), arq)
        c["arquivo"] = str(arq)
        achado = P.locate(arq, c["en"], c["pagina"] - 1) if arq.exists() else None
        c["ok"] = bool(achado and achado["nota"] >= 0.85)
        if not c["ok"]:
            print(f"  ! citação da fala {c['fala'] + 1} ({c.get('autores', '?')}): "
                  + ("trecho não achado na p. %d" % c["pagina"] if arq.exists() else f"PDF ausente: {arq.name}")
                  + " — rode `artigo checar` no vault")
    return citacoes


def run_import(md, audio=None, nome=None, camera=None, modo=None):
    """`modo`: "dark" (só narração + bancos de imagens) ou "apresentador" (vídeo da câmera + B-roll); padrão:
    `modo:` do frontmatter do roteiro, senão `[producao] modo` do perfil do canal."""
    cfg = tomllib.loads((ROOT / "config.toml").read_text())["fontes"]
    md = Path(md)
    canal = md.parent.parent.name
    texto = md.read_text()
    titulo, linhas, notas, fontes, citacoes = obsidian.convert(texto)
    citacoes = _cross_check_quotes(citacoes, cfg)
    import frontmatter
    meta = frontmatter.loads(texto).metadata
    numero, letra = obsidian._number(md.name, meta), obsidian.short(md.name, meta)
    formato = "9:16" if letra else "16:9"
    pasta = folder_ep(nome or name_project(canal, numero, titulo, letra))
    pasta.mkdir(parents=True, exist_ok=True)

    shutil.copy2(md, pasta / "roteiro_original.md")
    (pasta / "roteiro.txt").write_text(obsidian.script_txt(titulo, linhas))
    (pasta / "roteiro.json").write_text(json.dumps(
        {"canal": canal, "numero": numero, "short": letra, "formato": formato, "titulo": titulo, "origem": str(md),
         "capitulos": obsidian.chapters(linhas), "notas": notas, "fontes": fontes, "citacoes": citacoes},
        ensure_ascii=False, indent=2))
    modo = modo or str(meta.get("modo") or "").strip().lower() or None
    if modo not in (None, "dark", "apresentador"):  # "a-definir": usa o padrão do perfil, avisando
        print(f"  ! roteiro com modo '{modo}': usando o padrão do perfil; defina dark ou apresentador no roteiro")
        modo = None
    if not (pasta / "config.toml").exists():
        (pasta / "config.toml").write_text(f'canal = "{canal}"\n\n[video]\nformato = "{formato}"\n'
                                           + (f'\n[producao]\nmodo = "{modo}"\n' if modo else ""))
    from esteira.project import Project
    modo = Project(pasta).cfg.get("producao", {}).get("modo", "dark")

    if not audio:
        cands = recordings.candidates(cfg["gravacoes"], canal, numero, titulo, short=bool(letra))
        if (not cands or cands[0]["nota"] < 0.5) and modo != "apresentador":
            print(f"  ! áudio não identificado com segurança: {[c['caminho'] for c in cands[:3]]}; use --audio")
        audio = cands[0]["caminho"] if cands and (cands[0]["nota"] >= 0.5 or modo != "apresentador") else None

    if modo == "apresentador" and not production.camera(Project(pasta)):
        if not camera:
            cands = recordings.candidates(cfg["gravacoes"], canal, numero, titulo, short=bool(letra),
                                         exts=production.VIDEO_EXT)
            camera = cands[0]["caminho"] if cands and cands[0]["nota"] >= 0.5 else None
        if camera:
            audio = production.prepare_camera(pasta, camera, audio)  # WAV sincronizado ou som da câmera
            info = production.info_camera(Project(pasta))
            print(f"  câmera: {Path(camera).name}" + (f" (WAV sincronizado, offset {info['offset']:+.2f}s, "
                                                      f"confiança {info.get('confianca_sync')})" if "confianca_sync" in info
                                                      else " (áudio extraído da câmera)"))
        else:
            print("  ! modo apresentador sem vídeo da câmera: use --camera arquivo.mp4 (sem ele, sai como dark)")
    if audio and not any(pasta.glob("narracao*")):
        shutil.copy2(audio, pasta / f"narracao{Path(audio).suffix.lower()}")
        st = Path(audio).stat()
        (pasta / "origem_audio.json").write_text(json.dumps(
            {"caminho": str(audio), "tamanho": st.st_size, "modificado": st.st_mtime}, ensure_ascii=False))
        if Path(audio).parent == pasta:
            Path(audio).unlink()  # narracao_camera.wav já copiada como narracao.wav
    falas = sum("fala" in l for l in linhas)
    print(f"  {ep_id(pasta)} [{modo}]: {falas} falas, {len(notas)} notas de cena, {len(fontes)} fontes, "
          f"{sum(c['ok'] for c in citacoes)}/{len(citacoes)} citações com PDF conferido"
          + (f", áudio {Path(audio).name}" if audio else ", SEM áudio"))
    return pasta


def update_script(projeto):
    """Antes do limpar: o roteiro no vault mudou desde a importação (texto ≠ roteiro_original.md)? Importa de
    novo (roteiro.txt, roteiro.json, citações; o áudio já copiado fica). True se atualizou."""
    rot = projeto.caminho("roteiro.json")
    if not rot.exists():
        return False
    origem = Path(json.loads(rot.read_text()).get("origem") or "")
    copia = projeto.caminho("roteiro_original.md")
    if not origem.is_file() or (copia.exists() and copia.read_text() == origem.read_text()):
        return False
    run_import(origem, nome=projeto.ep)
    return True
