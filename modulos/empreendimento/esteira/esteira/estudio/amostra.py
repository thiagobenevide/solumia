"""Exemplo de um template (versão de estilo) nos formatos dele, para validar antes de produzir.

Usa o mapa de cenas de uma produção já dirigida (de preferência do mesmo canal; no modo apresentador, uma com
câmera) e renderiza só os primeiros `SEGUNDOS` com o estilo escolhido. Sai em
`estilos/amostras/<id>-v<N>/<16x9|9x16>/previa.mp4` (o `final.mp4` cheio é apagado: a amostra é só para ver).
"""
import shutil

from esteira.estudio import compilar, estilo
from esteira.projeto import PROJETOS, Projeto

SEGUNDOS = 30
PASTA = estilo.PASTA / "amostras"


def pasta(est):
    return PASTA / f"{est.id}-v{est.versao}"


def estado(est):
    """{"16x9": True/False, ...}: quais formatos da versão já têm exemplo."""
    return {f.replace(":", "x"): (pasta(est) / f.replace(":", "x") / "previa.mp4").exists() for f in est.formatos}


def referencia(est):
    """Episódio cujo mapa serve de roteiro da amostra: o mais recente do canal, senão o mais recente da rede."""
    from esteira import producao
    mapas = sorted(PROJETOS.glob("*/*/estudio/mapa.json"), key=lambda a: a.stat().st_mtime, reverse=True)
    projetos = [Projeto(a.parent.parent) for a in mapas]
    if est.modo == "apresentador":
        projetos = [p for p in projetos if producao.camera(p)]
    if not projetos:
        raise SystemExit("nenhuma produção com mapa de cenas" + (" e câmera" if est.modo == "apresentador" else "")
                         + ": produza um episódio no Estúdio antes de gerar exemplos")
    return next((p for p in projetos if p.canal == est.canal), projetos[0])


def gerar(alvo):
    """`alvo` = id do estilo ou `id@N`."""
    est = estilo.carregar(alvo)
    ref = referencia(est)
    print(f"  exemplo de {estilo.rotulo(est)} ({est.id}) com o mapa de {ref.pasta.parent.name}-{ref.pasta.name}", flush=True)
    for fmt in est.formatos:
        p = pasta(est) / fmt.replace(":", "x")
        if p.exists():
            shutil.rmtree(p)
        compilar.compilar(ref, est, fmt, destino=p, ate=SEGUNDOS)
        compilar.render(ref, fmt, p=p)
        compilar.audio(ref, est, fmt, p=p)
        (p / "final.mp4").unlink(missing_ok=True)
        shutil.rmtree(p / "render", ignore_errors=True)
        print(f"  {fmt}: {p / 'previa.mp4'}", flush=True)
    return pasta(est)
