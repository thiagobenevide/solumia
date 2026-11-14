"""Ligações elétricas do esquemático (netlist) e lista de peças (BOM). Liga num mesmo ponto da mesma
folha: pinos, pontas e cantos de fio. A ponta de um fio (ou um pino) que cai no meio de outro fio
também liga (junção em T); fios que só se cruzam não. Rótulos com o mesmo nome e símbolos de
alimentação com o mesmo valor ligam redes entre folhas. A conta da posição do pino é a mesma do app
(`posicaoPino` em `modelos.dart`): espelha em x, gira em passos de 90° no sentido horário da tela (y
para baixo) e soma a posição do componente."""

import csv
import io
import re
from typing import Any

from eletronica.biblioteca import POR_ID
from eletronica.projetos import BuscaSimbolo

Ponto = tuple[str, int, int]  # (folha, x, y)


def posicao_pino(c: dict[str, Any], pino: dict[str, Any]) -> tuple[int, int]:
    x, y = pino["x"], pino["y"]
    if c.get("espelho"):
        x = -x
    for _ in range(c.get("rot", 0) // 90):
        x, y = -y, x
    return c["x"] + x, c["y"] + y


class _Uniao:
    def __init__(self) -> None:
        self.pai: dict[Any, Any] = {}

    def achar(self, a: Any) -> Any:
        self.pai.setdefault(a, a)
        while self.pai[a] != a:
            self.pai[a] = self.pai[self.pai[a]]
            a = self.pai[a]
        return a

    def unir(self, a: Any, b: Any) -> None:
        self.pai[self.achar(a)] = self.achar(b)


def _no_segmento(p: tuple[int, int], a: list[int], b: list[int]) -> bool:
    (x, y), (x1, y1), (x2, y2) = p, a, b
    if (x2 - x1) * (y - y1) != (y2 - y1) * (x - x1):
        return False
    return min(x1, x2) <= x <= max(x1, x2) and min(y1, y2) <= y <= max(y1, y2)


def _chave_natural(ref: str) -> list[Any]:
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", ref)]


def netlist(projeto: dict[str, Any], simbolo: BuscaSimbolo = POR_ID.get) -> dict[str, Any]:
    """`redes` [{nome, pinos: [{ref, pino, nome}]}], `soltos` (pinos sem ligação) e `sondas`
    [{id, tipo, rede | ref}]: a rede onde cada ponta de tensão encosta (None se em nada)."""
    u = _Uniao()
    pinos: list[tuple[Ponto, dict[str, Any], dict[str, Any]]] = []
    nomes: dict[Any, set[str]] = {}

    def nomear(no: Any, nome: str) -> None:
        u.unir(no, ("nome", nome))
        nomes.setdefault(("nome", nome), set()).add(nome)

    for c in projeto.get("componentes", []):
        simb = simbolo(c["simbolo"])
        if simb is None:
            continue
        for pino in simb["pinos"]:
            ponto = (c["folha"], *posicao_pino(c, pino))
            u.achar(ponto)
            if simb["tipo"] == "alimentacao":
                nomear(ponto, c.get("valor") or simb["valor"])
            else:
                pinos.append((ponto, c, pino))

    fios = projeto.get("fios", [])
    for f in fios:
        cantos = [(f["folha"], x, y) for x, y in f["pontos"]]
        for a in cantos[1:]:
            u.unir(cantos[0], a)
    # Pontas de fio e pinos no meio de um fio da mesma folha.
    pontas = [(f["folha"], *f["pontos"][i]) for f in fios for i in (0, -1)]
    pontas += [p for p, _, _ in pinos]
    sondas_v = [s for s in projeto.get("sondas", []) if s.get("tipo") == "v"]
    for s in sondas_v:
        ponto = (s["folha"], s["x"], s["y"])
        u.achar(ponto)
        pontas.append(ponto)
    for f in fios:
        dono = (f["folha"], *f["pontos"][0])
        for folha, x, y in pontas:
            if folha != f["folha"]:
                continue
            pts = f["pontos"]
            if any(_no_segmento((x, y), pts[i], pts[i + 1]) for i in range(len(pts) - 1)):
                u.unir((folha, x, y), dono)

    for r in projeto.get("rotulos", []):
        nomear((r["folha"], r["x"], r["y"]), r["nome"].strip())

    grupos: dict[Any, list[dict[str, Any]]] = {}
    for ponto, c, pino in pinos:
        grupos.setdefault(u.achar(ponto), []).append(
            {"ref": c.get("ref", "?"), "pino": pino["n"], "nome": pino["nome"]}
        )
    nome_de: dict[Any, str] = {}
    for chave, conj in nomes.items():
        nome_de.setdefault(u.achar(chave), sorted(conj)[0])

    redes, soltos, anonimas = [], [], 0
    nome_raiz: dict[Any, str] = dict(nome_de)
    for raiz, lista in sorted(
        grupos.items(), key=lambda kv: _chave_natural(min(p["ref"] for p in kv[1]))
    ):
        lista.sort(key=lambda p: (_chave_natural(p["ref"]), _chave_natural(p["pino"])))
        nome = nome_de.get(raiz)
        if nome is None:
            if len(lista) == 1:
                soltos.extend(lista)
                continue
            anonimas += 1
            nome = f"N${anonimas}"
        nome_raiz[raiz] = nome
        redes.append({"nome": nome, "pinos": lista})
    redes.sort(key=lambda r: _chave_natural(r["nome"]))
    sondas = [
        {"id": s["id"], "tipo": "v", "rede": nome_raiz.get(u.achar((s["folha"], s["x"], s["y"])))}
        for s in sondas_v
    ] + [
        {"id": s["id"], "tipo": "i", "ref": s.get("ref", "")}
        for s in projeto.get("sondas", [])
        if s.get("tipo") == "i"
    ]
    return {"redes": redes, "soltos": soltos, "sondas": sondas}


def bom(projeto: dict[str, Any], simbolo: BuscaSimbolo = POR_ID.get) -> list[dict[str, Any]]:
    """Uma linha por símbolo + valor + encapsulamento, com as referências em ordem natural.
    Unidades de um mesmo CI (U1 A, U1 B) contam uma vez."""
    linhas: dict[tuple[str, str, str], list[str]] = {}
    for c in projeto.get("componentes", []):
        simb = simbolo(c["simbolo"])
        if simb is not None and simb["tipo"] != "componente":
            continue
        nome = simb["nome"].split(" (")[0] if simb else c["simbolo"]
        chave = (nome, c.get("valor", ""), c.get("encapsulamento", ""))
        refs = linhas.setdefault(chave, [])
        if c.get("ref", "?") not in refs:
            refs.append(c.get("ref", "?"))
    saida = [
        {
            "refs": sorted(refs, key=_chave_natural),
            "quantidade": len(refs),
            "descricao": nome,
            "valor": valor,
            "encapsulamento": enc,
        }
        for (nome, valor, enc), refs in linhas.items()
    ]
    return sorted(saida, key=lambda linha: _chave_natural(linha["refs"][0]))


def bom_csv(projeto: dict[str, Any], simbolo: BuscaSimbolo = POR_ID.get) -> str:
    saida = io.StringIO()
    w = csv.writer(saida)
    w.writerow(["Referências", "Quantidade", "Descrição", "Valor", "Encapsulamento"])
    for linha in bom(projeto, simbolo):
        w.writerow(
            [
                " ".join(linha["refs"]),
                linha["quantidade"],
                linha["descricao"],
                linha["valor"],
                linha["encapsulamento"],
            ]
        )
    return saida.getvalue()
