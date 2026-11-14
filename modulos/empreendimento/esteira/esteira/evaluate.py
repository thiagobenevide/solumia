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


class Note(BaseModel):
    nota: int = Field(ge=1, le=5)
    problema: str = Field("", max_length=80)
    sugestao_en: str = Field("", max_length=60)


def _frame(project, cena):
    """Imagem que representa a mídia: a própria foto ou o quadro do meio do vídeo (512 px)."""
    file = project.pasta / cena["midia"]
    destination = project.pasta / "midia" / f".aval_{cena['id']:03d}.jpg"
    if destination.exists() and destination.stat().st_mtime >= file.stat().st_mtime:
        return destination
    # -ss só em vídeo: numa foto ele pula o único quadro e o ffmpeg sai sem gravar nada
    search = ["-ss", f"{(cena['fim'] - cena['inicio']) / 2:.2f}"] if cena.get("midia_tipo") == "video" else []
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", *search, "-i", file, "-frames:v", "1",
                    "-vf", "scale=512:-2", "-q:v", "4", "-update", "1", destination], check=True)
    return destination


def _evaluate(project, cenas):
    """Nota de cada mídia para a sua cena. A nota já dada no acervo para a mesma mídia e o mesmo termo é
    reaproveitada (sem chamar o modelo de visão); as novas vão para o acervo."""
    notes, reused = {}, 0
    for n, c in enumerate(cenas, 1):
        events.progress(n, len(cenas), f"cena {c['id']}")
        term = c.get("busca_en") or c["busca"]
        before = library.evaluation(c["midia_id"], term) if c.get("midia_id") else None
        if before:
            r, reused = Note(nota=before["nota"], problema=before["problema"] or ""), reused + 1
        else:
            r = local.ask(local.prompt("avaliar", texto=c["texto"], busca=term),
                                Note, model=local.VISION, images=[_frame(project, c)], max_tokens=120)
            if r and c.get("midia_id"):
                library.save_evaluation(c["midia_id"], term, r.nota, r.problema)
        if r:
            c.update(nota_midia=r.nota, problema_midia=r.problema)
            notes[c["id"]] = r
    if reused:
        print(f"  {reused} notas reaproveitadas do acervo (sem modelo de visão)")
    return notes


def _claude(project, plan, weak):
    """Cenas que o modelo local não resolveu: uma folha com todas para o Claude sugerir novos termos."""
    from esteira.ai import claude
    from esteira.media import sheet

    class Troca(BaseModel):
        id: int
        busca_en: str
        tipo: str = Field(pattern="^(video|imagem)$")

    class Resposta(BaseModel):
        trocas: list[Troca]

    weak = weak[:16]
    frames = [(project.pasta / c["midia"], (c["fim"] - c["inicio"]) / 2 if c.get("midia_tipo") == "video" else None,
                f"{c['id']}") for c in weak]
    destination = project.caminho("avaliar_claude.jpg")
    sheet(project, frames, destination)
    lines = "\n".join(f"{c['id']}: fala \"{c['texto'][:140]}\" | busca atual \"{c.get('busca_en')}\" | "
                       f"problema: {c.get('problema_midia', '')}" for c in weak)
    channel = getattr(project, "canal", "") or "documentário"
    r = claude.query(
        f"Canal {channel}. A folha mostra o fundo atual de cenas cujas imagens não combinaram com a fala "
        f"(número da cena no canto). Para cada cena, proponha uma busca melhor para Pexels/Pixabay: 2-4 palavras "
        f"em inglês, concretas e filmáveis, que ilustrem a ideia da fala sem ser literal demais, e o tipo "
        f"(video para ambiente/ação, imagem para objeto/pessoa/documento).\n\n{lines}",
        Resposta, project.cfg, project.ep, f"mídia: {len(weak)} cenas fracas", image=destination)
    if not r:
        return False
    by_id = {c["id"]: c for c in plan["cenas"]}
    for t in r.trocas:
        if t.id in by_id:
            by_id[t.id].update(busca_en=t.busca_en, tipo=t.tipo)
            by_id[t.id].pop("nota_midia", None)
    project.salvar_json("plano.json", plan)
    return True


def evaluate(project, rodadas=2, minimum=3):
    from esteira.media import fetch
    plan = project.carregar_json("plano.json")
    target = [c for c in plan["cenas"] if c.get("midia") and "nota_midia" not in c]
    for rounded in range(1, rodadas + 2):
        notes = _evaluate(project, target)
        project.salvar_json("plano.json", plan)
        weak = [c for c in target if c["id"] in notes and notes[c["id"]].nota < minimum]
        print(f"  rodada {rounded}: {len(notes)} avaliadas, {len(weak)} fracas"
              + (f" ({', '.join(str(c['id']) for c in weak[:20])})" if weak else ""))
        if not weak or rounded > rodadas:
            break
        for c in weak:  # termo sugerido pelo modelo de visão; a mídia atual não volta
            s = notes[c["id"]].sugestao_en.strip()
            if s and s.lower() != (c.get("busca_en") or "").lower():
                c["busca_en"] = s
            c.pop("nota_midia", None)
        project.salvar_json("plano.json", plan)
        local.free_gpu()
        fetch(project, refazer=True, cenas=[c["id"] for c in weak])
        plan = project.carregar_json("plano.json")
        ids = {c["id"] for c in weak}
        target = [c for c in plan["cenas"] if c["id"] in ids and c.get("midia")]
    weak = [c for c in plan["cenas"] if c.get("nota_midia", 5) < minimum]
    if weak and _claude(project, plan, weak):
        fetch(project, refazer=True, cenas=[c["id"] for c in weak])
        plan = project.carregar_json("plano.json")
        ids = {c["id"] for c in weak}
        _evaluate(project, [c for c in plan["cenas"] if c["id"] in ids and c.get("midia")])
        project.salvar_json("plano.json", plan)
    everything = [c.get("nota_midia") for c in plan["cenas"] if c.get("nota_midia")]
    if everything:
        print(f"  nota média da mídia {sum(everything) / len(everything):.1f}; "
              f"{sum(1 for x in everything if x < minimum)} cenas abaixo de {minimum}")
