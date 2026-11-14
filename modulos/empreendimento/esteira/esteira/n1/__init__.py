"""N1: vocabulário de operações de domínio por Craft App (`docs/PLANO-DATASET.md` §3).

O modelo escreve N1 (JSON validado por esquema, que vira gramática no llama.cpp); um executor determinístico por
app transforma N1 em comandos N0 da app e devolve o rastro dos comandos para o dataset. Regras comuns: nomes em
vez de índices, tempo em segundos, espaço em frações 0–1 da tela, cor e fonte por papel, catálogos fechados.
"""
import json
from pathlib import Path

from pydantic import BaseModel


def schema_json(model: type[BaseModel]) -> dict:
    return model.model_json_schema()


def save_schemas(pasta: Path) -> list[Path]:
    """Escreve `<app>/n1.v<N>.json` de cada app em `pasta` (o dataset guarda a versão de cada registro)."""
    from esteira.n1 import effectcraft, filmcraft, photocraft
    output = []
    for mod in (filmcraft, photocraft, effectcraft):
        file = pasta / mod.APP / f"n1.v{mod.VERSION}.json"
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(json.dumps(schema_json(mod.DOCUMENT), ensure_ascii=False, indent=1))
        output.append(file)
    return output
