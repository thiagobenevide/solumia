import io
import time
import zipfile
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.files.mapping import localizar, texto_docx
from backend.files.rewrite import Reescrita
from backend.core.config import Settings
from backend.main import create_app

CITADO = "A leitura ativa exige marcar os trechos importantes do texto original."


def _pdf(linhas: list[str]) -> bytes:
    """PDF mínimo de uma página com uma linha de texto por item (Helvetica)."""
    texto = "".join(
        f"BT /F1 12 Tf 72 {720 - 20 * i} Td ({linha}) Tj ET\n" for i, linha in enumerate(linhas)
    ).encode()
    objetos = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(texto) + texto + b"endstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    saida = io.BytesIO(b"%PDF-1.4\n")
    posicoes = []
    for n, o in enumerate(objetos, 1):
        posicoes.append(saida.tell())
        saida.write(b"%d 0 obj\n" % n + o + b"\nendobj\n")
    xref = saida.tell()
    saida.write(b"xref\n0 %d\n0000000000 65535 f \n" % (len(objetos) + 1))
    for p in posicoes:
        saida.write(b"%010d 00000 n \n" % p)
    saida.write(b"trailer << /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
                % (len(objetos) + 1, xref))
    return saida.getvalue()


def _docx(paragrafos: list[tuple[str, str]]) -> bytes:
    ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
    corpo = "".join(
        f'<w:p><w:pPr><w:pStyle w:val="{estilo}"/></w:pPr><w:r><w:t>{texto}</w:t></w:r></w:p>'
        if estilo else f"<w:p><w:r><w:t>{texto}</w:t></w:r></w:p>"
        for estilo, texto in paragrafos
    )
    saida = io.BytesIO()
    with zipfile.ZipFile(saida, "w") as z:
        z.writestr("word/document.xml", f"<w:document {ns}><w:body>{corpo}</w:body></w:document>")
    return saida.getvalue()


def test_texto_docx_marca_titulos() -> None:
    t = texto_docx(_docx([("Heading1", "Introdução"), ("", "Texto (Silva, 2020).")]))
    assert t == "# Introdução\nTexto (Silva, 2020)."


def test_localizar_aproximado_com_hifen() -> None:
    palavras = [
        ("A", [10, 10, 20, 20], 0), ("leitura", [21, 10, 60, 20], 0), ("ati-", [61, 10, 80, 20], 0),
        ("va", [10, 30, 20, 40], 1), ("exige", [21, 30, 50, 40], 1), 
        ("tempo.", [51, 30, 80, 40], 1),
        ("Outra", [10, 50, 40, 60], 2),
    ]
    rets, texto, cobertura = localizar(palavras, "a leitura ativa exige tempo")
    assert cobertura == 1
    assert rets == [[10, 10, 80, 20], [10, 30, 80, 40]]
    assert "Outra" not in texto


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
    pedidos: list[dict] = []

    async def sem_internet(ref: dict, extras: list | None = None, baixar: bool = True) -> dict:
        return {"pdf": None, "url_pdf": "", "doi": "10.1/x" if "Leitura" in ref["titulo"] else "",
                "link": "https://doi.org/10.1/x" if "Leitura" in ref["titulo"] else ""}

    monkeypatch.setattr("backend.files.mapping.buscar_pdf_aberto", sem_internet)

    async def executar_json(pedido: dict) -> dict:
        pedidos.append(pedido)
        if "catalogo_de_pdfs" in pedido["prompt"]:
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
        if "<obras>" in pedido["prompt"]:
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

    app.state.reescrita = Reescrita(executar, lambda: None, executar_json)
    app.state.pedidos = pedidos
    with TestClient(app, headers=AUTH_HEADERS) as c:
        yield c


def _esperar(api: TestClient, pid: str) -> dict:
    for _ in range(100):
        m = api.get(f"/api/estudos/projetos/{pid}/mapeamento").json()
        if m.get("estado") != "rodando":
            return m
        time.sleep(0.05)
    raise AssertionError("mapeamento não terminou")


def test_mapeamento_marca_citacoes_e_cria_pendencias(api: TestClient) -> None:
    pdf = _pdf(["Capitulo 1", "A leitura ativa exige marcar os trechos", "importantes do texto "
                "original. Depois vem outra frase."])
    r = api.post("/api/arquivos", files={"arquivo": ("silva2020.pdf", pdf)})
    assert r.status_code in (200, 201), r.text
    pdf_id = r.json()["id"]
    pid = api.post("/api/estudos/projetos", json={"nome": "Pré-TCC"}).json()["id"]

    doc = _docx([("Heading1", "Introdução"), ("", f"Segundo Silva (2020), “{CITADO}”")])
    r = api.post(f"/api/estudos/projetos/{pid}/documento", files={"arquivo": ("tcc.docx", doc)})
    assert r.status_code == 202, r.text
    m = _esperar(api, pid)
    assert m["estado"] == "pronto", m
    assert (m["citacoes"], m["marcadas"], m["pendentes"]) == (2, 1, 1)
    assert m["documento_id"] != pdf_id

    destaques = api.get(f"/api/arquivos/{pdf_id}/anotacoes").json()["destaques"]
    assert len(destaques) == 1 and destaques[0]["projetos"] == [pid]
    assert destaques[0]["retangulos"] and "importantes" in destaques[0]["texto"]

    matriz = api.get(f"/api/estudos/projetos/{pid}/matriz").json()
    item = matriz["itens"][0]
    assert item["classificacao"]["status_uso"] == "Usado"
    assert item["classificacao"]["secao"] == "Introdução"
    assert matriz["trabalhos"][0]["autor_citacao"] == "Silva"
    assert matriz["trabalhos"][0]["link"] == "https://doi.org/10.1/x"
    assert "Claude" not in item["classificacao"]["observacoes"]

    tarefas = api.get("/api/rotinas/tarefas").json()
    assert any("Souza" in t["titulo"] for t in tarefas)

    # refazer não duplica a marcação nem a tarefa
    assert api.post(f"/api/estudos/projetos/{pid}/mapeamento").status_code == 202
    m = _esperar(api, pid)
    assert m["marcadas"] == 1
    assert len(api.get(f"/api/arquivos/{pdf_id}/anotacoes").json()["destaques"]) == 1
    assert sum("Souza" in t["titulo"] for t in api.get("/api/rotinas/tarefas").json()) == 1


def test_dividir_documento_corta_em_titulo_e_leva_a_secao() -> None:
    from backend.files.mapping import dividir_documento

    texto = "\n".join(["# Introdução", *["frase " * 20] * 30, "# Método", *["linha " * 20] * 30])
    partes = dividir_documento(texto, limite=2000)
    assert len(partes) > 2
    assert "".join(partes).count("frase") == 600
    assert any(p.startswith("(continuação da seção: Introdução)") for p in partes)
    assert any(p.startswith("# Método") or "seção: Método" in p for p in partes)


def test_referencia_com_link_na_exportacao() -> None:
    from estudos.projects import link_do_trabalho, referencia_com_link

    assert link_do_trabalho({"doi": "doi: 10.5/abc"}) == "https://doi.org/10.5/abc"
    link = "https://doi.org/10.5/abc"
    t = {"referencia": "SILVA, A. Leitura. 2020.", "link": link, "doi": "",
         "autor": "", "titulo": "", "ano": ""}
    assert referencia_com_link(t) == f"SILVA, A. Leitura. 2020. Disponível em: {link}."
