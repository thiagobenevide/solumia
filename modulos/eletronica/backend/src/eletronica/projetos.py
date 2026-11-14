"""Projetos de eletrônica guardados um por arquivo em `projetos/<id>.json` na pasta de dados. O
esquemático fica em `folhas` ([{id, nome}]) e nas listas `componentes` (símbolo da biblioteca,
`ref`, `valor`, `encapsulamento`, posição `x`/`y` em µm, `rot` 0/90/180/270 e `espelho`), `fios`
(`pontos` [[x, y], …]), `rotulos` (nome da rede em `x`/`y`) e `textos`. Todo item diz a sua `folha`.
`versao` sobe a cada gravação: quem grava com uma versão velha recebe [Conflito] (vários
aparelhos)."""

import json
import os
import re
import threading
import uuid
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from eletronica.biblioteca import POR_ID

# Acha o símbolo pelo id (base ou importado); None = desconhecido.
BuscaSimbolo = Callable[[str], dict[str, Any] | None]

LISTAS = ("componentes", "fios", "rotulos", "textos", "sondas")
CAMPOS_EDITAVEIS = {"titulo", "pasta"}
ROTACOES = (0, 90, 180, 270)
_ID = re.compile(r"^[0-9a-f]{32}$")


class NaoEncontrado(Exception):
    pass


class Invalido(Exception):
    pass


class Conflito(Exception):
    def __init__(self, atual: dict[str, Any]) -> None:
        super().__init__("O projeto mudou em outro aparelho")
        self.atual = atual


def _agora() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _eh_peca(simbolo: BuscaSimbolo, id_: str) -> bool:
    s = simbolo(id_)
    return s is None or s["tipo"] == "componente"


def _inteiro(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def validar_esquematico(e: dict[str, Any], simbolo: BuscaSimbolo = POR_ID.get) -> None:
    folhas = e.get("folhas")
    if not isinstance(folhas, list) or not folhas:
        raise Invalido("O projeto precisa de ao menos uma folha")
    if not all(
        isinstance(f, dict) and f.get("id") and isinstance(f.get("nome"), str) for f in folhas
    ):
        raise Invalido("Folhas precisam de id e nome")
    ids_folhas = {f["id"] for f in folhas}
    for lista in LISTAS:
        itens = e.get(lista, [])
        if not isinstance(itens, list):
            raise Invalido(f"{lista} deve ser uma lista")
        for i in itens:
            if not isinstance(i, dict) or not i.get("id") or i.get("folha") not in ids_folhas:
                raise Invalido(f"Item de {lista} sem id ou com folha desconhecida")
    for c in e.get("componentes", []):
        if not isinstance(c.get("simbolo"), str) or simbolo(c["simbolo"]) is None:
            raise Invalido(f"Símbolo desconhecido: {c.get('simbolo')}")
        if not (_inteiro(c.get("x")) and _inteiro(c.get("y"))) or c.get("rot", 0) not in ROTACOES:
            raise Invalido("Componente com posição ou rotação inválida")
    for f in e.get("fios", []):
        pontos = f.get("pontos")
        if not isinstance(pontos, list) or len(pontos) < 2:
            raise Invalido("Fio precisa de ao menos dois pontos")
        if not all(isinstance(p, list) and len(p) == 2 and all(map(_inteiro, p)) for p in pontos):
            raise Invalido("Pontos de fio devem ser [x, y] inteiros (µm)")
    for s in e.get("sondas", []):
        if s.get("tipo") not in ("v", "i") or not (_inteiro(s.get("x")) and _inteiro(s.get("y"))):
            raise Invalido("Sonda precisa de tipo v ou i e posição inteira (µm)")
        if s["tipo"] == "i" and not isinstance(s.get("ref"), str):
            raise Invalido("Sonda de corrente precisa da referência do componente")
    for r in e.get("rotulos", []):
        if not isinstance(r.get("nome"), str) or not r["nome"].strip():
            raise Invalido("Rótulo sem nome")


class Projetos:
    def __init__(self, raiz: str | Path, simbolo: BuscaSimbolo = POR_ID.get) -> None:
        self.simbolo = simbolo
        self.raiz = Path(raiz).expanduser() / "projetos"
        self.raiz.mkdir(parents=True, exist_ok=True)
        self._trava = threading.RLock()

    def _resumo(self, p: dict[str, Any]) -> dict[str, Any]:
        return {
            **{k: v for k, v in p.items() if k not in LISTAS},
            "total": sum(1 for c in p["componentes"] if _eh_peca(self.simbolo, c["simbolo"])),
        }

    def _caminho(self, id_: str) -> Path:
        if not _ID.match(id_):
            raise NaoEncontrado(id_)
        return self.raiz / f"{id_}.json"

    def _ler(self, id_: str) -> dict[str, Any]:
        caminho = self._caminho(id_)
        if not caminho.exists():
            raise NaoEncontrado(id_)
        dados: dict[str, Any] = json.loads(caminho.read_text("utf-8"))
        return dados

    def _gravar(self, p: dict[str, Any]) -> None:
        caminho = self._caminho(p["id"])
        tmp = caminho.with_suffix(".tmp")
        tmp.write_text(json.dumps(p, ensure_ascii=False, separators=(",", ":")), "utf-8")
        os.replace(tmp, caminho)

    def listar(self, pasta: str | None = None) -> list[dict[str, Any]]:
        with self._trava:
            projetos = [self._resumo(self._ler(p.stem)) for p in self.raiz.glob("*.json")]
        if pasta is not None:
            projetos = [p for p in projetos if p["pasta"] == pasta]
        return sorted(projetos, key=lambda p: p["atualizado"], reverse=True)

    def obter(self, id_: str) -> dict[str, Any]:
        with self._trava:
            return self._ler(id_)

    def criar(self, campos: dict[str, Any]) -> dict[str, Any]:
        esquematico = {
            "folhas": campos.get("folhas") or [{"id": "f1", "nome": "Folha 1"}],
            **{lista: campos.get(lista, []) for lista in LISTAS},
        }
        validar_esquematico(esquematico, self.simbolo)
        agora = _agora()
        p = {
            "id": uuid.uuid4().hex,
            "titulo": campos.get("titulo") or "Projeto sem título",
            "pasta": campos.get("pasta", ""),
            "criado": agora,
            "atualizado": agora,
            "versao": 1,
            **esquematico,
        }
        with self._trava:
            self._gravar(p)
        return p

    def editar(self, id_: str, campos: dict[str, Any]) -> dict[str, Any]:
        campos = {k: v for k, v in campos.items() if k in CAMPOS_EDITAVEIS and v is not None}
        with self._trava:
            p = self._ler(id_)
            p.update(campos, atualizado=_agora())
            self._gravar(p)
        return self._resumo(p)

    def salvar(self, id_: str, esquematico: dict[str, Any], versao: int) -> dict[str, Any]:
        """Troca folhas e itens se [versao] for a atual; devolve o resumo com a versão nova."""
        validar_esquematico(esquematico, self.simbolo)
        with self._trava:
            p = self._ler(id_)
            if versao != p["versao"]:
                raise Conflito(p)
            p.update(
                {k: esquematico.get(k, []) for k in ("folhas", *LISTAS)},
                versao=p["versao"] + 1,
                atualizado=_agora(),
            )
            self._gravar(p)
        return self._resumo(p)

    def duplicar(self, id_: str) -> dict[str, Any]:
        p = self.obter(id_)
        return self.criar({**p, "titulo": f"{p['titulo']} (cópia)"})

    def excluir(self, id_: str) -> None:
        with self._trava:
            caminho = self._caminho(id_)
            if not caminho.exists():
                raise NaoEncontrado(id_)
            caminho.unlink()
