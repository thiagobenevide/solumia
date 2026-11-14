"""One-time rewrite of the stored data to the English keys (docs/GLOSSARIO-INGLES.md). The code no longer reads
the old keys. Run with the panel and every `./dark` stopped:

    python -m esteira.migrate_english            # rewrites
    python -m esteira.migrate_english --dry-run  # only lists what it would do

Safe to run again: a file already migrated has no old file left, so it is skipped. Each unit of the migration
adds its files here.
"""
import argparse
import json

from esteira.projeto import CACHE, PROJETOS

EVENT_KEYS = {"etapa": "stage", "tipo": "kind", "msg": "message", "dur": "duration", "resta": "remaining",
              "custo": "cost", "seg": "seconds"}
EVENT_KINDS = {"inicio": "start", "fim": "end", "progresso": "progress", "saida": "output", "aviso": "warning",
               "erro": "error"}
PROCESS_KEYS = {"ev": "event", "comando": "command", "alvo": "target", "vaga": "slot", "motor": "engine",
                "inicio": "start", "fila": "queue", "saida": "output", "fim": "end", "erro": "error",
                "cancelado": "cancelled"}
PROCESS_EVENTS = {"inicio": "start", "fim": "end"}
SLOTS = {"maquina": "machine"}
TRACE_KEYS = {"tipo": "kind", "proc": "process", "fluxo": "flow", "no": "node", "detalhe": "detail",
              "motor": "engine", "nome": "name", "modelo": "model", "entrada": "input", "saida": "output",
              "esquema": "schema", "erro": "error", "seg": "seconds"}
TRACE_KINDS = {"no": "node", "chamada": "call"}
OPTION_KEYS = {"motor": "engine", "modelo_claude": "claude_model", "teto_episodio_usd": "episode_cap_usd",
               "teto_dia_usd": "daily_cap_usd", "operacoes": "operations", "socorro_claude": "claude_fallback",
               "direcao": "direction", "limite_cota": "quota_limit"}
OPERATION_KEYS = {"motor": "engine", "texto": "text", "visao": "vision"}
ENGINES = {"padrao": "default"}
DIRECTIONS = {"blocos": "blocks", "frases": "sentences"}


def _rename(record, keys):
    renamed = {}
    for key, value in record.items():
        renamed[keys.get(key, key)] = value
    return renamed


def _translate(record, key, values):
    if record.get(key) in values:
        record[key] = values[record[key]]


def _event(record):
    record = _rename(record, EVENT_KEYS)
    _translate(record, "kind", EVENT_KINDS)
    if record.get("kind") == "error" and record.get("message") == "interrompido":
        record["message"] = "interrupted"
    return record


def _process(record):
    record = _rename(record, PROCESS_KEYS)
    _translate(record, "event", PROCESS_EVENTS)
    _translate(record, "slot", SLOTS)
    return record


def _trace(record):
    record = _rename(record, TRACE_KEYS)
    _translate(record, "kind", TRACE_KINDS)
    return record


def _options(record):
    record = _rename(record, OPTION_KEYS)
    _translate(record, "direction", DIRECTIONS)
    operations = {}
    for name, chosen in (record.get("operations") or {}).items():
        chosen = _rename(chosen, OPERATION_KEYS)
        _translate(chosen, "engine", ENGINES)
        operations[name] = chosen
    record["operations"] = operations
    return record


def _write(path, text):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)


def migrate_jsonl(old, new, convert, dry_run):
    """Old lines converted first, then whatever the new code already appended to the new file."""
    if not old.exists():
        return False
    print(f"{old} → {new.name}")
    if dry_run:
        return True
    lines = []
    for line in old.read_text().splitlines():
        if not line.strip():
            continue
        try:
            lines.append(json.dumps(convert(json.loads(line)), ensure_ascii=False))
        except ValueError:
            lines.append(line)
    if new.exists():
        lines.extend(new.read_text().splitlines())
    _write(new, "\n".join(lines) + "\n")
    old.unlink()
    return True


def migrate_options(dry_run):
    """The old file wins over an `options.json` created before this migration ran."""
    old, new = CACHE / "opcoes.json", CACHE / "options.json"
    if not old.exists():
        return False
    print(f"{old} → {new.name}")
    if dry_run:
        return True
    _write(new, json.dumps(_options(json.loads(old.read_text())), ensure_ascii=False, indent=1))
    old.unlink()
    return True


def migrate_queue(dry_run):
    """`cache/fila.json` keeps its own keys for now; only the slot value comes from the core."""
    path = CACHE / "fila.json"
    if not path.exists():
        return False
    tasks = json.loads(path.read_text())
    changed = False
    for task in tasks:
        if task.get("vaga") in SLOTS:
            task["vaga"] = SLOTS[task["vaga"]]
            changed = True
    if not changed:
        return False
    print(f"{path}: slot values")
    if not dry_run:
        _write(path, json.dumps(tasks, ensure_ascii=False, indent=1))
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    done = 0
    done += migrate_options(args.dry_run)
    done += migrate_queue(args.dry_run)
    done += migrate_jsonl(CACHE / "processos.jsonl", CACHE / "processes.jsonl", _process, args.dry_run)
    done += migrate_jsonl(CACHE / "rastro.jsonl", CACHE / "trace.jsonl", _trace, args.dry_run)
    for old in sorted(PROJETOS.glob("*/*/log/eventos.jsonl")):
        done += migrate_jsonl(old, old.with_name("events.jsonl"), _event, args.dry_run)
    print(f"{done} file(s) {'to migrate' if args.dry_run else 'migrated'}")


if __name__ == "__main__":
    main()
