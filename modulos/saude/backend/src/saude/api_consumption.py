"""Rotas de Saúde › Consumo (`/consumo`): regras com trava de 24 h, sincronização dos aparelhos
Android e a leitura do "vigia" pela LLM local (`app.state.saude_llm`; nunca serviço externo)."""

from datetime import UTC, date, datetime, timedelta
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from saude.consumption import CATEGORIES, Consumption
from saude.workouts import Invalid, NotFound, Workouts

router = APIRouter(prefix="/consumo")

SYSTEM = """Você é o vigia pessoal do usuário contra o consumo excessivo de conteúdo no celular e
nos tablets. O objetivo dele: usar redes sociais para conversar com pessoas (amizades, contatos) e
não para consumir entretenimento que não agrega, notícias que dão raiva, compras por impulso ou
conteúdo adulto. WhatsApp é trabalho e não entra na conta.
Responda em português do Brasil, em Markdown, como um amigo franco: direto, sem sermão, sem rodeio.
Estrutura:
## Como foi
(minutos por categoria, média por dia, apps campeões, número de aberturas)
## Onde você escorregou
(horários de pico, dias piores, tentativas barradas, buscas por categoria, violações de proteção;
cite números)
## O que isso diz
(padrões: tédio, fuga, madrugada, compras sem necessidade; só o que os dados sustentam)
## Para os próximos 7 dias
(3 a 5 ações concretas: horários a bloquear, limites a baixar, o que fazer no lugar, uma conversa
real com alguém em vez de rolar o feed)
Se uma regra afrouxada ou um aparelho sem proteção aparecer, diga claramente."""


def get_consumption(request: Request) -> Consumption:
    state = request.app.state
    if getattr(state, "consumo", None) is None:
        workouts: Workouts = state.treinos
        state.consumo = Consumption(workouts.raiz / "consumo")
    consumption: Consumption = state.consumo
    return consumption


ConsumptionDep = Annotated[Consumption, Depends(get_consumption)]


def _error(e: Exception) -> HTTPException:
    if isinstance(e, NotFound):
        return HTTPException(404, "Não encontrado")
    return HTTPException(422, str(e))


class Timetable(BaseModel):
    inicio: str = Field(max_length=5)
    fim: str = Field(max_length=5)


class Rule(BaseModel):
    modo: str
    limite_min: int = 0
    horarios: list[Timetable] = []


class App(BaseModel):
    pacote: str = Field(min_length=3, max_length=200)
    nome: str = Field("", max_length=80)
    categoria: str


class Domain(BaseModel):
    dominio: str = Field(min_length=3, max_length=200)


class Protection(BaseModel):
    ativa: bool


class Sync(BaseModel):
    dispositivo: dict[str, Any]
    dias: list[dict[str, Any]] = Field([], max_length=31)
    eventos: list[dict[str, Any]] = Field([], max_length=2000)


class RequestAnalysis(BaseModel):
    dias: int = Field(7, ge=1, le=90)
    pergunta: str = Field("", max_length=2000)


@router.get("/config")
def config(consumo: ConsumptionDep) -> Any:
    return consumo.config()


@router.put("/regras/{categoria}")
def rule(consumo: ConsumptionDep, categoria: str, corpo: Rule) -> Any:
    try:
        return consumo.definir_regra(categoria, corpo.model_dump())
    except Invalid as e:
        raise _error(e) from e


@router.put("/apps")
def app(consumo: ConsumptionDep, corpo: App) -> Any:
    try:
        return consumo.definir_app(corpo.pacote, corpo.nome, corpo.categoria)
    except Invalid as e:
        raise _error(e) from e


@router.delete("/apps/{pacote}")
def remove_app(consumo: ConsumptionDep, pacote: str) -> Any:
    try:
        return consumo.remover_app(pacote)
    except NotFound as e:
        raise _error(e) from e


@router.post("/dominios/{categoria}")
def include_domain(consumo: ConsumptionDep, categoria: str, corpo: Domain) -> Any:
    try:
        return consumo.incluir_dominio(categoria, corpo.dominio)
    except Invalid as e:
        raise _error(e) from e


@router.delete("/dominios/{categoria}/{dominio}")
def remove_domain(consumo: ConsumptionDep, categoria: str, dominio: str) -> Any:
    try:
        return consumo.remover_dominio(categoria, dominio)
    except (Invalid, NotFound) as e:
        raise _error(e) from e


@router.put("/protecao")
def protection(consumo: ConsumptionDep, corpo: Protection) -> Any:
    return consumo.definir_protecao(corpo.ativa)


@router.delete("/pendencias/{id_}", status_code=204)
def cancel(consumo: ConsumptionDep, id_: str) -> None:
    try:
        consumo.cancelar_pendencia(id_)
    except NotFound as e:
        raise _error(e) from e


@router.post("/sincronizar")
def sync(consumo: ConsumptionDep, corpo: Sync) -> Any:
    try:
        return consumo.sincronizar(corpo.model_dump())
    except (KeyError, ValueError, TypeError) as e:
        raise HTTPException(422, f"Dados inválidos: {e}") from e


@router.get("/dispositivos")
def devices(consumo: ConsumptionDep) -> Any:
    return consumo.dispositivos()


@router.get("/resumo")
def summary(consumo: ConsumptionDep, de: str, ate: str) -> Any:
    try:
        return consumo.resumo(de, ate)
    except (Invalid, ValueError) as e:
        raise HTTPException(422, str(e)) from e


def assemble_context(consumption: Consumption, de: date, ate: date) -> str:
    r = consumption.resumo(de.isoformat(), ate.isoformat())
    days = (ate - de).days + 1
    names = {**CATEGORIES, "outros": "Outros apps"}
    totals: dict[str, float] = {}
    for cats in r["por_dia"].values():
        for c, v in cats.items():
            totals[c] = totals.get(c, 0) + v
    cfg = consumption.config()
    lines = [
        f"Período: {r['de']} a {r['ate']} ({days} dias, {len(r['por_dia'])} com dados)",
        "",
        "# Minutos por categoria (total; média por dia)",
    ]
    lines += [
        f"- {names.get(c, c)}: {v:.0f} min; {v / days:.0f} min/dia"
        for c, v in sorted(totals.items(), key=lambda x: -x[1])
    ]
    lines += ["", "# Apps mais usados"]
    lines += [
        f"- {a['nome']} ({names.get(a['categoria'], a['categoria'])}): {a['minutos']:.0f} min,"
        f" {a['aberturas']} aberturas"
        for a in r["apps"][:12]
    ]
    lines += ["", "# Dia a dia (min)"]
    lines += [
        f"- {d}: " + ", ".join(f"{names.get(c, c)} {v:.0f}" for c, v in cats.items())
        for d, cats in sorted(r["por_dia"].items())
    ]
    if r["por_hora"]:
        lines += ["", "# Horas do dia com mais uso (todas as categorias vigiadas, min)"]
        total = [sum(h[i] for h in r["por_hora"].values()) for i in range(24)]
        picos = sorted(range(24), key=lambda i: -total[i])[:5]
        lines += [f"- {i:02d}h: {total[i]:.0f}" for i in sorted(picos) if total[i] > 0]
    if r["eventos"]:
        lines += ["", "# Eventos (buscas são só categoria; bloqueio = tentativa barrada)"]
        lines += [f"- {k}: {v}" for k, v in sorted(r["eventos"].items())]
    lines += ["", "# Regras atuais"]
    for c, rule in cfg["regras"].items():
        extra = f" {rule['limite_min']} min/dia" if rule["modo"] == "limite" else ""
        hours = ", ".join(f"{h['inicio']}–{h['fim']}" for h in rule["horarios"])
        lines.append(
            f"- {names[c]}: {rule['modo']}{extra}" + (f"; bloqueio {hours}" if hours else "")
        )
    if cfg["pendencias"]:
        lines += ["", "# Pedidos para afrouxar (esperando 24 h)"]
        lines += [f"- {p['descricao']} (libera {p['libera_em']})" for p in cfg["pendencias"]]
    lines += ["", "# Aparelhos"]
    for d in consumption.dispositivos():
        desligado = [k for k, v in d["estado"].items() if not v]
        lines.append(
            f"- {d['nome']}: visto {d['visto_em']}"
            + (f"; DESLIGADO: {', '.join(desligado)}" if desligado else "; tudo ativo")
        )
    return "\n".join(lines)


@router.get("/analises")
def analyses(consumo: ConsumptionDep) -> Any:
    return consumo.analises()


@router.post("/analises")
async def analyze(pedido: RequestAnalysis, request: Request, consumo: ConsumptionDep) -> Any:
    llm = getattr(request.app.state, "saude_llm", None)
    if llm is None:
        raise HTTPException(503, "LLM local indisponível")
    until = date.today()
    de = until - timedelta(days=pedido.dias - 1)
    user = assemble_context(consumo, de, until)
    if pedido.pergunta.strip():
        user += f"\n\nPergunta do usuário: {pedido.pergunta}"
    try:
        text = await llm(
            [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}]
        )
    except Exception as e:  # LLMIndisponivel da plataforma (sem worker, timeout)
        raise HTTPException(503, str(e)) from e
    return consumo.guardar_analise(
        {
            "criada_em": datetime.now(UTC).isoformat(timespec="seconds"),
            "de": de.isoformat(),
            "ate": until.isoformat(),
            "pergunta": pedido.pergunta.strip(),
            "texto": text.strip(),
        }
    )
