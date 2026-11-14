"""Verificação elétrica do esquemático (ERC). Usa as mesmas ligações de `netlist.py` (pinos,
pontas e T de fio na mesma folha; rótulos e símbolos de alimentação ligam entre folhas) e devolve
uma lista de problemas `{nivel: "erro"|"aviso", codigo, mensagem, refs, pinos, rede, folha, x, y}`
(posição em µm quando o problema tem um ponto). Unidades de um mesmo CI (`<lib>:<nome>:<n>`)
podem repetir a ref."""

from typing import Any

from eletronica.library import POR_ID
from eletronica.netlist import _no_segmento, _Uniao, netlist, posicao_pino
from eletronica.projects import BuscaSimbolo

ORDEM = {"erro": 0, "aviso": 1}


def _problema(
    nivel: str,
    codigo: str,
    mensagem: str,
    pinos: list[dict[str, Any]] | None = None,
    refs: list[str] | None = None,
    rede: str | None = None,
    ponto: tuple[str, int, int] | None = None,
) -> dict[str, Any]:
    pinos = pinos or []
    p: dict[str, Any] = {
        "nivel": nivel,
        "codigo": codigo,
        "mensagem": mensagem,
        "refs": refs if refs is not None else sorted({x["ref"] for x in pinos}),
        "pinos": pinos,
        "rede": rede,
    }
    if ponto is not None:
        p["folha"], p["x"], p["y"] = ponto
    return p


def _eh_fonte(simb: dict[str, Any]) -> bool:
    return simb.get("categoria") == "Fontes" or simb.get("prefixo") in ("V", "BT")


def _unidade(id_: str) -> tuple[str, str] | None:
    """(`<lib>:<nome>`, `<n>`) para símbolos de várias unidades; senão None."""
    partes = id_.split(":")
    if len(partes) == 3 and partes[2].isdigit():
        return f"{partes[0]}:{partes[1]}", partes[2]
    return None


def erc(projeto: dict[str, Any], simbolo: BuscaSimbolo = POR_ID.get) -> list[dict[str, Any]]:
    u = _Uniao()
    componentes = projeto.get("componentes", [])
    fios = projeto.get("fios", [])
    rotulos = projeto.get("rotulos", [])
    # (ponto, componente, pino) dos símbolos que não são de alimentação.
    pinos: list[tuple[tuple[str, int, int], dict[str, Any], dict[str, Any]]] = []
    pontos_pino: set[tuple[str, int, int]] = set()
    alimentados: set[Any] = set()  # nós com símbolo de alimentação
    fontes: list[tuple[str, int, int]] = []
    nomes_alimentacao: set[str] = set()

    for c in componentes:
        simb = simbolo(c["simbolo"])
        if simb is None:
            continue
        for pino in simb["pinos"]:
            ponto = (c["folha"], *posicao_pino(c, pino))
            u.achar(ponto)
            pontos_pino.add(ponto)
            if simb["tipo"] == "alimentacao":
                nome = c.get("valor") or simb["valor"]
                nomes_alimentacao.add(nome)
                u.unir(ponto, ("nome", nome))
                alimentados.add(ponto)
            else:
                pinos.append((ponto, c, pino))
                if _eh_fonte(simb):
                    fontes.append(ponto)

    for f in fios:
        cantos = [(f["folha"], x, y) for x, y in f["pontos"]]
        for a in cantos[1:]:
            u.unir(cantos[0], a)
    pontas = [(f["folha"], *f["pontos"][i]) for f in fios for i in (0, -1)]
    pontas += [p for p, _, _ in pinos]
    for f in fios:
        dono = (f["folha"], *f["pontos"][0])
        pts = f["pontos"]
        for folha, x, y in pontas:
            if folha == f["folha"] and any(
                _no_segmento((x, y), pts[i], pts[i + 1]) for i in range(len(pts) - 1)
            ):
                u.unir((folha, x, y), dono)

    nomes_rotulo: dict[str, int] = {}
    raiz_rotulo: dict[Any, str] = {}
    for r in rotulos:
        nome = r["nome"].strip()
        ponto = (r["folha"], r["x"], r["y"])
        u.unir(ponto, ("nome", nome))
        nomes_rotulo[nome] = nomes_rotulo.get(nome, 0) + 1

    for r in rotulos:
        raiz_rotulo.setdefault(u.achar(("nome", r["nome"].strip())), r["nome"].strip())
    raizes_alimentadas = {u.achar(p) for p in alimentados}
    raizes_fonte = {u.achar(p) for p in fontes}

    # Nome da rede igual ao da netlist (mesma ordem de N$k).
    nome_de: dict[tuple[str, str], str] = {}
    for rede in netlist(projeto, simbolo)["redes"]:
        for x in rede["pinos"]:
            nome_de.setdefault((x["ref"], x["pino"]), rede["nome"])

    grupos: dict[Any, list[tuple[tuple[str, int, int], dict[str, Any], dict[str, Any]]]] = {}
    for item in pinos:
        grupos.setdefault(u.achar(item[0]), []).append(item)

    def info(c: dict[str, Any], pino: dict[str, Any]) -> dict[str, Any]:
        return {"ref": c.get("ref", "?"), "pino": pino["n"], "nome": pino["nome"]}

    def rotulo_pino(c: dict[str, Any], pino: dict[str, Any]) -> str:
        nome = f" ({pino['nome']})" if pino["nome"] else ""
        return f"{c.get('ref', '?')} pino {pino['n']}{nome}"

    problemas: list[dict[str, Any]] = []
    for raiz, lista in grupos.items():
        primeiro = lista[0]
        rede = nome_de.get((primeiro[1].get("ref", "?"), primeiro[2]["n"]))
        alimentada = raiz in raizes_alimentadas
        rotulada = raiz in raiz_rotulo
        if len(lista) == 1:
            ponto, c, pino = primeiro
            if rotulada and not alimentada:
                problemas.append(
                    _problema(
                        "aviso",
                        "rede_um_pino",
                        f"A rede {raiz_rotulo[raiz]} liga só {rotulo_pino(c, pino)}.",
                        [info(c, pino)],
                        rede=raiz_rotulo[raiz],
                        ponto=ponto,
                    )
                )
            elif not rotulada and not alimentada and pino.get("tipo") != "nc":
                problemas.append(
                    _problema(
                        "erro",
                        "pino_solto",
                        f"{rotulo_pino(c, pino)} não está ligado a nada.",
                        [info(c, pino)],
                        ponto=ponto,
                    )
                )
        saidas = [(p, c, pino) for p, c, pino in lista if pino.get("tipo") == "saida"]
        if len(saidas) >= 2:
            problemas.append(
                _problema(
                    "erro",
                    "saidas_em_curto",
                    f"{len(saidas)} saídas ligadas na mesma rede {rede}: "
                    + ", ".join(rotulo_pino(c, pino) for _, c, pino in saidas)
                    + ".",
                    [info(c, pino) for _, c, pino in saidas],
                    rede=rede,
                    ponto=saidas[0][0],
                )
            )
        tipos = {pino.get("tipo") for _, _, pino in lista}
        if len(lista) >= 2 and tipos == {"entrada"} and not alimentada:
            problemas.append(
                _problema(
                    "erro",
                    "entrada_sem_acionamento",
                    f"A rede {rede} só liga entradas; nada a aciona.",
                    [info(c, pino) for _, c, pino in lista],
                    rede=rede,
                    ponto=primeiro[0],
                )
            )
        if not alimentada and raiz not in raizes_fonte:
            for ponto, c, pino in lista:
                if pino.get("tipo") == "alimentacao":
                    problemas.append(
                        _problema(
                            "aviso",
                            "alimentacao_sem_fonte",
                            f"{rotulo_pino(c, pino)} é de alimentação, mas a rede não tem "
                            "símbolo de alimentação nem fonte.",
                            [info(c, pino)],
                            rede=rede,
                            ponto=ponto,
                        )
                    )

    # Referências repetidas (menos símbolos de alimentação e unidades diferentes do mesmo CI).
    por_ref: dict[str, list[dict[str, Any]]] = {}
    for c in componentes:
        simb = simbolo(c["simbolo"])
        if simb is not None and simb["tipo"] != "componente":
            continue
        por_ref.setdefault(c.get("ref", "?"), []).append(c)
    for ref, lista in por_ref.items():
        if len(lista) < 2:
            continue
        unidades = [_unidade(c["simbolo"]) for c in lista]
        if (
            all(unidades)
            and len({un[0] for un in unidades if un}) == 1
            and len({un[1] for un in unidades if un}) == len(unidades)
        ):
            continue
        c = lista[1]
        problemas.append(
            _problema(
                "erro",
                "ref_duplicada",
                f"A referência {ref} aparece {len(lista)} vezes.",
                refs=[ref],
                ponto=(c["folha"], c["x"], c["y"]),
            )
        )

    por_posicao: dict[tuple[str, int, int], list[dict[str, Any]]] = {}
    for c in componentes:
        por_posicao.setdefault((c["folha"], c["x"], c["y"]), []).append(c)
    for ponto, lista in por_posicao.items():
        if len(lista) >= 2:
            refs = [c.get("ref", "?") for c in lista]
            problemas.append(
                _problema(
                    "erro",
                    "componentes_sobrepostos",
                    f"Componentes um em cima do outro: {', '.join(refs)}.",
                    refs=refs,
                    ponto=ponto,
                )
            )

    pontos_rotulo = {(r["folha"], r["x"], r["y"]) for r in rotulos}
    for f in fios:
        for i in (0, -1):
            ponta = (f["folha"], *f["pontos"][i])
            if ponta in pontos_pino or ponta in pontos_rotulo:
                continue
            if any(
                g is not f
                and g["folha"] == f["folha"]
                and any(
                    _no_segmento(ponta[1:], g["pontos"][k], g["pontos"][k + 1])
                    for k in range(len(g["pontos"]) - 1)
                )
                for g in fios
            ):
                continue
            problemas.append(
                _problema(
                    "aviso",
                    "fio_solto",
                    "Ponta de fio que não liga a nada.",
                    refs=[],
                    ponto=ponta,
                )
            )

    for r in rotulos:
        nome = r["nome"].strip()
        if nomes_rotulo.get(nome) == 1 and nome not in nomes_alimentacao:
            problemas.append(
                _problema(
                    "aviso",
                    "rotulo_unico",
                    f"O rótulo {nome} aparece uma vez só no projeto.",
                    refs=[],
                    rede=nome,
                    ponto=(r["folha"], r["x"], r["y"]),
                )
            )

    problemas.sort(key=lambda p: ORDEM[p["nivel"]])
    return problemas
