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


def _notes_by_time(projeto):
    """[(instante, nota)] das notas de cena do roteiro, pelo tempo da fala que vem depois delas."""
    arq = projeto.caminho("roteiro.json")
    if not arq.exists() or not projeto.caminho("frases.json").exists():
        return []
    from esteira.graphics.plan import _speech_to_sentence
    rot, frases = json.loads(arq.read_text()), projeto.carregar_json("frases.json")
    mapa = _speech_to_sentence(projeto.roteiro().read_text())
    saida = []
    for n in rot.get("notas", []):
        k = mapa[min(n["antes_da_fala"], len(mapa) - 1)] if mapa else 0
        t = next((frases[i]["ini"] for i in range(k, len(frases)) if frases[i]["ini"] is not None), None)
        if t is not None:
            saida.append((t, n["texto"]))
    return saida


def _repeated(termo, anteriores):
    """Mesmo termo, ou 3+ palavras em comum com um termo recente."""
    p = set(termo.lower().split())
    return any(termo.lower() == a.lower() or len(p & set(a.lower().split())) >= 3 for a in anteriores)


def curate(projeto, refazer=False):
    plano = projeto.carregar_json("plano.json")
    cenas = plano["cenas"]
    canal = getattr(projeto, "canal", None) or ""
    notas = _notes_by_time(projeto)
    usados, feitas, falhas = [], 0, 0
    for k, c in enumerate(cenas):
        events.progress(k + 1, len(cenas), f"cena {c['id']}")
        if c.get("busca_definida") or (c.get("curada") and not refazer):
            usados.append(c.get("busca_en") or c["busca"])
            continue
        # a direção de cena vale só para a cena em que ela começa (senão vira o mesmo fundo por 20 s)
        nota = next((n for t, n in notas if c["inicio"] - 0.5 <= t < c["fim"]), "")
        campos = dict(canal=canal or "documentário", estilo=STYLES.get(canal, "documentário dark"),
                      dur=c["fim"] - c["inicio"], texto=c["texto"], antes=cenas[k - 1]["texto"][-160:] if k else "",
                      depois=cenas[k + 1]["texto"][:160] if k + 1 < len(cenas) else "",
                      nota=f'Direção de cena do roteiro: "{nota}"' if nota else "",
                      usados=", ".join(usados[-6:]) or "nenhum")
        r = local.ask(local.prompt("curadoria", **campos), Curation)
        if r and _repeated(r.busca_en, usados[-6:]):
            campos["usados"] += f'. PROIBIDO repetir "{r.busca_en}": escolha outro assunto visual da fala'
            r = local.ask(local.prompt("curadoria", **campos), Curation, temperature=0.7) or r
        if not r:
            falhas += 1
            continue
        if (c.get("busca_en"), c.get("tipo")) != (r.busca_en, r.tipo):
            c.pop("rejeitados", None)  # termo novo: mídias rejeitadas antes podem servir
        c.update(busca_en=r.busca_en, busca=r.busca, tipo=r.tipo, clima=r.clima, curada=True, chave_en=r.chave_en,
                 alternativas=[a for a in r.alternativas if a and a.lower() != r.busca_en.lower()][:2])
        usados.append(r.busca_en)
        feitas += 1
    projeto.salvar_json("plano.json", plano)
    climas = {x: sum(c.get("clima") == x for c in cenas) for x in MOODS}
    print(f"  {feitas} cenas curadas pelo LLM local" + (f"; {falhas} sem resposta (ficam com o termo automático)"
                                                       if falhas else "") + f"; climas {climas}")
