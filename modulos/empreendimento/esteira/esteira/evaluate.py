"""Etapa avaliar: o modelo de visão local dá nota (1–5) à mídia de cada cena e troca a que não combina.

Rodadas: avalia → cenas com nota ≤ 2 ganham o termo sugerido pelo modelo e a mídia vai para `rejeitados`
→ busca de novo só essas → avalia só essas. Depois de `rodadas`, o que ainda estiver fraco fica no
relatório (`./dark review <ep> --scenes ...` mostra a folha delas).
"""
import subprocess

from pydantic import BaseModel, Field

from esteira import library
from esteira.core import events
from esteira.ai import local


class Nota(BaseModel):
    nota: int = Field(ge=1, le=5)
    problema: str = Field("", max_length=80)
    sugestao_en: str = Field("", max_length=60)


def _quadro(projeto, cena):
    """Imagem que representa a mídia: a própria foto ou o quadro do meio do vídeo (512 px)."""
    arq = projeto.pasta / cena["midia"]
    destino = projeto.pasta / "midia" / f".aval_{cena['id']:03d}.jpg"
    if destino.exists() and destino.stat().st_mtime >= arq.stat().st_mtime:
        return destino
    # -ss só em vídeo: numa foto ele pula o único quadro e o ffmpeg sai sem gravar nada
    busca = ["-ss", f"{(cena['fim'] - cena['inicio']) / 2:.2f}"] if cena.get("midia_tipo") == "video" else []
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", *busca, "-i", arq, "-frames:v", "1",
                    "-vf", "scale=512:-2", "-q:v", "4", "-update", "1", destino], check=True)
    return destino


def _avaliar(projeto, cenas):
    """Nota de cada mídia para a sua cena. A nota já dada no acervo para a mesma mídia e o mesmo termo é
    reaproveitada (sem chamar o modelo de visão); as novas vão para o acervo."""
    notas, reusadas = {}, 0
    for n, c in enumerate(cenas, 1):
        events.progress(n, len(cenas), f"cena {c['id']}")
        termo = c.get("busca_en") or c["busca"]
        antes = library.avaliacao(c["midia_id"], termo) if c.get("midia_id") else None
        if antes:
            r, reusadas = Nota(nota=antes["nota"], problema=antes["problema"] or ""), reusadas + 1
        else:
            r = local.ask(local.prompt("avaliar", texto=c["texto"], busca=termo),
                                Nota, model=local.VISION, images=[_quadro(projeto, c)], max_tokens=120)
            if r and c.get("midia_id"):
                library.salvar_avaliacao(c["midia_id"], termo, r.nota, r.problema)
        if r:
            c.update(nota_midia=r.nota, problema_midia=r.problema)
            notas[c["id"]] = r
    if reusadas:
        print(f"  {reusadas} notas reaproveitadas do acervo (sem modelo de visão)")
    return notas


def _claude(projeto, plano, fracas):
    """Cenas que o modelo local não resolveu: uma folha com todas para o Claude sugerir novos termos."""
    from esteira.ai import claude
    from esteira.media import folha

    class Troca(BaseModel):
        id: int
        busca_en: str
        tipo: str = Field(pattern="^(video|imagem)$")

    class Resposta(BaseModel):
        trocas: list[Troca]

    fracas = fracas[:16]
    quadros = [(projeto.pasta / c["midia"], (c["fim"] - c["inicio"]) / 2 if c.get("midia_tipo") == "video" else None,
                f"{c['id']}") for c in fracas]
    destino = projeto.caminho("avaliar_claude.jpg")
    folha(projeto, quadros, destino)
    linhas = "\n".join(f"{c['id']}: fala \"{c['texto'][:140]}\" | busca atual \"{c.get('busca_en')}\" | "
                       f"problema: {c.get('problema_midia', '')}" for c in fracas)
    canal = getattr(projeto, "canal", "") or "documentário"
    r = claude.query(
        f"Canal {canal}. A folha mostra o fundo atual de cenas cujas imagens não combinaram com a fala "
        f"(número da cena no canto). Para cada cena, proponha uma busca melhor para Pexels/Pixabay: 2-4 palavras "
        f"em inglês, concretas e filmáveis, que ilustrem a ideia da fala sem ser literal demais, e o tipo "
        f"(video para ambiente/ação, imagem para objeto/pessoa/documento).\n\n{linhas}",
        Resposta, projeto.cfg, projeto.ep, f"mídia: {len(fracas)} cenas fracas", image=destino)
    if not r:
        return False
    por_id = {c["id"]: c for c in plano["cenas"]}
    for t in r.trocas:
        if t.id in por_id:
            por_id[t.id].update(busca_en=t.busca_en, tipo=t.tipo)
            por_id[t.id].pop("nota_midia", None)
    projeto.salvar_json("plano.json", plano)
    return True


def avaliar(projeto, rodadas=2, minimo=3):
    from esteira.media import buscar
    plano = projeto.carregar_json("plano.json")
    alvo = [c for c in plano["cenas"] if c.get("midia") and "nota_midia" not in c]
    for rodada in range(1, rodadas + 2):
        notas = _avaliar(projeto, alvo)
        projeto.salvar_json("plano.json", plano)
        fracas = [c for c in alvo if c["id"] in notas and notas[c["id"]].nota < minimo]
        print(f"  rodada {rodada}: {len(notas)} avaliadas, {len(fracas)} fracas"
              + (f" ({', '.join(str(c['id']) for c in fracas[:20])})" if fracas else ""))
        if not fracas or rodada > rodadas:
            break
        for c in fracas:  # termo sugerido pelo modelo de visão; a mídia atual não volta
            s = notas[c["id"]].sugestao_en.strip()
            if s and s.lower() != (c.get("busca_en") or "").lower():
                c["busca_en"] = s
            c.pop("nota_midia", None)
        projeto.salvar_json("plano.json", plano)
        local.free_gpu()
        buscar(projeto, refazer=True, cenas=[c["id"] for c in fracas])
        plano = projeto.carregar_json("plano.json")
        ids = {c["id"] for c in fracas}
        alvo = [c for c in plano["cenas"] if c["id"] in ids and c.get("midia")]
    fracas = [c for c in plano["cenas"] if c.get("nota_midia", 5) < minimo]
    if fracas and _claude(projeto, plano, fracas):
        buscar(projeto, refazer=True, cenas=[c["id"] for c in fracas])
        plano = projeto.carregar_json("plano.json")
        ids = {c["id"] for c in fracas}
        _avaliar(projeto, [c for c in plano["cenas"] if c["id"] in ids and c.get("midia")])
        projeto.salvar_json("plano.json", plano)
    todas = [c.get("nota_midia") for c in plano["cenas"] if c.get("nota_midia")]
    if todas:
        print(f"  nota média da mídia {sum(todas) / len(todas):.1f}; "
              f"{sum(1 for x in todas if x < minimo)} cenas abaixo de {minimo}")
