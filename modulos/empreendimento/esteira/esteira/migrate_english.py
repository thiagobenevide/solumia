"""One-time rewrite of the stored data to the English keys (docs/GLOSSARIO-INGLES.md). The code no longer reads
the old keys. Run with the panel and every `./dark` stopped:

    python -m esteira.migrate_english            # rewrites
    python -m esteira.migrate_english --dry-run  # only lists what it would do

Safe to run again: the conversions are idempotent and a file is only rewritten when something changes. Each
unit of the migration adds its files and values here.
"""
import argparse
import json

from esteira.project import CACHE, PROJETOS

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
              "esquema": "schema", "erro": "error", "seg": "seconds", "tokens_entrada": "input_tokens",
              "tokens_saida": "output_tokens", "geracao_s": "generation_s", "carga_s": "load_s",
              "custo_usd": "cost_usd", "cache_lido": "cache_read"}
CALL_PARAMS = {"tentativa": "attempt", "pensar": "think", "imagens": "images", "imagem": "image",
               "temperatura": "temperature"}
LEDGER_KEYS = {"motivo": "reason", "custo": "cost", "resposta": "answer"}
TRACE_KINDS = {"no": "node", "chamada": "call"}
OPTION_KEYS = {"motor": "engine", "modelo_claude": "claude_model", "teto_episodio_usd": "episode_cap_usd",
               "teto_dia_usd": "daily_cap_usd", "operacoes": "operations", "socorro_claude": "claude_fallback",
               "direcao": "direction", "limite_cota": "quota_limit"}
OPERATION_KEYS = {"motor": "engine", "texto": "text", "visao": "vision"}
ENGINES = {"padrao": "default"}
# CLI commands; the stage ids recorded in events, trace nodes, processes and the queue are the same names
COMMANDS = {"tudo": "all", "transcrever": "transcribe", "limpar": "clean", "partes": "parts", "cenas": "scenes",
            "curar": "curate", "avaliar": "evaluate", "graficos": "graphics", "buscar": "fetch", "revisar": "review",
            "resumo": "summary", "palavras": "words", "ajustar": "adjust", "quadros": "frames", "montar": "assemble",
            "abrir": "open", "exportar": "export", "roteiros": "scripts", "importar": "import", "roteiro": "script",
            "acervo": "library", "painel": "panel", "estudio": "studio", "estudio-corte": "studio-cut",
            "estudio-instalar": "studio-install", "estudio-estilo": "studio-style",
            "estudio-fabrica": "studio-factory", "estudio-peca-previa": "studio-piece-preview",
            "estudio-prova-canais": "studio-channel-proof", "estudio-bloco": "studio-block",
            "estudio-amostra": "studio-sample", "treino": "training", "bancada": "bench"}
FLAGS = {"--refazer": "--redo", "--motor": "--engine", "--cenas": "--scenes", "--so-render": "--render-only",
         "--sem-exportar": "--no-export", "--ate": "--to", "--estilo": "--style", "--formatos": "--formats",
         "--etapas": "--stages", "--sem-portao": "--no-gate", "--intensidade": "--intensity", "--nicho": "--niche",
         "--sem-visao": "--no-vision", "--formato": "--format", "--estilos": "--styles", "--bloco": "--block",
         "--epocas": "--epochs", "--tarefas": "--tasks", "--modelos": "--models", "treinar": "train",
         "rodar": "run"}
OPERATIONS = {"limpar": "clean", "curar": "curate", "avaliar": "evaluate", "graficos": "graphics",
              "acervo": "library", "roteiro": "script", "estudio_cena": "studio_scene", "direcao": "direction",
              "estudio_visao": "studio_vision"}
DIRECTIONS = {"blocos": "blocks", "frases": "sentences"}


def _rename(record, keys):
    renamed = {}
    for key, value in record.items():
        renamed[keys.get(key, key)] = value
    return renamed


def _translate(record, key, values):
    if record.get(key) in values:
        record[key] = values[record[key]]


def _arguments(args):
    translated = []
    for arg in args or []:
        translated.append(FLAGS.get(arg, arg))
    return translated


def _event(record):
    record = _rename(record, EVENT_KEYS)
    _translate(record, "kind", EVENT_KINDS)
    _translate(record, "stage", COMMANDS)
    if record.get("kind") == "error" and record.get("message") == "interrompido":
        record["message"] = "interrupted"
    return record


def _process(record):
    record = _rename(record, PROCESS_KEYS)
    _translate(record, "event", PROCESS_EVENTS)
    _translate(record, "slot", SLOTS)
    _translate(record, "command", COMMANDS)
    if "args" in record:
        record["args"] = _arguments(record["args"])
    return record


def _trace(record):
    record = _rename(record, TRACE_KEYS)
    _translate(record, "kind", TRACE_KINDS)
    _translate(record, "node", COMMANDS)
    if isinstance(record.get("params"), dict):
        record["params"] = _rename(record["params"], CALL_PARAMS)
    return record


def _ledger(record):
    return _rename(record, LEDGER_KEYS)


def _options(record):
    record = _rename(record, OPTION_KEYS)
    _translate(record, "direction", DIRECTIONS)
    operations = {}
    for name, chosen in (record.get("operations") or {}).items():
        chosen = _rename(chosen, OPERATION_KEYS)
        _translate(chosen, "engine", ENGINES)
        operations[OPERATIONS.get(name, name)] = chosen
    record["operations"] = operations
    return record


def _write(path, text):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)


def _converted(text, convert):
    lines = []
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            lines.append(json.dumps(convert(json.loads(line)), ensure_ascii=False))
        except ValueError:
            lines.append(line)
    return lines


def migrate_jsonl(old, new, convert, dry_run):
    """Old lines first, then what is already in the new file; `convert` is applied to both (it is idempotent)."""
    lines = []
    current = ""
    if old.exists():
        lines.extend(_converted(old.read_text(), convert))
    if new.exists():
        current = new.read_text()
        lines.extend(_converted(current, convert))
    if not lines:
        return False
    text = "\n".join(lines) + "\n"
    if not old.exists() and text == current:
        return False
    print(f"{old if old.exists() else new} → {new.name}")
    if dry_run:
        return True
    _write(new, text)
    old.unlink(missing_ok=True)
    return True


def migrate_options(dry_run):
    """The old file wins over an `options.json` created before this migration ran."""
    old, new = CACHE / "opcoes.json", CACHE / "options.json"
    source = old
    if not old.exists():
        source = new
    if not source.exists():
        return False
    current = source.read_text()
    text = json.dumps(_options(json.loads(current)), ensure_ascii=False, indent=1)
    if source == new and text == current:
        return False
    print(f"{source} → {new.name}")
    if dry_run:
        return True
    _write(new, text)
    old.unlink(missing_ok=True)
    return True


def migrate_queue(dry_run):
    """`cache/fila.json` keeps its own keys for now; slot, command and flags come from the core and the CLI."""
    path = CACHE / "fila.json"
    if not path.exists():
        return False
    current = path.read_text()
    tasks = json.loads(current)
    for task in tasks:
        _translate(task, "vaga", SLOTS)
        _translate(task, "comando", COMMANDS)
        if "args" in task:
            task["args"] = _arguments(task["args"])
    text = json.dumps(tasks, ensure_ascii=False, indent=1)
    if text == current:
        return False
    print(f"{path}: slot, command and flag values")
    if not dry_run:
        _write(path, text)
    return True


def migrate_claude(dry_run):
    """`cache/claude.jsonl` keeps its name (only the keys change); the quota reading file is renamed."""
    done = migrate_jsonl(CACHE / "claude.pt.jsonl", CACHE / "claude.jsonl", _ledger, dry_run)
    old = CACHE / "cota_claude.json"
    if old.exists():
        print(f"{old} → claude_quota.json")
        if not dry_run:
            old.replace(CACHE / "claude_quota.json")
        done += 1
    return done


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    done = 0
    done += migrate_options(args.dry_run)
    done += migrate_queue(args.dry_run)
    done += migrate_claude(args.dry_run)
    done += migrate_jsonl(CACHE / "processos.jsonl", CACHE / "processes.jsonl", _process, args.dry_run)
    done += migrate_jsonl(CACHE / "rastro.jsonl", CACHE / "trace.jsonl", _trace, args.dry_run)
    logs = set()
    for name in ("eventos.jsonl", "events.jsonl"):
        for path in PROJETOS.glob(f"*/*/log/{name}"):
            logs.add(path.parent)
    for folder in sorted(logs):
        done += migrate_jsonl(folder / "eventos.jsonl", folder / "events.jsonl", _event, args.dry_run)
    print(f"{done} file(s) {'to migrate' if args.dry_run else 'migrated'}")


if __name__ == "__main__":
    main()
