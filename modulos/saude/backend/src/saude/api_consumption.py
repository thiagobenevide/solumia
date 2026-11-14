"""Rotas de Saúde › Consumo (`/consumo`): regras com trava de 24 h, sincronização dos aparelhos
Android e a leitura do "vigia" pela LLM local (`app.state.saude_llm`; nunca serviço externo)."""

from datetime import UTC, date, datetime, timedelta
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from saude.consumption import CATEGORIAS, Consumo
from saude.workouts import Invalido, NaoEncontrado, Treinos

router = APIRouter(prefix="/consumo")

SISTEMA = """Você é o vigia pessoal do usuário contra o consumo excessivo de conteúdo no celular e
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


def get_consumo(request: Request) -> Consumo:
    estado = request.app.state
    if getattr(estado, "consumo", None) is None:
        treinos: Treinos = estado.treinos
        estado.consumo = Consumo(treinos.raiz / "consumo")
    consumo: Consumo = estado.consumo
    return consumo


ConsumoDep = Annotated[Consumo, Depends(get_consumo)]


def _erro(e: Exception) -> HTTPException:
    if isinstance(e, NaoEncontrado):
        return HTTPException(404, "Não encontrado")
    return HTTPException(422, str(e))


class Horario(BaseModel):
    inicio: str = Field(max_length=5)
    fim: str = Field(max_length=5)


class Regra(BaseModel):
    modo: str
    limite_min: int = 0
    horarios: list[Horario] = []


class App(BaseModel):
    pacote: str = Field(min_length=3, max_length=200)
    nome: str = Field("", max_length=80)
    categoria: str


class Dominio(BaseModel):
    dominio: str = Field(min_length=3, max_length=200)


class Protecao(BaseModel):
    ativa: bool


class Sincronia(BaseModel):
    dispositivo: dict[str, Any]
    dias: list[dict[str, Any]] = Field([], max_length=31)
    eventos: list[dict[str, Any]] = Field([], max_length=2000)


class PedidoAnalise(BaseModel):
    dias: int = Field(7, ge=1, le=90)
    pergunta: str = Field("", max_length=2000)


@router.get("/config")
def config(consumo: ConsumoDep) -> Any:
    return consumo.config()


@router.put("/regras/{categoria}")
def regra(consumo: ConsumoDep, categoria: str, corpo: Regra) -> Any:
    try:
        return consumo.definir_regra(categoria, corpo.model_dump())
    except Invalido as e:
        raise _erro(e) from e


@router.put("/apps")
def app(consumo: ConsumoDep, corpo: App) -> Any:
    try:
        return consumo.definir_app(corpo.pacote, corpo.nome, corpo.categoria)
    except Invalido as e:
        raise _erro(e) from e


@router.delete("/apps/{pacote}")
def remover_app(consumo: ConsumoDep, pacote: str) -> Any:
    try:
        return consumo.remover_app(pacote)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.post("/dominios/{categoria}")
def incluir_dominio(consumo: ConsumoDep, categoria: str, corpo: Dominio) -> Any:
    try:
        return consumo.incluir_dominio(categoria, corpo.dominio)
    except Invalido as e:
        raise _erro(e) from e


@router.delete("/dominios/{categoria}/{dominio}")
def remover_dominio(consumo: ConsumoDep, categoria: str, dominio: str) -> Any:
    try:
        return consumo.remover_dominio(categoria, dominio)
    except (Invalido, NaoEncontrado) as e:
        raise _erro(e) from e


@router.put("/protecao")
def protecao(consumo: ConsumoDep, corpo: Protecao) -> Any:
    return consumo.definir_protecao(corpo.ativa)


@router.delete("/pendencias/{id_}", status_code=204)
def cancelar(consumo: ConsumoDep, id_: str) -> None:
    try:
        consumo.cancelar_pendencia(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.post("/sincronizar")
def sincronizar(consumo: ConsumoDep, corpo: Sincronia) -> Any:
    try:
        return consumo.sincronizar(corpo.model_dump())
    except (KeyError, ValueError, TypeError) as e:
        raise HTTPException(422, f"Dados inválidos: {e}") from e


@router.get("/dispositivos")
def dispositivos(consumo: ConsumoDep) -> Any:
    return consumo.dispositivos()


@router.get("/resumo")
def resumo(consumo: ConsumoDep, de: str, ate: str) -> Any:
    try:
        return consumo.resumo(de, ate)
    except (Invalido, ValueError) as e:
        raise HTTPException(422, str(e)) from e


def montar_contexto(consumo: Consumo, de: date, ate: date) -> str:
    r = consumo.resumo(de.isoformat(), ate.isoformat())
    dias = (ate - de).days + 1
    nomes = {**CATEGORIAS, "outros": "Outros apps"}
    totais: dict[str, float] = {}
    for cats in r["por_dia"].values():
        for c, v in cats.items():
            totais[c] = totais.get(c, 0) + v
    cfg = consumo.config()
    linhas = [
        f"Período: {r['de']} a {r['ate']} ({dias} dias, {len(r['por_dia'])} com dados)",
        "",
        "# Minutos por categoria (total; média por dia)",
    ]
    linhas += [
        f"- {nomes.get(c, c)}: {v:.0f} min; {v / dias:.0f} min/dia"
        for c, v in sorted(totais.items(), key=lambda x: -x[1])
    ]
    linhas += ["", "# Apps mais usados"]
    linhas += [
        f"- {a['nome']} ({nomes.get(a['categoria'], a['categoria'])}): {a['minutos']:.0f} min,"
        f" {a['aberturas']} aberturas"
        for a in r["apps"][:12]
    ]
    linhas += ["", "# Dia a dia (min)"]
    linhas += [
        f"- {d}: " + ", ".join(f"{nomes.get(c, c)} {v:.0f}" for c, v in cats.items())
        for d, cats in sorted(r["por_dia"].items())
    ]
    if r["por_hora"]:
        linhas += ["", "# Horas do dia com mais uso (todas as categorias vigiadas, min)"]
        soma = [sum(h[i] for h in r["por_hora"].values()) for i in range(24)]
        picos = sorted(range(24), key=lambda i: -soma[i])[:5]
        linhas += [f"- {i:02d}h: {soma[i]:.0f}" for i in sorted(picos) if soma[i] > 0]
    if r["eventos"]:
        linhas += ["", "# Eventos (buscas são só categoria; bloqueio = tentativa barrada)"]
        linhas += [f"- {k}: {v}" for k, v in sorted(r["eventos"].items())]
    linhas += ["", "# Regras atuais"]
    for c, regra in cfg["regras"].items():
        extra = f" {regra['limite_min']} min/dia" if regra["modo"] == "limite" else ""
        horas = ", ".join(f"{h['inicio']}–{h['fim']}" for h in regra["horarios"])
        linhas.append(
            f"- {nomes[c]}: {regra['modo']}{extra}" + (f"; bloqueio {horas}" if horas else "")
        )
    if cfg["pendencias"]:
        linhas += ["", "# Pedidos para afrouxar (esperando 24 h)"]
        linhas += [f"- {p['descricao']} (libera {p['libera_em']})" for p in cfg["pendencias"]]
    linhas += ["", "# Aparelhos"]
    for d in consumo.dispositivos():
        desligado = [k for k, v in d["estado"].items() if not v]
        linhas.append(
            f"- {d['nome']}: visto {d['visto_em']}"
            + (f"; DESLIGADO: {', '.join(desligado)}" if desligado else "; tudo ativo")
        )
    return "\n".join(linhas)


@router.get("/analises")
def analises(consumo: ConsumoDep) -> Any:
    return consumo.analises()


@router.post("/analises")
async def analisar(pedido: PedidoAnalise, request: Request, consumo: ConsumoDep) -> Any:
    llm = getattr(request.app.state, "saude_llm", None)
    if llm is None:
        raise HTTPException(503, "LLM local indisponível")
    ate = date.today()
    de = ate - timedelta(days=pedido.dias - 1)
    usuario = montar_contexto(consumo, de, ate)
    if pedido.pergunta.strip():
        usuario += f"\n\nPergunta do usuário: {pedido.pergunta}"
    try:
        texto = await llm(
            [{"role": "system", "content": SISTEMA}, {"role": "user", "content": usuario}]
        )
    except Exception as e:  # LLMIndisponivel da plataforma (sem worker, timeout)
        raise HTTPException(503, str(e)) from e
    return consumo.guardar_analise(
        {
            "criada_em": datetime.now(UTC).isoformat(timespec="seconds"),
            "de": de.isoformat(),
            "ate": ate.isoformat(),
            "pergunta": pedido.pergunta.strip(),
            "texto": texto.strip(),
        }
    )
