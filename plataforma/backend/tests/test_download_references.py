from backend.files.download_references import (
    doi_of_reference,
    links_of_reference,
    links_openalex,
)


def test_reference_doi_and_links() -> None:
    ref = (
        "SILVA, A. Título. Revista, 2020. DOI: 10.1000/xyz.123. "
        "Disponível em: https://site.org/artigo.pdf. Preprint: https://arxiv.org/abs/2101.00001."
    )
    assert doi_of_reference(ref) == "10.1000/xyz.123"
    assert links_of_reference(ref) == ["https://site.org/artigo.pdf", "https://arxiv.org/pdf/2101.00001"]


def test_openalex_links_only_open() -> None:
    work = {
        "best_oa_location": {"pdf_url": "https://a/1.pdf", "is_oa": True},
        "locations": [
            {"pdf_url": "https://a/1.pdf", "is_oa": True},
            {"pdf_url": "https://fechado/2.pdf", "is_oa": False},
        ],
        "open_access": {"oa_url": "https://a/pagina"},
    }
    assert links_openalex(work) == ["https://a/1.pdf", "https://a/pagina"]
