"""Exemplo de um template (versão de estilo) nos formatos dele, para validar antes de produzir.

Usa o mapa de cenas de uma produção já dirigida (de preferência do mesmo canal; no modo apresentador, uma com
câmera) e renderiza só os primeiros `SEGUNDOS` com o estilo escolhido. Sai em
`estilos/amostras/<id>-v<N>/<16x9|9x16>/previa.mp4` (o `final.mp4` cheio é apagado: a amostra é só para ver).
"""
import shutil

from esteira.studio import compiler, style
from esteira.project import PROJECTS, Project

SECONDS = 30
FOLDER = style.FOLDER / "amostras"


def folder(est):
    return FOLDER / f"{est.id}-v{est.versao}"


def state(est):
    """{"16x9": True/False, ...}: quais formatos da versão já têm exemplo."""
    return {f.replace(":", "x"): (folder(est) / f.replace(":", "x") / "previa.mp4").exists() for f in est.formatos}


def reference(est):
    """Episódio cujo mapa serve de roteiro da amostra: o mais recente do canal, senão o mais recente da rede."""
    from esteira import production
    mapas = sorted(PROJECTS.glob("*/*/estudio/mapa.json"), key=lambda a: a.stat().st_mtime, reverse=True)
    projects = [Project(a.parent.parent) for a in mapas]
    if est.modo == "apresentador":
        projects = [p for p in projects if production.camera(p)]
    if not projects:
        raise SystemExit("nenhuma produção com mapa de cenas" + (" e câmera" if est.modo == "apresentador" else "")
                         + ": produza um episódio no Estúdio antes de gerar exemplos")
    return next((p for p in projects if p.canal == est.canal), projects[0])


def generate(target):
    """`alvo` = id do estilo ou `id@N`."""
    est = style.load(target)
    ref = reference(est)
    print(f"  exemplo de {style.label(est)} ({est.id}) com o mapa de {ref.folder_path.parent.name}-{ref.folder_path.name}", flush=True)
    for fmt in est.formatos:
        p = folder(est) / fmt.replace(":", "x")
        if p.exists():
            shutil.rmtree(p)
        compiler.build(ref, est, fmt, destination=p, until=SECONDS)
        compiler.render(ref, fmt, p=p)
        compiler.audio(ref, est, fmt, p=p)
        (p / "final.mp4").unlink(missing_ok=True)
        shutil.rmtree(p / "render", ignore_errors=True)
        print(f"  {fmt}: {p / 'previa.mp4'}", flush=True)
    return folder(est)
