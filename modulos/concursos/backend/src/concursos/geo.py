"""Coordenadas dos municípios (lista do IBGE com latitude/longitude, baixada uma vez para a pasta de
dados) e rotas de carro pelo OSRM público, com cache em `rotas/`."""

import csv
import hashlib
import json
import math
import unicodedata
from pathlib import Path
from typing import Any

import httpx

URL_MUNICIPIOS = (
    "https://raw.githubusercontent.com/kelvins/municipios-brasileiros/main/csv/municipios.csv"
)
URL_OSRM = (
    "https://router.project-osrm.org/route/v1/driving/{a};{b}?overview=full&geometries=geojson"
)
AGENTE = "agent-concursos/0.1 (uso pessoal)"

UF_DO_CODIGO = {
    11: "RO",
    12: "AC",
    13: "AM",
    14: "RR",
    15: "PA",
    16: "AP",
    17: "TO",
    21: "MA",
    22: "PI",
    23: "CE",
    24: "RN",
    25: "PB",
    26: "PE",
    27: "AL",
    28: "SE",
    29: "BA",
    31: "MG",
    32: "ES",
    33: "RJ",
    35: "SP",
    41: "PR",
    42: "SC",
    43: "RS",
    50: "MS",
    51: "MT",
    52: "GO",
    53: "DF",
}


def normalizar(texto: str) -> str:
    sem = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode()
    return " ".join(sem.lower().replace("-", " ").replace("'", " ").split())


def haversine_km(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, (*a, *b))
    h = (
        math.sin((lat2 - lat1) / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    )
    return 6371 * 2 * math.asin(math.sqrt(h))


class Geo:
    def __init__(self, raiz: Path, transporte: httpx.AsyncBaseTransport | None = None) -> None:
        self.raiz = raiz
        self._transporte = transporte
        self._municipios: dict[tuple[str, str], tuple[float, float]] | None = None
        self._capitais: dict[str, tuple[str, float, float]] = {}

    def _http(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=self._transporte, timeout=30, follow_redirects=True)

    async def _carregar(self) -> None:
        if self._municipios is not None:
            return
        arq = self.raiz / "municipios.csv"
        if not arq.exists():
            async with self._http() as c:
                r = await c.get(URL_MUNICIPIOS, headers={"User-Agent": AGENTE})
                r.raise_for_status()
                arq.write_text(r.text, "utf-8")
        self._municipios = {}
        with arq.open(encoding="utf-8") as f:
            for linha in csv.DictReader(f):
                uf = UF_DO_CODIGO.get(int(linha["codigo_uf"]), "")
                pos = (float(linha["latitude"]), float(linha["longitude"]))
                self._municipios[(normalizar(linha["nome"]), uf)] = pos
                if linha["capital"] == "1":
                    self._capitais[uf] = (linha["nome"], *pos)

    async def municipio(self, cidade: str, uf: str) -> dict[str, Any] | None:
        """`{cidade, uf, lat, lon}` do município; sem cidade (ou não achada), a capital da UF."""
        await self._carregar()
        assert self._municipios is not None
        uf = uf.strip().upper()[:2]
        pos = self._municipios.get((normalizar(cidade), uf)) if cidade else None
        if pos:
            return {
                "cidade": cidade.strip(),
                "uf": uf,
                "lat": pos[0],
                "lon": pos[1],
                "aproximado": False,
            }
        if uf in self._capitais:
            nome, lat, lon = self._capitais[uf]
            return {"cidade": nome, "uf": uf, "lat": lat, "lon": lon, "aproximado": True}
        return None

    async def capitais(self) -> list[dict[str, Any]]:
        """As 27 capitais (onde costumam ser as provas dos concursos federais)."""
        await self._carregar()
        return [
            {"cidade": nome, "uf": uf, "lat": lat, "lon": lon, "aproximado": False}
            for uf, (nome, lat, lon) in self._capitais.items()
        ]

    async def rota(self, a: dict[str, Any], b: dict[str, Any]) -> dict[str, Any]:
        """Rota de carro: `{km, horas, linha: [[lat, lon], ...]}`; sem o OSRM, linha reta × 1,3."""
        pa, pb = f"{a['lon']:.5f},{a['lat']:.5f}", f"{b['lon']:.5f},{b['lat']:.5f}"
        pasta = self.raiz / "rotas"
        pasta.mkdir(exist_ok=True)
        arq = pasta / (hashlib.sha1(f"{pa};{pb}".encode()).hexdigest()[:16] + ".json")
        if arq.exists():
            dados: dict[str, Any] = json.loads(arq.read_text("utf-8"))
            return dados
        try:
            async with self._http() as c:
                r = await c.get(URL_OSRM.format(a=pa, b=pb), headers={"User-Agent": AGENTE})
                r.raise_for_status()
                rota = r.json()["routes"][0]
            pontos = rota["geometry"]["coordinates"]
            passo = max(
                1, len(pontos) // 400
            )  # até ~400 pontos: leve no app e ainda segue a estrada
            linha = [[p[1], p[0]] for p in pontos[::passo]] + [[pontos[-1][1], pontos[-1][0]]]
            dados = {
                "km": round(rota["distance"] / 1000),
                "horas": round(rota["duration"] / 3600, 1),
                "linha": linha,
                "estimada": False,
            }
        except (httpx.HTTPError, KeyError, IndexError, ValueError):
            km = haversine_km((a["lat"], a["lon"]), (b["lat"], b["lon"])) * 1.3
            dados = {
                "km": round(km),
                "horas": round(km / 70, 1),
                "linha": [[a["lat"], a["lon"]], [b["lat"], b["lon"]]],
                "estimada": True,
            }
            return dados  # estimativa não vai para o cache: tenta o OSRM de novo depois
        arq.write_text(json.dumps(dados), "utf-8")
        return dados
