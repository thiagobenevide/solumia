"""Projetos de leitura (pré-TCC, roteiro de vídeo…): reúnem os trechos marcados, comentários e
anotações à mão feitos no módulo Arquivos. O vínculo fica no próprio elemento da anotação (campo
`projetos`); aqui ficam o projeto, a classificação de cada trecho naquele projeto e o código
estável de cada trabalho (T001…). A matriz e a planilha seguem
`docs/Mapeamento de Conteúdo.xlsx`."""

import io
import re
from collections.abc import Callable
from typing import Any

TIPOS_CITACAO = [
    "Direta curta (até 3 linhas)",
    "Direta longa (mais de 3 linhas)",
    "Indireta (paráfrase)",
    "Citação de citação (apud)",
    "Ideia para redação própria",
]
TIPOS_CONTEUDO = [
    "Conceito ou definição",
    "Dado ou estatística",
    "Contexto",
    "Problema",
    "Lacuna",
    "Justificativa",
    "Objetivo",
    "Método ou procedimento",
    "Ferramenta ou tecnologia",
    "Resultado",
    "Conclusão",
    "Crítica ou limitação",
    "Figura, tabela ou quadro",
    "Critério ou protocolo",
]
STATUS_USO = ["Não usado", "Usado", "Descartado"]
CAMPOS_CLASSIFICACAO = {
    "secao",
    "tipo_citacao",
    "tipo_conteudo",
    "palavras_chave",
    "status_uso",
    "parafrase",
    "observacoes",
}
CAMPOS_PROJETO = {"nome", "descricao", "cor", "secoes"}

Marcacoes = Callable[[str], list[dict[str, Any]]]


def sobrenome_citacao(autor: str) -> str:
    """'Araújo, W. C. O.' / 'Wánderson Araújo; Fulano' → 'Araújo' ou 'Araújo et al.'."""
    autores = [a.strip() for a in re.split(r";|\s+e\s+|\s+and\s+", autor) if a.strip()]
    if not autores:
        return ""

    def sobrenome(a: str) -> str:
        return a.split(",")[0].strip() if "," in a else a.split()[-1]

    if len(autores) == 1:
        return sobrenome(autores[0])
    if len(autores) == 2:
        return f"{sobrenome(autores[0])} e {sobrenome(autores[1])}"
    return f"{sobrenome(autores[0])} et al."


def link_do_trabalho(leitura: dict[str, Any]) -> str:
    """Link do artigo para citar: a URL guardada na ficha ou, sem ela, o DOI em doi.org."""
    url = str(leitura.get("url") or "").strip()
    if url:
        return url
    doi = re.sub(r"^(https?://(dx\.)?doi\.org/|doi:\s*)", "", str(leitura.get("doi") or "").strip(),
                 flags=re.IGNORECASE)
    return f"https://doi.org/{doi}" if doi else ""


def referencia_com_link(t: dict[str, Any]) -> str:
    """Referência ABNT com "Disponível em: <link>." quando ela ainda não traz o link."""
    ref = (t.get("referencia") or f"{t['autor']}. {t['titulo']}. {t['ano']}").strip().strip(".")
    link = t.get("link") or ""
    if not link or link in ref or (t.get("doi") and t["doi"] in ref):
        return ref + "."
    return f"{ref}. Disponível em: {link}."


def _pagina(item: dict[str, Any]) -> int:
    return int(item.get("pagina") or 0) + 1


def montar_matriz(
    projeto: dict[str, Any], marcacoes: list[dict[str, Any]], leituras: list[dict[str, Any]]
) -> dict[str, Any]:
    """Junta as marcações do projeto com as fichas das leituras (ligadas por `arquivo_id`).
    Traços à mão viram um item por página (`manuscrito`). Devolve também os códigos de trabalho
    novos em `codigos`, para o chamador guardar no projeto."""
    codigos: dict[str, str] = dict(projeto.get("codigos") or {})
    classif: dict[str, dict[str, Any]] = projeto.get("classificacao") or {}
    por_arquivo = {x["arquivo_id"]: x for x in leituras if x.get("arquivo_id")}

    itens: list[dict[str, Any]] = []
    manuscritos: dict[tuple[str, int], dict[str, Any]] = {}
    for m in sorted(marcacoes, key=lambda m: (m["arquivo_titulo"].lower(), _pagina(m))):
        if m["tipo"] == "traco":
            chave = (m["arquivo_id"], int(m.get("pagina") or 0))
            grupo = manuscritos.get(chave)
            if grupo is None:
                grupo = manuscritos[chave] = {
                    "id": f"m-{m['arquivo_id']}-{chave[1]}",
                    "tipo": "manuscrito",
                    "arquivo_id": m["arquivo_id"],
                    "arquivo_titulo": m["arquivo_titulo"],
                    "pagina": chave[1],
                    "texto": "",
                    "tracos": [],
                    "criado": m.get("criado") or "",
                }
                itens.append(grupo)
            grupo["tracos"].append(
                {k: m[k] for k in ("pincel", "cor", "espessura", "pontos") if k in m}
            )
            continue
        itens.append({
            "id": m["id"],
            "tipo": m["tipo"],
            "arquivo_id": m["arquivo_id"],
            "arquivo_titulo": m["arquivo_titulo"],
            "pagina": int(m.get("pagina") or 0),
            "texto": m.get("texto") or "",
            "traducao": m.get("traducao") or "",
            "comentario": m.get("comentario") or "",
            "cor": m.get("cor"),
            "criado": m.get("criado") or "",
        })

    for arquivo_id in dict.fromkeys(i["arquivo_id"] for i in itens):
        if arquivo_id not in codigos:
            codigos[arquivo_id] = f"T{len(codigos) + 1:03d}"

    trabalhos: dict[str, dict[str, Any]] = {}
    for arquivo_id, codigo in codigos.items():
        leitura = por_arquivo.get(arquivo_id) or {}
        titulo_arquivo = next(
            (i["arquivo_titulo"] for i in itens if i["arquivo_id"] == arquivo_id), ""
        )
        if not leitura and not titulo_arquivo:
            continue  # arquivo sem marcações neste projeto agora
        autor = sobrenome_citacao(str(leitura.get("autor") or ""))
        ano = str(leitura.get("ano") or "")
        trabalhos[arquivo_id] = {
            "codigo": codigo,
            "arquivo_id": arquivo_id,
            "leitura_id": leitura.get("id"),
            "titulo": leitura.get("titulo") or titulo_arquivo,
            "autor": leitura.get("autor") or "",
            "autor_citacao": autor,
            "ano": ano,
            "referencia": leitura.get("referencia") or "",
            "tipo_publicacao": leitura.get("tipo_publicacao") or "",
            "veiculo": leitura.get("veiculo") or "",
            "doi": leitura.get("doi") or "",
            "link": link_do_trabalho(leitura),
            "idioma": leitura.get("idioma") or "",
            "status": leitura.get("status") or "",
        }

    contagem: dict[str, int] = {}
    for item in itens:
        trab = trabalhos[item["arquivo_id"]]
        contagem[trab["codigo"]] = contagem.get(trab["codigo"], 0) + 1
        item["trabalho"] = trab["codigo"]
        item["codigo"] = f"{trab['codigo']}-{contagem[trab['codigo']]:02d}"
        autor = trab["autor_citacao"] or trab["titulo"]
        ano = trab["ano"] or "s.d."
        item["citacao_parentetica"] = f"[{autor} {ano}]"
        item["citacao_narrativa"] = f"{autor} ({ano})"
        item["classificacao"] = {"status_uso": "Não usado", **(classif.get(item["id"]) or {})}
        trab["trechos"] = trab.get("trechos", 0) + 1
        if item["classificacao"].get("status_uso") == "Usado":
            trab["usados"] = trab.get("usados", 0) + 1

    lista_trab = sorted(trabalhos.values(), key=lambda t: t["codigo"])
    for t in lista_trab:
        t.setdefault("trechos", 0)
        t.setdefault("usados", 0)
    itens.sort(key=lambda i: (i["trabalho"], i["pagina"], i["criado"]))
    return {
        "projeto": {k: v for k, v in projeto.items() if k not in ("classificacao", "codigos")},
        "trabalhos": [t for t in lista_trab if t["trechos"]],
        "itens": itens,
        "codigos": codigos,
    }


def _rotulo_tipo(item: dict[str, Any]) -> str:
    return {
        "destaque": "Trecho marcado",
        "texto": "Comentário na página",
        "manuscrito": "Anotação à mão",
    }.get(item["tipo"], item["tipo"])


def exportar_xlsx(matriz: dict[str, Any]) -> bytes:
    """Planilha no formato do mapeamento: Trabalhos, Trechos, Painel (cobertura por seção) e
    Referências."""
    from openpyxl import Workbook
    from openpyxl.styles import Alignment, Font, PatternFill
    from openpyxl.utils import get_column_letter

    projeto = matriz["projeto"]
    wb = Workbook()
    cabecalho_fonte = Font(bold=True, color="FFFFFF")
    cabecalho_fundo = PatternFill("solid", fgColor="1F4E79")

    def aba(titulo: str, explicacao: str, colunas: list[tuple[str, int]], linhas: list[list[Any]]):
        ws = wb.create_sheet(titulo)
        ws["A1"] = f"{titulo} · {projeto.get('nome', '')}"
        ws["A1"].font = Font(bold=True, size=14)
        ws["A2"] = explicacao
        ws["A2"].font = Font(italic=True, color="555555")
        for c, (nome, largura) in enumerate(colunas, start=1):
            cel = ws.cell(row=4, column=c, value=nome)
            cel.font = cabecalho_fonte
            cel.fill = cabecalho_fundo
            cel.alignment = Alignment(wrap_text=True, vertical="center")
            ws.column_dimensions[get_column_letter(c)].width = largura
        for r, linha in enumerate(linhas, start=5):
            for c, valor in enumerate(linha, start=1):
                cel = ws.cell(row=r, column=c, value=valor)
                cel.alignment = Alignment(wrap_text=True, vertical="top")
                if isinstance(valor, str) and re.match(r"https?://\S+$", valor):
                    cel.hyperlink = valor  # link do artigo clicável
                    cel.font = Font(color="0563C1", underline="single")
        ws.freeze_panes = "A5"
        if linhas:
            ws.auto_filter.ref = f"A4:{get_column_letter(len(colunas))}{4 + len(linhas)}"
        return ws

    trabalhos = matriz["trabalhos"]
    aba(
        "Trabalhos",
        "Uma linha por trabalho lido com trechos ligados a este projeto.",
        [
            ("ID", 8), ("Autor para citação", 20), ("Ano", 8), ("Título", 45),
            ("Autor(es) completos", 35), ("Referência completa", 60), ("Tipo de publicação", 18),
            ("Veículo", 30), ("DOI", 28), ("Link do artigo", 45), ("Idioma", 12),
            ("Status de leitura", 14), ("Nº de trechos", 10), ("Trechos usados", 10),
        ],
        [
            [
                t["codigo"], t["autor_citacao"], t["ano"], t["titulo"], t["autor"],
                referencia_com_link(t), t["tipo_publicacao"], t["veiculo"], t["doi"],
                t.get("link", ""), t["idioma"], t["status"], t["trechos"], t["usados"],
            ]
            for t in trabalhos
        ],
    )
    itens = matriz["itens"]
    aba(
        "Trechos",
        "Uma linha por trecho, comentário ou anotação à mão, com a página para conferência.",
        [
            ("ID do trecho", 10), ("ID do trabalho", 9), ("Tipo", 16),
            ("Trecho (texto original)", 60), ("Tradução (PT-BR)", 60), ("Meu comentário", 45),
            ("Página", 7), ("Citação parentética", 20), ("Citação narrativa", 20),
            ("Título do trabalho", 35), ("Link do artigo", 40), ("Seção", 24),
            ("Tipo de citação", 22),
            ("Tipo de conteúdo", 22), ("Palavras-chave", 24), ("Status de uso", 12),
            ("Paráfrase ou redação própria", 45), ("Observações", 30),
        ],
        [
            [
                i["codigo"], i["trabalho"], _rotulo_tipo(i),
                i["texto"] if i["tipo"] != "manuscrito" else "(anotação à mão — ver no app)",
                i.get("traducao", ""), i.get("comentario", ""), i["pagina"] + 1,
                i["citacao_parentetica"], i["citacao_narrativa"],
                next((t["titulo"] for t in trabalhos if t["codigo"] == i["trabalho"]), ""),
                next((t.get("link", "") for t in trabalhos if t["codigo"] == i["trabalho"]), ""),
                i["classificacao"].get("secao", ""), i["classificacao"].get("tipo_citacao", ""),
                i["classificacao"].get("tipo_conteudo", ""),
                i["classificacao"].get("palavras_chave", ""),
                i["classificacao"].get("status_uso", ""), i["classificacao"].get("parafrase", ""),
                i["classificacao"].get("observacoes", ""),
            ]
            for i in itens
        ],
    )
    secoes: dict[str, list[int]] = {s: [0, 0] for s in projeto.get("secoes") or []}
    for i in itens:
        s = i["classificacao"].get("secao") or "Não definido"
        cont = secoes.setdefault(s, [0, 0])
        cont[0] += 1
        cont[1] += i["classificacao"].get("status_uso") == "Usado"
    aba(
        "Painel",
        f"{len(itens)} itens · {sum(c[1] for c in secoes.values())} usados na escrita.",
        [("Seção", 40), ("Trechos", 10), ("Usados", 10), ("Disponíveis", 12)],
        [[s, c[0], c[1], c[0] - c[1]] for s, c in secoes.items()],
    )
    citados = {i["trabalho"] for i in itens if i["classificacao"].get("status_uso") == "Usado"}
    aba(
        "Referências",
        "Referências completas com o link do artigo; 'Citada' = ao menos um trecho marcado como "
        "Usado.",
        [("Referência", 90), ("Link do artigo", 45), ("Citada", 10)],
        [
            [referencia_com_link(t), t.get("link", ""), "Sim" if t["codigo"] in citados else ""]
            for t in sorted(trabalhos, key=lambda t: (t["autor_citacao"] or t["titulo"]).lower())
        ],
    )
    wb.remove(wb["Sheet"])
    saida = io.BytesIO()
    wb.save(saida)
    return saida.getvalue()
