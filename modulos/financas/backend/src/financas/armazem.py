"""Coleções do módulo guardadas em JSON na pasta de dados (`<colecao>.json`, uma lista de documentos
com `id`). Cada coleção tem um esquema simples (campo → tipo, padrão) que valida e completa o que
chega do app; campos fora do esquema são ignorados."""

import json
import os
import threading
import uuid
from datetime import date
from pathlib import Path
from typing import Any

from financas.padroes import CATEGORIAS_BASE, QUESTIONARIO_BASE


class NaoEncontrado(Exception):
    pass


class Invalido(Exception):
    pass


# tipos: str, num, int, bool, data, lista, dict, ref:<colecao>, opcao:<a|b|c>
ESQUEMAS: dict[str, dict[str, tuple[str, Any]]] = {
    "contas": {
        "nome": ("str", ""),
        "tipo": ("opcao:corrente|poupanca|cartao|investimento|carteira", "corrente"),
        "banco": ("str", ""),
        "saldo_inicial": ("num", 0.0),
        "limite": ("num", 0.0),
        "dia_fechamento": ("int", 0),
        "dia_vencimento": ("int", 0),
        "cor": ("str", ""),
        "ativa": ("bool", True),
    },
    "categorias": {
        "nome": ("str", ""),
        "tipo": ("opcao:despesa|receita|investimento|transferencia", "despesa"),
        # grupo da regra 50/30/20
        "grupo": ("opcao:essencial|estilo|futuro|", ""),
        "orcamento_mensal": ("num", 0.0),
        "cor": ("str", ""),
    },
    "transacoes": {
        "data": ("data", None),
        "descricao": ("str", ""),
        "valor": ("num", 0.0),
        "conta_id": ("ref:contas", ""),
        "categoria_id": ("ref:categorias", ""),
        "contraparte": ("str", ""),
        "observacao": ("str", ""),
        "tags": ("lista", []),
        "parcela": ("str", ""),
        "forma_pagamento": (
            "opcao:pix|debito|credito|boleto|ted|doc|transferencia|saque|deposito|tarifa|investimento|dinheiro|outro|",
            "",
        ),
        "programacao_id": ("str", ""),
        "hash": ("str", ""),
        # categoria posta pela IA: a reconferência pode trocar; editar à mão desmarca
        "categoria_ia": ("bool", False),
    },
    "regras": {
        "padrao": ("str", ""),
        "categoria_id": ("ref:categorias", ""),
        "contraparte": ("str", ""),
        "prioridade": ("int", 0),
    },
    "metas": {
        "nome": ("str", ""),
        "valor_alvo": ("num", 0.0),
        "valor_inicial": ("num", 0.0),
        "prazo": ("data", None),
        "categoria_id": ("ref:categorias", ""),
        "descricao": ("str", ""),
        "concluida": ("bool", False),
    },
    "programacoes": {
        "descricao": ("str", ""),
        "valor": ("num", 0.0),
        "conta_id": ("ref:contas", ""),
        "categoria_id": ("ref:categorias", ""),
        "contraparte": ("str", ""),
        "frequencia": ("opcao:mensal|semanal|anual|unica", "mensal"),
        "inicio": ("data", None),
        "fim": ("data", None),
        "ativa": ("bool", True),
    },
    "empresas": {
        "ticker": ("str", ""),
        "nome": ("str", ""),
        "setor": ("str", ""),
        "segmento": ("str", ""),
        "cnpj": ("str", ""),
        "site": ("str", ""),
        "descricao": ("str", ""),
        "status": ("opcao:estudo|observar|aprovada|reprovada|carteira", "estudo"),
        "cotacao": ("num", 0.0),
        "acoes": ("num", 0.0),
        "preco_teto": ("num", 0.0),
        "demonstrativos": ("lista", []),
        "relatorios": ("lista", []),
        "anotacoes": ("lista", []),
        "respostas": ("dict", {}),
        "tese": ("str", ""),
        "riscos": ("str", ""),
    },
    "estudo_progresso": {
        "item": ("str", ""),
        "status": ("opcao:pendente|lendo|feito", "pendente"),
        "nota": ("str", ""),
        "leitura_id": ("str", ""),
    },
    "estudo_livros": {
        "titulo": ("str", ""),
        "autor": ("str", ""),
        "catalogo": ("str", ""),
        "tenho": ("opcao:|sim|nao", ""),
        "guia": ("dict", {}),
    },
    "setores": {
        "nome": ("str", ""),
        "descricao": ("str", ""),
        "respostas": ("dict", {}),
        "anotacoes": ("lista", []),
    },
    "operacoes": {
        "data": ("data", None),
        "ticker": ("str", ""),
        "tipo": ("opcao:compra|venda", "compra"),
        "quantidade": ("num", 0.0),
        "preco": ("num", 0.0),
        "taxas": ("num", 0.0),
        "conta_id": ("ref:contas", ""),
        "observacao": ("str", ""),
    },
    "proventos": {
        "data": ("data", None),
        "ticker": ("str", ""),
        "tipo": ("opcao:dividendo|jcp|rendimento|outro", "dividendo"),
        "valor": ("num", 0.0),
    },
}

OBRIGATORIOS = {
    "contas": ["nome"],
    "categorias": ["nome"],
    "transacoes": ["data", "descricao"],
    "regras": ["padrao"],
    "metas": ["nome"],
    "programacoes": ["descricao", "inicio"],
    "empresas": ["ticker"],
    "setores": ["nome"],
    "estudo_progresso": ["item"],
    "estudo_livros": ["titulo"],
    "operacoes": ["data", "ticker"],
    "proventos": ["data", "ticker"],
}

# ao excluir um documento, limpa as referências a ele nas outras coleções
REFERENCIAS = {
    "contas": [("transacoes", "conta_id"), ("programacoes", "conta_id"), ("operacoes", "conta_id")],
    "categorias": [
        ("transacoes", "categoria_id"),
        ("regras", "categoria_id"),
        ("metas", "categoria_id"),
        ("programacoes", "categoria_id"),
    ],
}


def _gravar(caminho: Path, dados: Any) -> None:
    tmp = caminho.with_suffix(".tmp")
    tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1), "utf-8")
    os.replace(tmp, caminho)


def data_iso(valor: Any) -> str:
    try:
        return date.fromisoformat(str(valor)[:10]).isoformat()
    except ValueError as e:
        raise Invalido(f"Data inválida: {valor}") from e


def _converter(campo: str, tipo: str, valor: Any) -> Any:
    if valor is None:
        return None if tipo == "data" else valor
    try:
        if tipo == "str" or tipo.startswith("ref:"):
            return str(valor).strip()
        if tipo == "num":
            return round(float(valor), 6)
        if tipo == "int":
            return int(valor)
        if tipo == "bool":
            return bool(valor)
        if tipo == "data":
            return data_iso(valor) if valor != "" else None
        if tipo == "lista":
            if not isinstance(valor, list):
                raise TypeError
            return list(valor)
        if tipo == "dict":
            if not isinstance(valor, dict):
                raise TypeError
            return dict(valor)
        if tipo.startswith("opcao:"):
            opcoes = tipo[6:].split("|")
            if valor not in opcoes:
                raise Invalido(f"{campo}: use {', '.join(o for o in opcoes if o)}")
            return valor
    except (TypeError, ValueError) as e:
        raise Invalido(f"{campo}: valor inválido") from e
    raise Invalido(campo)


class Armazem:
    def __init__(self, raiz: str | Path) -> None:
        self.raiz = Path(raiz).expanduser()
        self.raiz.mkdir(parents=True, exist_ok=True)
        self.trava = threading.RLock()
        self._cache: dict[str, list[dict[str, Any]]] = {}

    def _arquivo(self, colecao: str) -> Path:
        return self.raiz / f"{colecao}.json"

    def todos(self, colecao: str) -> list[dict[str, Any]]:
        """Lista viva da coleção (não alterar fora de `salvar`)."""
        if colecao not in ESQUEMAS:
            raise NaoEncontrado(colecao)
        with self.trava:
            if colecao not in self._cache:
                arq = self._arquivo(colecao)
                if arq.exists():
                    self._cache[colecao] = json.loads(arq.read_text("utf-8"))
                else:
                    self._cache[colecao] = self._semente(colecao)
                    if self._cache[colecao]:
                        self.salvar(colecao)
            return self._cache[colecao]

    def _semente(self, colecao: str) -> list[dict[str, Any]]:
        if colecao != "categorias":
            return []
        return [
            self._completar("categorias", {"id": f"cat-{i}", **c})
            for i, c in enumerate(CATEGORIAS_BASE)
        ]

    def salvar(self, colecao: str) -> None:
        with self.trava:
            _gravar(self._arquivo(colecao), self._cache[colecao])

    def _completar(self, colecao: str, dados: dict[str, Any]) -> dict[str, Any]:
        doc = {"id": dados.get("id") or uuid.uuid4().hex[:12]}
        for campo, (tipo, padrao) in ESQUEMAS[colecao].items():
            valor = dados.get(campo, padrao)
            doc[campo] = _converter(campo, tipo, valor if valor is not None else padrao)
        return doc

    def obter(self, colecao: str, id_: str) -> dict[str, Any]:
        for d in self.todos(colecao):
            if d["id"] == id_:
                return d
        raise NaoEncontrado(id_)

    def criar(self, colecao: str, dados: dict[str, Any], gravar: bool = True) -> dict[str, Any]:
        with self.trava:
            dados = {k: v for k, v in dados.items() if k != "id"}
            for campo in OBRIGATORIOS.get(colecao, []):
                if dados.get(campo) in (None, ""):
                    raise Invalido(f"{campo} é obrigatório")
            doc = self._completar(colecao, dados)
            if colecao == "empresas":
                doc["ticker"] = doc["ticker"].upper()
                if any(e["ticker"] == doc["ticker"] for e in self.todos(colecao)):
                    raise Invalido(f"{doc['ticker']} já cadastrada")
            self.todos(colecao).append(doc)
            if gravar:
                self.salvar(colecao)
            return doc

    def editar(self, colecao: str, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self.trava:
            doc = self.obter(colecao, id_)
            esquema = ESQUEMAS[colecao]
            novo = dict(doc)
            for campo, valor in dados.items():
                if campo in esquema:
                    novo[campo] = _converter(campo, esquema[campo][0], valor)
            for campo in OBRIGATORIOS.get(colecao, []):
                if novo.get(campo) in (None, ""):
                    raise Invalido(f"{campo} é obrigatório")
            if colecao == "empresas":
                novo["ticker"] = novo["ticker"].upper()
            doc.update(novo)
            self.salvar(colecao)
            return doc

    def excluir(self, colecao: str, id_: str) -> None:
        with self.trava:
            lista = self.todos(colecao)
            doc = self.obter(colecao, id_)
            lista.remove(doc)
            self.salvar(colecao)
            for outra, campo in REFERENCIAS.get(colecao, []):
                mudou = False
                for d in self.todos(outra):
                    if d.get(campo) == id_:
                        d[campo] = ""
                        mudou = True
                if mudou:
                    self.salvar(outra)

    def excluir_varios(self, colecao: str, ids: list[str]) -> int:
        """Exclusão em lote: grava cada arquivo uma vez só; ids que não existem são ignorados."""
        alvo = set(ids)
        with self.trava:
            lista = self.todos(colecao)
            antes = len(lista)
            lista[:] = [d for d in lista if d.get("id") not in alvo]
            removidos = antes - len(lista)
            if not removidos:
                return 0
            self.salvar(colecao)
            for outra, campo in REFERENCIAS.get(colecao, []):
                mudou = False
                for d in self.todos(outra):
                    if d.get(campo) in alvo:
                        d[campo] = ""
                        mudou = True
                if mudou:
                    self.salvar(outra)
            return removidos

    # --- questionário (modelo editável) ---

    def questionario(self) -> list[dict[str, Any]]:
        arq = self.raiz / "questionario.json"
        with self.trava:
            if not arq.exists():
                return [dict(p) for p in QUESTIONARIO_BASE]
            lista: list[dict[str, Any]] = json.loads(arq.read_text("utf-8"))
            return lista

    def salvar_questionario(self, perguntas: list[dict[str, Any]]) -> list[dict[str, Any]]:
        limpas = []
        ids = set()
        for p in perguntas:
            texto = str(p.get("texto", "")).strip()
            if not texto:
                continue
            id_ = str(p.get("id") or uuid.uuid4().hex[:8])
            if id_ in ids:
                raise Invalido(f"Pergunta repetida: {id_}")
            ids.add(id_)
            alvo = p.get("alvo", "empresa")
            if alvo not in ("empresa", "setor"):
                raise Invalido("alvo: use empresa ou setor")
            limpas.append(
                {
                    "id": id_,
                    "alvo": alvo,
                    "bloco": str(p.get("bloco", "Geral")).strip() or "Geral",
                    "texto": texto,
                    "ajuda": str(p.get("ajuda", "")),
                    "peso": max(0, int(p.get("peso", 1))),
                }
            )
        with self.trava:
            _gravar(self.raiz / "questionario.json", limpas)
        return limpas
