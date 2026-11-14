"""N1: vocabulário de operações de domínio por Craft App (`docs/PLANO-DATASET.md` §3).

O modelo escreve N1 (JSON validado por esquema, que vira gramática no llama.cpp); um executor determinístico por
app transforma N1 em comandos N0 da app e devolve o rastro dos comandos para o dataset. Regras comuns: nomes em
vez de índices, tempo em segundos, espaço em frações 0–1 da tela, cor e fonte por papel, catálogos fechados.
"""
import json
from pathlib import Path

from pydantic import BaseModel


def esquema_json(modelo: type[BaseModel]) -> dict:
    return modelo.model_json_schema()


def salvar_esquemas(pasta: Path) -> list[Path]:
    """Escreve `<app>/n1.v<N>.json` de cada app em `pasta` (o dataset guarda a versão de cada registro)."""
    from esteira.n1 import effectcraft, filmcraft, photocraft
    saida = []
    for mod in (filmcraft, photocraft, effectcraft):
        arq = pasta / mod.APP / f"n1.v{mod.VERSAO}.json"
        arq.parent.mkdir(parents=True, exist_ok=True)
        arq.write_text(json.dumps(esquema_json(mod.DOCUMENTO), ensure_ascii=False, indent=1))
        saida.append(arq)
    return saida
