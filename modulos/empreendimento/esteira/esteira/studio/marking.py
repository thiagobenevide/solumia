"""Apontamento no roteiro: antes do diretor, a pessoa marca nos trechos da narração cortada qual cena entra.

Cada trecho (o mesmo recorte que o diretor usa: `diretor.trechos`) fica "auto" (a IA local escolhe no cardápio),
"nenhuma" (só a mídia) ou uma cena do cardápio. Numa cena marcada a IA local só preenche âncora, título e valores.
A marca é guardada pelo texto do trecho (normalizado), então sobrevive a um corte refeito que não mude a frase.
Confirmar o apontamento é o que libera o diretor (`estudio.produzir` recusa sem ele).
Arquivo: `<ep>/estudio/apontamentos.json` = {"confirmado", "em", "marcas": {texto normalizado: cena}}.
"""
import json
from datetime import datetime

from esteira.bench import SCENES, normalize

AUTO, NONE = "auto", "nenhuma"


def _file(projeto):
    return projeto.pasta / "estudio" / "apontamentos.json"


def load(projeto):
    arq = _file(projeto)
    return json.loads(arq.read_text()) if arq.exists() else {"confirmado": False, "marcas": {}}


def confirmed(projeto):
    return load(projeto).get("confirmado", False)


def _spans(projeto, estilo):
    from esteira.studio import cut, director
    palavras = cut.words(projeto)
    return director.spans(cut.sentences(projeto), palavras, estilo.regras.trecho_max_s)


def marks(projeto, trechos):
    """{índice do trecho: cena marcada} (sem os "auto")."""
    m = load(projeto).get("marcas", {})
    return {i: m[k] for i, t in enumerate(trechos) if (k := normalize(t["texto"])) in m and m[k] != AUTO}


def script(projeto, estilo):
    """Trechos com tempo e a marca de cada um, para a tela de apontamento."""
    trechos = _spans(projeto, estilo)
    m = marks(projeto, trechos)
    d = load(projeto)
    permitidas = estilo.regras.cardapio()
    return {"confirmado": d.get("confirmado", False), "em": d.get("em"), "cenas": permitidas,
            "trechos": [{"i": i, "texto": t["texto"], "ini": round(t["ini"], 2), "fim": round(t["fim"], 2),
                         "cena": m.get(i, AUTO)} for i, t in enumerate(trechos)]}


def save(projeto, itens, confirmar=False):
    """`itens`: [{"texto", "cena"}]; cena fora do cardápio geral é recusada. Mudar as marcas desconfirma."""
    validas = set(SCENES) | {AUTO, NONE}
    ruins = sorted({x["cena"] for x in itens if x["cena"] not in validas})
    if ruins:
        raise ValueError(f"cena inválida: {', '.join(ruins)}")
    novas = {normalize(x["texto"]): x["cena"] for x in itens if x["cena"] != AUTO}
    d = {"confirmado": bool(confirmar), "em": datetime.now().isoformat(timespec="seconds") if confirmar else None,
         "marcas": novas}
    _file(projeto).parent.mkdir(exist_ok=True)
    _file(projeto).write_text(json.dumps(d, ensure_ascii=False, indent=1))
    return d
