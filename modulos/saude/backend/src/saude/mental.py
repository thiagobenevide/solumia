"""Saúde mental em JSON na pasta de dados: `habitos.json` (hábitos a construir ou evitar, com dias
cumpridos), `foco.json` (sessões de foco/pomodoro contra a procrastinação) e `diario.json` (humor,
ansiedade, gatilhos e gratidão por dia)."""

import threading
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

from saude.workouts import Invalido, NaoEncontrado, _gravar, _ler

CAMPOS_HABITO = {"nome", "tipo", "dias_semana", "descricao", "arquivado"}
CAMPOS_DIARIO = {"humor", "ansiedade", "gatilhos", "o_que_fiz", "gratidao", "texto"}


def _data(valor: str) -> date:
    try:
        return date.fromisoformat(valor)
    except ValueError as e:
        raise Invalido(f"Data inválida: {valor}") from e


def sequencia(feitos: set[str], dias_semana: list[int], hoje: date) -> int:
    """Dias previstos seguidos cumpridos até hoje (hoje ainda em aberto não quebra a sequência)."""
    n = 0
    d = hoje
    for _ in range(3660):
        if d.isoweekday() in dias_semana:
            if d.isoformat() in feitos:
                n += 1
            elif d != hoje:
                break
        d -= timedelta(days=1)
    return n


class Mental:
    def __init__(self, raiz: str | Path) -> None:
        self.raiz = Path(raiz).expanduser()
        self.raiz.mkdir(parents=True, exist_ok=True)
        self._trava = threading.RLock()
        self._habitos = self.raiz / "habitos.json"
        self._foco = self.raiz / "foco.json"
        self._diario = self.raiz / "diario.json"

    # --- hábitos ---

    def _com_resumo(self, h: dict[str, Any], de: date, ate: date, hoje: date) -> dict[str, Any]:
        feitos = set(h.get("feitos", []))
        return {
            **{k: v for k, v in h.items() if k != "feitos"},
            "feitos": sorted(d for d in feitos if de.isoformat() <= d <= ate.isoformat()),
            "sequencia": sequencia(feitos, h["dias_semana"], hoje),
            "total": len(feitos),
        }

    def habitos(self, de: str, ate: str, hoje: date | None = None) -> list[dict[str, Any]]:
        d1, d2 = _data(de), _data(ate)
        with self._trava:
            lista = _ler(self._habitos, [])
        return [self._com_resumo(h, d1, d2, hoje or date.today()) for h in lista]

    def _validar(self, dados: dict[str, Any]) -> dict[str, Any]:
        dados = {k: v for k, v in dados.items() if k in CAMPOS_HABITO}
        if "tipo" in dados and dados["tipo"] not in ("construir", "evitar"):
            raise Invalido("tipo: construir ou evitar")
        if "dias_semana" in dados:
            dias = sorted({int(d) for d in dados["dias_semana"]})
            if not dias or dias[0] < 1 or dias[-1] > 7:
                raise Invalido("dias_semana: de 1 (segunda) a 7 (domingo)")
            dados["dias_semana"] = dias
        return dados

    def criar_habito(self, dados: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            lista = _ler(self._habitos, [])
            novo = {
                "id": uuid.uuid4().hex[:12],
                "tipo": "construir",
                "dias_semana": [1, 2, 3, 4, 5, 6, 7],
                "descricao": "",
                "arquivado": False,
                **self._validar(dados),
                "feitos": [],
            }
            lista.append(novo)
            _gravar(self._habitos, lista)
            hoje = date.today()
            return self._com_resumo(novo, hoje, hoje, hoje)

    def _alterar(self, id_: str, mudar: Any) -> dict[str, Any]:
        with self._trava:
            lista = _ler(self._habitos, [])
            for h in lista:
                if h["id"] == id_:
                    mudar(h)
                    _gravar(self._habitos, lista)
                    hoje = date.today()
                    return self._com_resumo(h, hoje - timedelta(days=6), hoje, hoje)
        raise NaoEncontrado(id_)

    def editar_habito(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        validos = self._validar(dados)
        return self._alterar(id_, lambda h: h.update(validos))

    def marcar_habito(self, id_: str, dia: str, feito: bool) -> dict[str, Any]:
        chave = _data(dia).isoformat()

        def mudar(h: dict[str, Any]) -> None:
            feitos = set(h.get("feitos", []))
            if feito:
                feitos.add(chave)
            else:
                feitos.discard(chave)
            h["feitos"] = sorted(feitos)

        return self._alterar(id_, mudar)

    def excluir_habito(self, id_: str) -> None:
        with self._trava:
            lista = _ler(self._habitos, [])
            restantes = [h for h in lista if h["id"] != id_]
            if len(restantes) == len(lista):
                raise NaoEncontrado(id_)
            _gravar(self._habitos, restantes)

    # --- foco ---

    def registrar_foco(self, dados: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            lista = _ler(self._foco, [])
            inicio = dados.get("inicio") or datetime.now().replace(microsecond=0).isoformat()
            try:
                datetime.fromisoformat(inicio)
            except ValueError as e:
                raise Invalido(f"Início inválido: {inicio}") from e
            sessao = {
                "id": uuid.uuid4().hex[:12],
                "inicio": inicio,
                "minutos": dados["minutos"],
                "tarefa": dados.get("tarefa", ""),
                "concluida": dados.get("concluida", True),
                "distracoes": dados.get("distracoes", 0),
            }
            lista.append(sessao)
            _gravar(self._foco, lista)
            return sessao

    def foco(self, de: str, ate: str) -> dict[str, Any]:
        d1, d2 = _data(de).isoformat(), _data(ate).isoformat()
        with self._trava:
            sessoes = [s for s in _ler(self._foco, []) if d1 <= s["inicio"][:10] <= d2]
        por_dia: dict[str, int] = {}
        for s in sessoes:
            if s["concluida"]:
                por_dia[s["inicio"][:10]] = por_dia.get(s["inicio"][:10], 0) + s["minutos"]
        return {"sessoes": sorted(sessoes, key=lambda s: s["inicio"]), "minutos_por_dia": por_dia}

    # --- diário (humor e ansiedade) ---

    def salvar_dia(self, dia: str, dados: dict[str, Any]) -> dict[str, Any]:
        chave = _data(dia).isoformat()
        with self._trava:
            diario: dict[str, Any] = _ler(self._diario, {})
            atual = diario.get(chave, {"data": chave})
            atual.update({k: v for k, v in dados.items() if k in CAMPOS_DIARIO})
            diario[chave] = atual
            _gravar(self._diario, diario)
            return dict(atual)

    def diario(self, de: str, ate: str) -> list[dict[str, Any]]:
        d1, d2 = _data(de).isoformat(), _data(ate).isoformat()
        with self._trava:
            diario: dict[str, Any] = _ler(self._diario, {})
        return [diario[k] for k in sorted(diario) if d1 <= k <= d2]
