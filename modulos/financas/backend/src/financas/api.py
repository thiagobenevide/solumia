"""Rotas do módulo Finanças. A plataforma monta o router em `/api/financas` com a autenticação e
guarda o [Armazem] em `app.state.financas`. As coleções simples usam o CRUD genérico
`/{colecao}`; as rotas específicas (resumo, importação, análise) vêm antes dele."""

import re
from datetime import date
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, File, Form, HTTPException, Request, UploadFile

from financas import analysis, study, statement, reports
from financas.warehouse import ESQUEMAS, Armazem, Invalido, NaoEncontrado, data_iso

router = APIRouter(tags=["financas"])


def get_armazem(request: Request) -> Armazem:
    arm: Armazem = request.app.state.financas
    return arm


ArmDep = Annotated[Armazem, Depends(get_armazem)]
Corpo = Annotated[dict[str, Any], Body()]


def _erro(e: Exception) -> HTTPException:
    if isinstance(e, NaoEncontrado):
        return HTTPException(404, "Não encontrado")
    return HTTPException(422, str(e))


# --- painel e relatórios ---


@router.get("/resumo")
def resumo(arm: ArmDep, mes: str | None = None) -> Any:
    try:
        return reports.resumo(arm, mes or date.today().isoformat()[:7])
    except Invalido as e:
        raise _erro(e) from e


@router.get("/fluxo")
def fluxo(arm: ArmDep, meses: int = 12, ate: str | None = None) -> Any:
    try:
        return reports.fluxo(arm, max(1, min(meses, 60)), ate)
    except Invalido as e:
        raise _erro(e) from e


@router.get("/contrapartes")
def contrapartes(
    arm: ArmDep, de: str | None = None, ate: str | None = None, limite: int = 15
) -> Any:
    try:
        return reports.contrapartes(arm, de, ate, limite)
    except Invalido as e:
        raise _erro(e) from e


@router.get("/faturas/{conta_id}")
def faturas(arm: ArmDep, conta_id: str) -> Any:
    try:
        return reports.faturas(arm, conta_id)
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


@router.get("/projecao")
def projecao(arm: ArmDep, dias: int = 60) -> Any:
    dias = max(1, min(dias, 366))
    return {
        "itens": reports.projecao(arm, dias=dias),
        "saldo": reports.projecao_saldo(arm, dias),
    }


@router.post("/programacoes/{id_}/lancar", status_code=201)
def lancar(arm: ArmDep, id_: str, corpo: Corpo) -> Any:
    try:
        return reports.lancar(arm, id_, data_iso(corpo.get("data", "")))
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


@router.get("/metas/progresso")
def metas(arm: ArmDep) -> Any:
    return reports.metas(arm)


# --- extrato ---


@router.get("/transacoes")
def transacoes(
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
        de_, ate_ = (data_iso(de) if de else ""), (data_iso(ate) if ate else "9999")
    except Invalido as e:
        raise _erro(e) from e
    alvo = statement.normalizar(q)
    itens = [
        t
        for t in arm.todos("transacoes")
        if de_ <= (t["data"] or "") <= ate_
        and (conta_id is None or t["conta_id"] == conta_id)
        and (categoria_id is None or t["categoria_id"] == categoria_id)
        and (not sem_categoria or not t["categoria_id"])
        and (
            not alvo
            or alvo in statement.normalizar(f"{t['descricao']} {t['contraparte']} {t['observacao']}")
        )
    ]
    itens.sort(key=lambda t: (t["data"] or "", t["id"]), reverse=True)
    return itens[:limite]


@router.post("/transacoes/lote")
def lote(arm: ArmDep, corpo: Corpo) -> Any:
    """Aplica os mesmos campos (`dados`) em várias transações (`ids`); `regra` cria a regra."""
    ids = set(corpo.get("ids") or [])
    dados = corpo.get("dados") or {}
    try:
        feitas = [arm.editar("transacoes", i, _preparar("transacoes", dados)) for i in ids]
        if corpo.get("regra") and feitas and dados.get("categoria_id"):
            arm.criar(
                "regras",
                {
                    "padrao": corpo["regra"],
                    "categoria_id": dados["categoria_id"],
                    "contraparte": dados.get("contraparte", ""),
                },
            )
            statement.aplicar_regras(arm)
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e
    return {"alteradas": len(feitas)}


def get_llms(request: Request) -> dict[str, Any]:
    """Provedores de LLM da plataforma (`local` = worker no PC, `claude` se houver chave)."""
    return getattr(request.app.state, "financas_llms", {})


LLMsDep = Annotated[dict[str, Any], Depends(get_llms)]

# Tarefas de IA em andamento (em memória): o LLM pode levar minutos e a Cloudflare corta resposta
# que demora mais de 100 s para começar; o app cria a tarefa e consulta `GET /tarefas/{id}`.
_TAREFAS: dict[str, dict[str, Any]] = {}
_SEGUNDO_PLANO: set[Any] = set()  # referência às tasks soltas para o GC não as matar


def _tarefa(trabalho: Any, parcial: dict[str, Any] | None = None) -> dict[str, Any]:
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
            t.update(estado="pronto", resultado=await trabalho())
        except Invalido as e:
            t.update(estado="erro", erro=str(e))
        except Exception as e:  # worker desligado, tempo esgotado, API fora
            t.update(estado="erro", erro=f"A IA não respondeu: {e}")

    while len(_TAREFAS) >= 50:
        _TAREFAS.pop(next(iter(_TAREFAS)))
    _TAREFAS[tid] = t
    t["_task"] = asyncio.create_task(rodar())
    return {"tarefa": tid, "estado": "rodando"}


def _llm(llms: dict[str, Any], provedor: str) -> Any:
    llm = llms.get(provedor)
    if llm is None:
        raise HTTPException(503, f"IA '{provedor}' indisponível.")
    return llm


@router.get("/tarefas/{tid}")
def tarefa(tid: str) -> Any:
    t = _TAREFAS.get(tid)
    if t is None:
        raise HTTPException(404, "Tarefa não encontrada (o servidor reiniciou?).")
    return {k: v for k, v in t.items() if not k.startswith("_")}


@router.get("/ia/provedores")
def provedores(llms: LLMsDep) -> Any:
    return sorted(k for k in llms if k != "local_rapido")  # o modo rápido é interno da conversa


def _guardar_original(request: Request, conta: dict[str, Any], nome: str, conteudo: bytes) -> None:
    """O arquivo bruto do extrato vai para o módulo Arquivos (`Finanças/Extratos/<conta>`)."""
    biblioteca = getattr(request.app.state, "biblioteca", None)
    if biblioteca is None:
        return
    import threading

    try:
        meta = biblioteca.adicionar(nome, conteudo, pasta=f"Finanças/Extratos/{conta['nome']}")
        if meta.get("status") == "convertendo":
            threading.Thread(target=biblioteca.converter, args=(meta["id"],), daemon=True).start()
    except Exception:  # noqa: BLE001 — guardar a cópia não pode impedir a importação
        pass


@router.post("/importar")
async def importar(
    request: Request,
    arm: ArmDep,
    llms: LLMsDep,
    arquivo: Annotated[UploadFile, File()],
    conta_id: Annotated[str, Form()],
    provedor: Annotated[str, Form()] = "local",
) -> Any:
    """Lê o extrato (OFX, CSV e XLS/XLSX dos bancos) e grava sem duplicar. PDF ou layout que o
    código não reconhece vira tarefa da IA (resposta 202 com `tarefa`)."""
    nome, conteudo = arquivo.filename or "", await arquivo.read()
    try:
        conta = arm.obter("contas", conta_id)
        _guardar_original(request, conta, nome, conteudo)
        try:
            r = statement.gravar_lancamentos(
                arm, statement.ler_arquivo(nome, conteudo, conta["tipo"]), conta_id
            )
            return _categorizar_novas(arm, llms.get(provedor), r)
        except statement.PrecisaIA as e:
            from fastapi.responses import JSONResponse

            from financas import ai

            llm, texto = _llm(llms, provedor), e.texto

            async def trabalho() -> Any:
                itens = await ai.extrair_lancamentos(llm, texto, fatura=conta["tipo"] == "cartao")
                r = statement.gravar_lancamentos(arm, itens, conta_id)
                ids = r.pop("ids")
                if r["sem_categoria"] and arm.todos("categorias"):
                    try:
                        feito = await ai.categorizar(llm, arm, ids=ids)
                        r["sem_categoria"] -= feito["categorizadas"]
                    except Exception:  # noqa: BLE001 — os lançamentos já estão gravados
                        pass
                return {**r, "lido_pela_ia": True}

            return JSONResponse(_tarefa(trabalho) | {"motivo": str(e)}, status_code=202)
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


def _categorizar_novas(arm: Armazem, llm: Any, r: dict[str, Any]) -> dict[str, Any]:
    """O que as regras e o histórico não categorizaram vai para a IA em segundo plano; o app
    acompanha pela tarefa em `categorizando`."""
    ids = r.pop("ids")
    if llm is None or not r["sem_categoria"] or not arm.todos("categorias"):
        return r
    from financas import ai

    return {**r, "categorizando": _tarefa(lambda: ai.categorizar(llm, arm, ids=ids))["tarefa"]}


@router.post("/regras/aplicar")
def aplicar_regras(arm: ArmDep) -> Any:
    return {"categorizadas": statement.aplicar_regras(arm)}


@router.post("/corrigir", status_code=202)
async def corrigir(request: Request, arm: ArmDep, llms: LLMsDep, provedor: str = "local") -> Any:
    """Reconferência em segundo plano: conserta o que já está gravado (sinal e forma de pagamento da
    conta do cartão, regras) e passa na IA o que segue sem categoria ou sem forma, o que a IA
    categorizou antes e o que está na categoria do sentido errado."""

    from financas import ai

    biblioteca = getattr(request.app.state, "biblioteca", None)
    llm = llms.get(provedor)

    def originais() -> dict[str, list[tuple[str, bytes]]]:
        if biblioteca is None:
            return {}
        por_conta: dict[str, list[tuple[str, bytes]]] = {}
        for c in arm.todos("contas"):
            for meta in biblioteca.listar(pasta=f"Finanças/Extratos/{c['nome']}"):
                try:
                    caminho, nome = biblioteca.caminho_original(meta["id"])
                    por_conta.setdefault(c["id"], []).append((nome, caminho.read_bytes()))
                except Exception:  # noqa: BLE001 — arquivo sumido não impede o resto
                    continue
        return por_conta

    async def trabalho() -> Any:
        feito = statement.corrigir(arm, originais())
        feito["categorizadas_ia"] = feito["trocadas_ia"] = 0
        if llm is not None and arm.todos("categorias"):
            try:
                r = await ai.categorizar(llm, arm, limite=3000, revisar=True)
                feito["categorizadas_ia"], feito["trocadas_ia"] = r["categorizadas"], r["trocadas"]
                feito["formas"] += r["formas"]
            except Exception as e:  # noqa: BLE001 — o conserto do sinal e da forma já foi gravado
                feito["erro_ia"] = f"A IA não respondeu: {e}"
        feito["sem_categoria"] = sum(1 for t in arm.todos("transacoes") if not t["categoria_id"])
        return feito

    return _tarefa(trabalho)


@router.post("/categorizar-ia", status_code=202)
async def categorizar_ia(arm: ArmDep, llms: LLMsDep, provedor: str = "local") -> Any:
    """Categoriza com a IA os lançamentos que as regras e o histórico não pegaram."""
    from financas import ai

    llm = _llm(llms, provedor)
    return _tarefa(lambda: ai.categorizar(llm, arm))


# --- parcelamentos e cenários (análise preditiva) ---


@router.get("/parcelamentos")
def parcelamentos(arm: ArmDep) -> Any:
    from financas import scenarios

    return scenarios.parcelamentos(arm)


@router.post("/cenarios/simular")
def simular(arm: ArmDep, corpo: Corpo) -> Any:
    """Juntar × financiar um bem sobre a sua realidade do extrato (só contas, sem IA)."""
    from financas import scenarios

    if not corpo.get("valor"):
        raise HTTPException(422, "Informe o valor do bem.")
    try:
        return scenarios.simular(arm, corpo)
    except (TypeError, ValueError) as e:
        raise HTTPException(422, f"Parâmetro inválido: {e}") from e


@router.post("/cenarios/perguntar", status_code=202)
async def perguntar(request: Request, arm: ArmDep, llms: LLMsDep, corpo: Corpo) -> Any:
    """Pergunta livre ("quero um EcoSport 2015 de 45 mil, quanto tempo para juntar?"): a IA tira os
    parâmetros, o Python simula e a IA explica o resultado. `ajustes` sobrescreve o que a IA
    tirou."""
    from financas import scenarios, ai

    pergunta = str(corpo.get("pergunta") or "").strip()
    if not pergunta:
        raise HTTPException(422, "Escreva o que você quer comprar.")
    llm = _llm(llms, str(corpo.get("provedor") or "local"))
    ajustes = corpo.get("ajustes") or {}

    internet = getattr(request.app.state, "internet", None)

    async def trabalho() -> Any:
        parametros = {**await ai.interpretar(llm, pergunta), **ajustes}
        # Dados de hoje: preço FIPE (completa o valor que faltou) e CDI (rendimento da reserva).
        atuais = await ai.dados_atuais(internet, parametros)
        if not parametros.get("valor") and atuais.get("fipe"):
            parametros["valor"] = atuais["fipe"]["media"]
        if not parametros.get("valor"):
            raise Invalido(
                "Não achei o valor do bem: diga quanto custa (ex.: 'carro de R$ 45 mil')."
            )
        if atuais.get("rendimento_mensal"):
            parametros.setdefault("rendimento_mensal", atuais["rendimento_mensal"])
        resultado = scenarios.simular(arm, parametros)
        return {
            "parametros": parametros,
            "dados_atuais": atuais,
            "resultado": resultado,
            "analise": await ai.analisar(llm, pergunta, resultado, atuais),
        }

    return _tarefa(trabalho)


@router.post("/cenarios/conversar")
async def conversar(arm: ArmDep, llms: LLMsDep, corpo: Corpo) -> Any:
    """Conversa curta (texto ou voz) sobre os seus dados e a simulação aberta. `mensagens`:
    [{role: user|assistant, content}], a última é a pergunta; `cenario`: {pergunta, analise}.
    No LLM local usa o modo rápido (sem raciocínio): a resposta sai em 1–3 s."""
    from financas import ai

    mensagens = [
        {"role": m["role"], "content": str(m["content"])[:4000]}
        for m in corpo.get("mensagens") or []
        if isinstance(m, dict) and m.get("role") in ("user", "assistant") and m.get("content")
    ]
    if not mensagens or mensagens[-1]["role"] != "user":
        raise HTTPException(422, "Diga ou escreva a sua pergunta.")
    provedor = str(corpo.get("provedor") or "local")
    llm = llms.get("local_rapido") if provedor == "local" else None
    llm = llm or _llm(llms, provedor)
    resposta = await ai.conversar(llm, mensagens, ai.contexto_financeiro(arm), corpo.get("cenario"))
    return {"resposta": resposta}


# --- mercado em tempo real e dados oficiais (CVM) ---


def _internet(request: Request) -> Any:
    internet = getattr(request.app.state, "internet", None)
    if internet is None:
        raise HTTPException(503, "Sem acesso à internet no servidor.")
    return internet


def _cvm(arm: Armazem) -> Any:
    from financas.cvm import CVM

    return CVM(arm.raiz)


_AQUECIDO = [0.0]


@router.get("/mercado/destaques")
async def destaques(request: Request, arm: ArmDep, tipo: str = "stock") -> Any:
    """10 maiores altas e 10 maiores baixas do dia na B3 (`fund` = fundos/FIIs). De carona, renova
    em segundo plano os arquivos da CVM (no máximo 1x/hora) para a ficha do ativo abrir rápido."""
    import asyncio
    import time

    if time.time() - _AQUECIDO[0] > 3600:
        _AQUECIDO[0] = time.time()
        _SEGUNDO_PLANO.add(t := asyncio.create_task(asyncio.to_thread(_cvm(arm).aquecer)))
        t.add_done_callback(_SEGUNDO_PLANO.discard)
    r = await _internet(request).usar("mercado", {"tipo": "fund" if tipo == "fund" else "stock"})
    if "erro" in r:
        raise HTTPException(503, r["erro"])
    return r


@router.get("/mercado/noticias")
async def noticias(request: Request, tema: str = "economia") -> Any:
    """Manchetes do dia por tema: economia, acoes, fiis, impostos ou juros."""
    r = await _internet(request).usar("noticias", {"tema": tema})
    if "erro" in r:
        raise HTTPException(503, r["erro"])
    return r


@router.post("/mercado/ativo", status_code=202)
async def ativo(request: Request, arm: ArmDep, corpo: Corpo) -> Any:
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
            sugestoes = await asyncio.to_thread(base.sugerir, q, 1)
            if sugestoes and sugestoes[0]["tipo"] == "fii":
                ticker = sugestoes[0]["tickers"][0]
        # cotação e proventos já saem junto com a leitura da CVM
        cotacoes = asyncio.create_task(mercado(ticker))
        fundo = await asyncio.to_thread(m_cvm.fii, base, ticker) if ticker.endswith("11") else None
        if fundo:
            cot, prov = await cotacoes
            preco = cot.get("cotacoes", {}).get(ticker, {})
            vp = (fundo["meses"][-1]["valor_patrimonial_cota"] if fundo["meses"] else None) or None
            return {
                "tipo": "fii",
                **fundo,
                "cotacao": preco,
                "proventos": prov,
                "p_vp": round(preco["preco"] / vp, 2) if preco.get("preco") and vp else None,
            }
        achados = await asyncio.to_thread(base.buscar, ticker or q)
        if not achados:
            cotacoes.cancel()
            raise Invalido(f"Não achei '{q}' na CVM (empresa ou FII listado).")
        e = achados[0]
        if ticker not in e["tickers"]:
            cotacoes.cancel()
            ticker = e["tickers"][0] if e["tickers"] else ""
            cotacoes = asyncio.create_task(mercado(ticker))
        carregando = parcial.setdefault("carregando", [])
        carregando += ["cotacao", "demonstrativos", "documentos"]
        parcial.update({**e, "tipo": "acao", "ticker": ticker, "outros": achados[1:5]})
        parcial["demonstrativos"] = []

        def resumir() -> None:
            """Indicadores e valuation com o que já chegou (refeito quando chega mais)."""
            preco = (parcial.get("cotacao") or {}).get("preco")
            parcial.update(analysis.resumo_ficha(parcial["demonstrativos"], preco, e["setor"]))

        async def cotacao() -> None:
            cot, prov = await cotacoes
            parcial.update(
                cotacao=(cot or {}).get("cotacoes", {}).get(ticker, {}), proventos=prov or {}
            )
            carregando.remove("cotacao")
            resumir()

        def ao_ano(anos: list[dict[str, Any]]) -> None:
            parcial["demonstrativos"] = analysis.limpar_demonstrativos(anos)
            resumir()

        async def demonstrativos() -> None:
            d = await asyncio.to_thread(base.demonstrativos, e["codigo_cvm"], ao_ano=ao_ano)
            parcial["demonstrativos"] = analysis.limpar_demonstrativos(d) if d else []
            carregando.remove("demonstrativos")
            resumir()

        async def documentos() -> None:
            parcial["documentos"] = await asyncio.to_thread(
                base.documentos, e["codigo_cvm"], ticker
            )
            carregando.remove("documentos")

        await asyncio.gather(cotacao(), demonstrativos(), documentos())
        return {k: v for k, v in parcial.items() if k != "carregando"}

    return _tarefa(trabalho, parcial)


@router.get("/mercado/sugerir")
async def sugerir(arm: ArmDep, q: str = "", limite: int = 12) -> Any:
    """Busca enquanto digita (ações e FIIs): ticker pelo começo, nome, apelido e nome parecido."""
    import asyncio

    if len(q.strip()) < 2:
        return []
    try:
        return await asyncio.to_thread(_cvm(arm).sugerir, q, min(max(limite, 1), 30))
    except Exception as e:  # sem rede na primeira vez: a CVM ainda não foi baixada
        raise HTTPException(503, f"Busca indisponível: {e}") from e


async def _vazio() -> dict[str, Any]:
    return {}


@router.post("/empresas/{id_}/importar-cvm", status_code=202)
async def importar_cvm(request: Request, arm: ArmDep, id_: str) -> Any:
    """Preenche DRE, balanço e fluxo de caixa (6 anos, R$ mil), o número de ações (mil), a cotação
    do dia e o cadastro da empresa pela CVM: sem ações e cotação, P/L, P/VP e preço justo ficam
    vazios."""
    import asyncio

    try:
        empresa = arm.obter("empresas", id_)
    except NaoEncontrado as e:
        raise _erro(e) from e
    base = _cvm(arm)

    async def trabalho() -> Any:
        achados = await asyncio.to_thread(base.buscar, empresa["ticker"] or empresa["nome"])
        if not achados:
            raise Invalido(f"{empresa['ticker']} não está na CVM.")
        e = achados[0]
        ticker = empresa["ticker"].upper() if empresa["ticker"] in e["tickers"] else ""
        ticker = ticker or (e["tickers"][0] if e["tickers"] else "")
        anos, cot = await asyncio.gather(
            asyncio.to_thread(base.demonstrativos, e["codigo_cvm"]),
            _internet(request).usar("acoes", {"tickers": [ticker]}) if ticker else _vazio(),
        )
        preco = ((cot or {}).get("cotacoes", {}).get(ticker) or {}).get("preco")
        acoes = next((d["acoes"] for d in reversed(anos) if d.get("acoes")), None)
        antigos = {d["ano"]: d for d in empresa["demonstrativos"]}
        for d in anos:  # o que veio da CVM substitui o ano; o resto que você digitou fica
            antigos[d["ano"]] = {**antigos.get(d["ano"], {}), **d}
        dados = {
            "demonstrativos": analysis.limpar_demonstrativos(list(antigos.values())),
            "cnpj": empresa["cnpj"] or e["cnpj"],
            "site": empresa["site"] or e["site"],
            "nome": empresa["nome"] or e["nome"],
            "setor": empresa["setor"] or e["setor"],
            "descricao": empresa["descricao"] or e["atividade"],
            "ticker": empresa["ticker"].upper() or ticker,
            **({"cotacao": preco} if preco else {}),
            **({"acoes": acoes} if acoes else {}),
        }
        return {"empresa": arm.editar("empresas", id_, dados), "anos": [d["ano"] for d in anos]}

    return _tarefa(trabalho)


def pdf_do_documento(conteudo: bytes) -> bytes | None:
    """O PDF de um documento da CVM: o próprio arquivo (release, apresentação) ou, no pacote ZIP do
    DFP/ITR, o maior PDF lá dentro (as demonstrações completas)."""
    import io
    import zipfile

    if conteudo.startswith(b"%PDF"):
        return conteudo
    if conteudo.startswith(b"PK"):
        try:
            with zipfile.ZipFile(io.BytesIO(conteudo)) as z:
                pdfs = [i for i in z.infolist() if i.filename.lower().endswith(".pdf")]
                if pdfs:
                    return z.read(max(pdfs, key=lambda i: i.file_size))
        except zipfile.BadZipFile:
            return None
    return None


def link_seguro(url: str) -> str:
    """Os links da CVM vêm em http://, que a CVM recusa (e o Android bloqueia): sempre https."""
    return "https://" + url.split("://", 1)[1] if url.startswith("http://") else url


@router.post("/mercado/guardar", status_code=202)
async def guardar_documento(request: Request, corpo: Corpo) -> Any:
    """Baixa um documento da CVM (release, apresentação, DFP/ITR) e guarda o PDF no módulo Arquivos
    (`Finanças/<ticker>`), para abrir no leitor do app, grifar e anotar. Vira tarefa: o pacote do
    DFP passa de 20 MB. O mesmo documento de novo não duplica (o Arquivos devolve o já guardado)."""
    import httpx

    url = link_seguro(str(corpo.get("url") or ""))
    ticker = str(corpo.get("ticker") or "Mercado").upper()
    if not url.startswith("https://www.rad.cvm.gov.br/"):
        raise HTTPException(422, "Só documentos do RAD da CVM.")
    biblioteca = getattr(request.app.state, "biblioteca", None)
    if biblioteca is None:
        raise HTTPException(503, "Módulo Arquivos indisponível.")
    titulo = (
        re.sub(r"[^\w\s.-]", "", str(corpo.get("titulo") or "documento"))[:80].strip()
        or "documento"
    )

    async def trabalho() -> Any:
        try:
            async with httpx.AsyncClient(follow_redirects=True, timeout=180) as c:
                r = await c.get(url, headers={"User-Agent": "Mozilla/5.0"})
                r.raise_for_status()
        except httpx.HTTPError as e:
            raise Invalido(f"A CVM não entregou o documento ({e.__class__.__name__}).") from e
        pdf = pdf_do_documento(r.content)
        if pdf is None:
            raise Invalido("O documento da CVM não tem PDF dentro: abra pelo navegador.")
        meta = biblioteca.adicionar(f"{ticker} {titulo}.pdf", pdf, pasta=f"Finanças/{ticker}")
        return {"arquivo": meta}

    return _tarefa(trabalho)


# --- empresas, setores e carteira ---


@router.get("/questionario")
def questionario(arm: ArmDep) -> Any:
    return arm.questionario()


@router.put("/questionario")
def salvar_questionario(arm: ArmDep, corpo: Annotated[list[dict[str, Any]], Body()]) -> Any:
    try:
        return arm.salvar_questionario(corpo)
    except Invalido as e:
        raise _erro(e) from e


@router.get("/empresas/ranking")
def ranking(arm: ArmDep) -> Any:
    return analysis.ranking(arm)


@router.get("/empresas/{id_}/analise")
def analisar(arm: ArmDep, id_: str) -> Any:
    try:
        return analysis.analisar(arm, arm.obter("empresas", id_))
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


@router.get("/setores/{id_}/analise")
def analisar_setor(arm: ArmDep, id_: str) -> Any:
    try:
        return analysis.setor_analise(arm, arm.obter("setores", id_))
    except NaoEncontrado as e:
        raise _erro(e) from e


# ---------- estudos de finanças (trilha, livros, artigos, relatórios) ----------


@router.get("/estudo")
def estudo_trilha(arm: ArmDep, objetivo: str = "") -> Any:
    """Trilha de finanças com o progresso, o guia de cada livro, artigos e relatórios."""
    return study.montar(arm, objetivo)


@router.put("/estudo/objetivo")
def estudo_objetivo(arm: ArmDep, corpo: Corpo) -> Any:
    objetivo = str(corpo.get("objetivo") or "")
    if objetivo not in {o["id"] for o in study.OBJETIVOS}:
        raise HTTPException(422, "Objetivo desconhecido.")
    study.marcar(arm, "objetivo", {"nota": objetivo})
    return study.montar(arm, objetivo)


@router.patch("/estudo/itens")
def estudo_marcar(arm: ArmDep, corpo: Corpo) -> Any:
    """`{item, status?, nota?}`: item = `etapa:<id>`, `livro:<id>`, `cap:<livro>:<n>`,
    `artigo:<id>` ou `relatorio:<id>`."""
    try:
        return study.marcar(arm, str(corpo.get("item") or ""), corpo)
    except Invalido as e:
        raise _erro(e) from e


@router.put("/estudo/livros/{id_}/tenho")
def estudo_tenho(arm: ArmDep, id_: str, corpo: Corpo) -> Any:
    try:
        return study.tenho(arm, id_, bool(corpo.get("tenho")))
    except (Invalido, NaoEncontrado) as e:
        raise _erro(e) from e


def _reescrita(request: Request) -> Any:
    """Claude Code headless do worker (o mesmo do mapeamento de leituras), ou 503."""
    r = getattr(request.app.state, "reescrita", None)
    motivo = r.disponivel() if r is not None else "Claude indisponível neste servidor."
    if motivo or r.executar_json is None:
        raise HTTPException(503, motivo or "Claude indisponível neste servidor.")
    return r


@router.post("/estudo/livros/{id_}/guia", status_code=202)
async def estudo_guia(request: Request, arm: ArmDep, id_: str) -> Any:
    """O Claude monta o guia de leitura não linear do livro (capítulos, ordem, por quê) e o guia
    fica gravado; nos livros do catálogo ele completa o que já está escrito."""
    claude = _reescrita(request)
    livro = study.livros(arm).get(id_)
    if livro is None:
        raise HTTPException(404, "Livro não encontrado.")

    async def trabalho() -> Any:
        guia = await claude.executar_json(
            {
                "prompt": study.prompt_guia(livro),
                "sistema": study.SISTEMA_GUIA,
                "esquema": study.ESQUEMA_GUIA,
                "effort": "high",
                "limite_s": 280,
            }
        )
        if not isinstance(guia, dict) or not guia.get("capitulos"):
            raise Invalido("O Claude não devolveu o guia.")
        registro = livro["registro_id"] or study.tenho(arm, id_, livro["tenho"])["id"]
        arm.editar("estudo_livros", registro, {"guia": guia})
        return study.livros(arm)[id_]

    return _tarefa(trabalho)


@router.post("/estudo/livros", status_code=201)
def estudo_novo_livro(arm: ArmDep, corpo: Corpo) -> Any:
    """Livro que você tem e não está no catálogo; depois peça o guia ao Claude."""
    titulo = str(corpo.get("titulo") or "").strip()
    if not titulo:
        raise HTTPException(422, "Diga o título.")
    r = arm.criar(
        "estudo_livros",
        {"titulo": titulo, "autor": str(corpo.get("autor") or "").strip(), "tenho": "sim"},
    )
    return study.livros(arm)[r["id"]]


@router.post("/estudo/ler", status_code=201)
def estudo_ler(request: Request, arm: ArmDep, corpo: Corpo) -> Any:
    """Põe o livro ou artigo em Estudos › Leituras (área Finanças) e garante o projeto de leitura
    "Trilha de Finanças": com ele ativo no leitor, grifos e comentários viram citações da trilha."""
    estudos = getattr(request.app.state, "estudos", None)
    if estudos is None:
        raise HTTPException(503, "Módulo Estudos indisponível.")
    item = str(corpo.get("item") or "")
    tipo, _, chave = item.partition(":")
    if tipo == "livro" and (livro := study.livros(arm).get(chave)):
        dados = {"titulo": livro["titulo"], "autor": livro["autor"], "tipo": "livro"}
    elif tipo == "artigo" and chave in study.ARTIGOS:
        autores, titulo, revista, _n, _p = study.ARTIGOS[chave]
        dados = {
            "titulo": titulo,
            "autor": autores,
            "tipo": "artigo",
            "referencia": f"{autores}. {titulo}. {revista}.",
        }
    else:
        raise HTTPException(404, "Item não encontrado.")
    leitura_id = next(
        (p["leitura_id"] for p in arm.todos("estudo_progresso") if p["item"] == item), ""
    )
    leituras = {x["id"]: x for x in estudos.listar_leituras(area="Finanças")}
    if leitura_id not in leituras:
        mesma = next((x for x in leituras.values() if x["titulo"] == dados["titulo"]), None)
        leitura = mesma or estudos.criar_leitura(
            {**dados, "area": "Finanças", "status": "lendo", "tags": ["trilha-financas"]}
        )
        leitura_id = leitura["id"]
    study.marcar(arm, item, {"leitura_id": leitura_id, "status": "lendo"})
    projeto = next((p for p in estudos.listar_projetos() if p["nome"] == study.PROJETO), None)
    if projeto is None:
        projeto = estudos.criar_projeto(
            {
                "nome": study.PROJETO,
                "descricao": "Grifos e comentários das leituras da trilha de finanças.",
                "secoes": [titulo for titulo, _ in study.NIVEIS.values()],
            }
        )
    return {"leitura_id": leitura_id, "projeto_id": projeto["id"], "projeto": study.PROJETO}


@router.get("/estudo/citacoes")
def estudo_citacoes(request: Request) -> Any:
    """Grifos, comentários e citações (ABNT) do projeto "Trilha de Finanças", por obra."""
    estudos = getattr(request.app.state, "estudos", None)
    if estudos is None:
        return {"projeto_id": None, "obras": []}
    projeto = next((p for p in estudos.listar_projetos() if p["nome"] == study.PROJETO), None)
    if projeto is None:
        return {"projeto_id": None, "obras": []}
    m = estudos.matriz(projeto["id"])
    obras: dict[str, dict[str, Any]] = {}
    for i in m["itens"]:
        if i["tipo"] == "manuscrito":
            continue
        o = obras.setdefault(
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
    return {"projeto_id": projeto["id"], "obras": list(obras.values())}


@router.get("/carteira")
def carteira(arm: ArmDep) -> Any:
    return analysis.carteira(arm)


# --- CRUD genérico ---


def _preparar(colecao: str, dados: dict[str, Any]) -> dict[str, Any]:
    if colecao == "empresas" and "demonstrativos" in dados:
        dados = {**dados, "demonstrativos": analysis.limpar_demonstrativos(dados["demonstrativos"])}
    if colecao == "transacoes" and "categoria_id" in dados and "categoria_ia" not in dados:
        dados = {**dados, "categoria_ia": False}  # escolha do usuário: a reconferência não troca
    return dados


@router.get("/{colecao}")
def listar(arm: ArmDep, colecao: str) -> Any:
    try:
        return arm.todos(colecao)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.post("/{colecao}/excluir-lote")
def excluir_lote(arm: ArmDep, colecao: str, corpo: Corpo) -> Any:
    """Exclui vários documentos (`ids`, até 500 por chamada; o app manda em lotes)."""
    ids = [str(i) for i in corpo.get("ids") or []]
    if len(ids) > 500:
        raise HTTPException(422, "No máximo 500 ids por lote")
    try:
        return {"excluidas": arm.excluir_varios(colecao, ids)}
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.post("/{colecao}", status_code=201)
def criar(arm: ArmDep, colecao: str, corpo: Corpo) -> Any:
    if colecao not in ESQUEMAS:
        raise HTTPException(404, "Não encontrado")
    try:
        doc = arm.criar(colecao, _preparar(colecao, corpo))
        if colecao == "transacoes" and statement.categorizar(arm, doc):
            arm.salvar("transacoes")
        return doc
    except Invalido as e:
        raise _erro(e) from e


@router.get("/{colecao}/{id_}")
def obter(arm: ArmDep, colecao: str, id_: str) -> Any:
    try:
        return arm.obter(colecao, id_)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.patch("/{colecao}/{id_}")
def editar(arm: ArmDep, colecao: str, id_: str, corpo: Corpo) -> Any:
    try:
        return arm.editar(colecao, id_, _preparar(colecao, corpo))
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


@router.delete("/{colecao}/{id_}", status_code=204)
def excluir(arm: ArmDep, colecao: str, id_: str) -> None:
    try:
        arm.excluir(colecao, id_)
    except NaoEncontrado as e:
        raise _erro(e) from e
