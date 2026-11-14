"""Direção por bloco (`docs/PLANO-ACERVO.md`, "Direção"): roteiro → blocos → tratamento → 5 candidatas → escolha →
preenchimento. Substitui o diretor por frase (`diretor.py`) quando Opções → `direcao = "blocos"` (padrão).

1. Blocos = parágrafos do roteiro (falas do `roteiro.txt` casadas com os trechos falados); sem roteiro, pausas e o
   tamanho de bloco do perfil. Cada bloco se divide em momentos do tamanho da virada do perfil (`virada_s`: ~30 s no
   longo, ~3 s no curto); um número dito abre momento próprio. O momento é a unidade que ganha uma peça.
2. Leitura (IA local, 1 chamada por bloco, prompt `direcao_leitura`): intenção, tom, entidades e tratamento de cada
   momento (só voz com motion, mídia com motion, câmera cheia, câmera + peça, 2,5D sobre a câmera, 3D); o código
   corrige o que o modo não permite e quebra três tratamentos iguais seguidos.
3. Candidatas (código): peças aprovadas do canal (`peca.no_canal`), no formato e na duração, filtradas pelo
   tratamento; ordem = semelhança do momento com os `exemplos_sim` (menos os `exemplos_nao`) por embeddings locais
   (`ia/embeddings.py`; sem o modelo, palavras em comum), + intenção que bate, − peça usada há pouco
   (anti-repetição) e cotas (3D, só texto). Saem 5.
4. Escolha (IA local, `direcao_escolha`): 1 das 5 com motivo; fora da lista = a primeira.
5. Preenchimento (IA local, `direcao_preencher`): encaixes + botões; o código valida (limites da ficha, número que
   não foi dito) e devolve o erro; 2ª falha → próxima candidata; sem nenhuma, o momento fica na mídia.
Apontamento da pessoa e gatilhos do estilo fixam a peça (a IA só preenche). Depois: perfil de ritmo (sem capítulos,
gancho, conferência) e o mapa no formato do kit (`encaixes`, `botoes`, `batidas`).
"""
import json
import re

from pydantic import BaseModel, Field

from esteira.bancada import EscolhaPeca as Escolha
from esteira.bancada import normalizar, numeros
from esteira.core import events
from esteira.estudio import peca as P
from esteira.estudio import ritmo as R
from esteira.ia import local

TRATAMENTOS = ("voz_motion", "midia_motion", "camera_cheia", "camera_peca", "camera_2_5d", "3d")
SO_APRESENTADOR = {"camera_cheia", "camera_peca", "camera_2_5d"}
REGRAS_TRATAMENTO = {
    "dark": "voz_motion = a peça ocupa a tela (dado forte, virada, pergunta); midia_motion = a imagem/vídeo do "
            "assunto com a peça por cima (a maioria); 3d só se a fala pedir um objeto no espaço.",
    "apresentador": "camera_cheia = o apresentador fala sem peça (opinião, conversa); camera_peca = câmera ao lado de "
                    "uma peça (dado, comparação); camera_2_5d = peça em perspectiva sobre a câmera; voz_motion = só a "
                    "peça na tela (virada forte); midia_motion = B-roll com peça por cima.",
}
N_CANDIDATAS = 5
PESO_NAO, BONUS_INTENCAO, PENA_RECENTE, PENA_PERTO = 0.3, 0.12, 0.25, 0.1
VAZIO = re.compile(r"\b(unknown|desconhecid[oa]s?|n/a|n\.a\.|não informad[oa]|não disponível|null)\b", re.I)
ESTUDO = re.compile(r"\b(estudos?|pesquisa\w*|publicaram|artigo|levantamento|relatorio|autores)\b")
CHAMADA = re.compile(r"\b(comenta|comentarios|inscrev|link na descricao|me segue|compartilh|curt[ae])")
COTA_TEXTO = 0.4   # peças só de texto até 40% das escolhas (a cota de 3D é do perfil de ritmo: `cota_3d_s`)


class Entidades(BaseModel):
    numeros: list[str] = Field(default_factory=list)
    datas: list[str] = Field(default_factory=list)
    nomes: list[str] = Field(default_factory=list)


class LeituraMomento(BaseModel):
    intencao: str
    tom: str = "didatica"
    tratamento: str = "midia_motion"
    entidades: Entidades = Field(default_factory=Entidades)


class LeituraBloco(BaseModel):
    momentos: list[LeituraMomento]


class Conferencia(BaseModel):
    fiel: bool
    problema: str = ""


class Preenchimento(BaseModel):
    encaixes: dict = Field(default_factory=dict)
    botoes: dict = Field(default_factory=dict)


# ---------------------------------------------------------------- números falados

UNIDADES = {"zero": 0, "um": 1, "uma": 1, "dois": 2, "duas": 2, "tres": 3, "quatro": 4, "cinco": 5, "seis": 6,
            "sete": 7, "oito": 8, "nove": 9, "dez": 10, "onze": 11, "doze": 12, "treze": 13, "catorze": 14,
            "quatorze": 14, "quinze": 15, "dezesseis": 16, "dezessete": 17, "dezoito": 18, "dezenove": 19}
DEZENAS = {"vinte": 20, "trinta": 30, "quarenta": 40, "cinquenta": 50, "sessenta": 60, "setenta": 70, "oitenta": 80,
           "noventa": 90}
CENTENAS = {"cem": 100, "cento": 100, "duzentos": 200, "duzentas": 200, "trezentos": 300, "trezentas": 300,
            "quatrocentos": 400, "quinhentos": 500, "seiscentos": 600, "setecentos": 700, "oitocentos": 800,
            "novecentos": 900}


def ditos(texto):
    """Números do que foi falado como dígitos (`bancada.numeros`), inclusive os por extenso ("oito em cada dez" →
    8 e 10; "vinte e cinco" → 25; "três mil" → 3000), para a conferência de número inventado."""
    saida = set(numeros(texto))
    ws = normalizar(texto).split() + ["."]
    valor, ativo = 0, False
    for k, w in enumerate(ws):
        n = UNIDADES.get(w, DEZENAS.get(w, CENTENAS.get(w)))
        if w in ("um", "uma") and not ativo and ws[k + 1] not in ("mil", "milhao", "milhoes", "bilhao"):
            n = None  # artigo ("um dia"), não número
        if w == "cento" and k and ws[k - 1] == "por":
            n = None  # "por cento"
        if n is not None:
            valor, ativo = valor + n, True
        elif w == "mil":
            valor, ativo = (valor or 1) * 1000, True
        elif w == "e" and ativo:
            continue
        else:
            if ativo:
                saida.add(str(valor))
            valor, ativo = 0, False
    return saida


# ---------------------------------------------------------------- 1. blocos e momentos

def _palavras_norm(t):
    return [w for w in normalizar(t).split() if w]


def blocos(trechos, falas, perfil):
    """Trechos (com tempo) agrupados por fala do roteiro (parágrafo); sem roteiro, por pausa > 1,2 s ou pelo tamanho
    máximo de bloco do perfil. → [{i, ini, fim, texto, trechos: [índices]}]."""
    grupos = []
    if falas:
        alvo = [len(_palavras_norm(f)) for f in falas if _palavras_norm(f)]
        k, acc, atual = 0, 0, []
        for n, t in enumerate(trechos):
            atual.append(n)
            acc += len(_palavras_norm(t["texto"]))
            if k < len(alvo) and acc >= 0.85 * alvo[k]:
                grupos.append(atual)
                atual, acc, k = [], 0, k + 1
        if atual:
            grupos.append(atual)
    else:
        atual = []
        for n, t in enumerate(trechos):
            if atual and (t["ini"] - trechos[atual[-1]]["fim"] > 1.2
                          or t["fim"] - trechos[atual[0]]["ini"] > perfil.bloco_s[1]):
                grupos.append(atual)
                atual = []
            atual.append(n)
        if atual:
            grupos.append(atual)
    return [{"i": i, "ini": trechos[g[0]]["ini"], "fim": trechos[g[-1]]["fim"],
             "texto": " ".join(trechos[n]["texto"] for n in g), "trechos": g} for i, g in enumerate(grupos)]


def momentos(bloco, trechos, perfil):
    """Momentos do bloco no tamanho da virada do perfil; um trecho com número abre momento novo se o atual já tem um."""
    saida, atual = [], []
    for n in bloco["trechos"]:
        t = trechos[n]
        dur = (t["fim"] - trechos[atual[0]]["ini"]) if atual else 0
        tem_num = any(ditos(trechos[x]["texto"]) for x in atual)
        if atual and (dur > perfil.virada_s[1]
                      or (ditos(t["texto"]) and tem_num)
                      or trechos[atual[-1]]["fim"] - trechos[atual[0]]["ini"] >= perfil.virada_s[0]):
            saida.append(atual)
            atual = []
        atual.append(n)
    if atual:
        saida.append(atual)
    return [{"bloco": bloco["i"], "j": j, "ini": trechos[m[0]]["ini"], "fim": trechos[m[-1]]["fim"],
             "texto": " ".join(trechos[n]["texto"] for n in m), "trechos": m} for j, m in enumerate(saida)]


# ---------------------------------------------------------------- 2. leitura e tratamento

def _regra(m):
    """Leitura sem IA (plano B): número → numero, pergunta → pergunta, resto → destaque."""
    t = m["texto"]
    intencao = "numero" if ditos(t) else "pergunta" if t.strip().endswith("?") else "destaque"
    return LeituraMomento(intencao=intencao, tratamento="voz_motion" if intencao == "numero" else "midia_motion",
                          entidades=Entidades(numeros=sorted(ditos(t))))


def ler(bloco, ms, modo, perfil, antes=""):
    trat = [t for t in TRATAMENTOS if modo == "apresentador" or t not in SO_APRESENTADOR]
    texto = local.prompt("direcao_leitura", intencoes=", ".join(P.INTENCOES), tratamentos=", ".join(trat),
                         regras_tratamento=REGRAS_TRATAMENTO.get(modo, REGRAS_TRATAMENTO["dark"]), modo=modo,
                         ritmo=perfil.id, antes=antes[-300:], n=len(ms),
                         momentos="\n".join(f"{k + 1}. {m['texto']}" for k, m in enumerate(ms)))
    r = local.perguntar(texto, LeituraBloco, max_tokens=300 + 160 * len(ms), operacao="direction")
    if not r or len(r.momentos) != len(ms):
        return [_regra(m) for m in ms], "regra"
    return [_corrigir(x, m) for x, m in zip(r.momentos, ms, strict=True)], "local"


def _corrigir(x: LeituraMomento, m):
    if x.intencao not in P.INTENCOES:
        x.intencao = _regra(m).intencao
    if x.tratamento not in TRATAMENTOS:
        x.tratamento = "midia_motion"
    # número que a IA não viu: o código põe (a peça precisa do dado)
    falados = ditos(m["texto"])
    if falados and not x.entidades.numeros:
        x.entidades.numeros = sorted(falados)
    return x


def tratar(leituras, modo):
    """Tratamento possível no modo; o mesmo três vezes seguidas troca o terceiro (variedade)."""
    saida = []
    for x in leituras:
        t = x.tratamento
        if modo != "apresentador" and t in SO_APRESENTADOR:
            t = "voz_motion" if t == "camera_peca" else "midia_motion"
        if len(saida) >= 2 and saida[-1] == saida[-2] == t:
            t = {"midia_motion": "voz_motion", "voz_motion": "midia_motion", "camera_cheia": "camera_peca",
                 "camera_peca": "camera_cheia"}.get(t, "midia_motion")
        saida.append(t)
    return saida


# ---------------------------------------------------------------- 3. candidatas

def _vetores_fichas(fichas):
    """{id: (vetor dos exemplos_sim, vetor dos exemplos_nao)} pelos embeddings; None sem o modelo."""
    from esteira.ia import embeddings as E
    textos = sorted({x for f in fichas for x in f.exemplos_sim + f.exemplos_nao + [f.comunica]})
    vs = E.vetores(textos, E.DOCUMENTO) if textos else []
    if vs is None:
        return None
    d = dict(zip(textos, vs, strict=True))
    return {f.id: (E.media([d[x] for x in f.exemplos_sim + [f.comunica]]), E.media([d[x] for x in f.exemplos_nao]))
            for f in fichas}


def _semelhanca_palavras(texto, f):
    """Plano B sem embeddings: proporção de radicais do momento que aparecem nos exemplos da ficha."""
    def rad(t):
        return {w[:5] for w in _palavras_norm(t) if len(w) > 3}
    m = rad(texto)
    if not m:
        return 0.0
    sim = rad(" ".join(f.exemplos_sim + [f.comunica]))
    nao = rad(" ".join(f.exemplos_nao))
    return len(m & sim) / len(m) - PESO_NAO * len(m & nao) / len(m)


def _cabe(f, tratamento, dur, formatos):
    if not set(formatos) <= set(f.formatos) or dur < f.duracao_min * 0.8:
        return False
    if tratamento == "3d":
        return f.peso == "3d"
    if tratamento == "camera_2_5d":
        return f.peso == "2_5d" or f.rosto == "sobre_camera"
    if tratamento in ("voz_motion", "camera_peca"):
        return f.tela_cheia
    if tratamento == "midia_motion":
        return not f.tela_cheia
    return True


def candidatas(m, leitura, tratamento, fichas, vet_m, vet_f, usadas, formatos, perfil, escolhidas):
    """As N_CANDIDATAS melhores [(pontos, ficha)] para o momento. `usadas`: {peça: último t}; `escolhidas`: [(ficha,
    t)] já escolhidas no vídeo (cotas). Se o tratamento deixar menos de 5, completa com as outras que cabem no formato."""
    from esteira.ia import embeddings as E
    dur = m["fim"] - m["ini"]
    texto_n = sum(1 for f, _ in escolhidas if f.peso == "texto")
    ultimo_3d = max((t for f, t in escolhidas if f.peso == "3d"), default=-1e9)

    def pontos(f):
        if vet_m is not None and vet_f is not None:
            sim, nao = vet_f[f.id]
            s = E.cosseno(vet_m, sim) - (PESO_NAO * E.cosseno(vet_m, nao) if nao else 0.0)
        else:
            s = _semelhanca_palavras(m["texto"], f)
        if leitura.intencao in f.intencoes:
            s += BONUS_INTENCAO
        t0 = usadas.get(f.id)
        if t0 is not None:
            s -= PENA_RECENTE if m["ini"] - t0 < perfil.anti_repeticao_s else (
                PENA_PERTO if m["ini"] - t0 < 2 * perfil.anti_repeticao_s else 0.0)
        if f.peso == "3d" and m["ini"] - ultimo_3d < perfil.cota_3d_s:
            s -= 1.0
        if f.peso == "texto" and escolhidas and texto_n / len(escolhidas) > COTA_TEXTO:
            s -= 0.1
        return round(s, 4)

    certas = [f for f in fichas if _cabe(f, tratamento, dur, formatos)]
    ordem = sorted(certas, key=pontos, reverse=True)[:N_CANDIDATAS]
    if len(ordem) < N_CANDIDATAS:
        resto = [f for f in fichas if f not in ordem and set(formatos) <= set(f.formatos) and dur >= f.duracao_min * 0.8]
        ordem += sorted(resto, key=pontos, reverse=True)[:N_CANDIDATAS - len(ordem)]
    return [(pontos(f), f) for f in ordem]


# ---------------------------------------------------------------- 4–5. escolha e preenchimento

def linhas_candidatas(fichas):
    return "\n".join(f"- {f.id}: {f.comunica} (serve para: \"{f.exemplos_sim[0]}\"; \"{f.exemplos_sim[1]}\")"
                     for f in fichas)


def escolher(m, leitura, tratamento, cands):
    if len(cands) == 1:
        return cands[0][1], "única candidata", "regra"
    linhas = linhas_candidatas([f for _, f in cands])
    texto = local.prompt("direcao_escolha", texto=m["texto"], intencao=leitura.intencao, tom=leitura.tom,
                         tratamento=tratamento, numeros=", ".join(leitura.entidades.numeros) or "nenhum",
                         candidatas=linhas)
    r = local.perguntar(texto, Escolha, max_tokens=200, operacao="direction")
    por_id = {f.id: f for _, f in cands}
    if r and r.escolha in por_id:
        return por_id[r.escolha], r.motivo[:200], "local"
    return cands[0][1], "fora da lista: ficou a mais parecida", "regra"


def _descrever_encaixes(f):
    linhas = []
    for e in f.encaixes:
        lim = {"itens": f"{e.min_itens}–{e.max_itens} itens de até {e.max_car} caracteres",
               "pares": f"{e.min_itens}–{e.max_itens} pares (rótulo até {e.max_car}, valor até {e.max_valor})",
               "pagina": "não preencha (vem do PDF)"}.get(e.tipo, f"até {e.max_car} caracteres")
        extra = f"; opções: {e.opcoes}" if e.opcoes else ""
        linhas.append(f"- {e.nome} ({e.tipo}, {lim}, {'obrigatório' if e.obrigatorio else 'opcional'}{extra}): "
                      f"{e.descricao} · exemplo: {json.dumps(e.exemplo, ensure_ascii=False)}")
    return "\n".join(linhas)


def problemas(f, enc, bot, texto):
    """Erros do preenchimento: limites da ficha + número que não foi dito no momento."""
    erros = P.validar_dados(f, enc, bot)
    valores = json.dumps(enc, ensure_ascii=False)
    de_numero = bool(f.intencoes) and f.intencoes[0] == "numero"
    if de_numero and ditos(texto) and not numeros(valores):
        erros.append("peça de número sem o número dito: ponha o valor como foi falado")
    if de_numero and not ditos(texto):
        erros.append("peça de número, mas nenhum número foi dito neste momento")
    inventados = numeros(valores) - ditos(texto)
    if inventados:
        erros.append(f"números que não foram ditos: {', '.join(sorted(inventados))}")
    if VAZIO.search(valores):
        erros.append("campo com marcador vazio (Unknown, N/A...): deixe de fora o que não foi dito")
    for e in f.encaixes:
        if e.tipo == "pares" and isinstance(enc.get(e.nome), list):
            rotulos = [str(x.get("rotulo", "")).strip() for x in enc[e.nome] if isinstance(x, dict)]
            if any(len(r.replace("*", "")) < 3 for r in rotulos):
                erros.append(f"{e.nome}: cada rótulo é um item completo, não um pedaço da frase")
    if "valor_a" in enc and str(enc["valor_a"]) == str(enc.get("valor_b")):
        erros.append("comparação de dois valores iguais não compara nada: use outra peça")
    pares = [str(x.get("valor", "")) for x in enc.get("valores") or [] if isinstance(x, dict)]
    if f.id.startswith("barras") and (not all(re.search(r"\d", v) for v in pares) or len(set(pares)) < 2):
        erros.append("barras precisam de números diferentes ditos na fala: use outra peça")
    if f.id == "citacao_estudo" and not ESTUDO.search(normalizar(texto)):
        erros.append("a fala não cita estudo nenhum: use outra peça")
    if f.id == "cta" and not CHAMADA.search(normalizar(texto)):
        erros.append("a fala não chama o público para nada: use outra peça")
    if f.id == "passo_a_passo" and re.match(r"\W*passo\s*:", str(enc.get("titulo", "")), re.I):
        erros.append("titulo: sem 'Passo:' quando não há número de passo")
    return erros


def conferir(f, enc, m, contexto):
    """Segunda passada da LLM local: o texto de tela diz o que a fala diz? Sem resposta, passa."""
    r = local.perguntar(local.prompt("direcao_conferir", texto=m["texto"], contexto=contexto[-300:], peca=f.id,
                                     comunica=f.comunica, tela=json.dumps(enc, ensure_ascii=False)),
                        Conferencia, max_tokens=300, operacao="direction")
    return [f"o texto de tela não bate com a fala: {r.problema}"] if getattr(r, "fiel", True) is False else []


def citacoes(projeto):
    """Blocos [!cite] do roteiro, com a fala em que aparecem: a única fonte de trecho, autor e ano."""
    arq = projeto.pasta / "roteiro.json"
    if not arq.exists():
        return []
    falas = _falas(projeto)
    cits = [c for c in json.loads(arq.read_text()).get("citacoes", []) if c.get("ok") and c.get("en")]
    return [{**c, "palavras": set(_palavras_norm(falas[c["fala"]]))} for c in cits if 0 <= c["fala"] < len(falas)]


def _citacao_de(m, cits):
    """Citação cuja fala contém o momento, ou None (o momento não cita estudo nenhum)."""
    ditas = set(_palavras_norm(m["texto"]))
    notas = [(len(ditas & c["palavras"]) / max(len(ditas), 1), n) for n, c in enumerate(cits)]
    nota, n = max(notas, default=(0, 0))
    return cits[n] if nota >= 0.6 else None


def _caber(texto, limite):
    if len(texto) <= limite:
        return texto
    frase = re.match(r".+?[.!?](?=\s|$)", texto)
    if frase and len(frase[0]) <= limite:
        return frase[0]
    return texto[:limite - 1].rsplit(" ", 1)[0].rstrip(" ,;:") + "…"


def _preencher_citacao(f, m, cits):
    """Peça de citação vem do bloco [!cite], nunca da LLM (que inventa trecho e autor). Sem citação no momento → None."""
    c = _citacao_de(m, cits)
    if not c:
        return None
    fonte = {"trecho_en": c["en"], "traducao": c.get("pt", ""), "autor": c.get("autores", ""),
             "autores": c.get("autores", ""), "ano": str(c.get("ano", ""))[:4], "revista": c.get("revista", ""),
             "titulo": c.get("titulo", "")}
    enc = {e.nome: _caber(fonte[e.nome], e.max_car) for e in f.encaixes if fonte.get(e.nome)}
    return None if P.validar_dados(f, enc, {}) else (enc, {})


def preencher(f, m, leitura, cits=(), contexto=""):
    """(encaixes, botões) válidos ou None depois de duas tentativas."""
    if any(e.nome == "trecho_en" for e in f.encaixes):
        return _preencher_citacao(f, m, cits)
    erros = []
    for _ in range(2):
        texto = local.prompt(
            "direcao_preencher", peca=f.id, comunica=f.comunica, texto=m["texto"],
            numeros=", ".join(leitura.entidades.numeros) or "nenhum", datas=", ".join(leitura.entidades.datas) or "nenhuma",
            nomes=", ".join(leitura.entidades.nomes) or "nenhum", encaixes=_descrever_encaixes(f),
            botoes="\n".join(f"- {b.nome}: {b.valores} (padrão {b.padrao})" for b in f.botoes) or "(nenhum)",
            erros=("\nSua resposta anterior foi recusada: " + "; ".join(erros) + ". Corrija.\n") if erros else "")
        r = local.perguntar(texto, Preenchimento, max_tokens=500, operacao="direction")
        if not r:
            erros = ["resposta vazia"]
            continue
        enc = {k: v for k, v in r.encaixes.items() if v not in (None, "", [])}
        bot = {k: v for k, v in r.botoes.items() if any(b.nome == k for b in f.botoes)}
        erros = problemas(f, enc, bot, m["texto"]) or conferir(f, enc, m, contexto)
        if not erros:
            return enc, bot
    return None


def batidas(f, enc, m, palavras):
    """Instante (s) em que a palavra de cada encaixe de `batidas` é dita dentro do momento."""
    saida = {}
    ditas = [w for w in palavras if m["ini"] - 0.05 <= w["ini"] <= m["fim"] + 0.05]
    for nome in f.batidas:
        v = enc.get(nome)
        alvo = None
        if isinstance(v, str):
            ns = sorted(numeros(v))  # o valor escrito em dígitos; a fala pode estar por extenso (casa pelo radical)
            alvo = ns[0] if ns else next((w for w in _palavras_norm(v) if len(w) > 3), None)
        if not alvo:
            continue
        for w in ditas:
            if alvo in normalizar(w["p"]).replace(" ", "") or normalizar(w["p"]).startswith(alvo[:5]):
                saida[nome] = round(max(m["ini"], w["ini"] - 0.05), 3)
                break
    return saida


# ---------------------------------------------------------------- mapa

def refazer_cena(cena, ficha):
    """Troca a peça de uma cena do mapa (linha do tempo do app): preenche a nova pela IA local com a mesma validação
    da direção; se não der, aproveita título/valores que a cena já tinha. → a cena atualizada (ou ValueError)."""
    m = {"ini": cena["t"], "fim": cena["ate"], "texto": cena.get("frase", "")}
    leitura = LeituraMomento(intencao=cena.get("intencao") or "destaque", tratamento=cena.get("tratamento", "midia_motion"),
                             entidades=Entidades(numeros=sorted(ditos(m["texto"]))))
    preenchido = preencher(ficha, m, leitura)
    if not preenchido:
        enc = P.legado({"titulo": cena.get("titulo", ""), "valores": cena.get("valores", [])}, ficha)
        if problemas(ficha, enc, {}, m["texto"]):
            raise ValueError(f"{ficha.id} não serve para este momento (a IA não preencheu e o que havia não cabe)")
        preenchido = (enc, {})
    enc, bot = preenchido
    dur = min(max(cena["ate"] - cena["t"], ficha.duracao_min), ficha.duracao_max)
    cena.update(cena=ficha.id, encaixes=enc, botoes={**P.padroes(ficha), **bot}, takeover=ficha.tela_cheia,
                titulo=str(enc.get("titulo", ""))[:80], valores=enc.get("valores", []), sfx=ficha.sfx.get("entrada"),
                ate=round(cena["t"] + dur, 3), manual=True, por="voce", motivo="trocada na linha do tempo")
    return cena


def gabarito(ep, cena, aceita, origem):
    """Caso da tarefa `bloco_peca` da bancada (momento + as 5 candidatas → a peça que a pessoa aprovou/trocou)."""
    from esteira.bancada import GABARITO
    ids = cena.get("candidatas") or []
    if not ids:
        return False
    fichas = []
    for i in dict.fromkeys(ids + [aceita]):
        try:
            fichas.append(P.carregar(i))
        except (KeyError, ValueError):
            continue
    GABARITO.mkdir(parents=True, exist_ok=True)
    caso = {"id": f"{origem}:{ep}:{cena.get('bloco')}:{cena.get('momento')}", "texto": cena.get("frase", ""),
            "intencao": cena.get("intencao", ""), "tratamento": cena.get("tratamento", ""),
            "numeros": ", ".join(sorted(ditos(cena.get("frase", "")))), "candidatas": linhas_candidatas(fichas),
            "aceitas": [aceita], "ia": cena.get("cena") if origem == "troca" else None}
    with open(GABARITO / "bloco_peca.jsonl", "a") as f:
        f.write(json.dumps(caso, ensure_ascii=False) + "\n")
    return True


def gabarito_preencher(ep, cena, origem):
    """Caso de preenchimento (momento + peça → encaixes e botões que ficaram): treino da tarefa `preencher`."""
    from esteira.bancada import GABARITO
    if not cena.get("encaixes"):
        return False
    GABARITO.mkdir(parents=True, exist_ok=True)
    caso = {"id": f"{origem}:{ep}:{cena.get('bloco')}:{cena.get('momento')}:{cena['cena']}", "texto": cena.get("frase", ""),
            "peca": cena["cena"], "intencao": cena.get("intencao", ""), "encaixes": cena["encaixes"],
            "botoes": cena.get("botoes") or {}}
    with open(GABARITO / "preencher.jsonl", "a") as f:
        f.write(json.dumps(caso, ensure_ascii=False) + "\n")
    return True


def aprovar_mapa(ep, mapa):
    """Mapa aprovado: cada peça escolhida pela IA (não fixada) vira acerto no gabarito, e cada preenchimento que ficou
    vira caso de preenchimento. → quantos casos de escolha."""
    for c in mapa.get("cenas", []):
        if c.get("por") in ("local", "regra", "voce", "gatilho") and c.get("encaixes"):
            gabarito_preencher(ep, c, "aprovado")
    return sum(gabarito(ep, c, c["cena"], "aprovado") for c in mapa.get("cenas", [])
               if c.get("candidatas") and c.get("por") in ("local", "regra") and not c.get("manual"))


def _falas(projeto):
    arq = projeto.pasta / "roteiro.txt"
    if not arq.exists():
        return []
    return [x.strip() for x in arq.read_text().splitlines() if x.strip() and not x.startswith("#")]


def _fixa(m, marcas, gat, fichas_id):
    """Peça fixada no momento pela pessoa (apontamento) ou por gatilho do estilo → (id, por) ou None."""
    for n in m["trechos"]:
        if (c := marcas.get(n)) and c in fichas_id:
            return c, "voce"
    for n in m["trechos"]:
        d = gat.get(n)
        if d and d["gatilho"].peca in fichas_id:
            return d["gatilho"].peca, "gatilho"
    return None


def dirigir(projeto, estilo, perfil=None, formatos=None):
    """Escreve `<ep>/estudio/mapa.json` pela direção por bloco; devolve o mapa."""
    from esteira.estudio import apontamento, corte, diretor, gatilhos
    from esteira.ia import embeddings as E
    perfil = perfil or R.perfil_do(projeto)
    formatos = formatos or estilo.formatos
    pasta = projeto.pasta / "estudio"
    pasta.mkdir(exist_ok=True)
    frases, palavras = corte.frases(projeto), corte.palavras(projeto)
    duracao = frases[-1]["fim"] + 1.0 if frases else 0
    palavras_d = [{"p": w["p"], "ini": w["ini"]} for w in palavras]
    trechos = diretor.trechos(frases, palavras, estilo.regras.trecho_max_s)
    marcas = apontamento.marcas(projeto, trechos)
    gat = gatilhos.aplicar(trechos, estilo.gatilhos)
    fichas = [f for f in P.no_canal(P.listar(), estilo) if f.motor in ("html", "effectcraft")]
    if not fichas:
        raise SystemExit("acervo vazio para o canal: aprove peças na Fábrica ou tire do filtro do canal")
    por_id = {f.id: f for f in fichas}
    cits = citacoes(projeto)
    bls = blocos(trechos, _falas(projeto), perfil)
    ms_por_bloco = [momentos(b, trechos, perfil) for b in bls]
    todos = [m for ms in ms_por_bloco for m in ms]
    vet_f = _vetores_fichas(fichas)
    vet_m = E.vetores([m["texto"] for m in todos], E.CONSULTA) if vet_f is not None else None
    if vet_f is None:
        events.warning("direção: sem o modelo de embeddings; candidatas por palavras em comum")
    vet_por = {id(m): (vet_m[k] if vet_m else None) for k, m in enumerate(todos)}
    cenas, usadas, escolhidas, decisoes = [], {}, [], {"local": 0, "regra": 0, "voce": 0, "gatilho": 0, "midia": 0}
    antes = ""
    for b, ms in zip(bls, ms_por_bloco, strict=True):
        events.progress(b["i"] + 1, len(bls), f"bloco {b['i'] + 1}: {b['texto'][:50]}")
        leituras, origem = ler(b, ms, estilo.modo, perfil, antes)
        antes = b["texto"]
        trats = tratar(leituras, estilo.modo)
        for m, lt, tr in zip(ms, leituras, trats, strict=True):
            if tr == "camera_cheia":
                decisoes["midia"] += 1
                continue
            fixa = _fixa(m, marcas, gat, por_id)
            reserva = []
            if fixa:
                cands = [(1.0, por_id[fixa[0]])]
                if fixa[1] == "gatilho":  # o gatilho sugere; se a peça não preencher, a direção escolhe outra
                    reserva = candidatas(m, lt, tr, fichas, vet_por[id(m)], vet_f, usadas, formatos, perfil, escolhidas)
            else:
                cands = candidatas(m, lt, tr, fichas, vet_por[id(m)], vet_f, usadas, formatos, perfil, escolhidas)
            if not cands:
                decisoes["midia"] += 1
                continue
            f, motivo, por = escolher(m, lt, tr, cands)
            por = fixa[1] if fixa else por
            ordem = [f] + [x for _, x in cands + reserva if x.id != f.id]
            preenchido = None
            for alvo in ordem[:3]:
                preenchido = preencher(alvo, m, lt, cits, b["texto"])
                if preenchido:
                    if alvo.id != f.id:
                        motivo = f"{f.id} não preencheu; ficou {alvo.id}"
                        por = "local" if por == "gatilho" else por
                    f = alvo
                    break
            if not preenchido:
                decisoes["midia"] += 1
                events.warning(f"direção: nenhuma peça preenchida em {m['ini']:.1f}s; fica a mídia")
                continue
            enc, bot = preenchido
            dur = min(m["fim"] - m["ini"] + 0.3, f.duracao_max, perfil.peca_s[1])
            t = max(0.0, m["ini"] - 0.08)
            if dur < max(f.duracao_min, perfil.peca_s[0]) * 0.8:
                decisoes["midia"] += 1
                continue
            bat = batidas(f, enc, m, palavras_d)
            t = max(t, bat.get("valor", 0) - 0.5)  # peça de número abre quando ele é dito, não vazia antes
            decisoes[por] = decisoes.get(por, 0) + 1
            usadas[f.id] = m["ini"]
            escolhidas.append((f, m["ini"]))
            cenas.append({"t": round(t, 3), "ate": round(t + dur, 3), "cena": f.id, "encaixes": enc,
                          "botoes": {**P.padroes(f), **bot}, "batidas": bat,
                          "takeover": f.tela_cheia, "frase": m["texto"], "titulo": str(enc.get("titulo", ""))[:80],
                          "valores": enc.get("valores", []), "ancora": "", "por": por, "motivo": motivo,
                          "tratamento": tr, "intencao": lt.intencao, "leitura": origem, "bloco": b["i"], "momento": m["j"],
                          "candidatas": [x.id for _, x in cands], "pontos": [p for p, _ in cands],
                          "sfx": f.sfx.get("entrada"), "frase_i": m["trechos"][0],
                          **({"layout_pedido": "split"} if tr in ("camera_peca", "camera_2_5d") else {})})
    for a, b in zip(cenas, cenas[1:], strict=False):
        a["ate"] = round(min(a["ate"], b["t"] - 0.05), 3)
    cenas = [c for c in cenas if c["ate"] - c["t"] >= 0.6]
    cenas = R.sem_capitulos(cenas, perfil)
    cenas = R.gancho(cenas, perfil, trechos)
    for n, c in enumerate(cenas):
        c["id"] = n
        c.setdefault("takeover", por_id[c["cena"]].tela_cheia if c["cena"] in por_id else False)
    avisos = R.conferir(cenas, diretor._midia_tempos(projeto), duracao, perfil)
    mapa = {"estilo": estilo.id, "versao": estilo.versao, "duracao": duracao, "direcao": "blocos",
            "decisoes": decisoes, "cenas": cenas, "ritmo": {"perfil": perfil.id, "avisos": avisos},
            "blocos": [{"i": b["i"], "ini": b["ini"], "fim": b["fim"], "texto": b["texto"][:120]} for b in bls],
            "embeddings": vet_f is not None}
    (pasta / "mapa.json").write_text(json.dumps(mapa, ensure_ascii=False, indent=1))
    print(f"  direção: {len(bls)} blocos · {len(todos)} momentos · {len(cenas)} peças · decisões {decisoes} · "
          f"ritmo {perfil.id} ({len(avisos)} aviso(s))" + ("" if vet_f is not None else " · sem embeddings"))
    return mapa

