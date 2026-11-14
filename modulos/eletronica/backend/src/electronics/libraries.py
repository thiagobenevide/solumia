"""Libraries imported from KiCad in `bibliotecas/<nome>.json` (full symbols) and
`<nome>.indice.json` (what the search uses: id, name, value, description and keywords). Only the
indexes stay in memory; the full file is read when symbols are delivered and kept in a small cache.
The base library (`library.py`) always comes along in [obter]."""

import json
import os
import re
import threading
from collections import OrderedDict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from electronics.library import POR_ID

_NAME = re.compile(r"^[A-Za-z0-9_.+-]{1,80}$")
_CACHE = 6  # full libraries kept in memory

# Official KiCad libraries most useful for PC, phone, monitor/TV and audio.
SUGGESTED = [
    "Device",
    "power",
    "Connector",
    "Connector_Generic",
    "Connector_Audio",
    "Diode",
    "Diode_Bridge",
    "Transistor_BJT",
    "Transistor_FET",
    "Transistor_Power_Module",
    "Amplifier_Operational",
    "Amplifier_Audio",
    "Audio",
    "Regulator_Linear",
    "Regulator_Switching",
    "Regulator_Controller",
    "Reference_Voltage",
    "Power_Management",
    "Battery_Management",
    "Power_Protection",
    "Converter_DCDC",
    "Isolator",
    "Interface_USB",
    "Interface_HDMI",
    "Interface_UART",
    "Interface_Expansion",
    "Memory_EEPROM",
    "Memory_Flash",
    "MCU_Espressif",
    "MCU_RaspberryPi",
    "MCU_ST_STM32F1",
    "MCU_Microchip_ATmega",
    "Timer",
    "Logic_LevelTranslator",
    "74xx",
    "Display_Character",
    "Display_Graphic",
    "RF_Module",
    "Driver_LED",
    "Driver_Motor",
    "LED",
    "Relay",
    "Switch",
    "Sensor_Current",
    "Sensor_Temperature",
    "Analog_DAC",
    "Analog_ADC",
    "Oscillator",
    "Mechanical",
]


class LibraryNotFound(Exception):
    pass


class NameInvalid(Exception):
    pass


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _input_index(s: dict[str, Any]) -> dict[str, Any]:
    text = " ".join(
        [s["id"], s["nome"], s["valor"], s.get("descricao", ""), s.get("palavras", "")]
    )
    return {
        "id": s["id"],
        "nome": s["nome"],
        "valor": s["valor"],
        "descricao": s.get("descricao", ""),
        "busca": text.lower(),
    }


class Libraries:
    def __init__(self, root: str | Path) -> None:
        self.root = Path(root).expanduser() / "bibliotecas"
        self.root.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._indexes: dict[str, dict[str, Any]] = {}
        self._cheias: OrderedDict[str, dict[str, dict[str, Any]]] = OrderedDict()
        for file in self.root.glob("*.indice.json"):
            self._indexes[file.name.removesuffix(".indice.json")] = json.loads(
                file.read_text("utf-8")
            )

    @staticmethod
    def validate_name(nome: str) -> str:
        if not _NAME.match(nome):
            raise NameInvalid(f"Nome de biblioteca inválido: {nome!r}")
        return nome

    def _write(self, caminho: Path, dados: Any) -> None:
        tmp = caminho.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, separators=(",", ":")), "utf-8")
        os.replace(tmp, caminho)

    def store(self, nome: str, symbols: list[dict[str, Any]], origem: str) -> dict[str, Any]:
        """Creates or replaces the named library (reimporting updates it)."""
        self.validate_name(nome)
        index = {
            "nome": nome,
            "origem": origem,
            "importado": _now(),
            "total": len(symbols),
            "simbolos": [_input_index(s) for s in symbols],
        }
        with self._lock:
            self._write(self.root / f"{nome}.json", symbols)
            self._write(self.root / f"{nome}.indice.json", index)
            self._indexes[nome] = index
            self._cheias.pop(nome, None)
        return self._summary(index)

    @staticmethod
    def _summary(indice: dict[str, Any]) -> dict[str, Any]:
        return {k: indice[k] for k in ("nome", "origem", "importado", "total")}

    def list_all(self) -> list[dict[str, Any]]:
        with self._lock:
            return sorted(
                (self._summary(i) for i in self._indexes.values()), key=lambda r: r["nome"]
            )

    def remover(self, nome: str) -> None:
        with self._lock:
            if nome not in self._indexes:
                raise LibraryNotFound(nome)
            del self._indexes[nome]
            self._cheias.pop(nome, None)
            (self.root / f"{nome}.json").unlink(missing_ok=True)
            (self.root / f"{nome}.indice.json").unlink(missing_ok=True)

    def _cheia(self, nome: str) -> dict[str, dict[str, Any]]:
        with self._lock:
            if nome in self._cheias:
                self._cheias.move_to_end(nome)
                return self._cheias[nome]
            symbols = json.loads((self.root / f"{nome}.json").read_text("utf-8"))
            cheia = {s["id"]: s for s in symbols}
            self._cheias[nome] = cheia
            while len(self._cheias) > _CACHE:
                self._cheias.popitem(last=False)
            return cheia

    def obter(self, id_: str) -> dict[str, Any] | None:
        """Symbol from the base or from an imported library (`<lib>:<nome>[:<unidade>]`)."""
        if id_ in POR_ID:
            return POR_ID[id_]
        lib = id_.split(":", 1)[0]
        if ":" not in id_ or lib not in self._indexes:
            return None
        return self._cheia(lib).get(id_)

    def varios(self, ids: list[str]) -> list[dict[str, Any]]:
        return [s for s in map(self.obter, dict.fromkeys(ids)) if s is not None]

    def fetch(
        self, text: str, collection: str | None = None, limite: int = 60
    ) -> list[dict[str, Any]]:
        """Imported symbols with all the words of the text; exact name and name prefix come
        first."""
        terms = text.lower().split()
        target = text.strip().lower()
        found: list[tuple[int, str, str]] = []
        with self._lock:
            indexes = [self._indexes[collection]] if collection in self._indexes else []
            if collection is None:
                indexes = list(self._indexes.values())
            for index in indexes:
                for e in index["simbolos"]:
                    if all(t in e["busca"] for t in terms):
                        name = e["nome"].lower()
                        weight = 0 if name == target else 1 if name.startswith(target) else 2
                        found.append((weight, name, e["id"]))
        found.sort()
        return self.varios([i for _, _, i in found[:limite]])
