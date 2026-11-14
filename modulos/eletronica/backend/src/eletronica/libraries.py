"""Bibliotecas importadas do KiCad em `bibliotecas/<nome>.json` (símbolos completos) e
`<nome>.indice.json` (o que a busca usa: id, nome, valor, descrição e palavras-chave). Só os índices
ficam na memória; o arquivo completo é lido na hora de entregar símbolos e fica num cache pequeno. A
biblioteca base (`biblioteca.py`) vem sempre junto em [obter]."""

import json
import os
import re
import threading
from collections import OrderedDict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from eletronica.library import POR_ID

_NAME = re.compile(r"^[A-Za-z0-9_.+-]{1,80}$")
_CACHE = 6  # bibliotecas completas guardadas na memória

# Bibliotecas oficiais do KiCad que mais servem para PC, celular, monitor/TV e som.
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
        self.raiz = Path(root).expanduser() / "bibliotecas"
        self.raiz.mkdir(parents=True, exist_ok=True)
        self._trava = threading.RLock()
        self._indices: dict[str, dict[str, Any]] = {}
        self._cheias: OrderedDict[str, dict[str, dict[str, Any]]] = OrderedDict()
        for file in self.raiz.glob("*.indice.json"):
            self._indices[file.name.removesuffix(".indice.json")] = json.loads(
                file.read_text("utf-8")
            )

    @staticmethod
    def validar_nome(nome: str) -> str:
        if not _NAME.match(nome):
            raise NameInvalid(f"Nome de biblioteca inválido: {nome!r}")
        return nome

    def _gravar(self, caminho: Path, dados: Any) -> None:
        tmp = caminho.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, separators=(",", ":")), "utf-8")
        os.replace(tmp, caminho)

    def guardar(self, nome: str, symbols: list[dict[str, Any]], origem: str) -> dict[str, Any]:
        """Cria ou troca a biblioteca [nome] (reimportar atualiza)."""
        self.validar_nome(nome)
        index = {
            "nome": nome,
            "origem": origem,
            "importado": _now(),
            "total": len(symbols),
            "simbolos": [_input_index(s) for s in symbols],
        }
        with self._trava:
            self._gravar(self.raiz / f"{nome}.json", symbols)
            self._gravar(self.raiz / f"{nome}.indice.json", index)
            self._indices[nome] = index
            self._cheias.pop(nome, None)
        return self._resumo(index)

    @staticmethod
    def _resumo(indice: dict[str, Any]) -> dict[str, Any]:
        return {k: indice[k] for k in ("nome", "origem", "importado", "total")}

    def listar(self) -> list[dict[str, Any]]:
        with self._trava:
            return sorted(
                (self._resumo(i) for i in self._indices.values()), key=lambda r: r["nome"]
            )

    def remover(self, nome: str) -> None:
        with self._trava:
            if nome not in self._indices:
                raise LibraryNotFound(nome)
            del self._indices[nome]
            self._cheias.pop(nome, None)
            (self.raiz / f"{nome}.json").unlink(missing_ok=True)
            (self.raiz / f"{nome}.indice.json").unlink(missing_ok=True)

    def _cheia(self, nome: str) -> dict[str, dict[str, Any]]:
        with self._trava:
            if nome in self._cheias:
                self._cheias.move_to_end(nome)
                return self._cheias[nome]
            symbols = json.loads((self.raiz / f"{nome}.json").read_text("utf-8"))
            cheia = {s["id"]: s for s in symbols}
            self._cheias[nome] = cheia
            while len(self._cheias) > _CACHE:
                self._cheias.popitem(last=False)
            return cheia

    def obter(self, id_: str) -> dict[str, Any] | None:
        """Símbolo da base ou de uma biblioteca importada (`<lib>:<nome>[:<unidade>]`)."""
        if id_ in POR_ID:
            return POR_ID[id_]
        lib = id_.split(":", 1)[0]
        if ":" not in id_ or lib not in self._indices:
            return None
        return self._cheia(lib).get(id_)

    def varios(self, ids: list[str]) -> list[dict[str, Any]]:
        return [s for s in map(self.obter, dict.fromkeys(ids)) if s is not None]

    def buscar(
        self, text: str, collection: str | None = None, limite: int = 60
    ) -> list[dict[str, Any]]:
        """Símbolos importados com todas as palavras de [texto]; nome exato e começo do nome vêm
        antes."""
        terms = text.lower().split()
        target = text.strip().lower()
        found: list[tuple[int, str, str]] = []
        with self._trava:
            indexes = [self._indices[collection]] if collection in self._indices else []
            if collection is None:
                indexes = list(self._indices.values())
            for index in indexes:
                for e in index["simbolos"]:
                    if all(t in e["busca"] for t in terms):
                        name = e["nome"].lower()
                        weight = 0 if name == target else 1 if name.startswith(target) else 2
                        found.append((weight, name, e["id"]))
        found.sort()
        return self.varios([i for _, _, i in found[:limite]])
