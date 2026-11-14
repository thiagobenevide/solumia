"""Edições à mão nas Craft Apps viram dados (`docs/PLANO-DATASET.md` F5).

FilmCraft: o `.fcproj` salvo à mão (`projeto.manual-*.fcproj`) é comparado com a montagem N1 registrada e a
diferença vira operações de correção (`remover`, `colocar`, `mover`, `aparar`, `velocidade`) na tarefa
`corrigir_montagem`. PhotoCraft: o `.pcraft` de uma thumb salvo à mão volta para a composição N1 com os textos
editados (`thumb_compor`, veredito `editada`). O que não se levanta (efeitos, chaves) fica em `brutos`, que nunca
entra no vocabulário do modelo; muitos brutos repetidos indicam operação que falta no N1.
"""
import hashlib
import json
import subprocess
from pathlib import Path

from esteira.dataset import registry as R
from esteira.filmcraft import TICKS
from esteira.project import Project, episodes

TRACKS = {"Video 1": "base", "Video 2": "apoio", "Video 3": "texto", "Video 4": "grafismo", "Audio 1": "narracao",
           "Audio 2": "musica", "Audio 3": "sfx"}
TOL = 1 / 60  # s: diferença abaixo de meio quadro não é edição


def _sha(file: Path) -> str:
    return hashlib.sha1(file.read_bytes()).hexdigest()


def _already_registered(sha: str) -> bool:
    return any((r.get("extra") or {}).get("sha") == sha for r in R.records())


# ---------- FilmCraft ----------

def clips_fcproj(file: Path) -> list[dict]:
    d = json.loads(Path(file).read_text())
    items = d["project"]["items"]
    seq = next(x["kind"]["Sequence"] for x in items.values() if "Sequence" in x["kind"])
    output = []
    for t in [*seq["video_tracks"], *seq.get("audio_tracks", [])]:
        track = TRACKS.get(t["name"])
        if not track:
            continue
        for c in t["items"]:
            media = items.get(str(c.get("item")), {}).get("kind", {}).get("Media", {}).get("media", {})
            path = (media.get("File") or {}).get("path")
            output.append({"trilha": track, "arquivo": Path(path).name if path else None, "nome": c.get("name"),
                          "em": c["start"] / TICKS, "dur": c["duration"] / TICKS,
                          "origem": (c.get("source_in") or 0) / TICKS, "velocidade": c.get("speed", 1.0),
                          "efeitos": len(c.get("effects") or [])})
    return output


def clips_n1(doc: dict, medias: dict) -> list[dict]:
    output = []
    for o in doc["ops"]:
        if o["op"] == "colocar":
            output.append({"id": o["id"], "trilha": o["trilha"], "arquivo": medias.get(o["midia"]), "em": o["em"],
                          "dur": o.get("dur"), "origem": o.get("origem") or 0, "velocidade": 1.0})
        elif o["op"] == "texto":
            output.append({"id": o["id"], "trilha": "texto", "arquivo": None, "nome": o["conteudo"], "em": o["em"],
                          "dur": o["dur"], "origem": 0, "velocidade": 1.0})
    return output


def lift_fc(doc: dict, medias: dict, edited: Path) -> tuple[list[dict], list[dict]]:
    """Diferença N1 gerado × `.fcproj` editado → (operações N1 de correção, brutos)."""
    before, after = clips_n1(doc, medias), clips_fcproj(edited)
    ops, raw, used = [], [], set()
    for a in before:
        cands = [(abs(b["em"] - a["em"]), k) for k, b in enumerate(after) if k not in used
                 and b["trilha"] == a["trilha"] and (b["arquivo"] == a["arquivo"] if a["arquivo"] else b["nome"] == a.get("nome"))]
        if not cands:
            ops.append({"op": "remover", "alvo": a["id"], "fechar": False})
            continue
        _, k = min(cands)
        used.add(k)
        b = after[k]
        d_origin = b["origem"] - a["origem"]
        if abs(d_origin) > TOL:
            ops.append({"op": "aparar", "alvo": a["id"], "borda": "entrada", "delta": round(-d_origin, 3)})
        in_expected = a["em"] + (d_origin if abs(d_origin) > TOL else 0)
        if abs(b["em"] - in_expected) > TOL:
            ops.append({"op": "mover", "alvo": a["id"], "para": round(b["em"], 3)})
        if a["dur"] is not None:
            duration_expected = a["dur"] - (d_origin if abs(d_origin) > TOL else 0)
            if abs(b["dur"] - duration_expected) > TOL:
                ops.append({"op": "aparar", "alvo": a["id"], "borda": "saida", "delta": round(b["dur"] - duration_expected, 3)})
        if abs(b["velocidade"] - 1.0) > 1e-3:
            ops.append({"op": "velocidade", "alvo": a["id"], "fator": round(b["velocidade"], 3)})
    for k, b in enumerate(after):
        if k in used:
            continue
        if b["arquivo"]:
            ops.append({"op": "colocar", "id": f"novo{k}", "midia": f"arquivo:{b['arquivo']}", "trilha": b["trilha"],
                        "em": round(b["em"], 3), "dur": round(b["dur"], 3), "origem": round(b["origem"], 3)})
        else:
            raw.append({"clipe_sem_midia": b["nome"], "trilha": b["trilha"], "em": round(b["em"], 3)})
    return ops, raw


def fcproj_edited(project: Project, edited: Path) -> str | None:
    """Registra `corrigir_montagem` para um `.fcproj` salvo à mão. → id do registro (None se já estava)."""
    sha = _sha(edited)
    if _already_registered(sha):
        return None
    # a base tem de ser a montagem que a app executou ANTES da edição (com o rastro N0); uma tradução feita
    # depois, pelo plano atual, misturaria replanejamento com edição humana
    base = R.last(f"ep:{project.ep}", "montar")
    when = __import__("datetime").datetime.fromtimestamp(edited.stat().st_mtime).strftime("%Y-%m-%dT%H:%M:%S")
    if not base or base.get("n0") is None or base["t"] > when or not (base.get("extra") or {}).get("midias"):
        raise ValueError("sem a montagem executada antes da edição (edição anterior ao registro)")
    doc = R.read_artifact(base["saida"]["n1"])
    ops, raw = lift_fc(doc, base["extra"]["midias"], edited)
    if not ops and not raw:
        return None
    return R.write("corrigir_montagem", group=f"ep:{project.ep}", parent=base["id"], origin="humano",
                    context={"montagem": base["saida"]["n1"], "episodio": project.ep,
                              "formato": base["contexto"].get("formato"), "modo": base["contexto"].get("modo")},
                    output={"versao": 1, "ops": ops}, humano={"veredito": "editada", "nota": None, "motivo": None,
                                                              "comentario": None, "em": R._now()},
                    versions={"n1": 1, "app": "filmcraft"},
                    extra={"episodio": project.ep, "arquivo": edited.name, "sha": sha, "brutos": raw[:50]})


# ---------- PhotoCraft ----------

def _info(pcraft: Path) -> dict:
    r = subprocess.run(["photocraft-cli", "info", str(pcraft)], capture_output=True, text=True, timeout=120)
    if r.returncode:
        raise RuntimeError(r.stderr.strip()[-300:])
    return json.loads(r.stdout)


def lift_pc(doc: dict, info: dict) -> tuple[dict, list[dict]]:
    """Composição N1 + árvore de camadas do `.pcraft` editado → (composição com os textos editados, brutos)."""
    layers = {lay["name"]: lay for lay in info.get("layers", [])}
    new, raw = json.loads(json.dumps(doc)), []
    boxes = 0
    for e in new["elementos"]:
        name = {"titulo": "Título", "selo": "Selo (texto)"}.get(e["tipo"])
        if e["tipo"] == "caixa":
            boxes += 1
            name = f"Caixa {boxes}"
        if not name:
            continue
        lay = layers.get(name)
        if lay is None:
            raw.append({"camada_removida": name})
            continue
        text = (lay.get("text") or {}).get("text")
        if text is not None and text.replace("*", "") != e["conteudo"].replace("*", "").upper() \
                and text != e["conteudo"].replace("*", ""):
            e["conteudo"] = text
        pt = (lay.get("text") or {}).get("sizePt")
        if e["tipo"] in ("titulo", "caixa") and pt and abs(pt - e["tamanho"] * info["height"]) > 1:
            e["tamanho"] = round(pt / info["height"], 4)
    known = {"Título", "Selo (texto)", "Selo (fundo)", "Seta", "Vinheta das bordas", "Vinheta lateral",
                  "Ajuste: saturação", "Ajuste: contraste", "Ajuste: look", "Fundo", "Background", "Tarja"}
    for name in layers:
        if name not in known and not name.startswith(("Caixa ", "Fundo da ")):
            raw.append({"camada_nova": name})
    return new, raw


def pcraft_edited(project: Project, pcraft: Path) -> str | None:
    sha = _sha(pcraft)
    if _already_registered(sha):
        return None
    base = R.last(f"thumb:{project.ep}", "thumb_compor", arquivo=pcraft.with_suffix(".png").name)
    if not base or "elementos" not in (R.read_artifact(base["saida"]["n1"]) or {}):
        return None
    doc = R.read_artifact(base["saida"]["n1"])
    new, raw = lift_pc(doc, _info(pcraft))
    if new == doc and not raw:
        return None
    return R.write("thumb_compor", group=f"thumb:{project.ep}", parent=base["id"], origin="humano",
                    context=base["contexto"], output=new,
                    humano={"veredito": "editada", "nota": None, "motivo": None, "comentario": None, "em": R._now()},
                    versions={"n1": 1, "app": "photocraft"},
                    extra={"episodio": project.ep, "arquivo": pcraft.with_suffix(".png").name, "sha": sha,
                           "brutos": raw[:50]})


def sweep() -> list[str]:
    """Procura edições à mão ainda não registradas em todos os episódios. → linhas de relatório."""
    from esteira import photocraft
    output = []
    for folder in episodes():
        try:
            p = Project(folder)
        except SystemExit:
            continue
        for file in sorted(p.folder_path.glob("projeto.manual-*.fcproj")):
            try:
                if rg := fcproj_edited(p, file):
                    output.append(f"{p.ep}: {file.name} → {rg}")
            except (KeyError, ValueError, StopIteration) as e:
                output.append(f"{p.ep}: {file.name} não levantado ({e})")
        for pc in sorted(p.path_of("thumbs").glob("*.pcraft")) if p.path_of("thumbs").exists() else []:
            if photocraft.edited(pc):
                try:
                    if rg := pcraft_edited(p, pc):
                        output.append(f"{p.ep}: {pc.name} → {rg}")
                except (RuntimeError, KeyError, ValueError) as e:
                    output.append(f"{p.ep}: {pc.name} não levantado ({e})")
    return output or ["nenhuma edição nova"]
