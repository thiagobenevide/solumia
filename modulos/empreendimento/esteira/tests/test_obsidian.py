"""Leitura dos roteiros do vault: falas, notas de cena e blocos [!cite] (citação com PDF, página e trecho)."""
from esteira.sources import obsidian

ROTEIRO = '''---
tipo: roteiro
video: 5
---
# Roteiro — 005 Cartão ou dinheiro

## Parte 1 — Gancho (0:00)
> [!example] Cena
> leilão de ingressos

**Passo 1**
"Em 2021, Banker e colegas colocaram pessoas num aparelho de ressonância."
> [!cite] Banker et al. (2021) — Scientific Reports
> **Título:** Neural mechanisms of credit card spending
> **DOI:** 10.1038/s41598-021-83488-3
> **PDF:** [[Referências/Artigos/banker-2021.pdf#page=7|banker-2021.pdf, p. 7]]
> **Página:** 7
> **EN:** ==Exposure to credit card logos has also been shown to increase the willingness to pay==
> **PT:** Ver o logotipo do cartão já aumenta quanto as pessoas aceitam pagar.
> [!example] Cena
> cérebro acendendo

**Passo 2**
"E o resultado surpreendeu."

## Notas de produção
- [ ] **Banker et al. (2021)**: "Neural mechanisms of credit card spending", *Scientific Reports* 11. DOI 10.1038/s41598-021-83488-3.
'''


def test_citacao_do_roteiro():
    titulo, linhas, notas, fontes, citacoes = obsidian.converter(ROTEIRO)
    assert [l["fala"][:8] for l in linhas if "fala" in l] == ["Em 2021,", "E o resu"]
    assert len(notas) == 2 and notas[1]["texto"] == "cérebro acendendo"
    assert len(fontes) == 1
    (c,) = citacoes
    assert c["fala"] == 0 and c["pagina"] == 7 and c["arquivo"] == "Referências/Artigos/banker-2021.pdf"
    assert c["en"].startswith("Exposure") and not c["en"].endswith("==")
    assert c["pt"].startswith("Ver o logotipo")
    assert (c["autores"], c["ano"], c["revista"]) == ("Banker et al.", "2021", "Scientific Reports")
    assert c["titulo"] == "Neural mechanisms of credit card spending"


def test_short_pela_pasta_e_nome():
    assert obsidian.short("Short 005a — Cartão.md", {}) == "a"
    assert obsidian.short("Roteiro — 005 Cartão.md", {}) == ""
    assert obsidian.titulo_limpo("# Short 005b — O cartão anestesia") == "O cartão anestesia"
