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


def _file(project):
    return project.folder_path / "estudio" / "apontamentos.json"


def load(project):
    file = _file(project)
    return json.loads(file.read_text()) if file.exists() else {"confirmado": False, "marcas": {}}


def confirmed(project):
    return load(project).get("confirmado", False)


def _spans(project, style):
    from esteira.studio import cut, director
    words = cut.words(project)
    return director.spans(cut.sentences(project), words, style.regras.trecho_max_s)


def marks(project, segments):
    """{índice do trecho: cena marcada} (sem os "auto")."""
    m = load(project).get("marcas", {})
    return {i: m[k] for i, t in enumerate(segments) if (k := normalize(t["texto"])) in m and m[k] != AUTO}


def script(project, style):
    """Trechos com tempo e a marca de cada um, para a tela de apontamento."""
    spans = _spans(project, style)
    m = marks(project, spans)
    d = load(project)
    permitidas = style.regras.cardapio()
    return {"confirmado": d.get("confirmado", False), "em": d.get("em"), "cenas": permitidas,
            "trechos": [{"i": i, "texto": t["texto"], "ini": round(t["ini"], 2), "fim": round(t["fim"], 2),
                         "cena": m.get(i, AUTO)} for i, t in enumerate(spans)]}


def save(project, items, confirm=False):
    """`itens`: [{"texto", "cena"}]; cena fora do cardápio geral é recusada. Mudar as marcas desconfirma."""
    valid = set(SCENES) | {AUTO, NONE}
    bad = sorted({x["cena"] for x in items if x["cena"] not in valid})
    if bad:
        raise ValueError(f"cena inválida: {', '.join(bad)}")
    new = {normalize(x["texto"]): x["cena"] for x in items if x["cena"] != AUTO}
    d = {"confirmado": bool(confirm), "em": datetime.now().isoformat(timespec="seconds") if confirm else None,
         "marcas": new}
    _file(project).parent.mkdir(exist_ok=True)
    _file(project).write_text(json.dumps(d, ensure_ascii=False, indent=1))
    return d
