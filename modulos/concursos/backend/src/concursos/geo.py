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

URL_MUNICIPALITIES = (
    "https://raw.githubusercontent.com/kelvins/municipios-brasileiros/main/csv/municipios.csv"
)
URL_OSRM = (
    "https://router.project-osrm.org/route/v1/driving/{a};{b}?overview=full&geometries=geojson"
)
AGENT = "agent-concursos/0.1 (uso pessoal)"

UF_DO_CODE = {
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


def normalize(text: str) -> str:
    sem = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return " ".join(sem.lower().replace("-", " ").replace("'", " ").split())


def haversine_km(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, (*a, *b))
    h = (
        math.sin((lat2 - lat1) / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    )
    return 6371 * 2 * math.asin(math.sqrt(h))


class Geo:
    def __init__(self, root: Path, transporte: httpx.AsyncBaseTransport | None = None) -> None:
        self.root = root
        self._transporte = transporte
        self._municipalities: dict[tuple[str, str], tuple[float, float]] | None = None
        self._capitais: dict[str, tuple[str, float, float]] = {}

    def _http(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=self._transporte, timeout=30, follow_redirects=True)

    async def _load(self) -> None:
        if self._municipalities is not None:
            return
        file = self.root / "municipios.csv"
        if not file.exists():
            async with self._http() as c:
                r = await c.get(URL_MUNICIPALITIES, headers={"User-Agent": AGENT})
                r.raise_for_status()
                file.write_text(r.text, "utf-8")
        self._municipalities = {}
        with file.open(encoding="utf-8") as f:
            for line in csv.DictReader(f):
                uf = UF_DO_CODE.get(int(line["codigo_uf"]), "")
                pos = (float(line["latitude"]), float(line["longitude"]))
                self._municipalities[(normalize(line["nome"]), uf)] = pos
                if line["capital"] == "1":
                    self._capitais[uf] = (line["nome"], *pos)

    async def municipio(self, city: str, uf: str) -> dict[str, Any] | None:
        """`{cidade, uf, lat, lon}` do município; sem cidade (ou não achada), a capital da UF."""
        await self._load()
        assert self._municipalities is not None
        uf = uf.strip().upper()[:2]
        pos = self._municipalities.get((normalize(city), uf)) if city else None
        if pos:
            return {
                "cidade": city.strip(),
                "uf": uf,
                "lat": pos[0],
                "lon": pos[1],
                "aproximado": False,
            }
        if uf in self._capitais:
            name, lat, lon = self._capitais[uf]
            return {"cidade": name, "uf": uf, "lat": lat, "lon": lon, "aproximado": True}
        return None

    async def capitais(self) -> list[dict[str, Any]]:
        """As 27 capitais (onde costumam ser as provas dos concursos federais)."""
        await self._load()
        return [
            {"cidade": name, "uf": uf, "lat": lat, "lon": lon, "aproximado": False}
            for uf, (name, lat, lon) in self._capitais.items()
        ]

    async def route(self, a: dict[str, Any], b: dict[str, Any]) -> dict[str, Any]:
        """Rota de carro: `{km, horas, linha: [[lat, lon], ...]}`; sem o OSRM, linha reta × 1,3."""
        pa, pb = f"{a['lon']:.5f},{a['lat']:.5f}", f"{b['lon']:.5f},{b['lat']:.5f}"
        folder = self.root / "rotas"
        folder.mkdir(exist_ok=True)
        file = folder / (hashlib.sha1(f"{pa};{pb}".encode()).hexdigest()[:16] + ".json")
        if file.exists():
            data: dict[str, Any] = json.loads(file.read_text("utf-8"))
            return data
        try:
            async with self._http() as c:
                r = await c.get(URL_OSRM.format(a=pa, b=pb), headers={"User-Agent": AGENT})
                r.raise_for_status()
                route = r.json()["routes"][0]
            points = route["geometry"]["coordinates"]
            step = max(
                1, len(points) // 400
            )  # até ~400 pontos: leve no app e ainda segue a estrada
            line = [[p[1], p[0]] for p in points[::step]] + [[points[-1][1], points[-1][0]]]
            data = {
                "km": round(route["distance"] / 1000),
                "horas": round(route["duration"] / 3600, 1),
                "linha": line,
                "estimada": False,
            }
        except (httpx.HTTPError, KeyError, IndexError, ValueError):
            km = haversine_km((a["lat"], a["lon"]), (b["lat"], b["lon"])) * 1.3
            data = {
                "km": round(km),
                "horas": round(km / 70, 1),
                "linha": [[a["lat"], a["lon"]], [b["lat"], b["lon"]]],
                "estimada": True,
            }
            return data  # estimativa não vai para o cache: tenta o OSRM de novo depois
        file.write_text(json.dumps(data), "utf-8")
        return data
