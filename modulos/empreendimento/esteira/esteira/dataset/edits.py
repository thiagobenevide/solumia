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
from esteira.project import Projeto, episodios

TRILHAS = {"Video 1": "base", "Video 2": "apoio", "Video 3": "texto", "Video 4": "grafismo", "Audio 1": "narracao",
           "Audio 2": "musica", "Audio 3": "sfx"}
TOL = 1 / 60  # s: diferença abaixo de meio quadro não é edição


def _sha(arq: Path) -> str:
    return hashlib.sha1(arq.read_bytes()).hexdigest()


def _ja_registrado(sha: str) -> bool:
    return any((r.get("extra") or {}).get("sha") == sha for r in R.registros())


# ---------- FilmCraft ----------

def clipes_fcproj(arq: Path) -> list[dict]:
    d = json.loads(Path(arq).read_text())
    itens = d["project"]["items"]
    seq = next(x["kind"]["Sequence"] for x in itens.values() if "Sequence" in x["kind"])
    saida = []
    for t in [*seq["video_tracks"], *seq.get("audio_tracks", [])]:
        trilha = TRILHAS.get(t["name"])
        if not trilha:
            continue
        for c in t["items"]:
            media = itens.get(str(c.get("item")), {}).get("kind", {}).get("Media", {}).get("media", {})
            caminho = (media.get("File") or {}).get("path")
            saida.append({"trilha": trilha, "arquivo": Path(caminho).name if caminho else None, "nome": c.get("name"),
                          "em": c["start"] / TICKS, "dur": c["duration"] / TICKS,
                          "origem": (c.get("source_in") or 0) / TICKS, "velocidade": c.get("speed", 1.0),
                          "efeitos": len(c.get("effects") or [])})
    return saida


def clipes_n1(doc: dict, midias: dict) -> list[dict]:
    saida = []
    for o in doc["ops"]:
        if o["op"] == "colocar":
            saida.append({"id": o["id"], "trilha": o["trilha"], "arquivo": midias.get(o["midia"]), "em": o["em"],
                          "dur": o.get("dur"), "origem": o.get("origem") or 0, "velocidade": 1.0})
        elif o["op"] == "texto":
            saida.append({"id": o["id"], "trilha": "texto", "arquivo": None, "nome": o["conteudo"], "em": o["em"],
                          "dur": o["dur"], "origem": 0, "velocidade": 1.0})
    return saida


def levantar_fc(doc: dict, midias: dict, editado: Path) -> tuple[list[dict], list[dict]]:
    """Diferença N1 gerado × `.fcproj` editado → (operações N1 de correção, brutos)."""
    antes, depois = clipes_n1(doc, midias), clipes_fcproj(editado)
    ops, brutos, usados = [], [], set()
    for a in antes:
        cands = [(abs(b["em"] - a["em"]), k) for k, b in enumerate(depois) if k not in usados
                 and b["trilha"] == a["trilha"] and (b["arquivo"] == a["arquivo"] if a["arquivo"] else b["nome"] == a.get("nome"))]
        if not cands:
            ops.append({"op": "remover", "alvo": a["id"], "fechar": False})
            continue
        _, k = min(cands)
        usados.add(k)
        b = depois[k]
        d_origem = b["origem"] - a["origem"]
        if abs(d_origem) > TOL:
            ops.append({"op": "aparar", "alvo": a["id"], "borda": "entrada", "delta": round(-d_origem, 3)})
        em_esperado = a["em"] + (d_origem if abs(d_origem) > TOL else 0)
        if abs(b["em"] - em_esperado) > TOL:
            ops.append({"op": "mover", "alvo": a["id"], "para": round(b["em"], 3)})
        if a["dur"] is not None:
            dur_esperada = a["dur"] - (d_origem if abs(d_origem) > TOL else 0)
            if abs(b["dur"] - dur_esperada) > TOL:
                ops.append({"op": "aparar", "alvo": a["id"], "borda": "saida", "delta": round(b["dur"] - dur_esperada, 3)})
        if abs(b["velocidade"] - 1.0) > 1e-3:
            ops.append({"op": "velocidade", "alvo": a["id"], "fator": round(b["velocidade"], 3)})
    for k, b in enumerate(depois):
        if k in usados:
            continue
        if b["arquivo"]:
            ops.append({"op": "colocar", "id": f"novo{k}", "midia": f"arquivo:{b['arquivo']}", "trilha": b["trilha"],
                        "em": round(b["em"], 3), "dur": round(b["dur"], 3), "origem": round(b["origem"], 3)})
        else:
            brutos.append({"clipe_sem_midia": b["nome"], "trilha": b["trilha"], "em": round(b["em"], 3)})
    return ops, brutos


def fcproj_editado(projeto: Projeto, editado: Path) -> str | None:
    """Registra `corrigir_montagem` para um `.fcproj` salvo à mão. → id do registro (None se já estava)."""
    sha = _sha(editado)
    if _ja_registrado(sha):
        return None
    # a base tem de ser a montagem que a app executou ANTES da edição (com o rastro N0); uma tradução feita
    # depois, pelo plano atual, misturaria replanejamento com edição humana
    base = R.ultimo(f"ep:{projeto.ep}", "montar")
    quando = __import__("datetime").datetime.fromtimestamp(editado.stat().st_mtime).strftime("%Y-%m-%dT%H:%M:%S")
    if not base or base.get("n0") is None or base["t"] > quando or not (base.get("extra") or {}).get("midias"):
        raise ValueError("sem a montagem executada antes da edição (edição anterior ao registro)")
    doc = R.ler_artefato(base["saida"]["n1"])
    ops, brutos = levantar_fc(doc, base["extra"]["midias"], editado)
    if not ops and not brutos:
        return None
    return R.gravar("corrigir_montagem", grupo=f"ep:{projeto.ep}", pai=base["id"], origem="humano",
                    contexto={"montagem": base["saida"]["n1"], "episodio": projeto.ep,
                              "formato": base["contexto"].get("formato"), "modo": base["contexto"].get("modo")},
                    saida={"versao": 1, "ops": ops}, humano={"veredito": "editada", "nota": None, "motivo": None,
                                                              "comentario": None, "em": R._agora()},
                    versoes={"n1": 1, "app": "filmcraft"},
                    extra={"episodio": projeto.ep, "arquivo": editado.name, "sha": sha, "brutos": brutos[:50]})


# ---------- PhotoCraft ----------

def _info(pcraft: Path) -> dict:
    r = subprocess.run(["photocraft-cli", "info", str(pcraft)], capture_output=True, text=True, timeout=120)
    if r.returncode:
        raise RuntimeError(r.stderr.strip()[-300:])
    return json.loads(r.stdout)


def levantar_pc(doc: dict, info: dict) -> tuple[dict, list[dict]]:
    """Composição N1 + árvore de camadas do `.pcraft` editado → (composição com os textos editados, brutos)."""
    camadas = {lay["name"]: lay for lay in info.get("layers", [])}
    novo, brutos = json.loads(json.dumps(doc)), []
    caixas = 0
    for e in novo["elementos"]:
        nome = {"titulo": "Título", "selo": "Selo (texto)"}.get(e["tipo"])
        if e["tipo"] == "caixa":
            caixas += 1
            nome = f"Caixa {caixas}"
        if not nome:
            continue
        lay = camadas.get(nome)
        if lay is None:
            brutos.append({"camada_removida": nome})
            continue
        texto = (lay.get("text") or {}).get("text")
        if texto is not None and texto.replace("*", "") != e["conteudo"].replace("*", "").upper() \
                and texto != e["conteudo"].replace("*", ""):
            e["conteudo"] = texto
        pt = (lay.get("text") or {}).get("sizePt")
        if e["tipo"] in ("titulo", "caixa") and pt and abs(pt - e["tamanho"] * info["height"]) > 1:
            e["tamanho"] = round(pt / info["height"], 4)
    conhecidas = {"Título", "Selo (texto)", "Selo (fundo)", "Seta", "Vinheta das bordas", "Vinheta lateral",
                  "Ajuste: saturação", "Ajuste: contraste", "Ajuste: look", "Fundo", "Background", "Tarja"}
    for nome in camadas:
        if nome not in conhecidas and not nome.startswith(("Caixa ", "Fundo da ")):
            brutos.append({"camada_nova": nome})
    return novo, brutos


def pcraft_editado(projeto: Projeto, pcraft: Path) -> str | None:
    sha = _sha(pcraft)
    if _ja_registrado(sha):
        return None
    base = R.ultimo(f"thumb:{projeto.ep}", "thumb_compor", arquivo=pcraft.with_suffix(".png").name)
    if not base or "elementos" not in (R.ler_artefato(base["saida"]["n1"]) or {}):
        return None
    doc = R.ler_artefato(base["saida"]["n1"])
    novo, brutos = levantar_pc(doc, _info(pcraft))
    if novo == doc and not brutos:
        return None
    return R.gravar("thumb_compor", grupo=f"thumb:{projeto.ep}", pai=base["id"], origem="humano",
                    contexto=base["contexto"], saida=novo,
                    humano={"veredito": "editada", "nota": None, "motivo": None, "comentario": None, "em": R._agora()},
                    versoes={"n1": 1, "app": "photocraft"},
                    extra={"episodio": projeto.ep, "arquivo": pcraft.with_suffix(".png").name, "sha": sha,
                           "brutos": brutos[:50]})


def varrer() -> list[str]:
    """Procura edições à mão ainda não registradas em todos os episódios. → linhas de relatório."""
    from esteira import photocraft
    saida = []
    for pasta in episodios():
        try:
            p = Projeto(pasta)
        except SystemExit:
            continue
        for arq in sorted(p.pasta.glob("projeto.manual-*.fcproj")):
            try:
                if rg := fcproj_editado(p, arq):
                    saida.append(f"{p.ep}: {arq.name} → {rg}")
            except (KeyError, ValueError, StopIteration) as e:
                saida.append(f"{p.ep}: {arq.name} não levantado ({e})")
        for pc in sorted(p.caminho("thumbs").glob("*.pcraft")) if p.caminho("thumbs").exists() else []:
            if photocraft.editado(pc):
                try:
                    if rg := pcraft_editado(p, pc):
                        saida.append(f"{p.ep}: {pc.name} → {rg}")
                except (RuntimeError, KeyError, ValueError) as e:
                    saida.append(f"{p.ep}: {pc.name} não levantado ({e})")
    return saida or ["nenhuma edição nova"]
