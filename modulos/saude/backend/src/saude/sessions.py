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

from saude.workouts import Invalid, NotFound, Workouts, _data, _write, _read

REST_DEFAULT = 60
HISTORY = 200  # sessões guardadas
FC_STEP_S = 5  # uma amostra de frequência (o pico) a cada 5 s basta
FC_MAX_SAMPLES = 5000
FIELDS_CLOSING = ("esforco", "notas", "frequencia")


def _iso(t: datetime) -> str:
    return t.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _dt(valor: str) -> datetime:
    return datetime.fromisoformat(valor.replace("Z", "+00:00"))


def meta(repetitions: str) -> dict[str, int | None]:
    """Metas da repetição: "8-12" → mín 8, máx 12; "10 cada lado" → 10; "20 s" ou "2 min" →
    exercício por tempo."""
    text = repetitions.lower()
    if m := re.search(r"(\d+)\s*(s\b|seg|min)", text):
        n = int(m.group(1))
        return {"tempo_s": n * 60 if m.group(2) == "min" else n, "min": None, "max": None}
    numbers = [int(n) for n in re.findall(r"\d+", text)[:2]]
    if not numbers:
        return {"tempo_s": None, "min": None, "max": None}
    return {"tempo_s": None, "min": numbers[0], "max": numbers[-1]}


def _step_load(load: float) -> float:
    return 2.5 if load >= 20 else 1.0


def suggestion(planejado: dict[str, Any], previous: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Progressão dupla a partir das últimas vezes do exercício (mais recente primeiro): bateu o
    máximo de repetições em todas as séries → sobe a carga (ou as repetições, sem carga); ficou
    abaixo do mínimo duas vezes seguidas → tira 10% da carga; abaixo uma vez → mantém."""
    if not previous:
        return None
    m = meta(planejado["repeticoes"])
    last = previous[0]["series"]
    load = next((s["carga_kg"] for s in reversed(last) if s.get("carga_kg") is not None), None)
    if m["tempo_s"]:
        times = [s.get("tempo_s") or 0 for s in last]
        if len(last) >= planejado["series"] and min(times) >= m["tempo_s"]:
            return {"carga_kg": load, "tempo_s": m["tempo_s"] + 10,
                    "motivo": "Completou o tempo em todas as séries: tente +10 s."}
        return None
    if m["max"] is None:
        return None

    def abaixo(series: list[dict[str, Any]]) -> bool:
        return any((s.get("repeticoes") or 0) < (m["min"] or 0) for s in series)

    reps = [s.get("repeticoes") or 0 for s in last]
    if len(last) >= planejado["series"] and min(reps) >= m["max"]:
        if load is None:
            return {"carga_kg": None, "repeticoes": m["max"] + 2,
                    "motivo": f"Fez {m['max']}+ em todas as séries: suba as repetições "
                              "ou ponha carga."}
        new = round(load + _step_load(load), 1)
        return {"carga_kg": new, "repeticoes": m["min"],
                "motivo": f"Fez {m['max']}+ em todas as séries com {load:g} kg: suba a carga."}
    if abaixo(last):
        if load is not None and len(previous) > 1 and abaixo(previous[1]["series"]):
            new = round(load * 0.9 * 2) / 2
            return {"carga_kg": new, "repeticoes": m["min"],
                    "motivo": "Ficou abaixo do mínimo duas vezes seguidas: reduza a carga."}
        return {"carga_kg": load, "repeticoes": m["min"],
                "motivo": "Na última ficou abaixo do mínimo: mantenha a carga."}
    return {"carga_kg": load, "repeticoes": max(reps) + 1 if reps else m["min"],
            "motivo": "Mantenha a carga e busque uma repetição a mais."}


def _closing(s: dict[str, Any], dados: dict[str, Any]) -> None:
    """Esforço, notas e frequência; a frequência medida ao vivo no relógio não é trocada pela do
    Health Connect."""
    for k, v in dados.items():
        if k not in FIELDS_CLOSING:
            continue
        if k == "frequencia" and (s.get("frequencia") or {}).get("origem") == "relogio":
            continue
        s[k] = v


def _fc_of_series(s: dict[str, Any]) -> None:
    """Pico de frequência de cada série (do início da série até ela ser marcada)."""
    samples = s.get("fc_amostras") or []
    if not samples:
        return
    for e in s["exercicios"]:
        for x in e["series"]:
            end = int(_dt(x["feita_em"]).timestamp())
            start = end - (x.get("duracao_s") or 60)
            picos = [b for t, b in samples if start <= t <= end + FC_STEP_S]
            if picos:
                x["fc_max"] = max(picos)


class Sessions:
    def __init__(self, workouts: Workouts, agora: Callable[[], datetime] | None = None) -> None:
        self.workouts = workouts
        self._now = agora or (lambda: datetime.now(UTC))
        self._file = workouts.root / "sessoes.json"

    def _todas(self) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = _read(self._file, [])
        return items

    def _save(self, items: list[dict[str, Any]]) -> None:
        _write(self._file, items[-HISTORY:])

    def _answer(self, s: dict[str, Any]) -> dict[str, Any]:
        return {**s, "agora": _iso(self._now())}

    # --- consulta ---

    def list_all(self, de: str, ate: str) -> list[dict[str, Any]]:
        de, ate = _data(de), _data(ate)
        with self.workouts._lock:
            return [s for s in self._todas() if de <= s["data"] <= ate]

    def ativa(self) -> dict[str, Any] | None:
        with self.workouts._lock:
            items = self._todas()
            for s in reversed(items):
                if s["estado"] == "andamento":
                    if self._normalize(s):
                        self._save(items)
                    return self._answer(s)
        return None

    def session(self, id_: str) -> dict[str, Any]:
        with self.workouts._lock:
            items = self._todas()
            s = self._find(items, id_)
            if self._normalize(s):
                self._save(items)
            return self._answer(s)

    @staticmethod
    def _find(items: list[dict[str, Any]], id_: str) -> dict[str, Any]:
        for s in items:
            if s["id"] == id_:
                return s
        raise NotFound(id_)

    def _previous(self, items: list[dict[str, Any]], exercise_id: str) -> list[dict[str, Any]]:
        """Últimas 2 vezes (mais recente primeiro) em que o exercício teve séries feitas."""
        found = []
        for s in reversed(items):
            if s["estado"] != "concluida":
                continue
            for e in s["exercicios"]:
                if e["exercicio_id"] == exercise_id and e["series"]:
                    found.append({"data": s["data"], "series": e["series"]})
                    break
            if len(found) == 2:
                break
        return found

    # --- início e fim ---

    def iniciar(self, day: str, rest_s: int = REST_DEFAULT) -> dict[str, Any]:
        """Monta a sessão com os exercícios ainda não feitos do dia. Se já houver uma em andamento,
        devolve ela (só uma por vez)."""
        day = _data(day)
        if (current := self.ativa()) is not None:
            return current
        items = [i for i in self.workouts.agenda(day, day) if not i["feito"]]
        if not items:
            raise Invalid("Nenhum exercício pendente neste dia")
        with self.workouts._lock:
            lista = self._todas()
            exercises = []
            for i in items:
                try:
                    ex = self.workouts.exercicio(i["exercicio_id"])
                except NotFound:
                    continue
                planejado = {k: i[k] for k in ("series", "repeticoes", "carga_kg")}
                previous = self._previous(lista, ex["id"])
                exercises.append({
                    "item_id": i["id"], "exercicio_id": ex["id"], "nome": ex["nome"],
                    "instrucoes": ex.get("instrucoes", ""),
                    "equipamento": ex.get("equipamento", ""),
                    "planejado": planejado, "meta": meta(i["repeticoes"]),
                    "anterior": previous[0] if previous else None,
                    "sugestao": suggestion(planejado, previous),
                    "series": [], "pulado": False,
                })
            now = _iso(self._now())
            s = {
                "id": uuid.uuid4().hex[:12], "data": day, "inicio": now, "fim": None,
                "estado": "andamento", "descanso_s": rest_s, "exercicios": exercises,
                "controle": {"fase": "exercicio", "indice": 0, "inicio_serie": now,
                             "descanso_ate": None, "descanso_restante_s": None,
                             "pausado": False, "pausado_em": None, "pausa_total_s": 0},
                "esforco": None, "notas": "", "frequencia": None, "resumo": None,
            }
            lista.append(s)
            self._save(lista)
            return self._answer(s)

    def finish(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        """Fecha a sessão, marca na agenda os exercícios com alguma série e guarda o resumo."""
        with self.workouts._lock:
            items = self._todas()
            s = self._find(items, id_)
            if s["estado"] == "andamento":
                c = s["controle"]
                if c["pausado"]:
                    self._continuar(s)
                now = self._now()
                s.update(estado="concluida", fim=_iso(now))
                c.update(fase="concluida", descanso_ate=None)
                total = (now - _dt(s["inicio"])).total_seconds()
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
                done = [e["item_id"] for e in s["exercicios"] if e["series"]]
            else:
                done = []
            _closing(s, dados)
            _fc_of_series(s)
            self._save(items)
        for item_id in done:
            with suppress(NotFound):
                self.workouts.edit_item(item_id, {"feito": True})
        return self._answer(s)

    def excluir(self, id_: str) -> None:
        with self.workouts._lock:
            items = self._todas()
            s = self._find(items, id_)
            items.remove(s)
            self._save(items)

    def edit(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        """Notas, esforço (1–10) e a frequência cardíaca do relógio, também depois de concluída."""
        with self.workouts._lock:
            items = self._todas()
            s = self._find(items, id_)
            _closing(s, dados)
            self._save(items)
            return self._answer(s)

    # --- frequência cardíaca ao vivo (relógio) ---

    def register_fc(self, id_: str, samples: list[dict[str, Any]]) -> dict[str, Any]:
        """Amostras do sensor do relógio (`em` ISO UTC, `bpm`), enviadas em lotes. Guarda o pico de
        cada 5 s dentro da sessão, a última como `fc_atual` (o celular mostra ao vivo) e recalcula
        `frequencia`, que passa a valer no lugar da lida depois pelo Health Connect."""
        with self.workouts._lock:
            items = self._todas()
            s = self._find(items, id_)
            serie: list[list[int]] = s.setdefault("fc_amostras", [])
            start = int(_dt(s["inicio"]).timestamp())
            end = int(_dt(s["fim"]).timestamp()) if s.get("fim") else None
            for a in sorted(samples, key=lambda a: a["em"]):
                t, bpm = int(_dt(a["em"]).timestamp()), round(float(a["bpm"]))
                if not 25 <= bpm <= 240 or t < start or (end is not None and t > end):
                    continue
                # uma por janela de 5 s, com o pico dela (não perde o máximo da série)
                window = t - t % FC_STEP_S
                if serie and serie[-1][0] == window:
                    serie[-1][1] = max(serie[-1][1], bpm)
                elif not serie or window > serie[-1][0]:
                    serie.append([window, bpm])
                if not s.get("fc_atual") or a["em"] >= s["fc_atual"]["em"]:
                    s["fc_atual"] = {"bpm": bpm, "em": a["em"]}
            del serie[:-FC_MAX_SAMPLES]
            if serie:
                bpms = [b for _, b in serie]
                s["frequencia"] = {
                    "media": round(sum(bpms) / len(bpms)), "maxima": max(bpms),
                    "minima": min(bpms), "amostras": len(bpms), "origem": "relogio",
                }
            if s["estado"] == "concluida":
                _fc_of_series(s)
            elif s["estado"] == "andamento":
                self._normalize(s)
            self._save(items)
            # o relógio usa a fase e o descanso para vibrar com a tela apagada
            e = self._current(s)
            return {"estado": s["estado"], "frequencia": s.get("frequencia"),
                    "fc_atual": s.get("fc_atual"), "controle": s["controle"],
                    "atual": f"{e['nome']} {len(e['series']) + 1}/{e['planejado']['series']}"
                    if e else None,
                    "agora": _iso(self._now())}

    # --- comandos (celular e relógio) ---

    def command(self, id_: str, action: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self.workouts._lock:
            items = self._todas()
            s = self._find(items, id_)
            if s["estado"] != "andamento":
                raise Invalid("A sessão já terminou")
            self._normalize(s)
            fazer = {
                "concluir_serie": self._finish_serie, "pausar": self._pause,
                "continuar": self._continuar, "pular_descanso": self._pular_rest,
                "somar_descanso": self._add_up_rest, "ir_para": self._ir_for,
                "pular_exercicio": self._pular_exercise, "desfazer_serie": self._desfazer_serie,
                "editar_serie": self._edit_serie, "descanso_padrao": self._rest_default,
            }.get(action)
            if fazer is None:
                raise Invalid(f"Comando desconhecido: {action}")
            fazer(s, **dados)
            self._save(items)
            return self._answer(s)

    def _normalize(self, s: dict[str, Any]) -> bool:
        """Descanso vencido vira a próxima série (começando quando o descanso acabou)."""
        c = s["controle"]
        if c["fase"] == "descanso" and not c["pausado"] and c["descanso_ate"]:
            end = _dt(c["descanso_ate"])
            if self._now() >= end:
                c.update(fase="exercicio", inicio_serie=_iso(end), descanso_ate=None)
                return True
        return False

    def _current(self, s: dict[str, Any]) -> dict[str, Any] | None:
        i = s["controle"]["indice"]
        return s["exercicios"][i] if 0 <= i < len(s["exercicios"]) else None

    def _next_index(self, s: dict[str, Any], de: int) -> int:
        """Próximo exercício com séries faltando (depois de `de`, e depois volta ao começo)."""
        n = len(s["exercicios"])
        for k in [*range(de + 1, n), *range(0, de + 1)]:
            e = s["exercicios"][k]
            if not e["pulado"] and len(e["series"]) < e["planejado"]["series"]:
                return k
        return n

    def _descansar(self, s: dict[str, Any], seconds: int) -> None:
        c = s["controle"]
        if c["indice"] >= len(s["exercicios"]):
            c.update(fase="fim", descanso_ate=None)
            return
        c["fase"] = "descanso"
        if c["pausado"]:
            c["descanso_restante_s"] = seconds
        else:
            c["descanso_ate"] = _iso(self._now() + timedelta(seconds=seconds))

    def _finish_serie(self, s: dict[str, Any], repetitions: int | None = None,
                        load_kg: float | None = None, time_s: int | None = None,
                        **_: Any) -> None:
        e = self._current(s)
        if e is None:
            raise Invalid("Não há exercício em andamento")
        c = s["controle"]
        now = self._now()
        sug = e["sugestao"] or {}
        m = e["meta"]
        if time_s is None and m["tempo_s"]:
            time_s = m["tempo_s"]
        if repetitions is None and not m["tempo_s"]:
            repetitions = m["max"]
        if load_kg is None:
            load_kg = sug.get("carga_kg", e["planejado"]["carga_kg"]) if not e["series"] \
                else e["series"][-1].get("carga_kg")
        duration = None
        if c["inicio_serie"] and not c["pausado"]:
            duration = int((now - _dt(c["inicio_serie"])).total_seconds())
        e["series"].append({"repeticoes": repetitions, "carga_kg": load_kg, "tempo_s": time_s,
                            "duracao_s": duration, "feita_em": _iso(now)})
        if len(e["series"]) >= e["planejado"]["series"]:
            c["indice"] = self._next_index(s, c["indice"])
        self._descansar(s, s["descanso_s"])

    def _pause(self, s: dict[str, Any], **_: Any) -> None:
        c = s["controle"]
        if c["pausado"]:
            return
        now = self._now()
        c.update(pausado=True, pausado_em=_iso(now))
        if c["fase"] == "descanso" and c["descanso_ate"]:
            c["descanso_restante_s"] = max(0, int((_dt(c["descanso_ate"]) - now).total_seconds()))
            c["descanso_ate"] = None

    def _continuar(self, s: dict[str, Any], **_: Any) -> None:
        c = s["controle"]
        if not c["pausado"]:
            return
        now = self._now()
        pause = int((now - _dt(c["pausado_em"])).total_seconds())
        c.update(pausado=False, pausado_em=None, pausa_total_s=c["pausa_total_s"] + pause)
        if c["fase"] == "descanso":
            restante = c["descanso_restante_s"] or 0
            c.update(descanso_ate=_iso(now + timedelta(seconds=restante)),
                     descanso_restante_s=None)
        elif c["inicio_serie"]:
            c["inicio_serie"] = _iso(_dt(c["inicio_serie"]) + timedelta(seconds=pause))

    def _pular_rest(self, s: dict[str, Any], **_: Any) -> None:
        c = s["controle"]
        if c["fase"] == "descanso":
            c.update(fase="exercicio", descanso_ate=None, descanso_restante_s=None,
                     inicio_serie=_iso(self._now()))

    def _add_up_rest(self, s: dict[str, Any], seconds: int = 30, **_: Any) -> None:
        c = s["controle"]
        if c["fase"] != "descanso":
            return
        if c["pausado"]:
            c["descanso_restante_s"] = max(0, (c["descanso_restante_s"] or 0) + int(seconds))
        else:
            end = max(_dt(c["descanso_ate"]) + timedelta(seconds=int(seconds)), self._now())
            c["descanso_ate"] = _iso(end)

    def _ir_for(self, s: dict[str, Any], indice: int = 0, **_: Any) -> None:
        if not 0 <= indice < len(s["exercicios"]):
            raise Invalid("Exercício fora da sessão")
        s["exercicios"][indice]["pulado"] = False
        s["controle"].update(indice=indice, fase="exercicio", descanso_ate=None,
                             descanso_restante_s=None, inicio_serie=_iso(self._now()))

    def _pular_exercise(self, s: dict[str, Any], **_: Any) -> None:
        e = self._current(s)
        if e is None:
            return
        e["pulado"] = True
        c = s["controle"]
        c["indice"] = self._next_index(s, c["indice"])
        if c["indice"] >= len(s["exercicios"]):
            c.update(fase="fim", descanso_ate=None)
        else:
            c.update(fase="exercicio", descanso_ate=None, inicio_serie=_iso(self._now()))

    def _desfazer_serie(self, s: dict[str, Any], **_: Any) -> None:
        """Tira a última série feita (do exercício atual ou, sem ela, da mais recente)."""
        c = s["controle"]
        candidates = [(k, e) for k, e in enumerate(s["exercicios"]) if e["series"]]
        if not candidates:
            return
        k, e = max(candidates, key=lambda ke: ke[1]["series"][-1]["feita_em"])
        e["series"].pop()
        c.update(indice=k, fase="exercicio", descanso_ate=None, descanso_restante_s=None,
                 inicio_serie=_iso(self._now()))

    def _edit_serie(self, s: dict[str, Any], exercise: int = 0, serie: int = 0,
                      **fields: Any) -> None:
        try:
            target = s["exercicios"][exercise]["series"][serie]
        except IndexError as e:
            raise Invalid("Série não encontrada") from e
        target.update({k: v for k, v in fields.items() if k in ("repeticoes", "carga_kg", "tempo_s")})

    def _rest_default(self, s: dict[str, Any], seconds: int = REST_DEFAULT,
                         **_: Any) -> None:
        s["descanso_s"] = max(10, min(600, int(seconds)))
