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

from financas.patterns import CATEGORIES_BASE, QUESTIONNAIRE_BASE


class NotFound(Exception):
    pass


class Invalid(Exception):
    pass


# tipos: str, num, int, bool, data, lista, dict, ref:<colecao>, opcao:<a|b|c>
SCHEMAS: dict[str, dict[str, tuple[str, Any]]] = {
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

REQUIRED = {
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
REFERENCES = {
    "contas": [("transacoes", "conta_id"), ("programacoes", "conta_id"), ("operacoes", "conta_id")],
    "categorias": [
        ("transacoes", "categoria_id"),
        ("regras", "categoria_id"),
        ("metas", "categoria_id"),
        ("programacoes", "categoria_id"),
    ],
}


def _write(caminho: Path, dados: Any) -> None:
    tmp = caminho.with_suffix(".tmp")
    tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1), "utf-8")
    os.replace(tmp, caminho)


def data_iso(valor: Any) -> str:
    try:
        return date.fromisoformat(str(valor)[:10]).isoformat()
    except ValueError as e:
        raise Invalid(f"Data inválida: {valor}") from e


def _convert(field: str, tipo: str, valor: Any) -> Any:
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
            options = tipo[6:].split("|")
            if valor not in options:
                raise Invalid(f"{field}: use {', '.join(o for o in options if o)}")
            return valor
    except (TypeError, ValueError) as e:
        raise Invalid(f"{field}: valor inválido") from e
    raise Invalid(field)


class Warehouse:
    def __init__(self, root: str | Path) -> None:
        self.raiz = Path(root).expanduser()
        self.raiz.mkdir(parents=True, exist_ok=True)
        self.trava = threading.RLock()
        self._cache: dict[str, list[dict[str, Any]]] = {}

    def _arquivo(self, collection: str) -> Path:
        return self.raiz / f"{collection}.json"

    def todos(self, collection: str) -> list[dict[str, Any]]:
        """Lista viva da coleção (não alterar fora de `salvar`)."""
        if collection not in SCHEMAS:
            raise NotFound(collection)
        with self.trava:
            if collection not in self._cache:
                file = self._arquivo(collection)
                if file.exists():
                    self._cache[collection] = json.loads(file.read_text("utf-8"))
                else:
                    self._cache[collection] = self._semente(collection)
                    if self._cache[collection]:
                        self.salvar(collection)
            return self._cache[collection]

    def _semente(self, collection: str) -> list[dict[str, Any]]:
        if collection != "categorias":
            return []
        return [
            self._completar("categorias", {"id": f"cat-{i}", **c})
            for i, c in enumerate(CATEGORIES_BASE)
        ]

    def salvar(self, collection: str) -> None:
        with self.trava:
            _write(self._arquivo(collection), self._cache[collection])

    def _completar(self, collection: str, dados: dict[str, Any]) -> dict[str, Any]:
        doc = {"id": dados.get("id") or uuid.uuid4().hex[:12]}
        for field, (kind, default) in SCHEMAS[collection].items():
            value = dados.get(field, default)
            doc[field] = _convert(field, kind, value if value is not None else default)
        return doc

    def obter(self, collection: str, id_: str) -> dict[str, Any]:
        for d in self.todos(collection):
            if d["id"] == id_:
                return d
        raise NotFound(id_)

    def criar(self, collection: str, dados: dict[str, Any], gravar: bool = True) -> dict[str, Any]:
        with self.trava:
            dados = {k: v for k, v in dados.items() if k != "id"}
            for field in REQUIRED.get(collection, []):
                if dados.get(field) in (None, ""):
                    raise Invalid(f"{field} é obrigatório")
            doc = self._completar(collection, dados)
            if collection == "empresas":
                doc["ticker"] = doc["ticker"].upper()
                if any(e["ticker"] == doc["ticker"] for e in self.todos(collection)):
                    raise Invalid(f"{doc['ticker']} já cadastrada")
            self.todos(collection).append(doc)
            if gravar:
                self.salvar(collection)
            return doc

    def editar(self, collection: str, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self.trava:
            doc = self.obter(collection, id_)
            schema = SCHEMAS[collection]
            new = dict(doc)
            for field, value in dados.items():
                if field in schema:
                    new[field] = _convert(field, schema[field][0], value)
            for field in REQUIRED.get(collection, []):
                if new.get(field) in (None, ""):
                    raise Invalid(f"{field} é obrigatório")
            if collection == "empresas":
                new["ticker"] = new["ticker"].upper()
            doc.update(new)
            self.salvar(collection)
            return doc

    def excluir(self, collection: str, id_: str) -> None:
        with self.trava:
            items = self.todos(collection)
            doc = self.obter(collection, id_)
            items.remove(doc)
            self.salvar(collection)
            for other, field in REFERENCES.get(collection, []):
                mudou = False
                for d in self.todos(other):
                    if d.get(field) == id_:
                        d[field] = ""
                        mudou = True
                if mudou:
                    self.salvar(other)

    def excluir_varios(self, collection: str, ids: list[str]) -> int:
        """Exclusão em lote: grava cada arquivo uma vez só; ids que não existem são ignorados."""
        target = set(ids)
        with self.trava:
            items = self.todos(collection)
            before = len(items)
            items[:] = [d for d in items if d.get("id") not in target]
            removidos = before - len(items)
            if not removidos:
                return 0
            self.salvar(collection)
            for other, field in REFERENCES.get(collection, []):
                mudou = False
                for d in self.todos(other):
                    if d.get(field) in target:
                        d[field] = ""
                        mudou = True
                if mudou:
                    self.salvar(other)
            return removidos

    # --- questionário (modelo editável) ---

    def questionario(self) -> list[dict[str, Any]]:
        file = self.raiz / "questionario.json"
        with self.trava:
            if not file.exists():
                return [dict(p) for p in QUESTIONNAIRE_BASE]
            items: list[dict[str, Any]] = json.loads(file.read_text("utf-8"))
            return items

    def salvar_questionario(self, perguntas: list[dict[str, Any]]) -> list[dict[str, Any]]:
        limpas = []
        ids = set()
        for p in perguntas:
            text = str(p.get("texto", "")).strip()
            if not text:
                continue
            id_ = str(p.get("id") or uuid.uuid4().hex[:8])
            if id_ in ids:
                raise Invalid(f"Pergunta repetida: {id_}")
            ids.add(id_)
            target = p.get("alvo", "empresa")
            if target not in ("empresa", "setor"):
                raise Invalid("alvo: use empresa ou setor")
            limpas.append(
                {
                    "id": id_,
                    "alvo": target,
                    "bloco": str(p.get("bloco", "Geral")).strip() or "Geral",
                    "texto": text,
                    "ajuda": str(p.get("ajuda", "")),
                    "peso": max(0, int(p.get("peso", 1))),
                }
            )
        with self.trava:
            _write(self.raiz / "questionario.json", limpas)
        return limpas
