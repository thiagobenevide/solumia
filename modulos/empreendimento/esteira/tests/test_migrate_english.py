import json

from esteira import migrate_english as M


def test_events_and_options_are_rewritten_once(tmp_path, monkeypatch):
    monkeypatch.setattr(M, "CACHE", tmp_path)
    log = tmp_path / "eventos.jsonl"
    log.write_text(json.dumps({"t": "x", "ep": "a-001", "etapa": "montar", "tipo": "fim", "msg": "", "dur": 2.5}) + "\n")
    new = tmp_path / "events.jsonl"
    new.write_text(json.dumps({"t": "y", "stage": "montar", "kind": "start", "message": ""}) + "\n")
    assert M.migrate_jsonl(log, new, M._event, False) is True
    lines = [json.loads(line) for line in new.read_text().splitlines()]
    assert lines[0] == {"t": "x", "ep": "a-001", "stage": "assemble", "kind": "end", "message": "", "duration": 2.5}
    assert lines[1]["kind"] == "start" and not log.exists()
    assert M.migrate_jsonl(log, new, M._event, False) is False  # nothing left to change

    (tmp_path / "opcoes.json").write_text(json.dumps({
        "motor": "claude", "direcao": "frases", "operacoes": {"curar": {"motor": "padrao", "texto": "m", "visao": None}}}))
    assert M.migrate_options(False) is True
    assert json.loads((tmp_path / "options.json").read_text()) == {
        "engine": "claude", "direction": "sentences",
        "operations": {"curate": {"engine": "default", "text": "m", "vision": None}}}
    assert M.migrate_options(False) is False


def test_process_and_trace_records():
    old = {"id": "1", "ev": "inicio", "vaga": "maquina", "motor": "local", "inicio": 1.0, "comando": "buscar",
           "args": ["a-001", "--refazer", "--cenas", "3"]}
    assert M._process(old) == {"id": "1", "event": "start", "slot": "machine", "engine": "local", "start": 1.0,
                               "command": "fetch", "args": ["a-001", "--redo", "--scenes", "3"]}
    assert M._process(M._process(old)) == M._process(old)
    assert M._trace({"tipo": "chamada", "proc": "1", "no": "curar", "seg": 2}) == {
        "kind": "call", "process": "1", "node": "curate", "seconds": 2}
