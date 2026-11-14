"""Quadro Kanban guardado em `tarefas.json` na pasta de dados. Cada tarefa tem uma coluna
(pendente, execução, concluída), uma ordem dentro dela e as sessões do temporizador
(`{"inicio", "fim"}` em ISO UTC; `fim` nulo = cronômetro rodando)."""

import json
import os
import threading
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

COLUNAS = ("pendente", "execucao", "concluida")
PRIORIDADES = ("baixa", "media", "alta")
CAMPOS_EDITAVEIS = {"titulo", "descricao", "prioridade", "tags", "prazo"}


class NaoEncontrada(Exception):
    pass


class Invalida(Exception):
    pass


def _agora() -> datetime:
    return datetime.now(UTC)


def _iso(momento: datetime) -> str:
    return momento.isoformat(timespec="seconds")


def _segundos(sessao: dict[str, Any], agora: datetime) -> int:
    fim = datetime.fromisoformat(sessao["fim"]) if sessao["fim"] else agora
    return max(0, int((fim - datetime.fromisoformat(sessao["inicio"])).total_seconds()))


class Quadro:
    def __init__(self, raiz: str | Path) -> None:
        self.raiz = Path(raiz).expanduser()
        self.raiz.mkdir(parents=True, exist_ok=True)
        self._arquivo = self.raiz / "tarefas.json"
        self._trava = threading.RLock()

    def _ler(self) -> list[dict[str, Any]]:
        if not self._arquivo.exists():
            return []
        dados: list[dict[str, Any]] = json.loads(self._arquivo.read_text("utf-8"))
        return dados

    def _gravar(self, tarefas: list[dict[str, Any]]) -> None:
        tmp = self._arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(tarefas, ensure_ascii=False, indent=1), "utf-8")
        os.replace(tmp, self._arquivo)

    @staticmethod
    def _achar(tarefas: list[dict[str, Any]], id_: str) -> dict[str, Any]:
        for t in tarefas:
            if t["id"] == id_:
                return t
        raise NaoEncontrada(id_)

    @staticmethod
    def _publica(t: dict[str, Any], agora: datetime) -> dict[str, Any]:
        """Tarefa com os campos derivados do temporizador."""
        aberta = next((s for s in t["sessoes"] if not s["fim"]), None)
        return {
            **t,
            "tempo_total": sum(_segundos(s, agora) for s in t["sessoes"]),
            "rodando_desde": aberta["inicio"] if aberta else None,
        }

    @staticmethod
    def _validar(dados: dict[str, Any]) -> None:
        if dados.get("prioridade", "media") not in PRIORIDADES:
            raise Invalida(f"Prioridade inválida: {dados['prioridade']}")
        if dados.get("prazo"):
            try:
                datetime.fromisoformat(dados["prazo"])
            except ValueError as e:
                raise Invalida(f"Prazo inválido: {dados['prazo']}") from e

    @staticmethod
    def _parar(t: dict[str, Any], agora: datetime) -> None:
        for s in t["sessoes"]:
            if not s["fim"]:
                s["fim"] = _iso(agora)

    @staticmethod
    def _reordenar(tarefas: list[dict[str, Any]], coluna: str) -> None:
        da_coluna = sorted((t for t in tarefas if t["coluna"] == coluna), key=lambda t: t["ordem"])
        for i, t in enumerate(da_coluna):
            t["ordem"] = i

    # --- consultas ---

    def listar(self) -> list[dict[str, Any]]:
        agora = _agora()
        with self._trava:
            tarefas = self._ler()
        tarefas.sort(key=lambda t: (COLUNAS.index(t["coluna"]), t["ordem"]))
        return [self._publica(t, agora) for t in tarefas]

    def obter(self, id_: str) -> dict[str, Any]:
        with self._trava:
            return self._publica(self._achar(self._ler(), id_), _agora())

    def resumo(self) -> dict[str, Any]:
        """Contagem por coluna, tempo gasto hoje (UTC) e o cronômetro ativo."""
        agora = _agora()
        inicio_dia = agora.replace(hour=0, minute=0, second=0, microsecond=0)
        tarefas = self.listar()
        hoje = 0
        for t in tarefas:
            for s in t["sessoes"]:
                ini = max(datetime.fromisoformat(s["inicio"]), inicio_dia)
                fim = datetime.fromisoformat(s["fim"]) if s["fim"] else agora
                hoje += max(0, int((fim - ini).total_seconds()))
        return {
            "colunas": {c: sum(t["coluna"] == c for t in tarefas) for c in COLUNAS},
            "tempo_hoje": hoje,
            "tempo_total": sum(t["tempo_total"] for t in tarefas),
            "rodando": next((t["id"] for t in tarefas if t["rodando_desde"]), None),
        }

    # --- edição ---

    def criar(self, dados: dict[str, Any]) -> dict[str, Any]:
        self._validar(dados)
        coluna = dados.get("coluna", "pendente")
        if coluna not in COLUNAS:
            raise Invalida(f"Coluna inválida: {coluna}")
        agora = _agora()
        with self._trava:
            tarefas = self._ler()
            t = {
                "id": uuid.uuid4().hex[:12],
                "titulo": dados["titulo"].strip(),
                "descricao": dados.get("descricao", ""),
                "prioridade": dados.get("prioridade", "media"),
                "tags": dados.get("tags", []),
                "prazo": dados.get("prazo"),
                "coluna": coluna,
                "ordem": sum(x["coluna"] == coluna for x in tarefas),
                "criada_em": _iso(agora),
                "concluida_em": _iso(agora) if coluna == "concluida" else None,
                "sessoes": [],
            }
            tarefas.append(t)
            self._gravar(tarefas)
            return self._publica(t, agora)

    def atualizar(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        mudancas = {k: v for k, v in dados.items() if k in CAMPOS_EDITAVEIS and v is not None}
        self._validar(mudancas)
        with self._trava:
            tarefas = self._ler()
            t = self._achar(tarefas, id_)
            t.update(mudancas)
            if "prazo" in dados and dados["prazo"] == "":
                t["prazo"] = None
            self._gravar(tarefas)
            return self._publica(t, _agora())

    def mover(self, id_: str, coluna: str, ordem: int | None = None) -> dict[str, Any]:
        """Leva a tarefa para [coluna] na posição [ordem] (fim da coluna se nula). Concluir para o
        cronômetro; reabrir limpa a data de conclusão."""
        if coluna not in COLUNAS:
            raise Invalida(f"Coluna inválida: {coluna}")
        agora = _agora()
        with self._trava:
            tarefas = self._ler()
            t = self._achar(tarefas, id_)
            origem = t["coluna"]
            destino = sorted(
                (x for x in tarefas if x["coluna"] == coluna and x is not t),
                key=lambda x: x["ordem"],
            )
            pos = len(destino) if ordem is None else max(0, min(ordem, len(destino)))
            destino.insert(pos, t)
            for i, x in enumerate(destino):
                x["ordem"] = i
            t["coluna"] = coluna
            if coluna == "concluida":
                self._parar(t, agora)
                t["concluida_em"] = t["concluida_em"] or _iso(agora)
            else:
                t["concluida_em"] = None
            if origem != coluna:
                self._reordenar(tarefas, origem)
            self._gravar(tarefas)
            return self._publica(t, agora)

    def excluir(self, id_: str) -> None:
        with self._trava:
            tarefas = self._ler()
            t = self._achar(tarefas, id_)
            tarefas.remove(t)
            self._reordenar(tarefas, t["coluna"])
            self._gravar(tarefas)

    # --- temporizador ---

    def iniciar(self, id_: str) -> dict[str, Any]:
        """Um cronômetro por vez: pausa o que estiver rodando e leva a tarefa para execução."""
        agora = _agora()
        with self._trava:
            tarefas = self._ler()
            t = self._achar(tarefas, id_)
            if t["coluna"] == "concluida":
                raise Invalida("Reabra a tarefa antes de iniciar o cronômetro")
            if any(not s["fim"] for s in t["sessoes"]):
                return self._publica(t, agora)
            for outra in tarefas:
                self._parar(outra, agora)
            t["sessoes"].append({"inicio": _iso(agora), "fim": None})
            self._gravar(tarefas)
        if t["coluna"] == "pendente":
            return self.mover(id_, "execucao", 0)
        return self._publica(t, agora)

    def pausar(self, id_: str) -> dict[str, Any]:
        agora = _agora()
        with self._trava:
            tarefas = self._ler()
            t = self._achar(tarefas, id_)
            self._parar(t, agora)
            self._gravar(tarefas)
            return self._publica(t, agora)

    def zerar(self, id_: str) -> dict[str, Any]:
        with self._trava:
            tarefas = self._ler()
            t = self._achar(tarefas, id_)
            t["sessoes"] = []
            self._gravar(tarefas)
            return self._publica(t, _agora())

    # --- LLM ---

    def contexto(self) -> str:
        """Retrato do quadro em texto para o prompt do assistente."""

        def dur(s: int) -> str:
            return f"{s // 3600}h{s % 3600 // 60:02d}min"

        nomes = {"pendente": "Pendentes", "execucao": "Em execução", "concluida": "Concluídas"}
        tarefas = self.listar()
        linhas = [f"Agora (UTC): {_iso(_agora())}"]
        for c in COLUNAS:
            linhas.append(f"\n## {nomes[c]}")
            for t in (x for x in tarefas if x["coluna"] == c):
                extra = [f"prioridade {t['prioridade']}", f"tempo {dur(t['tempo_total'])}"]
                if t["prazo"]:
                    extra.append(f"prazo {t['prazo']}")
                if t["tags"]:
                    extra.append("tags " + ", ".join(t["tags"]))
                if t["rodando_desde"]:
                    extra.append("cronômetro rodando")
                linhas.append(f"- {t['titulo']} ({'; '.join(extra)})")
                if t["descricao"]:
                    linhas.append(f"  {t['descricao'][:300]}")
        return "\n".join(linhas)
