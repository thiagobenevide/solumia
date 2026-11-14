"""Guia de treino: a sessão do dia em `sessoes.json`, montada a partir da agenda.

O estado (exercício atual, descanso, pausa) fica aqui e só muda por comandos, para que o celular e,
depois, o relógio controlem a mesma sessão. Os tempos são instantes em UTC (`descanso_ate`,
`pausado_em`); quem mostra o cronômetro calcula o que falta com o `agora` da resposta."""

import re
import uuid
from collections.abc import Callable
from contextlib import suppress
from datetime import UTC, datetime, timedelta
from typing import Any

from saude.workouts import Invalido, NaoEncontrado, Treinos, _data, _gravar, _ler

DESCANSO_PADRAO = 60
HISTORICO = 200  # sessões guardadas
FC_PASSO_S = 5  # uma amostra de frequência (o pico) a cada 5 s basta
FC_MAX_AMOSTRAS = 5000
CAMPOS_FECHAMENTO = ("esforco", "notas", "frequencia")


def _iso(t: datetime) -> str:
    return t.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _dt(valor: str) -> datetime:
    return datetime.fromisoformat(valor.replace("Z", "+00:00"))


def meta(repeticoes: str) -> dict[str, int | None]:
    """Metas da repetição: "8-12" → mín 8, máx 12; "10 cada lado" → 10; "20 s" ou "2 min" →
    exercício por tempo."""
    texto = repeticoes.lower()
    if m := re.search(r"(\d+)\s*(s\b|seg|min)", texto):
        n = int(m.group(1))
        return {"tempo_s": n * 60 if m.group(2) == "min" else n, "min": None, "max": None}
    numeros = [int(n) for n in re.findall(r"\d+", texto)[:2]]
    if not numeros:
        return {"tempo_s": None, "min": None, "max": None}
    return {"tempo_s": None, "min": numeros[0], "max": numeros[-1]}


def _passo_carga(carga: float) -> float:
    return 2.5 if carga >= 20 else 1.0


def sugestao(planejado: dict[str, Any], anteriores: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Progressão dupla a partir das últimas vezes do exercício (mais recente primeiro): bateu o
    máximo de repetições em todas as séries → sobe a carga (ou as repetições, sem carga); ficou
    abaixo do mínimo duas vezes seguidas → tira 10% da carga; abaixo uma vez → mantém."""
    if not anteriores:
        return None
    m = meta(planejado["repeticoes"])
    ultima = anteriores[0]["series"]
    carga = next((s["carga_kg"] for s in reversed(ultima) if s.get("carga_kg") is not None), None)
    if m["tempo_s"]:
        tempos = [s.get("tempo_s") or 0 for s in ultima]
        if len(ultima) >= planejado["series"] and min(tempos) >= m["tempo_s"]:
            return {"carga_kg": carga, "tempo_s": m["tempo_s"] + 10,
                    "motivo": "Completou o tempo em todas as séries: tente +10 s."}
        return None
    if m["max"] is None:
        return None

    def abaixo(series: list[dict[str, Any]]) -> bool:
        return any((s.get("repeticoes") or 0) < (m["min"] or 0) for s in series)

    reps = [s.get("repeticoes") or 0 for s in ultima]
    if len(ultima) >= planejado["series"] and min(reps) >= m["max"]:
        if carga is None:
            return {"carga_kg": None, "repeticoes": m["max"] + 2,
                    "motivo": f"Fez {m['max']}+ em todas as séries: suba as repetições "
                              "ou ponha carga."}
        nova = round(carga + _passo_carga(carga), 1)
        return {"carga_kg": nova, "repeticoes": m["min"],
                "motivo": f"Fez {m['max']}+ em todas as séries com {carga:g} kg: suba a carga."}
    if abaixo(ultima):
        if carga is not None and len(anteriores) > 1 and abaixo(anteriores[1]["series"]):
            nova = round(carga * 0.9 * 2) / 2
            return {"carga_kg": nova, "repeticoes": m["min"],
                    "motivo": "Ficou abaixo do mínimo duas vezes seguidas: reduza a carga."}
        return {"carga_kg": carga, "repeticoes": m["min"],
                "motivo": "Na última ficou abaixo do mínimo: mantenha a carga."}
    return {"carga_kg": carga, "repeticoes": max(reps) + 1 if reps else m["min"],
            "motivo": "Mantenha a carga e busque uma repetição a mais."}


def _fechamento(s: dict[str, Any], dados: dict[str, Any]) -> None:
    """Esforço, notas e frequência; a frequência medida ao vivo no relógio não é trocada pela do
    Health Connect."""
    for k, v in dados.items():
        if k not in CAMPOS_FECHAMENTO:
            continue
        if k == "frequencia" and (s.get("frequencia") or {}).get("origem") == "relogio":
            continue
        s[k] = v


def _fc_das_series(s: dict[str, Any]) -> None:
    """Pico de frequência de cada série (do início da série até ela ser marcada)."""
    amostras = s.get("fc_amostras") or []
    if not amostras:
        return
    for e in s["exercicios"]:
        for x in e["series"]:
            fim = int(_dt(x["feita_em"]).timestamp())
            ini = fim - (x.get("duracao_s") or 60)
            picos = [b for t, b in amostras if ini <= t <= fim + FC_PASSO_S]
            if picos:
                x["fc_max"] = max(picos)


class Sessoes:
    def __init__(self, treinos: Treinos, agora: Callable[[], datetime] | None = None) -> None:
        self.treinos = treinos
        self._agora = agora or (lambda: datetime.now(UTC))
        self._arq = treinos.raiz / "sessoes.json"

    def _todas(self) -> list[dict[str, Any]]:
        lista: list[dict[str, Any]] = _ler(self._arq, [])
        return lista

    def _salvar(self, lista: list[dict[str, Any]]) -> None:
        _gravar(self._arq, lista[-HISTORICO:])

    def _resposta(self, s: dict[str, Any]) -> dict[str, Any]:
        return {**s, "agora": _iso(self._agora())}

    # --- consulta ---

    def listar(self, de: str, ate: str) -> list[dict[str, Any]]:
        de, ate = _data(de), _data(ate)
        with self.treinos._trava:
            return [s for s in self._todas() if de <= s["data"] <= ate]

    def ativa(self) -> dict[str, Any] | None:
        with self.treinos._trava:
            lista = self._todas()
            for s in reversed(lista):
                if s["estado"] == "andamento":
                    if self._normalizar(s):
                        self._salvar(lista)
                    return self._resposta(s)
        return None

    def sessao(self, id_: str) -> dict[str, Any]:
        with self.treinos._trava:
            lista = self._todas()
            s = self._achar(lista, id_)
            if self._normalizar(s):
                self._salvar(lista)
            return self._resposta(s)

    @staticmethod
    def _achar(lista: list[dict[str, Any]], id_: str) -> dict[str, Any]:
        for s in lista:
            if s["id"] == id_:
                return s
        raise NaoEncontrado(id_)

    def _anteriores(self, lista: list[dict[str, Any]], exercicio_id: str) -> list[dict[str, Any]]:
        """Últimas 2 vezes (mais recente primeiro) em que o exercício teve séries feitas."""
        achados = []
        for s in reversed(lista):
            if s["estado"] != "concluida":
                continue
            for e in s["exercicios"]:
                if e["exercicio_id"] == exercicio_id and e["series"]:
                    achados.append({"data": s["data"], "series": e["series"]})
                    break
            if len(achados) == 2:
                break
        return achados

    # --- início e fim ---

    def iniciar(self, dia: str, descanso_s: int = DESCANSO_PADRAO) -> dict[str, Any]:
        """Monta a sessão com os exercícios ainda não feitos do dia. Se já houver uma em andamento,
        devolve ela (só uma por vez)."""
        dia = _data(dia)
        if (atual := self.ativa()) is not None:
            return atual
        itens = [i for i in self.treinos.agenda(dia, dia) if not i["feito"]]
        if not itens:
            raise Invalido("Nenhum exercício pendente neste dia")
        with self.treinos._trava:
            lista = self._todas()
            exercicios = []
            for i in itens:
                try:
                    ex = self.treinos.exercicio(i["exercicio_id"])
                except NaoEncontrado:
                    continue
                planejado = {k: i[k] for k in ("series", "repeticoes", "carga_kg")}
                anteriores = self._anteriores(lista, ex["id"])
                exercicios.append({
                    "item_id": i["id"], "exercicio_id": ex["id"], "nome": ex["nome"],
                    "instrucoes": ex.get("instrucoes", ""),
                    "equipamento": ex.get("equipamento", ""),
                    "planejado": planejado, "meta": meta(i["repeticoes"]),
                    "anterior": anteriores[0] if anteriores else None,
                    "sugestao": sugestao(planejado, anteriores),
                    "series": [], "pulado": False,
                })
            agora = _iso(self._agora())
            s = {
                "id": uuid.uuid4().hex[:12], "data": dia, "inicio": agora, "fim": None,
                "estado": "andamento", "descanso_s": descanso_s, "exercicios": exercicios,
                "controle": {"fase": "exercicio", "indice": 0, "inicio_serie": agora,
                             "descanso_ate": None, "descanso_restante_s": None,
                             "pausado": False, "pausado_em": None, "pausa_total_s": 0},
                "esforco": None, "notas": "", "frequencia": None, "resumo": None,
            }
            lista.append(s)
            self._salvar(lista)
            return self._resposta(s)

    def concluir(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        """Fecha a sessão, marca na agenda os exercícios com alguma série e guarda o resumo."""
        with self.treinos._trava:
            lista = self._todas()
            s = self._achar(lista, id_)
            if s["estado"] == "andamento":
                c = s["controle"]
                if c["pausado"]:
                    self._continuar(s)
                agora = self._agora()
                s.update(estado="concluida", fim=_iso(agora))
                c.update(fase="concluida", descanso_ate=None)
                total = (agora - _dt(s["inicio"])).total_seconds()
                series = [x for e in s["exercicios"] for x in e["series"]]
                s["resumo"] = {
                    "duracao_min": round(total / 60, 1),
                    "ativo_min": round((total - c["pausa_total_s"]) / 60, 1),
                    "series_feitas": len(series),
                    "series_planejadas": sum(e["planejado"]["series"] for e in s["exercicios"]),
                    "exercicios_feitos": sum(1 for e in s["exercicios"] if e["series"]),
                    "volume_kg": round(sum((x.get("repeticoes") or 0) * (x.get("carga_kg") or 0)
                                           for x in series), 1),
                }
                feitos = [e["item_id"] for e in s["exercicios"] if e["series"]]
            else:
                feitos = []
            _fechamento(s, dados)
            _fc_das_series(s)
            self._salvar(lista)
        for item_id in feitos:
            with suppress(NaoEncontrado):
                self.treinos.editar_item(item_id, {"feito": True})
        return self._resposta(s)

    def excluir(self, id_: str) -> None:
        with self.treinos._trava:
            lista = self._todas()
            s = self._achar(lista, id_)
            lista.remove(s)
            self._salvar(lista)

    def editar(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        """Notas, esforço (1–10) e a frequência cardíaca do relógio, também depois de concluída."""
        with self.treinos._trava:
            lista = self._todas()
            s = self._achar(lista, id_)
            _fechamento(s, dados)
            self._salvar(lista)
            return self._resposta(s)

    # --- frequência cardíaca ao vivo (relógio) ---

    def registrar_fc(self, id_: str, amostras: list[dict[str, Any]]) -> dict[str, Any]:
        """Amostras do sensor do relógio (`em` ISO UTC, `bpm`), enviadas em lotes. Guarda o pico de
        cada 5 s dentro da sessão, a última como `fc_atual` (o celular mostra ao vivo) e recalcula
        `frequencia`, que passa a valer no lugar da lida depois pelo Health Connect."""
        with self.treinos._trava:
            lista = self._todas()
            s = self._achar(lista, id_)
            serie: list[list[int]] = s.setdefault("fc_amostras", [])
            inicio = int(_dt(s["inicio"]).timestamp())
            fim = int(_dt(s["fim"]).timestamp()) if s.get("fim") else None
            for a in sorted(amostras, key=lambda a: a["em"]):
                t, bpm = int(_dt(a["em"]).timestamp()), round(float(a["bpm"]))
                if not 25 <= bpm <= 240 or t < inicio or (fim is not None and t > fim):
                    continue
                # uma por janela de 5 s, com o pico dela (não perde o máximo da série)
                janela = t - t % FC_PASSO_S
                if serie and serie[-1][0] == janela:
                    serie[-1][1] = max(serie[-1][1], bpm)
                elif not serie or janela > serie[-1][0]:
                    serie.append([janela, bpm])
                if not s.get("fc_atual") or a["em"] >= s["fc_atual"]["em"]:
                    s["fc_atual"] = {"bpm": bpm, "em": a["em"]}
            del serie[:-FC_MAX_AMOSTRAS]
            if serie:
                bpms = [b for _, b in serie]
                s["frequencia"] = {
                    "media": round(sum(bpms) / len(bpms)), "maxima": max(bpms),
                    "minima": min(bpms), "amostras": len(bpms), "origem": "relogio",
                }
            if s["estado"] == "concluida":
                _fc_das_series(s)
            elif s["estado"] == "andamento":
                self._normalizar(s)
            self._salvar(lista)
            # o relógio usa a fase e o descanso para vibrar com a tela apagada
            e = self._atual(s)
            return {"estado": s["estado"], "frequencia": s.get("frequencia"),
                    "fc_atual": s.get("fc_atual"), "controle": s["controle"],
                    "atual": f"{e['nome']} {len(e['series']) + 1}/{e['planejado']['series']}"
                    if e else None,
                    "agora": _iso(self._agora())}

    # --- comandos (celular e relógio) ---

    def comando(self, id_: str, acao: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self.treinos._trava:
            lista = self._todas()
            s = self._achar(lista, id_)
            if s["estado"] != "andamento":
                raise Invalido("A sessão já terminou")
            self._normalizar(s)
            fazer = {
                "concluir_serie": self._concluir_serie, "pausar": self._pausar,
                "continuar": self._continuar, "pular_descanso": self._pular_descanso,
                "somar_descanso": self._somar_descanso, "ir_para": self._ir_para,
                "pular_exercicio": self._pular_exercicio, "desfazer_serie": self._desfazer_serie,
                "editar_serie": self._editar_serie, "descanso_padrao": self._descanso_padrao,
            }.get(acao)
            if fazer is None:
                raise Invalido(f"Comando desconhecido: {acao}")
            fazer(s, **dados)
            self._salvar(lista)
            return self._resposta(s)

    def _normalizar(self, s: dict[str, Any]) -> bool:
        """Descanso vencido vira a próxima série (começando quando o descanso acabou)."""
        c = s["controle"]
        if c["fase"] == "descanso" and not c["pausado"] and c["descanso_ate"]:
            fim = _dt(c["descanso_ate"])
            if self._agora() >= fim:
                c.update(fase="exercicio", inicio_serie=_iso(fim), descanso_ate=None)
                return True
        return False

    def _atual(self, s: dict[str, Any]) -> dict[str, Any] | None:
        i = s["controle"]["indice"]
        return s["exercicios"][i] if 0 <= i < len(s["exercicios"]) else None

    def _proximo_indice(self, s: dict[str, Any], de: int) -> int:
        """Próximo exercício com séries faltando (depois de `de`, e depois volta ao começo)."""
        n = len(s["exercicios"])
        for k in [*range(de + 1, n), *range(0, de + 1)]:
            e = s["exercicios"][k]
            if not e["pulado"] and len(e["series"]) < e["planejado"]["series"]:
                return k
        return n

    def _descansar(self, s: dict[str, Any], segundos: int) -> None:
        c = s["controle"]
        if c["indice"] >= len(s["exercicios"]):
            c.update(fase="fim", descanso_ate=None)
            return
        c["fase"] = "descanso"
        if c["pausado"]:
            c["descanso_restante_s"] = segundos
        else:
            c["descanso_ate"] = _iso(self._agora() + timedelta(seconds=segundos))

    def _concluir_serie(self, s: dict[str, Any], repeticoes: int | None = None,
                        carga_kg: float | None = None, tempo_s: int | None = None,
                        **_: Any) -> None:
        e = self._atual(s)
        if e is None:
            raise Invalido("Não há exercício em andamento")
        c = s["controle"]
        agora = self._agora()
        sug = e["sugestao"] or {}
        m = e["meta"]
        if tempo_s is None and m["tempo_s"]:
            tempo_s = m["tempo_s"]
        if repeticoes is None and not m["tempo_s"]:
            repeticoes = m["max"]
        if carga_kg is None:
            carga_kg = sug.get("carga_kg", e["planejado"]["carga_kg"]) if not e["series"] \
                else e["series"][-1].get("carga_kg")
        duracao = None
        if c["inicio_serie"] and not c["pausado"]:
            duracao = int((agora - _dt(c["inicio_serie"])).total_seconds())
        e["series"].append({"repeticoes": repeticoes, "carga_kg": carga_kg, "tempo_s": tempo_s,
                            "duracao_s": duracao, "feita_em": _iso(agora)})
        if len(e["series"]) >= e["planejado"]["series"]:
            c["indice"] = self._proximo_indice(s, c["indice"])
        self._descansar(s, s["descanso_s"])

    def _pausar(self, s: dict[str, Any], **_: Any) -> None:
        c = s["controle"]
        if c["pausado"]:
            return
        agora = self._agora()
        c.update(pausado=True, pausado_em=_iso(agora))
        if c["fase"] == "descanso" and c["descanso_ate"]:
            c["descanso_restante_s"] = max(0, int((_dt(c["descanso_ate"]) - agora).total_seconds()))
            c["descanso_ate"] = None

    def _continuar(self, s: dict[str, Any], **_: Any) -> None:
        c = s["controle"]
        if not c["pausado"]:
            return
        agora = self._agora()
        pausa = int((agora - _dt(c["pausado_em"])).total_seconds())
        c.update(pausado=False, pausado_em=None, pausa_total_s=c["pausa_total_s"] + pausa)
        if c["fase"] == "descanso":
            restante = c["descanso_restante_s"] or 0
            c.update(descanso_ate=_iso(agora + timedelta(seconds=restante)),
                     descanso_restante_s=None)
        elif c["inicio_serie"]:
            c["inicio_serie"] = _iso(_dt(c["inicio_serie"]) + timedelta(seconds=pausa))

    def _pular_descanso(self, s: dict[str, Any], **_: Any) -> None:
        c = s["controle"]
        if c["fase"] == "descanso":
            c.update(fase="exercicio", descanso_ate=None, descanso_restante_s=None,
                     inicio_serie=_iso(self._agora()))

    def _somar_descanso(self, s: dict[str, Any], segundos: int = 30, **_: Any) -> None:
        c = s["controle"]
        if c["fase"] != "descanso":
            return
        if c["pausado"]:
            c["descanso_restante_s"] = max(0, (c["descanso_restante_s"] or 0) + int(segundos))
        else:
            fim = max(_dt(c["descanso_ate"]) + timedelta(seconds=int(segundos)), self._agora())
            c["descanso_ate"] = _iso(fim)

    def _ir_para(self, s: dict[str, Any], indice: int = 0, **_: Any) -> None:
        if not 0 <= indice < len(s["exercicios"]):
            raise Invalido("Exercício fora da sessão")
        s["exercicios"][indice]["pulado"] = False
        s["controle"].update(indice=indice, fase="exercicio", descanso_ate=None,
                             descanso_restante_s=None, inicio_serie=_iso(self._agora()))

    def _pular_exercicio(self, s: dict[str, Any], **_: Any) -> None:
        e = self._atual(s)
        if e is None:
            return
        e["pulado"] = True
        c = s["controle"]
        c["indice"] = self._proximo_indice(s, c["indice"])
        if c["indice"] >= len(s["exercicios"]):
            c.update(fase="fim", descanso_ate=None)
        else:
            c.update(fase="exercicio", descanso_ate=None, inicio_serie=_iso(self._agora()))

    def _desfazer_serie(self, s: dict[str, Any], **_: Any) -> None:
        """Tira a última série feita (do exercício atual ou, sem ela, da mais recente)."""
        c = s["controle"]
        candidatos = [(k, e) for k, e in enumerate(s["exercicios"]) if e["series"]]
        if not candidatos:
            return
        k, e = max(candidatos, key=lambda ke: ke[1]["series"][-1]["feita_em"])
        e["series"].pop()
        c.update(indice=k, fase="exercicio", descanso_ate=None, descanso_restante_s=None,
                 inicio_serie=_iso(self._agora()))

    def _editar_serie(self, s: dict[str, Any], exercicio: int = 0, serie: int = 0,
                      **campos: Any) -> None:
        try:
            alvo = s["exercicios"][exercicio]["series"][serie]
        except IndexError as e:
            raise Invalido("Série não encontrada") from e
        alvo.update({k: v for k, v in campos.items() if k in ("repeticoes", "carga_kg", "tempo_s")})

    def _descanso_padrao(self, s: dict[str, Any], segundos: int = DESCANSO_PADRAO,
                         **_: Any) -> None:
        s["descanso_s"] = max(10, min(600, int(segundos)))
