"""descricao.txt: texto para a descrição do YouTube com as fontes citadas no vídeo (os gráficos de citação
mostram "LINK NA DESCRIÇÃO", então o link tem de estar lá) e os créditos das imagens.

As fontes que aparecem na tela (citação/fonte em graficos.json) vêm primeiro, na ordem em que aparecem.
"""
import json
import re


def _link(f):
    if f.get("doi"):
        return f"https://doi.org/{f['doi']}"
    return f.get("url", "")


def _line(f):
    author, year = f.get("autores", "").strip(), f.get("ano", "")[:4]
    details = f.get("detalhes", "").split(" · ")[0].strip()  # depois do "·" vêm anotações do vault
    parts = [f"{author} ({year})" if year else author, f.get("titulo", "").strip(),
              " ".join(x for x in (f.get("revista", "").strip(), details) if x)]
    text = ". ".join(p for p in parts if p)
    return f"• {text}" + (f"\n  {_link(f)}" if _link(f) else "")


def generate(project):
    rot = json.loads(project.caminho("roteiro.json").read_text()) if project.caminho("roteiro.json").exists() else {}
    sources = rot.get("fontes", [])
    graphics = project.carregar_json("graficos.json") if project.caminho("graficos.json").exists() else []
    surname = lambda f: re.split(r"[ ,]", f.get("autores", "") or "?")[0].lower()
    in_screen = []
    for g in graphics:
        if g["modelo"] not in ("citacao", "fonte"):
            continue
        text = json.dumps(g["dados"], ensure_ascii=False).lower()
        for k, f in enumerate(sources):
            if k not in in_screen and len(surname(f)) > 2 and surname(f) in text:
                in_screen.append(k)
    order = in_screen + [k for k in range(len(sources)) if k not in in_screen]
    blocks = []
    if sources:
        blocks.append("📚 Estudos e fontes citados no vídeo\n" + "\n".join(_line(sources[k]) for k in order))
    credit = project.caminho("creditos.txt")
    if credit.exists() and credit.read_text().strip():
        blocks.append("📷 Créditos das imagens\n" + credit.read_text().strip())
    destination = project.caminho("descricao.txt")
    destination.write_text("\n\n".join(blocks) + "\n")
    return destination
