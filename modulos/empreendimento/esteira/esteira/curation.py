"""Etapa curar: o LLM local define busca_en, busca, tipo e clima de cada cena do plano.json.

Cenas com `busca_definida` (vieram de [busca: ...] no roteiro) e cenas já curadas ficam como estão
(`--refazer` cura de novo). A nota de cena do roteiro mais próxima entra no prompt como direção visual.
"""
import json

from pydantic import BaseModel, Field

from esteira.core import events
from esteira.ai import local

STYLES = {
    "finlumia": "finanças pessoais; visual sóbrio de documentário: pessoas comuns, contas, cartões, cidades",
    "cosmoatomico": "astronomia e física; espaço, telescópios, laboratório, natureza em escala épica",
    "benehistory": "história e religião; manuscritos, ruínas, igrejas, arte antiga, paisagens históricas",
    "thiagobenevide": "tecnologia e software; servidores, código, data centers, telas, engenharia",
    "embarcados": "eletrônica embarcada; placas, microcontroladores, solda, sensores, oficina",
}
MOODS = ("tensao", "revelacao", "dado", "respiro", "neutro")


class Curation(BaseModel):
    chave_en: str = Field(max_length=40)
    busca_en: str = Field(max_length=60)
    alternativas: list[str] = Field(default_factory=list, max_length=2)
    busca: str = Field(max_length=60)
    tipo: str = Field(pattern="^(video|imagem)$")
    clima: str = Field(pattern="^(tensao|revelacao|dado|respiro|neutro)$")


def _notes_by_time(project):
    """[(instante, nota)] das notas de cena do roteiro, pelo tempo da fala que vem depois delas."""
    file = project.path_of("roteiro.json")
    if not file.exists() or not project.path_of("frases.json").exists():
        return []
    from esteira.graphics.plan import _speech_to_sentence
    rot, sentences = json.loads(file.read_text()), project.load_json("frases.json")
    mapping = _speech_to_sentence(project.script_path().read_text())
    output = []
    for n in rot.get("notas", []):
        k = mapping[min(n["antes_da_fala"], len(mapping) - 1)] if mapping else 0
        t = next((sentences[i]["ini"] for i in range(k, len(sentences)) if sentences[i]["ini"] is not None), None)
        if t is not None:
            output.append((t, n["texto"]))
    return output


def _repeated(term, previous):
    """Mesmo termo, ou 3+ palavras em comum com um termo recente."""
    p = set(term.lower().split())
    return any(term.lower() == a.lower() or len(p & set(a.lower().split())) >= 3 for a in previous)


def curate(project, redo=False):
    plan = project.load_json("plano.json")
    scenes = plan["cenas"]
    channel = getattr(project, "canal", None) or ""
    notes = _notes_by_time(project)
    used, done, failures = [], 0, 0
    for k, c in enumerate(scenes):
        events.progress(k + 1, len(scenes), f"cena {c['id']}")
        if c.get("busca_definida") or (c.get("curada") and not redo):
            used.append(c.get("busca_en") or c["busca"])
            continue
        # a direção de cena vale só para a cena em que ela começa (senão vira o mesmo fundo por 20 s)
        note = next((n for t, n in notes if c["inicio"] - 0.5 <= t < c["fim"]), "")
        fields = dict(canal=channel or "documentário", estilo=STYLES.get(channel, "documentário dark"),
                      dur=c["fim"] - c["inicio"], texto=c["texto"], antes=scenes[k - 1]["texto"][-160:] if k else "",
                      depois=scenes[k + 1]["texto"][:160] if k + 1 < len(scenes) else "",
                      nota=f'Direção de cena do roteiro: "{note}"' if note else "",
                      usados=", ".join(used[-6:]) or "nenhum")
        r = local.ask(local.prompt("curation", **fields), Curation)
        if r and _repeated(r.busca_en, used[-6:]):
            fields["usados"] += f'. PROIBIDO repetir "{r.busca_en}": escolha outro assunto visual da fala'
            r = local.ask(local.prompt("curation", **fields), Curation, temperature=0.7) or r
        if not r:
            failures += 1
            continue
        if (c.get("busca_en"), c.get("tipo")) != (r.busca_en, r.tipo):
            c.pop("rejeitados", None)  # termo novo: mídias rejeitadas antes podem servir
        c.update(busca_en=r.busca_en, busca=r.busca, tipo=r.tipo, clima=r.clima, curada=True, chave_en=r.chave_en,
                 alternativas=[a for a in r.alternativas if a and a.lower() != r.busca_en.lower()][:2])
        used.append(r.busca_en)
        done += 1
    project.save_json("plano.json", plan)
    moods = {x: sum(c.get("clima") == x for c in scenes) for x in MOODS}
    print(f"  {done} cenas curadas pelo LLM local" + (f"; {failures} sem resposta (ficam com o termo automático)"
                                                       if failures else "") + f"; climas {moods}")
