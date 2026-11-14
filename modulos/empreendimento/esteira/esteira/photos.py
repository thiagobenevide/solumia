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


def treat(projeto, cenas):
    """Trata as fotos de `cenas` (as de vídeo ficam como estão). → cenas com `midia` apontando para a tratada."""
    r = recipe(projeto.cfg)
    if not r.get("ativo"):
        return cenas
    from esteira import photocraft
    from esteira.n1 import photocraft as N1
    if not photocraft.available():
        events.warning("fotos: PhotoCraft ausente; seguindo com as originais")
        return cenas
    pasta = projeto.caminho("midia/tratadas")
    pasta.mkdir(parents=True, exist_ok=True)
    formato = projeto.cfg["video"].get("formato", "16:9")
    saida = []
    for c in cenas:
        if c.get("midia_tipo") == "video" or not c.get("midia"):
            saida.append(c)
            continue
        origem = projeto.pasta / c["midia"]
        destino = pasta / f"{Path(c['midia']).stem}.pcraft"
        png = destino.with_suffix(".png")
        if not png.exists() or png.stat().st_mtime < origem.stat().st_mtime:
            w, h = photocraft._size_image(origem)
            decisao = N1.PhotoDecision()
            doc = N1.treatment(r, decisao, formato, w, h)
            ex = N1.Executor(photocraft._run, {"foto": origem}, {}, photocraft._size_image)
            try:
                ex.executar(doc, destino)
                photocraft.export(destino, png)
            except RuntimeError as e:
                events.warning(f"fotos: cena {c['id']} sem tratamento ({e})")
                saida.append(c)
                continue
            _dataset(projeto, c, r, decisao, formato, ex.rastro)
        saida.append({**c, "midia": str(png.relative_to(projeto.pasta))})
    return saida


def _dataset(projeto, cena, r, decisao, formato, rastro):
    try:
        from esteira.dataset import registry as R
        R.write("foto_tratar", grupo=f"foto:{cena.get('midia_id') or cena['midia']}", origem="receita",
                 contexto={"canal": getattr(projeto, "canal", "") or "", "formato": formato,
                           "descricao": cena.get("descricao") or cena.get("busca_en") or cena.get("busca"),
                           "uso": "camera" if cena.get("camera") else "broll", "receita": r},
                 saida=decisao.model_dump(mode="json"), n0=[p for passada in rastro for p in passada],
                 versoes={"n1": 1, "app": "photocraft"}, extra={"episodio": projeto.ep, "cena": cena["id"]})
    except Exception as e:  # noqa: BLE001
        events.warning(f"dataset: foto da cena {cena.get('id')} não gravada ({e})")
