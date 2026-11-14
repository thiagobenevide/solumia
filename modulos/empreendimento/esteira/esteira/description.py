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
    autor, ano = f.get("autores", "").strip(), f.get("ano", "")[:4]
    detalhes = f.get("detalhes", "").split(" · ")[0].strip()  # depois do "·" vêm anotações do vault
    partes = [f"{autor} ({ano})" if ano else autor, f.get("titulo", "").strip(),
              " ".join(x for x in (f.get("revista", "").strip(), detalhes) if x)]
    texto = ". ".join(p for p in partes if p)
    return f"• {texto}" + (f"\n  {_link(f)}" if _link(f) else "")


def generate(projeto):
    rot = json.loads(projeto.caminho("roteiro.json").read_text()) if projeto.caminho("roteiro.json").exists() else {}
    fontes = rot.get("fontes", [])
    graficos = projeto.carregar_json("graficos.json") if projeto.caminho("graficos.json").exists() else []
    sobrenome = lambda f: re.split(r"[ ,]", f.get("autores", "") or "?")[0].lower()
    na_tela = []
    for g in graficos:
        if g["modelo"] not in ("citacao", "fonte"):
            continue
        texto = json.dumps(g["dados"], ensure_ascii=False).lower()
        for k, f in enumerate(fontes):
            if k not in na_tela and len(sobrenome(f)) > 2 and sobrenome(f) in texto:
                na_tela.append(k)
    ordem = na_tela + [k for k in range(len(fontes)) if k not in na_tela]
    blocos = []
    if fontes:
        blocos.append("📚 Estudos e fontes citados no vídeo\n" + "\n".join(_line(fontes[k]) for k in ordem))
    creditos = projeto.caminho("creditos.txt")
    if creditos.exists() and creditos.read_text().strip():
        blocos.append("📷 Créditos das imagens\n" + creditos.read_text().strip())
    destino = projeto.caminho("descricao.txt")
    destino.write_text("\n\n".join(blocos) + "\n")
    return destino
