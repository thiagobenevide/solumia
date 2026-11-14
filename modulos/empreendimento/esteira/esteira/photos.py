"""Tratamento das fotos das cenas no PhotoCraft pela receita fixa do canal (`[foto]` do perfil).

A receita (look, contraste, nitidez, grão, desfoque do fundo) é a mesma em toda foto do canal; por foto só se
decide a `FotoDecisao` (foco, recortar, separar planos). Hoje a decisão é a padrão (centro, sem recorte); cada
foto tratada vira registro `foto_tratar` pendente, para a pessoa e depois o modelo local aprenderem a decidir.
Desligado por padrão (`[foto] ativo = false`): ligado, a foto tratada substitui a original só na montagem.
"""
from pathlib import Path

from esteira.core import events


def recipe(cfg):
    return cfg.get("foto", {})


def treat(project, scenes):
    """Trata as fotos de `cenas` (as de vídeo ficam como estão). → cenas com `midia` apontando para a tratada."""
    r = recipe(project.cfg)
    if not r.get("ativo"):
        return scenes
    from esteira import photocraft
    from esteira.n1 import photocraft as N1
    if not photocraft.available():
        events.warning("fotos: PhotoCraft ausente; seguindo com as originais")
        return scenes
    folder = project.path_of("midia/tratadas")
    folder.mkdir(parents=True, exist_ok=True)
    fmt = project.cfg["video"].get("formato", "16:9")
    output = []
    for c in scenes:
        if c.get("midia_tipo") == "video" or not c.get("midia"):
            output.append(c)
            continue
        origin = project.folder_path / c["midia"]
        destination = folder / f"{Path(c['midia']).stem}.pcraft"
        png = destination.with_suffix(".png")
        if not png.exists() or png.stat().st_mtime < origin.stat().st_mtime:
            w, h = photocraft._size_image(origin)
            decision = N1.PhotoDecision()
            doc = N1.treatment(r, decision, fmt, w, h)
            ex = N1.Executor(photocraft._run, {"foto": origin}, {}, photocraft._size_image)
            try:
                ex.apply_doc(doc, destination)
                photocraft.export(destination, png)
            except RuntimeError as e:
                events.warning(f"fotos: cena {c['id']} sem tratamento ({e})")
                output.append(c)
                continue
            _dataset(project, c, r, decision, fmt, ex.trace)
        output.append({**c, "midia": str(png.relative_to(project.folder_path))})
    return output


def _dataset(project, scene, r, decision, fmt, trace):
    try:
        from esteira.dataset import registry as R
        R.write("foto_tratar", group=f"foto:{scene.get('midia_id') or scene['midia']}", origin="receita",
                 context={"canal": getattr(project, "canal", "") or "", "formato": fmt,
                           "descricao": scene.get("descricao") or scene.get("busca_en") or scene.get("busca"),
                           "uso": "camera" if scene.get("camera") else "broll", "receita": r},
                 output=decision.model_dump(mode="json"), n0=[p for skip in trace for p in skip],
                 versions={"n1": 1, "app": "photocraft"}, extra={"episodio": project.ep, "cena": scene["id"]})
    except Exception as e:  # noqa: BLE001
        events.warning(f"dataset: foto da cena {scene.get('id')} não gravada ({e})")
