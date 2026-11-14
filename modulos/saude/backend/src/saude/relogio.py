"""Dados do Galaxy Watch (via Samsung Health) por dia em `relogio/dias.json`.

O app no celular lê o Health Connect, soma cada dia e envia (`atualizar`, sobrescreve). O histórico
antigo e o que o Health Connect não recebe (estresse, pontuação do sono) vêm do zip de exportação do
Samsung Health (`importar_samsung`, só preenche o que falta, exceto esses dois campos).
O sono conta no dia em que a pessoa acorda.
"""

import csv
import io
import threading
import zipfile
from collections import defaultdict
from datetime import UTC, date, datetime, timedelta, timezone
from pathlib import Path
from statistics import mean
from typing import IO, Any

from saude.treinos import Invalido, _gravar, _ler

CAMPOS_NUMERICOS = {
    # atividade
    "passos",
    "distancia_km",
    "andares",
    "calorias_ativas",
    "calorias_total",
    "minutos_ativos",
    "agua_ml",
    # sono (minutos)
    "sono_min",
    "sono_profundo_min",
    "sono_leve_min",
    "sono_rem_min",
    "sono_acordado_min",
    "sono_pontuacao",
    # coração e respiração
    "fc_media",
    "fc_min",
    "fc_max",
    "fc_repouso",
    "hrv_ms",
    "spo2",
    "respiracao",
    "pressao_sistolica",
    "pressao_diastolica",
    "estresse",
    # corpo
    "peso_kg",
    "gordura_pct",
    "massa_magra_kg",
}
CAMPOS_TEXTO = {"sono_inicio", "sono_fim"}  # "HH:MM" local
CAMPOS = CAMPOS_NUMERICOS | CAMPOS_TEXTO | {"exercicios"}
SO_DA_EXPORTACAO = {"estresse", "sono_pontuacao"}  # o Health Connect não recebe

METAS = {"passos": 8000, "sono_min": 420, "minutos_ativos": 30, "agua_ml": 2000}


def _dia(valor: str) -> str:
    try:
        return date.fromisoformat(valor).isoformat()
    except (TypeError, ValueError) as e:
        raise Invalido(f"Data inválida: {valor}") from e


def pontuar_sono(d: dict[str, Any]) -> int | None:
    """Nota 0–100 da noite pelos estágios, nos moldes da do Samsung Health (que não vai ao Health
    Connect): duração (meta 8 h), eficiência (tempo acordado na cama), sono profundo (~20%) e REM
    (~22%). Sem estágios, só as partes que existem entram, reescaladas para 100."""
    dormido = d.get("sono_min")
    if not isinstance(dormido, int | float) or dormido < 60:
        return None

    def faixa(v: float, ruim: float, bom: float) -> float:
        return max(0.0, min(1.0, (v - ruim) / (bom - ruim)))

    partes = [(40, faixa(dormido, 240, 480))]  # 4 h = 0, 8 h = cheio
    acordado = d.get("sono_acordado_min")
    if isinstance(acordado, int | float):
        partes.append((20, faixa(dormido / (dormido + acordado), 0.75, 0.95)))
    profundo, rem = d.get("sono_profundo_min"), d.get("sono_rem_min")
    if isinstance(profundo, int | float) and isinstance(rem, int | float) and profundo + rem > 0:
        partes.append((20, faixa(profundo / dormido, 0.05, 0.18)))
        partes.append((20, faixa(rem / dormido, 0.08, 0.20)))
    peso = sum(p for p, _ in partes)
    return round(sum(p * v for p, v in partes) * 100 / peso)


def _limpar(dados: dict[str, Any]) -> dict[str, Any]:
    saida: dict[str, Any] = {}
    for k, v in dados.items():
        if k not in CAMPOS or v is None:
            continue
        if k in CAMPOS_NUMERICOS:
            try:
                saida[k] = round(float(v), 2)
            except (TypeError, ValueError) as e:
                raise Invalido(f"{k}: número inválido") from e
        elif k in CAMPOS_TEXTO:
            saida[k] = str(v)[:5]
        elif isinstance(v, list):
            saida[k] = [
                {
                    c: e[c]
                    for c in ("tipo", "inicio", "minutos", "calorias", "distancia_km")
                    if c in e
                }
                for e in v
                if isinstance(e, dict)
            ][:30]
    return saida


class Relogio:
    def __init__(self, raiz: str | Path) -> None:
        self.raiz = Path(raiz).expanduser()
        self.raiz.mkdir(parents=True, exist_ok=True)
        self._trava = threading.RLock()
        self._dias = self.raiz / "dias.json"
        self._analises = self.raiz / "analises.json"
        self._estado = self.raiz / "estado.json"

    def dias(self, de: str, ate: str) -> list[dict[str, Any]]:
        d1, d2 = _dia(de), _dia(ate)
        with self._trava:
            todos: dict[str, Any] = _ler(self._dias, {})
        saida = [{"data": k, **todos[k]} for k in sorted(todos) if d1 <= k <= d2]
        for d in saida:  # sem a nota do Samsung (só vem na exportação), calcula a nossa
            if "sono_pontuacao" not in d and (nota := pontuar_sono(d)) is not None:
                d["sono_pontuacao"] = nota
                d["sono_pontuacao_estimada"] = True
        return saida

    def atualizar(
        self, dias: list[dict[str, Any]], sobrescrever: bool = True, origem: str = ""
    ) -> int:
        """Grava os dias; com [sobrescrever]=False só preenche campos vazios (menos os exclusivos
        da exportação, que sempre entram)."""
        with self._trava:
            todos: dict[str, Any] = _ler(self._dias, {})
            n = 0
            for d in dias:
                chave = _dia(d.get("data", ""))
                novos = _limpar(d)
                if not novos:
                    continue
                atual = todos.setdefault(chave, {})
                for k, v in novos.items():
                    if sobrescrever or k in SO_DA_EXPORTACAO or k not in atual:
                        atual[k] = v
                n += 1
            _gravar(self._dias, todos)
            if origem:
                estado = _ler(self._estado, {})
                estado[origem] = datetime.now(UTC).isoformat(timespec="seconds")
                _gravar(self._estado, estado)
            return n

    def estado(self) -> dict[str, Any]:
        """Última sincronização de cada origem (`health_connect`, `exportacao`)."""
        with self._trava:
            return dict(_ler(self._estado, {}))

    def resumo(self, de: str, ate: str) -> dict[str, Any]:
        """Média de cada métrica nos dias que a têm e quantos dias bateram cada meta."""
        dias = self.dias(de, ate)
        medias: dict[str, float] = {}
        for k in CAMPOS_NUMERICOS:
            valores = [d[k] for d in dias if isinstance(d.get(k), int | float)]
            if valores:
                medias[k] = round(mean(valores), 1)
        metas = {
            k: {
                "meta": m,
                "batidos": sum(1 for d in dias if d.get(k, 0) >= m),
                "dias": sum(1 for d in dias if k in d),
            }
            for k, m in METAS.items()
        }
        return {
            "de": _dia(de),
            "ate": _dia(ate),
            "dias": len(dias),
            "medias": medias,
            "metas": metas,
        }

    # --- análises da LLM local ---

    def analises(self) -> list[dict[str, Any]]:
        with self._trava:
            return list(_ler(self._analises, []))

    def guardar_analise(self, analise: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            lista = [analise, *_ler(self._analises, [])][:20]
            _gravar(self._analises, lista)
        return analise

    # --- exportação do Samsung Health ---

    def importar_samsung(self, arquivo: IO[bytes]) -> dict[str, Any]:
        try:
            with zipfile.ZipFile(arquivo) as z:
                dias, lidos = ler_exportacao(z)
        except zipfile.BadZipFile as e:
            raise Invalido("Envie o .zip da exportação do Samsung Health") from e
        if not lidos:
            raise Invalido("Nenhum CSV do Samsung Health reconhecido no zip")
        n = self.atualizar(dias, sobrescrever=False, origem="exportacao")
        return {"dias": n, "arquivos": lidos}


# ---------------------------------------------------------------- CSVs da exportação
#
# Cada CSV tem uma linha de metadados, o cabeçalho e as linhas. As colunas às vezes vêm com o
# prefixo do tipo (`com.samsung.health.heart_rate.heart_rate`); usamos só o fim do nome. Os horários
# estão em UTC, com o fuso na coluna `time_offset` ("UTC-0300").

ESTAGIOS = {
    "40001": "sono_acordado_min",
    "40002": "sono_leve_min",
    "40003": "sono_profundo_min",
    "40004": "sono_rem_min",
}
EXERCICIOS = {
    "1001": "caminhada",
    "1002": "corrida",
    "11007": "bicicleta",
    "13001": "trilha",
    "14001": "natação",
    "15003": "bicicleta ergométrica",
    "15004": "musculação",
    "15005": "elíptico",
    "10007": "boxe",
}


def _linhas(z: zipfile.ZipFile, nome: str) -> list[dict[str, str]]:
    texto = z.read(nome).decode("utf-8-sig", "replace")
    partes = texto.split("\n", 1)
    if len(partes) < 2:
        return []
    leitor = csv.reader(io.StringIO(partes[1]))
    cabecalho = [c.rsplit(".", 1)[-1].strip() for c in next(leitor, [])]
    return [dict(zip(cabecalho, linha, strict=False)) for linha in leitor if linha]


def _fuso(texto: str) -> timezone:
    t = (texto or "").replace("UTC", "").strip()
    if len(t) == 5 and t[0] in "+-" and t[1:].isdigit():
        minutos = int(t[1:3]) * 60 + int(t[3:])
        return timezone(timedelta(minutes=minutos if t[0] == "+" else -minutos))
    return timezone(timedelta(hours=-3))


def _hora(linha: dict[str, str], coluna: str) -> datetime | None:
    valor = (linha.get(coluna) or "").strip()
    if not valor:
        return None
    try:
        if valor.isdigit():
            utc = datetime.fromtimestamp(int(valor) / 1000, UTC)
        else:
            utc = datetime.fromisoformat(valor.replace(" ", "T")[:19]).replace(tzinfo=UTC)
    except ValueError:
        return None
    return utc.astimezone(_fuso(linha.get("time_offset", "")))


def _num(linha: dict[str, str], coluna: str) -> float | None:
    try:
        v = float(linha.get(coluna) or "")
    except ValueError:
        return None
    return v if v == v else None  # NaN


def ler_exportacao(z: zipfile.ZipFile) -> tuple[list[dict[str, Any]], list[str]]:
    """Dias montados a partir dos CSVs reconhecidos e os tipos lidos."""
    dias: dict[str, dict[str, Any]] = defaultdict(dict)
    listas: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    lidos: list[str] = []

    def tipo(nome: str) -> str:
        base = nome.rsplit("/", 1)[-1].removesuffix(".csv")
        partes = base.split(".")
        return ".".join(partes[:-1]) if partes[-1].isdigit() else base

    leitores = {
        "tracker.pedometer_day_summary": _passos,
        "sleep": _sono,
        "sleep_stage": _estagios,
        "tracker.heart_rate": _fc,
        "stress": _estresse,
        "weight": _peso,
        "tracker.oxygen_saturation": _spo2,
        "exercise": _exercicio,
        "water_intake": _agua,
        "floors_climbed": _andares,
    }
    for nome in z.namelist():
        if not nome.endswith(".csv"):
            continue
        t = tipo(nome)
        for chave, leitor in leitores.items():
            if t.endswith("." + chave):
                leitor(_linhas(z, nome), dias, listas)
                lidos.append(chave)
                break

    for d, metricas in listas.items():
        for k, valores in metricas.items():
            if not valores:
                continue
            if k == "fc_min":
                dias[d][k] = min(valores)
            elif k == "fc_max":
                dias[d][k] = max(valores)
            else:
                dias[d][k] = round(mean(valores), 1)
    for v in dias.values():
        v.pop("_maior_sono", None)
    return [{"data": d, **v} for d, v in sorted(dias.items())], sorted(set(lidos))


Dias = dict[str, dict[str, Any]]
Listas = dict[str, dict[str, list[float]]]


def _passos(linhas: list[dict[str, str]], dias: Dias, _: Listas) -> None:
    for x in linhas:
        dia = _num(x, "day_time")
        passos = _num(x, "step_count")
        if dia is None or passos is None:
            continue
        d = datetime.fromtimestamp(dia / 1000, UTC).date().isoformat()
        if passos <= dias[d].get("passos", -1):
            continue  # um registro por aparelho; fica o maior (o combinado)
        dias[d]["passos"] = int(passos)
        if (m := _num(x, "distance")) is not None:
            dias[d]["distancia_km"] = round(m / 1000, 2)
        if (c := _num(x, "calorie")) is not None:
            dias[d]["calorias_ativas"] = round(c)
        if (a := _num(x, "active_time")) is not None:
            dias[d]["minutos_ativos"] = round(a / 60000)


def _sono(linhas: list[dict[str, str]], dias: Dias, _: Listas) -> None:
    for x in linhas:
        ini, fim = _hora(x, "start_time"), _hora(x, "end_time")
        if not ini or not fim or fim <= ini:
            continue
        d = dias[fim.date().isoformat()]
        minutos = round((fim - ini).total_seconds() / 60)
        d["sono_min"] = d.get("sono_min", 0) + minutos
        if minutos > d.get("_maior_sono", 0):  # horários da noite principal, não do cochilo
            d.update(
                _maior_sono=minutos,
                sono_inicio=ini.strftime("%H:%M"),
                sono_fim=fim.strftime("%H:%M"),
            )
            if (p := _num(x, "sleep_score")) is not None and p > 0:
                d["sono_pontuacao"] = p


def _estagios(linhas: list[dict[str, str]], dias: Dias, _: Listas) -> None:
    for x in linhas:
        ini, fim = _hora(x, "start_time"), _hora(x, "end_time")
        campo = ESTAGIOS.get((x.get("stage") or "").strip())
        if not ini or not fim or not campo:
            continue
        d = dias[fim.date().isoformat()]
        d[campo] = d.get(campo, 0) + round((fim - ini).total_seconds() / 60)


def _media_do_dia(coluna: str, campo: str):  # noqa: ANN202
    def ler(linhas: list[dict[str, str]], _: Dias, listas: Listas) -> None:
        for x in linhas:
            ini, v = _hora(x, "start_time"), _num(x, coluna)
            if ini and v is not None and v > 0:
                listas[ini.date().isoformat()][campo].append(v)

    return ler


_estresse = _media_do_dia("score", "estresse")
_spo2 = _media_do_dia("spo2", "spo2")


def _fc(linhas: list[dict[str, str]], dias: Dias, listas: Listas) -> None:
    for x in linhas:
        ini, v = _hora(x, "start_time"), _num(x, "heart_rate")
        if not ini or v is None or v <= 0:
            continue
        lista = listas[ini.date().isoformat()]
        lista["fc_media"].append(v)
        lista["fc_min"].append(_num(x, "min") or v)
        lista["fc_max"].append(_num(x, "max") or v)


def _peso(linhas: list[dict[str, str]], dias: Dias, _: Listas) -> None:
    for x in sorted(linhas, key=lambda x: x.get("start_time", "")):
        ini = _hora(x, "start_time")
        if not ini:
            continue
        d = dias[ini.date().isoformat()]
        for coluna, campo in (
            ("weight", "peso_kg"),
            ("body_fat", "gordura_pct"),
            ("fat_free_mass", "massa_magra_kg"),
        ):
            if (v := _num(x, coluna)) is not None and v > 0:
                d[campo] = round(v, 1)


def _exercicio(linhas: list[dict[str, str]], dias: Dias, _: Listas) -> None:
    for x in linhas:
        ini = _hora(x, "start_time")
        duracao = _num(x, "duration")
        if not ini or not duracao:
            continue
        codigo = (x.get("exercise_type") or "").strip()
        e: dict[str, Any] = {
            "tipo": EXERCICIOS.get(codigo, f"exercício {codigo}" if codigo else "exercício"),
            "inicio": ini.strftime("%H:%M"),
            "minutos": round(duracao / 60000),
        }
        if (c := _num(x, "calorie")) is not None:
            e["calorias"] = round(c)
        if (m := _num(x, "distance")) is not None and m > 0:
            e["distancia_km"] = round(m / 1000, 2)
        dias[ini.date().isoformat()].setdefault("exercicios", []).append(e)


def _soma_do_dia(coluna: str, campo: str):  # noqa: ANN202
    def ler(linhas: list[dict[str, str]], dias: Dias, _: Listas) -> None:
        for x in linhas:
            ini, v = _hora(x, "start_time"), _num(x, coluna)
            if ini and v is not None and v > 0:
                d = dias[ini.date().isoformat()]
                d[campo] = round(d.get(campo, 0) + v, 1)

    return ler


_agua = _soma_do_dia("amount", "agua_ml")
_andares = _soma_do_dia("floor", "andares")
