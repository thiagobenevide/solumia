"""Rotas do módulo Finanças. A plataforma monta o router em `/api/financas` com a autenticação e
guarda o [Armazem] em `app.state.financas`. As coleções simples usam o CRUD genérico
`/{colecao}`; as rotas específicas (resumo, importação, análise) vêm antes dele."""

import re
from datetime import date
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, File, Form, HTTPException, Request, UploadFile

from financas import analysis, study, statement, reports
from financas.warehouse import SCHEMAS, Warehouse, Invalid, NotFound, data_iso

router = APIRouter(tags=["financas"])


def get_warehouse(request: Request) -> Warehouse:
    arm: Warehouse = request.app.state.financas
    return arm


ArmDep = Annotated[Warehouse, Depends(get_warehouse)]
Payload = Annotated[dict[str, Any], Body()]


def _error(e: Exception) -> HTTPException:
    if isinstance(e, NotFound):
        return HTTPException(404, "Não encontrado")
    return HTTPException(422, str(e))


# --- painel e relatórios ---


@router.get("/resumo")
def summary(arm: ArmDep, mes: str | None = None) -> Any:
    try:
        return reports.summary(arm, mes or date.today().isoformat()[:7])
    except Invalid as e:
        raise _error(e) from e


@router.get("/fluxo")
def flow(arm: ArmDep, meses: int = 12, ate: str | None = None) -> Any:
    try:
        return reports.flow(arm, max(1, min(meses, 60)), ate)
    except Invalid as e:
        raise _error(e) from e


@router.get("/contrapartes")
def counterparts(
    arm: ArmDep, de: str | None = None, ate: str | None = None, limite: int = 15
) -> Any:
    try:
        return reports.counterparts(arm, de, ate, limite)
    except Invalid as e:
        raise _error(e) from e


@router.get("/faturas/{conta_id}")
def invoices(arm: ArmDep, conta_id: str) -> Any:
    try:
        return reports.invoices(arm, conta_id)
    except (NotFound, Invalid) as e:
        raise _error(e) from e


@router.get("/projecao")
def projection(arm: ArmDep, dias: int = 60) -> Any:
    dias = max(1, min(dias, 366))
    return {
        "itens": reports.projection(arm, dias=dias),
        "saldo": reports.projection_balance(arm, dias),
    }


@router.post("/programacoes/{id_}/lancar", status_code=201)
def post(arm: ArmDep, id_: str, corpo: Payload) -> Any:
    try:
        return reports.post(arm, id_, data_iso(corpo.get("data", "")))
    except (NotFound, Invalid) as e:
        raise _error(e) from e


@router.get("/metas/progresso")
def goals(arm: ArmDep) -> Any:
    return reports.goals(arm)


# --- extrato ---


@router.get("/transacoes")
def transactions(
    arm: ArmDep,
    de: str | None = None,
    ate: str | None = None,
    conta_id: str | None = None,
    categoria_id: str | None = None,
    q: str = "",
    sem_categoria: bool = False,
    limite: int = 2000,
) -> Any:
    try:
        de_, until_ = (data_iso(de) if de else ""), (data_iso(ate) if ate else "9999")
    except Invalid as e:
        raise _error(e) from e
    target = statement.normalize(q)
    items = [
        t
        for t in arm.todos("transacoes")
        if de_ <= (t["data"] or "") <= until_
        and (conta_id is None or t["conta_id"] == conta_id)
        and (categoria_id is None or t["categoria_id"] == categoria_id)
        and (not sem_categoria or not t["categoria_id"])
        and (
            not target
            or target in statement.normalize(f"{t['descricao']} {t['contraparte']} {t['observacao']}")
        )
    ]
    items.sort(key=lambda t: (t["data"] or "", t["id"]), reverse=True)
    return items[:limite]


@router.post("/transacoes/lote")
def batch(arm: ArmDep, corpo: Payload) -> Any:
    """Aplica os mesmos campos (`dados`) em várias transações (`ids`); `regra` cria a regra."""
    ids = set(corpo.get("ids") or [])
    data = corpo.get("dados") or {}
    try:
        done = [arm.editar("transacoes", i, _prepare("transacoes", data)) for i in ids]
        if corpo.get("regra") and done and data.get("categoria_id"):
            arm.criar(
                "regras",
                {
                    "padrao": corpo["regra"],
                    "categoria_id": data["categoria_id"],
                    "contraparte": data.get("contraparte", ""),
                },
            )
            statement.apply_rules(arm)
    except (NotFound, Invalid) as e:
        raise _error(e) from e
    return {"alteradas": len(done)}


def get_llms(request: Request) -> dict[str, Any]:
    """Provedores de LLM da plataforma (`local` = worker no PC, `claude` se houver chave)."""
    return getattr(request.app.state, "financas_llms", {})


LLMsDep = Annotated[dict[str, Any], Depends(get_llms)]

# Tarefas de IA em andamento (em memória): o LLM pode levar minutos e a Cloudflare corta resposta
# que demora mais de 100 s para começar; o app cria a tarefa e consulta `GET /tarefas/{id}`.
_TASKS: dict[str, dict[str, Any]] = {}
_SECOND_PLAN: set[Any] = set()  # referência às tasks soltas para o GC não as matar


def _task(work: Any, parcial: dict[str, Any] | None = None) -> dict[str, Any]:
    """Começa [trabalho] (corrotina) em segundo plano; só pode ser chamada de rota `async`. Com
    [parcial], o trabalho vai preenchendo esse dict e o app mostra o que já chegou."""
    import asyncio
    import uuid

    tid = uuid.uuid4().hex[:12]
    t: dict[str, Any] = {"estado": "rodando"}
    if parcial is not None:
        t["parcial"] = parcial

    async def rodar() -> None:
        try:
            t.update(estado="pronto", resultado=await work())
        except Invalid as e:
            t.update(estado="erro", erro=str(e))
        except Exception as e:  # worker desligado, tempo esgotado, API fora
            t.update(estado="erro", erro=f"A IA não respondeu: {e}")

    while len(_TASKS) >= 50:
        _TASKS.pop(next(iter(_TASKS)))
    _TASKS[tid] = t
    t["_task"] = asyncio.create_task(rodar())
    return {"tarefa": tid, "estado": "rodando"}


def _llm(llms: dict[str, Any], provedor: str) -> Any:
    llm = llms.get(provedor)
    if llm is None:
        raise HTTPException(503, f"IA '{provedor}' indisponível.")
    return llm


@router.get("/tarefas/{tid}")
def task(tid: str) -> Any:
    t = _TASKS.get(tid)
    if t is None:
        raise HTTPException(404, "Tarefa não encontrada (o servidor reiniciou?).")
    return {k: v for k, v in t.items() if not k.startswith("_")}


@router.get("/ia/provedores")
def providers(llms: LLMsDep) -> Any:
    return sorted(k for k in llms if k != "local_rapido")  # o modo rápido é interno da conversa


def _store_original(request: Request, account: dict[str, Any], nome: str, content: bytes) -> None:
    """O arquivo bruto do extrato vai para o módulo Arquivos (`Finanças/Extratos/<conta>`)."""
    collection = getattr(request.app.state, "biblioteca", None)
    if collection is None:
        return
    import threading

    try:
        meta = collection.adicionar(nome, content, pasta=f"Finanças/Extratos/{account['nome']}")
        if meta.get("status") == "convertendo":
            threading.Thread(target=collection.converter, args=(meta["id"],), daemon=True).start()
    except Exception:  # noqa: BLE001 — guardar a cópia não pode impedir a importação
        pass


@router.post("/importar")
async def run_import(
    request: Request,
    arm: ArmDep,
    llms: LLMsDep,
    arquivo: Annotated[UploadFile, File()],
    conta_id: Annotated[str, Form()],
    provedor: Annotated[str, Form()] = "local",
) -> Any:
    """Lê o extrato (OFX, CSV e XLS/XLSX dos bancos) e grava sem duplicar. PDF ou layout que o
    código não reconhece vira tarefa da IA (resposta 202 com `tarefa`)."""
    name, content = arquivo.filename or "", await arquivo.read()
    try:
        account = arm.obter("contas", conta_id)
        _store_original(request, account, name, content)
        try:
            r = statement.write_entries(
                arm, statement.read_file(name, content, account["tipo"]), conta_id
            )
            return _categorize_new(arm, llms.get(provedor), r)
        except statement.NeedsAi as e:
            from fastapi.responses import JSONResponse

            from financas import ai

            llm, text = _llm(llms, provedor), e.texto

            async def trabalho() -> Any:
                items = await ai.extract_entries(llm, text, fatura=account["tipo"] == "cartao")
                r = statement.write_entries(arm, items, conta_id)
                ids = r.pop("ids")
                if r["sem_categoria"] and arm.todos("categorias"):
                    try:
                        done = await ai.categorize(llm, arm, ids=ids)
                        r["sem_categoria"] -= done["categorizadas"]
                    except Exception:  # noqa: BLE001 — os lançamentos já estão gravados
                        pass
                return {**r, "lido_pela_ia": True}

            return JSONResponse(_task(trabalho) | {"motivo": str(e)}, status_code=202)
    except (NotFound, Invalid) as e:
        raise _error(e) from e


def _categorize_new(arm: Warehouse, llm: Any, r: dict[str, Any]) -> dict[str, Any]:
    """O que as regras e o histórico não categorizaram vai para a IA em segundo plano; o app
    acompanha pela tarefa em `categorizando`."""
    ids = r.pop("ids")
    if llm is None or not r["sem_categoria"] or not arm.todos("categorias"):
        return r
    from financas import ai

    return {**r, "categorizando": _task(lambda: ai.categorize(llm, arm, ids=ids))["tarefa"]}


@router.post("/regras/aplicar")
def apply_rules(arm: ArmDep) -> Any:
    return {"categorizadas": statement.apply_rules(arm)}


@router.post("/corrigir", status_code=202)
async def fix(request: Request, arm: ArmDep, llms: LLMsDep, provedor: str = "local") -> Any:
    """Reconferência em segundo plano: conserta o que já está gravado (sinal e forma de pagamento da
    conta do cartão, regras) e passa na IA o que segue sem categoria ou sem forma, o que a IA
    categorizou antes e o que está na categoria do sentido errado."""

    from financas import ai

    collection = getattr(request.app.state, "biblioteca", None)
    llm = llms.get(provedor)

    def originais() -> dict[str, list[tuple[str, bytes]]]:
        if collection is None:
            return {}
        by_account: dict[str, list[tuple[str, bytes]]] = {}
        for c in arm.todos("contas"):
            for meta in collection.listar(pasta=f"Finanças/Extratos/{c['nome']}"):
                try:
                    path, name = collection.caminho_original(meta["id"])
                    by_account.setdefault(c["id"], []).append((name, path.read_bytes()))
                except Exception:  # noqa: BLE001 — arquivo sumido não impede o resto
                    continue
        return by_account

    async def trabalho() -> Any:
        done = statement.fix(arm, originais())
        done["categorizadas_ia"] = done["trocadas_ia"] = 0
        if llm is not None and arm.todos("categorias"):
            try:
                r = await ai.categorize(llm, arm, limite=3000, revisar=True)
                done["categorizadas_ia"], done["trocadas_ia"] = r["categorizadas"], r["trocadas"]
                done["formas"] += r["formas"]
            except Exception as e:  # noqa: BLE001 — o conserto do sinal e da forma já foi gravado
                done["erro_ia"] = f"A IA não respondeu: {e}"
        done["sem_categoria"] = sum(1 for t in arm.todos("transacoes") if not t["categoria_id"])
        return done

    return _task(trabalho)


@router.post("/categorizar-ia", status_code=202)
async def categorize_ai(arm: ArmDep, llms: LLMsDep, provedor: str = "local") -> Any:
    """Categoriza com a IA os lançamentos que as regras e o histórico não pegaram."""
    from financas import ai

    llm = _llm(llms, provedor)
    return _task(lambda: ai.categorize(llm, arm))


# --- parcelamentos e cenários (análise preditiva) ---


@router.get("/parcelamentos")
def installment_plans(arm: ArmDep) -> Any:
    from financas import scenarios

    return scenarios.installment_plans(arm)


@router.post("/cenarios/simular")
def simulate(arm: ArmDep, corpo: Payload) -> Any:
    """Juntar × financiar um bem sobre a sua realidade do extrato (só contas, sem IA)."""
    from financas import scenarios

    if not corpo.get("valor"):
        raise HTTPException(422, "Informe o valor do bem.")
    try:
        return scenarios.simulate(arm, corpo)
    except (TypeError, ValueError) as e:
        raise HTTPException(422, f"Parâmetro inválido: {e}") from e


@router.post("/cenarios/perguntar", status_code=202)
async def ask(request: Request, arm: ArmDep, llms: LLMsDep, corpo: Payload) -> Any:
    """Pergunta livre ("quero um EcoSport 2015 de 45 mil, quanto tempo para juntar?"): a IA tira os
    parâmetros, o Python simula e a IA explica o resultado. `ajustes` sobrescreve o que a IA
    tirou."""
    from financas import scenarios, ai

    question = str(corpo.get("pergunta") or "").strip()
    if not question:
        raise HTTPException(422, "Escreva o que você quer comprar.")
    llm = _llm(llms, str(corpo.get("provedor") or "local"))
    adjustments = corpo.get("ajustes") or {}

    internet = getattr(request.app.state, "internet", None)

    async def trabalho() -> Any:
        parameters = {**await ai.interpret(llm, question), **adjustments}
        # Dados de hoje: preço FIPE (completa o valor que faltou) e CDI (rendimento da reserva).
        current = await ai.data_current(internet, parameters)
        if not parameters.get("valor") and current.get("fipe"):
            parameters["valor"] = current["fipe"]["media"]
        if not parameters.get("valor"):
            raise Invalid(
                "Não achei o valor do bem: diga quanto custa (ex.: 'carro de R$ 45 mil')."
            )
        if current.get("rendimento_mensal"):
            parameters.setdefault("rendimento_mensal", current["rendimento_mensal"])
        result = scenarios.simulate(arm, parameters)
        return {
            "parametros": parameters,
            "dados_atuais": current,
            "resultado": result,
            "analise": await ai.analyze(llm, question, result, current),
        }

    return _task(trabalho)


@router.post("/cenarios/conversar")
async def chat(arm: ArmDep, llms: LLMsDep, corpo: Payload) -> Any:
    """Conversa curta (texto ou voz) sobre os seus dados e a simulação aberta. `mensagens`:
    [{role: user|assistant, content}], a última é a pergunta; `cenario`: {pergunta, analise}.
    No LLM local usa o modo rápido (sem raciocínio): a resposta sai em 1–3 s."""
    from financas import ai

    messages = [
        {"role": m["role"], "content": str(m["content"])[:4000]}
        for m in corpo.get("mensagens") or []
        if isinstance(m, dict) and m.get("role") in ("user", "assistant") and m.get("content")
    ]
    if not messages or messages[-1]["role"] != "user":
        raise HTTPException(422, "Diga ou escreva a sua pergunta.")
    provider = str(corpo.get("provedor") or "local")
    llm = llms.get("local_rapido") if provider == "local" else None
    llm = llm or _llm(llms, provider)
    answer = await ai.chat(llm, messages, ai.context_financial(arm), corpo.get("cenario"))
    return {"resposta": answer}


# --- mercado em tempo real e dados oficiais (CVM) ---


def _internet(request: Request) -> Any:
    internet = getattr(request.app.state, "internet", None)
    if internet is None:
        raise HTTPException(503, "Sem acesso à internet no servidor.")
    return internet


def _cvm(arm: Warehouse) -> Any:
    from financas.cvm import CVM

    return CVM(arm.raiz)


_WARM = [0.0]


@router.get("/mercado/destaques")
async def highlights(request: Request, arm: ArmDep, tipo: str = "stock") -> Any:
    """10 maiores altas e 10 maiores baixas do dia na B3 (`fund` = fundos/FIIs). De carona, renova
    em segundo plano os arquivos da CVM (no máximo 1x/hora) para a ficha do ativo abrir rápido."""
    import asyncio
    import time

    if time.time() - _WARM[0] > 3600:
        _WARM[0] = time.time()
        _SECOND_PLAN.add(t := asyncio.create_task(asyncio.to_thread(_cvm(arm).aquecer)))
        t.add_done_callback(_SECOND_PLAN.discard)
    r = await _internet(request).usar("mercado", {"tipo": "fund" if tipo == "fund" else "stock"})
    if "erro" in r:
        raise HTTPException(503, r["erro"])
    return r


@router.get("/mercado/noticias")
async def news(request: Request, tema: str = "economia") -> Any:
    """Manchetes do dia por tema: economia, acoes, fiis, impostos ou juros."""
    r = await _internet(request).usar("noticias", {"tema": tema})
    if "erro" in r:
        raise HTTPException(503, r["erro"])
    return r


@router.post("/mercado/ativo", status_code=202)
async def active(request: Request, arm: ArmDep, corpo: Payload) -> Any:
    """Tudo sobre um ticker ou nome: cotação, proventos e, conforme o tipo, os informes do FII ou
    DRE/balanço/fluxo (CVM) com os links dos DFP, ITR e releases. Vira tarefa: a primeira consulta
    baixa os arquivos da CVM."""
    import asyncio

    from financas import cvm as m_cvm

    q = str(corpo.get("q") or "").strip()
    if not q:
        raise HTTPException(422, "Diga o ticker ou o nome.")
    internet, base = _internet(request), _cvm(arm)
    # O app mostra a ficha da ação assim que o cadastro chega; `carregando` diz o que ainda falta.
    parcial: dict[str, Any] = {}

    async def mercado(ticker: str) -> tuple[Any, Any]:
        if not ticker:
            return {}, {}
        return await asyncio.gather(
            internet.usar("acoes", {"tickers": [ticker]}),
            internet.usar("proventos", {"ticker": ticker}),
        )

    async def trabalho() -> Any:
        ticker = q.upper() if re.fullmatch(r"[A-Za-z0-9]{4}\d{1,2}", q) else ""
        if not ticker:  # nome ou apelido: o mais provável da busca (ação ou FII)
            suggestions = await asyncio.to_thread(base.sugerir, q, 1)
            if suggestions and suggestions[0]["tipo"] == "fii":
                ticker = suggestions[0]["tickers"][0]
        # cotação e proventos já saem junto com a leitura da CVM
        cotacoes = asyncio.create_task(mercado(ticker))
        background = await asyncio.to_thread(m_cvm.fii, base, ticker) if ticker.endswith("11") else None
        if background:
            cot, prov = await cotacoes
            preco = cot.get("cotacoes", {}).get(ticker, {})
            vp = (background["meses"][-1]["valor_patrimonial_cota"] if background["meses"] else None) or None
            return {
                "tipo": "fii",
                **background,
                "cotacao": preco,
                "proventos": prov,
                "p_vp": round(preco["preco"] / vp, 2) if preco.get("preco") and vp else None,
            }
        found = await asyncio.to_thread(base.buscar, ticker or q)
        if not found:
            cotacoes.cancel()
            raise Invalid(f"Não achei '{q}' na CVM (empresa ou FII listado).")
        e = found[0]
        if ticker not in e["tickers"]:
            cotacoes.cancel()
            ticker = e["tickers"][0] if e["tickers"] else ""
            cotacoes = asyncio.create_task(mercado(ticker))
        carregando = parcial.setdefault("carregando", [])
        carregando += ["cotacao", "demonstrativos", "documentos"]
        parcial.update({**e, "tipo": "acao", "ticker": ticker, "outros": found[1:5]})
        parcial["demonstrativos"] = []

        def resumir() -> None:
            """Indicadores e valuation com o que já chegou (refeito quando chega mais)."""
            preco = (parcial.get("cotacao") or {}).get("preco")
            parcial.update(analysis.summary_card(parcial["demonstrativos"], preco, e["setor"]))

        async def cotacao() -> None:
            cot, prov = await cotacoes
            parcial.update(
                cotacao=(cot or {}).get("cotacoes", {}).get(ticker, {}), proventos=prov or {}
            )
            carregando.remove("cotacao")
            resumir()

        def ao_ano(years: list[dict[str, Any]]) -> None:
            parcial["demonstrativos"] = analysis.clean_statements(years)
            resumir()

        async def demonstrativos() -> None:
            d = await asyncio.to_thread(base.demonstrativos, e["codigo_cvm"], ao_ano=ao_ano)
            parcial["demonstrativos"] = analysis.clean_statements(d) if d else []
            carregando.remove("demonstrativos")
            resumir()

        async def documentos() -> None:
            parcial["documentos"] = await asyncio.to_thread(
                base.documentos, e["codigo_cvm"], ticker
            )
            carregando.remove("documentos")

        await asyncio.gather(cotacao(), demonstrativos(), documentos())
        return {k: v for k, v in parcial.items() if k != "carregando"}

    return _task(trabalho, parcial)


@router.get("/mercado/sugerir")
async def suggest(arm: ArmDep, q: str = "", limite: int = 12) -> Any:
    """Busca enquanto digita (ações e FIIs): ticker pelo começo, nome, apelido e nome parecido."""
    import asyncio

    if len(q.strip()) < 2:
        return []
    try:
        return await asyncio.to_thread(_cvm(arm).sugerir, q, min(max(limite, 1), 30))
    except Exception as e:  # sem rede na primeira vez: a CVM ainda não foi baixada
        raise HTTPException(503, f"Busca indisponível: {e}") from e


async def _empty() -> dict[str, Any]:
    return {}


@router.post("/empresas/{id_}/importar-cvm", status_code=202)
async def import_cvm(request: Request, arm: ArmDep, id_: str) -> Any:
    """Preenche DRE, balanço e fluxo de caixa (6 anos, R$ mil), o número de ações (mil), a cotação
    do dia e o cadastro da empresa pela CVM: sem ações e cotação, P/L, P/VP e preço justo ficam
    vazios."""
    import asyncio

    try:
        company = arm.obter("empresas", id_)
    except NotFound as e:
        raise _error(e) from e
    base = _cvm(arm)

    async def trabalho() -> Any:
        found = await asyncio.to_thread(base.buscar, company["ticker"] or company["nome"])
        if not found:
            raise Invalid(f"{company['ticker']} não está na CVM.")
        e = found[0]
        ticker = company["ticker"].upper() if company["ticker"] in e["tickers"] else ""
        ticker = ticker or (e["tickers"][0] if e["tickers"] else "")
        years, cot = await asyncio.gather(
            asyncio.to_thread(base.demonstrativos, e["codigo_cvm"]),
            _internet(request).usar("acoes", {"tickers": [ticker]}) if ticker else _empty(),
        )
        preco = ((cot or {}).get("cotacoes", {}).get(ticker) or {}).get("preco")
        actions = next((d["acoes"] for d in reversed(years) if d.get("acoes")), None)
        old = {d["ano"]: d for d in company["demonstrativos"]}
        for d in years:  # o que veio da CVM substitui o ano; o resto que você digitou fica
            old[d["ano"]] = {**old.get(d["ano"], {}), **d}
        data = {
            "demonstrativos": analysis.clean_statements(list(old.values())),
            "cnpj": company["cnpj"] or e["cnpj"],
            "site": company["site"] or e["site"],
            "nome": company["nome"] or e["nome"],
            "setor": company["setor"] or e["setor"],
            "descricao": company["descricao"] or e["atividade"],
            "ticker": company["ticker"].upper() or ticker,
            **({"cotacao": preco} if preco else {}),
            **({"acoes": actions} if actions else {}),
        }
        return {"empresa": arm.editar("empresas", id_, data), "anos": [d["ano"] for d in years]}

    return _task(trabalho)


def pdf_of_document(content: bytes) -> bytes | None:
    """O PDF de um documento da CVM: o próprio arquivo (release, apresentação) ou, no pacote ZIP do
    DFP/ITR, o maior PDF lá dentro (as demonstrações completas)."""
    import io
    import zipfile

    if content.startswith(b"%PDF"):
        return content
    if content.startswith(b"PK"):
        try:
            with zipfile.ZipFile(io.BytesIO(content)) as z:
                pdfs = [i for i in z.infolist() if i.filename.lower().endswith(".pdf")]
                if pdfs:
                    return z.read(max(pdfs, key=lambda i: i.file_size))
        except zipfile.BadZipFile:
            return None
    return None


def link_safe(url: str) -> str:
    """Os links da CVM vêm em http://, que a CVM recusa (e o Android bloqueia): sempre https."""
    return "https://" + url.split("://", 1)[1] if url.startswith("http://") else url


@router.post("/mercado/guardar", status_code=202)
async def store_document(request: Request, corpo: Payload) -> Any:
    """Baixa um documento da CVM (release, apresentação, DFP/ITR) e guarda o PDF no módulo Arquivos
    (`Finanças/<ticker>`), para abrir no leitor do app, grifar e anotar. Vira tarefa: o pacote do
    DFP passa de 20 MB. O mesmo documento de novo não duplica (o Arquivos devolve o já guardado)."""
    import httpx

    url = link_safe(str(corpo.get("url") or ""))
    ticker = str(corpo.get("ticker") or "Mercado").upper()
    if not url.startswith("https://www.rad.cvm.gov.br/"):
        raise HTTPException(422, "Só documentos do RAD da CVM.")
    collection = getattr(request.app.state, "biblioteca", None)
    if collection is None:
        raise HTTPException(503, "Módulo Arquivos indisponível.")
    title = (
        re.sub(r"[^\w\s.-]", "", str(corpo.get("titulo") or "documento"))[:80].strip()
        or "documento"
    )

    async def trabalho() -> Any:
        try:
            async with httpx.AsyncClient(follow_redirects=True, timeout=180) as c:
                r = await c.get(url, headers={"User-Agent": "Mozilla/5.0"})
                r.raise_for_status()
        except httpx.HTTPError as e:
            raise Invalid(f"A CVM não entregou o documento ({e.__class__.__name__}).") from e
        pdf = pdf_of_document(r.content)
        if pdf is None:
            raise Invalid("O documento da CVM não tem PDF dentro: abra pelo navegador.")
        meta = collection.adicionar(f"{ticker} {title}.pdf", pdf, pasta=f"Finanças/{ticker}")
        return {"arquivo": meta}

    return _task(trabalho)


# --- empresas, setores e carteira ---


@router.get("/questionario")
def questionnaire(arm: ArmDep) -> Any:
    return arm.questionario()


@router.put("/questionario")
def save_questionnaire(arm: ArmDep, corpo: Annotated[list[dict[str, Any]], Body()]) -> Any:
    try:
        return arm.salvar_questionario(corpo)
    except Invalid as e:
        raise _error(e) from e


@router.get("/empresas/ranking")
def ranking(arm: ArmDep) -> Any:
    return analysis.ranking(arm)


@router.get("/empresas/{id_}/analise")
def analyze(arm: ArmDep, id_: str) -> Any:
    try:
        return analysis.analyze(arm, arm.obter("empresas", id_))
    except (NotFound, Invalid) as e:
        raise _error(e) from e


@router.get("/setores/{id_}/analise")
def analyze_sector(arm: ArmDep, id_: str) -> Any:
    try:
        return analysis.sector_analysis(arm, arm.obter("setores", id_))
    except NotFound as e:
        raise _error(e) from e


# ---------- estudos de finanças (trilha, livros, artigos, relatórios) ----------


@router.get("/estudo")
def study_track(arm: ArmDep, objetivo: str = "") -> Any:
    """Trilha de finanças com o progresso, o guia de cada livro, artigos e relatórios."""
    return study.assemble(arm, objetivo)


@router.put("/estudo/objetivo")
def study_goal(arm: ArmDep, corpo: Payload) -> Any:
    goal = str(corpo.get("objetivo") or "")
    if goal not in {o["id"] for o in study.GOALS}:
        raise HTTPException(422, "Objetivo desconhecido.")
    study.mark(arm, "objetivo", {"nota": goal})
    return study.assemble(arm, goal)


@router.patch("/estudo/itens")
def study_mark(arm: ArmDep, corpo: Payload) -> Any:
    """`{item, status?, nota?}`: item = `etapa:<id>`, `livro:<id>`, `cap:<livro>:<n>`,
    `artigo:<id>` ou `relatorio:<id>`."""
    try:
        return study.mark(arm, str(corpo.get("item") or ""), corpo)
    except Invalid as e:
        raise _error(e) from e


@router.put("/estudo/livros/{id_}/tenho")
def study_have(arm: ArmDep, id_: str, corpo: Payload) -> Any:
    try:
        return study.have(arm, id_, bool(corpo.get("tenho")))
    except (Invalid, NotFound) as e:
        raise _error(e) from e


def _rewrite(request: Request) -> Any:
    """Claude Code headless do worker (o mesmo do mapeamento de leituras), ou 503."""
    r = getattr(request.app.state, "reescrita", None)
    reason = r.disponivel() if r is not None else "Claude indisponível neste servidor."
    if reason or r.executar_json is None:
        raise HTTPException(503, reason or "Claude indisponível neste servidor.")
    return r


@router.post("/estudo/livros/{id_}/guia", status_code=202)
async def study_guide(request: Request, arm: ArmDep, id_: str) -> Any:
    """O Claude monta o guia de leitura não linear do livro (capítulos, ordem, por quê) e o guia
    fica gravado; nos livros do catálogo ele completa o que já está escrito."""
    claude = _rewrite(request)
    book = study.books(arm).get(id_)
    if book is None:
        raise HTTPException(404, "Livro não encontrado.")

    async def trabalho() -> Any:
        guide = await claude.executar_json(
            {
                "prompt": study.prompt_guide(book),
                "sistema": study.SYSTEM_GUIDE,
                "esquema": study.SCHEMA_GUIDE,
                "effort": "high",
                "limite_s": 280,
            }
        )
        if not isinstance(guide, dict) or not guide.get("capitulos"):
            raise Invalid("O Claude não devolveu o guia.")
        record = book["registro_id"] or study.have(arm, id_, book["tenho"])["id"]
        arm.editar("estudo_livros", record, {"guia": guide})
        return study.books(arm)[id_]

    return _task(trabalho)


@router.post("/estudo/livros", status_code=201)
def study_new_book(arm: ArmDep, corpo: Payload) -> Any:
    """Livro que você tem e não está no catálogo; depois peça o guia ao Claude."""
    title = str(corpo.get("titulo") or "").strip()
    if not title:
        raise HTTPException(422, "Diga o título.")
    r = arm.criar(
        "estudo_livros",
        {"titulo": title, "autor": str(corpo.get("autor") or "").strip(), "tenho": "sim"},
    )
    return study.books(arm)[r["id"]]


@router.post("/estudo/ler", status_code=201)
def study_read(request: Request, arm: ArmDep, corpo: Payload) -> Any:
    """Põe o livro ou artigo em Estudos › Leituras (área Finanças) e garante o projeto de leitura
    "Trilha de Finanças": com ele ativo no leitor, grifos e comentários viram citações da trilha."""
    studies = getattr(request.app.state, "estudos", None)
    if studies is None:
        raise HTTPException(503, "Módulo Estudos indisponível.")
    item = str(corpo.get("item") or "")
    kind, _, key = item.partition(":")
    if kind == "livro" and (book := study.books(arm).get(key)):
        data = {"titulo": book["titulo"], "autor": book["autor"], "tipo": "livro"}
    elif kind == "artigo" and key in study.ARTICLES:
        autores, title, revista, _n, _p = study.ARTICLES[key]
        data = {
            "titulo": title,
            "autor": autores,
            "tipo": "artigo",
            "referencia": f"{autores}. {title}. {revista}.",
        }
    else:
        raise HTTPException(404, "Item não encontrado.")
    reading_id = next(
        (p["leitura_id"] for p in arm.todos("estudo_progresso") if p["item"] == item), ""
    )
    readings = {x["id"]: x for x in studies.listar_leituras(area="Finanças")}
    if reading_id not in readings:
        mesma = next((x for x in readings.values() if x["titulo"] == data["titulo"]), None)
        reading = mesma or studies.criar_leitura(
            {**data, "area": "Finanças", "status": "lendo", "tags": ["trilha-financas"]}
        )
        reading_id = reading["id"]
    study.mark(arm, item, {"leitura_id": reading_id, "status": "lendo"})
    project = next((p for p in studies.listar_projetos() if p["nome"] == study.PROJECT), None)
    if project is None:
        project = studies.criar_projeto(
            {
                "nome": study.PROJECT,
                "descricao": "Grifos e comentários das leituras da trilha de finanças.",
                "secoes": [title for title, _ in study.LEVELS.values()],
            }
        )
    return {"leitura_id": reading_id, "projeto_id": project["id"], "projeto": study.PROJECT}


@router.get("/estudo/citacoes")
def study_quotes(request: Request) -> Any:
    """Grifos, comentários e citações (ABNT) do projeto "Trilha de Finanças", por obra."""
    studies = getattr(request.app.state, "estudos", None)
    if studies is None:
        return {"projeto_id": None, "obras": []}
    project = next((p for p in studies.listar_projetos() if p["nome"] == study.PROJECT), None)
    if project is None:
        return {"projeto_id": None, "obras": []}
    m = studies.matriz(project["id"])
    works: dict[str, dict[str, Any]] = {}
    for i in m["itens"]:
        if i["tipo"] == "manuscrito":
            continue
        o = works.setdefault(
            i["arquivo_id"],
            {"arquivo_id": i["arquivo_id"], "titulo": i["arquivo_titulo"], "itens": []},
        )
        o["itens"].append(
            {
                "id": i["id"],
                "pagina": i.get("pagina") or 0,
                "texto": i.get("texto") or "",
                "comentario": i.get("comentario") or "",
                "citacao": i.get("citacao_parentetica") or "",
                "secao": (i.get("classificacao") or {}).get("secao", ""),
            }
        )
    return {"projeto_id": project["id"], "obras": list(works.values())}


@router.get("/carteira")
def portfolio(arm: ArmDep) -> Any:
    return analysis.portfolio(arm)


# --- CRUD genérico ---


def _prepare(collection: str, dados: dict[str, Any]) -> dict[str, Any]:
    if collection == "empresas" and "demonstrativos" in dados:
        dados = {**dados, "demonstrativos": analysis.clean_statements(dados["demonstrativos"])}
    if collection == "transacoes" and "categoria_id" in dados and "categoria_ia" not in dados:
        dados = {**dados, "categoria_ia": False}  # escolha do usuário: a reconferência não troca
    return dados


@router.get("/{colecao}")
def list_all(arm: ArmDep, colecao: str) -> Any:
    try:
        return arm.todos(colecao)
    except NotFound as e:
        raise _error(e) from e


@router.post("/{colecao}/excluir-lote")
def delete_batch(arm: ArmDep, colecao: str, corpo: Payload) -> Any:
    """Exclui vários documentos (`ids`, até 500 por chamada; o app manda em lotes)."""
    ids = [str(i) for i in corpo.get("ids") or []]
    if len(ids) > 500:
        raise HTTPException(422, "No máximo 500 ids por lote")
    try:
        return {"excluidas": arm.excluir_varios(colecao, ids)}
    except NotFound as e:
        raise _error(e) from e


@router.post("/{colecao}", status_code=201)
def create(arm: ArmDep, colecao: str, corpo: Payload) -> Any:
    if colecao not in SCHEMAS:
        raise HTTPException(404, "Não encontrado")
    try:
        doc = arm.criar(colecao, _prepare(colecao, corpo))
        if colecao == "transacoes" and statement.categorize(arm, doc):
            arm.salvar("transacoes")
        return doc
    except Invalid as e:
        raise _error(e) from e


@router.get("/{colecao}/{id_}")
def get(arm: ArmDep, colecao: str, id_: str) -> Any:
    try:
        return arm.obter(colecao, id_)
    except NotFound as e:
        raise _error(e) from e


@router.patch("/{colecao}/{id_}")
def edit(arm: ArmDep, colecao: str, id_: str, corpo: Payload) -> Any:
    try:
        return arm.editar(colecao, id_, _prepare(colecao, corpo))
    except (NotFound, Invalid) as e:
        raise _error(e) from e


@router.delete("/{colecao}/{id_}", status_code=204)
def delete(arm: ArmDep, colecao: str, id_: str) -> None:
    try:
        arm.excluir(colecao, id_)
    except NotFound as e:
        raise _error(e) from e
