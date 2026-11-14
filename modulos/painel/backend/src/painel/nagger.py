"""Cobrador: metas com ritmo, agenda do dia (sugerida a partir das tarefas e editada pelo usuário),
contestação quando a edição tira ou empurra uma entrega prioritária, e alertas de desvio.

Tudo fica em `cobrador.json` na pasta de dados. Horários da agenda são locais (fuso configurado),
no formato `HH:MM`; datas são `AAAA-MM-DD`."""

import json
import os
import threading
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

PRIORIDADES = {"alta": 0, "media": 1, "baixa": 2}
FREQUENCIAS = ("diaria", "semanal")

# janela padrão do dia sugerido: blocos de foco de 50 min com 10 min de pausa
INICIO_DIA = "08:00"
FIM_DIA = "18:00"
BLOCO_MIN = 50
PAUSA_MIN = 10


class NaoEncontrado(Exception):
    pass


class Invalido(Exception):
    pass


def _min(hhmm: str) -> int:
    try:
        h, m = hhmm.split(":")
        total = int(h) * 60 + int(m)
    except ValueError as e:
        raise Invalido(f"Horário inválido: {hhmm!r}") from e
    if not 0 <= total < 24 * 60:
        raise Invalido(f"Horário inválido: {hhmm!r}")
    return total


def _hhmm(minutos: int) -> str:
    return f"{minutos // 60:02d}:{minutos % 60:02d}"


def _id() -> str:
    return uuid.uuid4().hex[:10]


class Cobrador:
    def __init__(self, raiz: str | Path, fuso: str = "America/Sao_Paulo") -> None:
        self.raiz = Path(raiz).expanduser()
        self.raiz.mkdir(parents=True, exist_ok=True)
        self.fuso = ZoneInfo(fuso)
        self._arquivo = self.raiz / "cobrador.json"
        self._trava = threading.RLock()

    def agora(self) -> datetime:
        return datetime.now(self.fuso)

    def _ler(self) -> dict[str, Any]:
        if not self._arquivo.exists():
            return {"metas": [], "acoes": [], "agendas": {}}
        dados: dict[str, Any] = json.loads(self._arquivo.read_text("utf-8"))
        return dados

    def _gravar(self, dados: dict[str, Any]) -> None:
        tmp = self._arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1), "utf-8")
        os.replace(tmp, self._arquivo)

    # --- metas ---

    def metas(self, hoje: date | None = None) -> list[dict[str, Any]]:
        """Metas com o progresso do período atual (dia ou semana iniciada na segunda)."""
        hoje = hoje or self.agora().date()
        with self._trava:
            dados = self._ler()
        saida = []
        for m in dados["metas"]:
            inicio = hoje if m["frequencia"] == "diaria" else hoje - timedelta(days=hoje.weekday())
            feito = sum(
                a["quantidade"]
                for a in dados["acoes"]
                if a["meta_id"] == m["id"] and inicio.isoformat() <= a["data"] <= hoje.isoformat()
            )
            # ritmo esperado: na semana, proporcional aos dias corridos (seg=1/7 … dom=7/7)
            fracao = 1.0 if m["frequencia"] == "diaria" else (hoje.weekday() + 1) / 7
            saida.append(m | {"feito": feito, "esperado": round(m["alvo"] * fracao, 1)})
        return saida

    def criar_meta(self, d: dict[str, Any]) -> dict[str, Any]:
        if d.get("frequencia", "diaria") not in FREQUENCIAS:
            raise Invalido("Frequência deve ser diaria ou semanal")
        if d.get("alvo", 1) <= 0:
            raise Invalido("Alvo deve ser positivo")
        meta = {
            "id": _id(),
            "titulo": d["titulo"].strip(),
            "frequencia": d.get("frequencia", "diaria"),
            "alvo": d.get("alvo", 1),
            "unidade": d.get("unidade", "vez"),
            "criada_em": self.agora().isoformat(timespec="seconds"),
        }
        with self._trava:
            dados = self._ler()
            dados["metas"].append(meta)
            self._gravar(dados)
        return meta

    def excluir_meta(self, id_: str) -> None:
        with self._trava:
            dados = self._ler()
            if not any(m["id"] == id_ for m in dados["metas"]):
                raise NaoEncontrado(id_)
            dados["metas"] = [m for m in dados["metas"] if m["id"] != id_]
            dados["acoes"] = [a for a in dados["acoes"] if a["meta_id"] != id_]
            self._gravar(dados)

    def registrar_acao(self, meta_id: str, quantidade: float = 1, nota: str = "") -> dict[str, Any]:
        agora = self.agora()
        with self._trava:
            dados = self._ler()
            if not any(m["id"] == meta_id for m in dados["metas"]):
                raise NaoEncontrado(meta_id)
            acao = {
                "id": _id(),
                "meta_id": meta_id,
                "data": agora.date().isoformat(),
                "em": agora.isoformat(timespec="seconds"),
                "quantidade": quantidade,
                "nota": nota,
            }
            dados["acoes"].append(acao)
            self._gravar(dados)
        return acao

    # --- agenda ---

    def agenda(self, dia: str) -> dict[str, Any]:
        date.fromisoformat(dia)
        with self._trava:
            ag = self._ler()["agendas"].get(dia)
        return ag or {"data": dia, "blocos": [], "sugerida": None, "alteracoes": []}

    def sugerir(self, dia: str, tarefas: list[dict[str, Any]]) -> dict[str, Any]:
        """Monta a agenda do dia com as tarefas abertas: prazo vencido/de hoje primeiro, depois
        prioridade e prazo. Guarda a sugestão como referência para contestar mudanças."""
        hoje = date.fromisoformat(dia)
        abertas = [t for t in tarefas if t.get("coluna") != "concluida"]

        def chave(t: dict[str, Any]) -> tuple[int, int, str]:
            prazo = (t.get("prazo") or "9999-12-31")[:10]
            return (
                0 if prazo <= hoje.isoformat() else 1,
                PRIORIDADES.get(t["prioridade"], 1),
                prazo,
            )

        blocos = []
        cursor, fim = _min(INICIO_DIA), _min(FIM_DIA)
        for t in sorted(abertas, key=chave):
            if cursor + BLOCO_MIN > fim:
                break
            blocos.append(
                {
                    "id": _id(),
                    "titulo": t["titulo"],
                    "inicio": _hhmm(cursor),
                    "fim": _hhmm(cursor + BLOCO_MIN),
                    "prioridade": t["prioridade"],
                    "tarefa_id": t["id"],
                    "prazo": t.get("prazo"),
                    "feito": False,
                }
            )
            cursor += BLOCO_MIN + PAUSA_MIN
        ag = {
            "data": dia,
            "blocos": blocos,
            "sugerida": [dict(b) for b in blocos],
            "alteracoes": [],
        }
        with self._trava:
            dados = self._ler()
            dados["agendas"][dia] = ag
            self._gravar(dados)
        return ag

    def salvar(self, dia: str, blocos: list[dict[str, Any]], motivo: str = "") -> dict[str, Any]:
        """Grava a agenda editada e devolve as contestações: entregas prioritárias que saíram do
        dia ou foram empurradas para depois. `motivo` vai para o histórico de alterações."""
        date.fromisoformat(dia)
        for b in blocos:
            if _min(b["inicio"]) >= _min(b["fim"]):
                raise Invalido(f"Bloco {b.get('titulo')!r} termina antes de começar")
            b.setdefault("id", _id())
            b.setdefault("feito", False)
            b.setdefault("prioridade", "media")
        with self._trava:
            dados = self._ler()
            antes = dados["agendas"].get(dia) or self.agenda(dia)
            contestacoes = self._contestar(antes["blocos"], blocos)
            alteracoes = antes.get("alteracoes", []) + [
                {
                    "em": self.agora().isoformat(timespec="seconds"),
                    "motivo": motivo,
                    "contestacoes": contestacoes,
                }
            ]
            ag = antes | {
                "blocos": sorted(blocos, key=lambda b: b["inicio"]),
                "alteracoes": alteracoes,
            }
            dados["agendas"][dia] = ag
            self._gravar(dados)
        return ag | {"contestacoes": contestacoes}

    @staticmethod
    def _contestar(antes: list[dict[str, Any]], depois: list[dict[str, Any]]) -> list[str]:
        novos = {b.get("tarefa_id") or b["titulo"]: b for b in depois}
        saida = []
        for b in antes:
            if b["prioridade"] != "alta" or b.get("feito"):
                continue
            novo = novos.get(b.get("tarefa_id") or b["titulo"])
            prazo = f" (prazo {b['prazo'][:10]})" if b.get("prazo") else ""
            if novo is None:
                saida.append(
                    f"Você tirou do dia “{b['titulo']}”, prioridade alta{prazo}. "
                    "Qual entrega substitui?"
                )
            elif _min(novo["inicio"]) > _min(b["inicio"]) + 120:
                saida.append(
                    f"“{b['titulo']}” foi de {b['inicio']} para {novo['inicio']}{prazo}. "
                    "Empurrar a prioridade para o fim do dia costuma virar adiamento."
                )
        return saida

    def marcar(self, dia: str, bloco_id: str, feito: bool = True) -> dict[str, Any]:
        with self._trava:
            dados = self._ler()
            ag = dados["agendas"].get(dia)
            bloco = next((b for b in (ag or {}).get("blocos", []) if b["id"] == bloco_id), None)
            if bloco is None:
                raise NaoEncontrado(bloco_id)
            bloco["feito"] = feito
            self._gravar(dados)
        return bloco

    # --- cobrança ---

    def disciplina(
        self, tarefas: list[dict[str, Any]], agora: datetime | None = None
    ) -> dict[str, Any]:
        """Retrato do dia: blocos cumpridos até agora, metas no ritmo e a lista de alertas."""
        agora = agora or self.agora()
        dia = agora.date().isoformat()
        minuto = agora.hour * 60 + agora.minute
        ag = self.agenda(dia)
        vencidos = [b for b in ag["blocos"] if _min(b["fim"]) <= minuto]
        feitos = [b for b in vencidos if b["feito"]]
        metas = self.metas(agora.date())
        alertas: list[dict[str, str]] = []

        def alerta(nivel: str, texto: str) -> None:
            alertas.append({"nivel": nivel, "texto": texto})

        if not ag["blocos"] and minuto >= _min(INICIO_DIA):
            alerta("aviso", "Sem agenda para hoje. Peça a sugestão do dia e ajuste.")
        for b in vencidos:
            if not b["feito"]:
                nivel = "critico" if b["prioridade"] == "alta" else "aviso"
                alerta(
                    nivel,
                    f"“{b['titulo']}” ({b['inicio']}–{b['fim']}) passou "
                    "e não foi marcado como feito.",
                )
        atual = next(
            (b for b in ag["blocos"] if _min(b["inicio"]) <= minuto < _min(b["fim"])), None
        )
        for m in metas:
            if m["feito"] < m["esperado"] and (m["frequencia"] == "semanal" or minuto >= 18 * 60):
                alerta(
                    "aviso",
                    f"Meta “{m['titulo']}”: {m['feito']:g} de {m['esperado']:g} "
                    f"{m['unidade']} esperados.",
                )
        na_agenda = {b.get("tarefa_id") for b in ag["blocos"]}
        for t in tarefas:
            prazo = (t.get("prazo") or "")[:10]
            if (
                t.get("coluna") != "concluida"
                and prazo
                and prazo <= dia
                and t["id"] not in na_agenda
            ):
                alerta(
                    "critico",
                    f"“{t['titulo']}” vence {'hoje' if prazo == dia else 'atrasada'} "
                    "e está fora da agenda.",
                )

        metas_ok = sum(m["feito"] >= m["esperado"] for m in metas)
        pontos = [len(feitos) / len(vencidos)] if vencidos else []
        if metas:
            pontos.append(metas_ok / len(metas))
        indice = round(100 * sum(pontos) / len(pontos)) if pontos else None
        return {
            "data": dia,
            "agora": _hhmm(minuto),
            "indice": indice,
            "dentro": indice is None or indice >= 70,
            "blocos": {
                "total": len(ag["blocos"]),
                "vencidos": len(vencidos),
                "feitos": len(feitos),
            },
            "bloco_atual": atual,
            "metas": {"total": len(metas), "no_ritmo": metas_ok},
            "alertas": alertas,
        }

    def contexto(self, tarefas: list[dict[str, Any]]) -> str:
        """Retrato do dia em texto para o prompt do cobrador."""
        return self.momento(tarefas) + "\n" + self.retrato(tarefas)

    def momento(self, tarefas: list[dict[str, Any]]) -> str:
        """O que muda a cada minuto (hora, índice, alertas). Fica fora do prompt de sistema para o
        llama-server reaproveitar o cache do prefixo entre as mensagens."""
        d = self.disciplina(tarefas)
        linhas = [f"Hoje {d['data']}, agora {d['agora']}. Índice de disciplina: {d['indice']}."]
        linhas.append("## Alertas")
        linhas += [f"- [{a['nivel']}] {a['texto']}" for a in d["alertas"]] or ["- nenhum"]
        return "\n".join(linhas)

    def retrato(self, tarefas: list[dict[str, Any]], max_tarefas: int = 40) -> str:
        """Agenda, metas e tarefas abertas (as mais urgentes primeiro, no máximo [max_tarefas])."""
        linhas = ["## Agenda do dia"]
        for b in self.agenda(self.agora().date().isoformat())["blocos"]:
            marca = "x" if b["feito"] else " "
            linhas.append(
                f"- [{marca}] {b['inicio']}–{b['fim']} {b['titulo']} (prioridade {b['prioridade']})"
            )
        linhas.append("\n## Metas")
        for m in self.metas():
            linhas.append(
                f"- {m['titulo']}: {m['feito']:g}/{m['alvo']:g} {m['unidade']} ({m['frequencia']})"
            )
        linhas.append("\n## Tarefas abertas")
        abertas = [t for t in tarefas if t.get("coluna") != "concluida"]
        peso = {"alta": 0, "media": 1, "baixa": 2}
        abertas.sort(
            key=lambda t: (
                t.get("coluna") != "execucao",
                not t.get("prazo"),
                str(t.get("prazo") or ""),
                peso.get(str(t.get("prioridade")), 1),
            )
        )
        for t in abertas[:max_tarefas]:
            prazo = f", prazo {t['prazo']}" if t.get("prazo") else ""
            linhas.append(f"- {t['titulo']} ({t['prioridade']}{prazo}, {t.get('coluna')})")
        if len(abertas) > max_tarefas:
            linhas.append(f"- … e mais {len(abertas) - max_tarefas} tarefas de menor urgência")
        return "\n".join(linhas)
