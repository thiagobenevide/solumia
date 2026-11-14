import io
import time
import zipfile
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.files.mapping import locate, text_docx
from backend.files.rewrite import Rewrite
from backend.main import create_app

CITADO = "A leitura ativa exige marcar os trechos importantes do texto original."


def _pdf(linhas: list[str]) -> bytes:
    """Minimal one-page PDF with one line of text per item (Helvetica)."""
    text = "".join(
        f"BT /F1 12 Tf 72 {720 - 20 * i} Td ({line}) Tj ET\n" for i, line in enumerate(linhas)
    ).encode()
    objetos = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(text) + text + b"endstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    output = io.BytesIO(b"%PDF-1.4\n")
    posicoes = []
    for n, o in enumerate(objetos, 1):
        posicoes.append(output.tell())
        output.write(b"%d 0 obj\n" % n + o + b"\nendobj\n")
    xref = output.tell()
    output.write(b"xref\n0 %d\n0000000000 65535 f \n" % (len(objetos) + 1))
    for p in posicoes:
        output.write(b"%010d 00000 n \n" % p)
    output.write(b"trailer << /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
                % (len(objetos) + 1, xref))
    return output.getvalue()


def _docx(paragrafos: list[tuple[str, str]]) -> bytes:
    ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
    body = "".join(
        f'<w:p><w:pPr><w:pStyle w:val="{style}"/></w:pPr><w:r><w:t>{text}</w:t></w:r></w:p>'
        if style else f"<w:p><w:r><w:t>{text}</w:t></w:r></w:p>"
        for style, text in paragrafos
    )
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as z:
        z.writestr("word/document.xml", f"<w:document {ns}><w:body>{body}</w:body></w:document>")
    return output.getvalue()


def test_docx_text_marks_headings() -> None:
    t = text_docx(_docx([("Heading1", "Introdução"), ("", "Texto (Silva, 2020).")]))
    assert t == "# Introdução\nTexto (Silva, 2020)."


def test_fuzzy_locate_with_hyphen() -> None:
    words = [
        ("A", [10, 10, 20, 20], 0), ("leitura", [21, 10, 60, 20], 0), ("ati-", [61, 10, 80, 20], 0),
        ("va", [10, 30, 20, 40], 1), ("exige", [21, 30, 50, 40], 1), 
        ("tempo.", [51, 30, 80, 40], 1),
        ("Outra", [10, 50, 40, 60], 2),
    ]
    rets, text, coverage = locate(words, "a leitura ativa exige tempo")
    assert coverage == 1
    assert rets == [[10, 10, 80, 20], [10, 30, 80, 40]]
    assert "Outra" not in text


@pytest.fixture
def api(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    s = Settings(
        client_api_keys=CLIENT_API_KEY,
        arquivos_dir=str(tmp_path / "arquivos"),
        estudos_dir=str(tmp_path / "estudos"),
        rotinas_dir=str(tmp_path / "rotinas"),
        notas_dir=str(tmp_path / "notas"),
    )
    app = create_app(settings=s)
    requests: list[dict] = []

    async def sem_internet(ref: dict, extras: list | None = None, baixar: bool = True) -> dict:
        return {"pdf": None, "url_pdf": "", "doi": "10.1/x" if "Leitura" in ref["titulo"] else "",
                "link": "https://doi.org/10.1/x" if "Leitura" in ref["titulo"] else ""}

    monkeypatch.setattr("backend.files.mapping.fetch_pdf_open", sem_internet)

    async def executar_json(pedido: dict) -> dict:
        requests.append(pedido)
        if "pdf_catalog" in pedido["prompt"]:
            pdf_id = pedido["prompt"].split('id "')[1].split('"')[0]
            return {
                "referencias": [
                    {"n": 1, "referencia": "SILVA, A. Leitura ativa. 2020.",
                     "autor_citacao": "Silva", "ano": "2020", "titulo": "Leitura ativa",
                     "arquivo_id": pdf_id, "fora_da_lista": False},
                    {"n": 2, "referencia": "SOUZA, B. Obra ausente. 2019.",
                     "autor_citacao": "Souza", "ano": "2019", "titulo": "Obra ausente",
                     "arquivo_id": "", "fora_da_lista": False},
                ],
            }
        if "<works>" in pedido["prompt"]:
            return {
                "citacoes": [
                    {"ref": 1, "trecho_documento": f"Segundo Silva (2020), “{CITADO}”",
                     "citacao": CITADO, "tipo": "direta", "pagina": "p. 1",
                     "secao": "Introdução"},
                    {"ref": 2, "trecho_documento": "Ler é difícil (Souza, 2019).",
                     "citacao": "", "tipo": "indireta", "pagina": "", "secao": "Introdução"},
                ],
            }
        if pedido.get("ferramentas"):
            return {"encontrado": True, "titulo": "Obra ausente", "doi": "", "urls_pdf": [],
                    "referencia_completa": "", "observacao": "fechada"}
        return {"trechos": [{"c": 0, "encontrado": True, "pagina": 1, "trecho": CITADO,
                             "confianca": "alta", "observacao": ""}]}

    async def executar(_p: dict) -> dict:
        return {}

    app.state.reescrita = Rewrite(executar, lambda: None, executar_json)
    app.state.requests = requests
    with TestClient(app, headers=AUTH_HEADERS) as c:
        yield c


def _wait(api: TestClient, pid: str) -> dict:
    for _ in range(100):
        m = api.get(f"/api/estudos/projetos/{pid}/mapeamento").json()
        if m.get("estado") != "rodando":
            return m
        time.sleep(0.05)
    raise AssertionError("mapeamento não terminou")


def test_mapping_marks_citations_and_creates_todos(api: TestClient) -> None:
    pdf = _pdf(["Capitulo 1", "A leitura ativa exige marcar os trechos", "importantes do texto "
                "original. Depois vem outra frase."])
    r = api.post("/api/arquivos", files={"arquivo": ("silva2020.pdf", pdf)})
    assert r.status_code in (200, 201), r.text
    pdf_id = r.json()["id"]
    pid = api.post("/api/estudos/projetos", json={"nome": "Pré-TCC"}).json()["id"]

    doc = _docx([("Heading1", "Introdução"), ("", f"Segundo Silva (2020), “{CITADO}”")])
    r = api.post(f"/api/estudos/projetos/{pid}/documento", files={"arquivo": ("tcc.docx", doc)})
    assert r.status_code == 202, r.text
    m = _wait(api, pid)
    assert m["estado"] == "pronto", m
    assert (m["citacoes"], m["marcadas"], m["pendentes"]) == (2, 1, 1)
    assert m["documento_id"] != pdf_id

    highlights = api.get(f"/api/arquivos/{pdf_id}/anotacoes").json()["destaques"]
    assert len(highlights) == 1 and highlights[0]["projetos"] == [pid]
    assert highlights[0]["retangulos"] and "importantes" in highlights[0]["texto"]

    matrix = api.get(f"/api/estudos/projetos/{pid}/matriz").json()
    item = matrix["itens"][0]
    assert item["classificacao"]["status_uso"] == "Usado"
    assert item["classificacao"]["secao"] == "Introdução"
    assert matrix["trabalhos"][0]["autor_citacao"] == "Silva"
    assert matrix["trabalhos"][0]["link"] == "https://doi.org/10.1/x"
    assert "Claude" not in item["classificacao"]["observacoes"]

    tasks = api.get("/api/rotinas/tarefas").json()
    assert any("Souza" in t["titulo"] for t in tasks)

    # redoing does not duplicate the mark or the task

    assert api.post(f"/api/estudos/projetos/{pid}/mapeamento").status_code == 202
    m = _wait(api, pid)
    assert m["marcadas"] == 1
    assert len(api.get(f"/api/arquivos/{pdf_id}/anotacoes").json()["destaques"]) == 1
    assert sum("Souza" in t["titulo"] for t in api.get("/api/rotinas/tarefas").json()) == 1


def test_split_document_cuts_at_heading_and_carries_section() -> None:
    from backend.files.mapping import divide_document

    text = "\n".join(["# Introdução", *["frase " * 20] * 30, "# Método", *["linha " * 20] * 30])
    parts = divide_document(text, limite=2000)
    assert len(parts) > 2
    assert "".join(parts).count("frase") == 600
    assert any(p.startswith("(continuação da seção: Introdução)") for p in parts)
    assert any(p.startswith("# Método") or "seção: Método" in p for p in parts)


def test_reference_with_link_in_export() -> None:
    from studies.projects import link_of_work, reference_with_link

    assert link_of_work({"doi": "doi: 10.5/abc"}) == "https://doi.org/10.5/abc"
    link = "https://doi.org/10.5/abc"
    t = {"referencia": "SILVA, A. Leitura. 2020.", "link": link, "doi": "",
         "autor": "", "titulo": "", "ano": ""}
    assert reference_with_link(t) == f"SILVA, A. Leitura. 2020. Disponível em: {link}."
