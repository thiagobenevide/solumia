import asyncio
import subprocess
from pathlib import Path
from types import SimpleNamespace

from worker.coding import Code, changes, lines_new, stages


def test_new_lines_and_changes() -> None:
    diff = "diff --git a/x b/x\n@@ -3,0 +4,2 @@\n+a\n+b\n@@ -9 +11 @@\n-c\n+d\n@@ -20,3 +23,0 @@\n"
    assert lines_new(diff) == [4, 5, 11]
    assert changes("A\tnovo.py\nM\tvelho.py\nR087\tde.py\tpara.py\n") == [
        {"caminho": "novo.py", "status": "A"},
        {"caminho": "velho.py", "status": "M"},
        {"caminho": "para.py", "status": "R"},
    ]


def test_tree_and_file_at_commit(tmp_path: Path) -> None:
    def git(*args: str) -> None:
        ident = ["-c", "user.name=t", "-c", "user.email=t@t"]
        subprocess.run(["git", *ident, *args], cwd=tmp_path, check=True, capture_output=True)

    git("init", "-q")
    (tmp_path / "a.py").write_text("um\ndois\n")
    git("add", ".")
    git("commit", "-qm", "primeiro")
    (tmp_path / "a.py").write_text("um\nnovo  # TODO revisar Dois\ndois\n")
    (tmp_path / "b.bin").write_bytes(b"\0\1")
    git("add", ".")
    git("commit", "-qm", "segundo")

    code = Code(SimpleNamespace(codigo_dir=str(tmp_path)), None)  # type: ignore[arg-type]
    tree = asyncio.run(code.tree(""))
    assert tree["arquivos"] == ["a.py", "b.bin"]
    assert [c["assunto"] for c in tree["commits"]] == ["segundo", "primeiro"]
    assert tree["mudancas"] == [
        {"caminho": "a.py", "status": "M"},
        {"caminho": "b.bin", "status": "A"},
    ]
    file = asyncio.run(code.arquivo("a.py", ""))
    assert file["texto"].startswith("um\nnovo") and file["novas"] == [2]
    found = asyncio.run(code.fetch("dois", ""))["resultados"]
    assert [(r["caminho"], r["linha"]) for r in found] == [("a.py", 2), ("a.py", 3)]
    obs = asyncio.run(code.fetch("dois", "", observacoes=True))["resultados"]
    assert [r["linha"] for r in obs] == [2]
    marks = asyncio.run(code.fetch("", "", observacoes=True))["resultados"]
    assert [r["linha"] for r in marks] == [2]
    assert asyncio.run(code.fetch("nada-disso", ""))["resultados"] == []
    assert asyncio.run(code.arquivo("b.bin", ""))["binario"]
    primeiro = tree["commits"][1]["curto"]
    assert asyncio.run(code.arquivo("a.py", primeiro))["novas"] == [1, 2]
    for bad in [("../x", ""), ("a.py", "HEAD~1"), ("a.py", "--all")]:
        try:
            asyncio.run(code.arquivo(*bad))
        except RuntimeError:
            continue
        raise AssertionError(bad)


def test_stream_json_steps() -> None:
    assert stages({"type": "system", "subtype": "init", "session_id": "s1", "model": "m"}) == [
        {"tipo": "inicio", "claude_sessao": "s1", "modelo": "m"}
    ]
    assistente = {
        "type": "assistant",
        "message": {
            "content": [
                {"type": "text", "text": "Vou ler."},
                {"type": "tool_use", "name": "Read", "input": {"file_path": "/a.py"}},
            ]
        },
    }
    assert stages(assistente) == [
        {"tipo": "texto", "texto": "Vou ler."},
        {"tipo": "ferramenta", "nome": "Read", "resumo": "/a.py"},
    ]
    result = {
        "type": "user",
        "message": {
            "content": [{"type": "tool_result", "is_error": True, "content": [{"text": "x" * 900}]}]
        },
    }
    [r] = stages(result)
    assert r["erro"] and r["resumo"].endswith("…") and len(r["resumo"]) == 601
    [end] = stages({"type": "result", "result": "ok", "session_id": "s1", "num_turns": 3})
    assert end["tipo"] == "fim" and end["claude_sessao"] == "s1" and not end["erro"]
    assert stages({"type": "stream_event"}) == []
