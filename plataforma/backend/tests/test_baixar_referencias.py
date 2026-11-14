from backend.arquivos.baixar_referencias import (
    doi_da_referencia,
    links_da_referencia,
    links_openalex,
)


def test_doi_e_links_da_referencia() -> None:
    ref = (
        "SILVA, A. Título. Revista, 2020. DOI: 10.1000/xyz.123. "
        "Disponível em: https://site.org/artigo.pdf. Preprint: https://arxiv.org/abs/2101.00001."
    )
    assert doi_da_referencia(ref) == "10.1000/xyz.123"
    assert links_da_referencia(ref) == ["https://site.org/artigo.pdf", "https://arxiv.org/pdf/2101.00001"]


def test_links_openalex_so_abertos() -> None:
    obra = {
        "best_oa_location": {"pdf_url": "https://a/1.pdf", "is_oa": True},
        "locations": [
            {"pdf_url": "https://a/1.pdf", "is_oa": True},
            {"pdf_url": "https://fechado/2.pdf", "is_oa": False},
        ],
        "open_access": {"oa_url": "https://a/pagina"},
    }
    assert links_openalex(obra) == ["https://a/1.pdf", "https://a/pagina"]
