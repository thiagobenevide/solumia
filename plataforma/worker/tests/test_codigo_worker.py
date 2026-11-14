import asyncio
import subprocess
from pathlib import Path
from types import SimpleNamespace

from worker.coding import Codigo, etapas, linhas_novas, mudancas


def test_linhas_novas_e_mudancas() -> None:
    diff = "diff --git a/x b/x\n@@ -3,0 +4,2 @@\n+a\n+b\n@@ -9 +11 @@\n-c\n+d\n@@ -20,3 +23,0 @@\n"
    assert linhas_novas(diff) == [4, 5, 11]
    assert mudancas("A\tnovo.py\nM\tvelho.py\nR087\tde.py\tpara.py\n") == [
        {"caminho": "novo.py", "status": "A"},
        {"caminho": "velho.py", "status": "M"},
        {"caminho": "para.py", "status": "R"},
    ]


def test_arvore_e_arquivo_do_commit(tmp_path: Path) -> None:
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

    codigo = Codigo(SimpleNamespace(codigo_dir=str(tmp_path)), None)  # type: ignore[arg-type]
    arvore = asyncio.run(codigo.arvore(""))
    assert arvore["arquivos"] == ["a.py", "b.bin"]
    assert [c["assunto"] for c in arvore["commits"]] == ["segundo", "primeiro"]
    assert arvore["mudancas"] == [
        {"caminho": "a.py", "status": "M"},
        {"caminho": "b.bin", "status": "A"},
    ]
    arquivo = asyncio.run(codigo.arquivo("a.py", ""))
    assert arquivo["texto"].startswith("um\nnovo") and arquivo["novas"] == [2]
    achados = asyncio.run(codigo.buscar("dois", ""))["resultados"]
    assert [(r["caminho"], r["linha"]) for r in achados] == [("a.py", 2), ("a.py", 3)]
    obs = asyncio.run(codigo.buscar("dois", "", observacoes=True))["resultados"]
    assert [r["linha"] for r in obs] == [2]
    marcas = asyncio.run(codigo.buscar("", "", observacoes=True))["resultados"]
    assert [r["linha"] for r in marcas] == [2]
    assert asyncio.run(codigo.buscar("nada-disso", ""))["resultados"] == []
    assert asyncio.run(codigo.arquivo("b.bin", ""))["binario"]
    primeiro = arvore["commits"][1]["curto"]
    assert asyncio.run(codigo.arquivo("a.py", primeiro))["novas"] == [1, 2]
    for ruim in [("../x", ""), ("a.py", "HEAD~1"), ("a.py", "--all")]:
        try:
            asyncio.run(codigo.arquivo(*ruim))
        except RuntimeError:
            continue
        raise AssertionError(ruim)


def test_etapas_do_stream_json() -> None:
    assert etapas({"type": "system", "subtype": "init", "session_id": "s1", "model": "m"}) == [
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
    assert etapas(assistente) == [
        {"tipo": "texto", "texto": "Vou ler."},
        {"tipo": "ferramenta", "nome": "Read", "resumo": "/a.py"},
    ]
    resultado = {
        "type": "user",
        "message": {
            "content": [{"type": "tool_result", "is_error": True, "content": [{"text": "x" * 900}]}]
        },
    }
    [r] = etapas(resultado)
    assert r["erro"] and r["resumo"].endswith("…") and len(r["resumo"]) == 601
    [fim] = etapas({"type": "result", "result": "ok", "session_id": "s1", "num_turns": 3})
    assert fim["tipo"] == "fim" and fim["claude_sessao"] == "s1" and not fim["erro"]
    assert etapas({"type": "stream_event"}) == []
