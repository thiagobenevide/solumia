"""Etapa 4: monta a timeline no FilmCraft a partir do plano.json e exporta o vídeo.

Faixas: V1 cenas · V2 camada de ajuste (cor dark + vinheta)
        V4 gráficos animados (graficos.json, com alfa) ou, sem eles, textos do FilmCraft · A1 narração · A2 trilha
"""

import threading
import time
from contextlib import contextmanager
from pathlib import Path

from esteira.core import events
from esteira.core.display import open_program
from esteira.filmcraft import FilmCraft, ticks
from esteira.media import duracao_midia
from esteira.n1 import filmcraft as N1
from esteira.project import RAIZ


def _caminho(valor, nome):
    """Caminho da config: absoluto, com ~ ou relativo à pasta da esteira. Ausente → aviso e None."""
    if not valor:
        return None
    p = Path(valor).expanduser()
    p = p if p.is_absolute() else RAIZ / p
    if not p.exists():
        print(f"  aviso: {nome} não encontrado em {p}; seguindo sem")
        return None
    return p


def _cenas_com_midia(plano):
    """Cenas sem mídia são absorvidas pela anterior (ou pela seguinte, se for a primeira)."""
    saida = []
    pendente_inicio = None
    for c in plano["cenas"]:
        if c.get("midia"):
            c = dict(c)
            if pendente_inicio is not None:
                c["inicio"], pendente_inicio = pendente_inicio, None
            saida.append(c)
        elif saida:
            saida[-1]["fim"] = c["fim"]
        else:
            pendente_inicio = c["inicio"]
    if not saida:
        raise SystemExit("nenhuma cena tem mídia; rode buscar")
    saida[-1]["fim"] = plano["duracao"]
    return saida


FORTES = {"glitch", "flash", "zoom_blur", "flicker", "light_leak", "chroma_leak", "whip", "cross_zoom"}


class _Transicoes:
    """Transição de entrada de cada cena pelo clima (perfil do canal), com rodízio dentro do clima, efeito
    forte (glitch, flash…) no máximo a cada `intervalo_forte` s e mergulho no preto nas viradas de capítulo."""

    def __init__(self, cfg, capitulos):
        ef = cfg.get("efeitos", {})
        self.mapa = ef.get("transicao", {})
        self.padrao = cfg["edicao"]["transicao"]
        self.intervalo = ef.get("intervalo_forte", 20)
        self.capitulos = sorted(capitulos)
        self.ultimo_forte, self.giro = -1e9, {}

    def escolher(self, cena):
        t = cena["inicio"]
        if any(abs(t - c) <= 1.5 for c in self.capitulos):
            return "dip_to_black"
        opcoes = self.mapa.get(cena.get("clima"), [self.padrao]) or [self.padrao]
        k = self.giro.get(cena.get("clima"), 0)
        self.giro[cena.get("clima")] = k + 1
        efeito = opcoes[k % len(opcoes)]
        if efeito in FORTES:
            if t - self.ultimo_forte < self.intervalo:
                return next((o for o in opcoes if o not in FORTES), self.padrao)
            self.ultimo_forte = t
        return efeito


SOCO, SOCO_DUR, SOCOS_MAX = 6, 0.12, 2  # % de zoom de impacto, s que ele leva, máximo por cena


def _legendas_srt(projeto, destino, max_palavras=7, max_seg=3.0):
    if projeto.caminho("alinhamento.json").exists():
        palavras = projeto.carregar_json("alinhamento.json")
    else:
        palavras = projeto.carregar_json("transcricao.json")["palavras"]
    blocos, atual = [], []
    for w in palavras:
        fim_de_frase = w["p"].endswith((".", "!", "?"))
        # Não deixa a última palavra da frase sozinha numa legenda.
        if atual and not fim_de_frase and (len(atual) >= max_palavras or w["fim"] - atual[0]["ini"] > max_seg):
            blocos.append(atual)
            atual = []
        atual.append(w)
        if fim_de_frase:
            blocos.append(atual)
            atual = []
    if atual:
        blocos.append(atual)

    def tc(s):
        ms = int(round(s * 1000))
        return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"

    linhas = []
    for i, b in enumerate(blocos, 1):
        linhas += [str(i), f"{tc(b[0]['ini'])} --> {tc(b[-1]['fim'])}", " ".join(w["p"] for w in b), ""]
    destino.write_text("\n".join(linhas))


@contextmanager
def _batimento(arquivo, duracao, intervalo=10):
    """Enquanto o FilmCraft exporta (chamada bloqueante), registra tempo e tamanho do arquivo."""
    parar = threading.Event()

    def bater():
        t0, n = time.monotonic(), 0
        while not parar.wait(intervalo):
            n += 1
            mb = arquivo.stat().st_size / 1e6 if arquivo.exists() else 0
            events.debug("exportando", seg=round(time.monotonic() - t0), mb=round(mb, 1), video_s=duracao)
            if n % 6 == 0:  # no terminal, uma linha por minuto
                print(f"  exportando… {int(time.monotonic() - t0)}s, {mb:.0f} MB")

    th = threading.Thread(target=bater, daemon=True)
    th.start()
    try:
        yield
    finally:
        parar.set()


def montar(projeto, exportar=True):
    _guardar_edicao_manual(projeto)
    cfg = projeto.cfg
    e = cfg["edicao"]
    plano = projeto.carregar_json("plano.json")
    from esteira import production
    cam = production.camera(projeto) if production.modo(projeto) == "apresentador" else None
    if cam:  # apresentador: câmera na V1 o tempo todo; mídia de banco só nas cenas de B-roll (V2)
        production.marcar_apresentador(projeto, plano)
        cenas = [c for c in plano["cenas"] if c.get("midia") and not c.get("camera")]
    else:
        cenas = _cenas_com_midia(plano)
    duracao = plano["duracao"]
    from esteira import photos
    cenas = photos.tratar(projeto, cenas)
    if e["legendas"]:
        _legendas_srt(projeto, projeto.caminho("legendas.srt"))
    doc, midias = montagem(projeto, plano, cenas, cam)
    fc = FilmCraft()
    try:
        ex = N1.Executor(fc, midias, estilo(cfg))
        ex.executar(doc)
        n_graf = sum(1 for o in doc.ops if o.op == "colocar" and o.trilha == "grafismo")
        n_chaves = sum(1 for o in doc.ops if o.op == "texto" and o.estilo == "pop")
        print(f"  {sum(1 for o in doc.ops if o.op == 'colocar' and o.midia.startswith('cena:'))} cenas"
              + (f", {n_graf} gráficos na V4" if n_graf else "") + (f", {n_chaves} palavras-chave na V3" if n_chaves else ""))

        from esteira.description import gerar as gerar_descricao
        print(f"  descrição com os links das fontes: {gerar_descricao(projeto).name}")

        fcproj = projeto.caminho("projeto.fcproj")
        fc.run("file.saveAs", path=str(fcproj))
        _assinar(projeto)
        print(f"  projeto salvo: {fcproj} (`./dark open {projeto.ep}` para editar à mão)")

        _dataset(projeto, plano, doc, ex.rastro, cam, midias)
        if exportar:
            _exportar(fc, projeto, duracao)
    finally:
        fc.fechar()


def estilo(cfg):
    """Fonte e cores por papel para o executor N1 (a pele do canal vem do perfil)."""
    e = cfg["edicao"]
    return {"fonte": e["fonte"], "fonte_estilo": e["fonte_estilo"],
            "cores": {"texto": "#ffffff", "destaque": e["destaque_cor"],
                      "acento": cfg.get("graficos", {}).get("cor", "#ffd400")}}


def montagem(projeto, plano, cenas, cam):
    """Plano do episódio → montagem em N1 do FilmCraft + mídias referenciadas. É o que o modelo local aprende a
    escrever na tarefa `montar` (o executor transforma em comandos da app)."""
    cfg = projeto.cfg
    e, au = cfg["edicao"], cfg["audio"]
    w, h = cfg["video"]["largura"], cfg["video"]["altura"]
    duracao = plano["duracao"]
    formato = cfg["video"].get("formato", "16:9")
    seq = {"op": "sequencia", "nome": plano.get("titulo") or projeto.ep, "formato": formato, "fps": cfg["video"]["fps"]}
    if (w, h) != N1.FORMATOS.get(formato):
        seq.update(largura=w, altura=h)
    ops = [seq, {"op": "colocar", "id": "narracao", "midia": "narracao", "trilha": "narracao", "em": 0},
           {"op": "tipo_audio", "alvo": "narracao", "tipo": "dialogo"}]
    midias = {"narracao": {"caminho": projeto.audio()}}

    pista = "base"
    if cam:  # apresentador: a câmera cortada igual à narração, sem o som dela
        from esteira import production
        midias["cam"] = {"caminho": cam.resolve()}
        ic = production.info_camera(projeto)
        # preenche o quadro (4K, 720p ou câmera deitada num Short 9:16), cortando o excesso
        escala = round(100 * max(w / (ic.get("largura") or w), h / (ic.get("altura") or h)), 3)
        trechos = production.trechos_camera(projeto)
        for k, (t_tl, t_cam, d) in enumerate(trechos):
            ops.append({"op": "colocar", "id": f"cam{k}", "midia": "cam", "trilha": "base", "em": t_tl,
                        "origem": t_cam, "dur": d})
            if escala != 100:
                ops.append({"op": "enquadrar", "alvo": f"cam{k}", "zoom": escala})
        print(f"  câmera: {len(trechos)} trechos na V1; {len(cenas)} cenas de B-roll na V2")
        pista = "apoio"

    graficos = [g for g in (projeto.carregar_json("graficos.json") if projeto.caminho("graficos.json").exists()
                            else []) if g.get("arquivo") and (projeto.pasta / g["arquivo"]).exists()]
    chaves = projeto.carregar_json("chaves.json") if projeto.caminho("chaves.json").exists() else []
    trans = _Transicoes(cfg, [g["inicio"] for g in graficos if g.get("origem") == "capitulo"])
    # socos de zoom: cada palavra-chave e cada número no instante em que é dito
    socos = [k["inicio"] + 0.08 for k in chaves] + [g["ancora"] for g in graficos if g.get("ancora")]
    zooms = cfg.get("efeitos", {}).get("zoom", {})
    nomes = []
    for i, cena in enumerate(cenas):
        ref, nome = f"cena:{cena['id']}", f"c{cena['id']}"
        midias[ref] = {"caminho": projeto.pasta / cena["midia"]}
        ini, fim = cena["inicio"], cena["fim"]
        ops.append({"op": "colocar", "id": nome, "midia": ref, "trilha": pista, "em": ini, "dur": fim - ini})
        ops.append({"op": "ken_burns", "alvo": nome, "movimento": cena.get("movimento", "zoom_in"),
                    "zoom": zooms.get(cena.get("clima"), e["zoom"]),
                    "socos": sorted(t for t in socos if ini + 0.3 < t < fim - 0.6)})
        q = e["transicao_frames"]
        if cam:  # B-roll entra e sai da câmera com fusão curta
            ops += [{"op": "transicao", "alvo": nome, "tipo": "cross_dissolve", "borda": b, "quadros": q}
                    for b in ("entrada", "saida")]
        else:
            ops.append({"op": "transicao", "alvo": nome, "tipo": "dip_to_black" if i == 0 else trans.escolher(cena),
                        "quadros": q})
        nomes.append(nome)
    if nomes and not cam:
        ops.append({"op": "transicao", "alvo": nomes[-1], "tipo": "dip_to_black", "borda": "saida",
                    "quadros": e["transicao_frames"] * 2})

    # Cor "dark": camada de ajuste sobre as cenas (no modo apresentador, só com `[producao] grade_camera = true`)
    if e.get("grade_cor", "dark") == "dark" and (not cam or cfg.get("producao", {}).get("grade_camera", False)):
        ops.append({"op": "cor", "acima_de": "apoio" if cam else "base", "dur": duracao, "ajustes": {
            "exposicao": -0.35, "contraste": 18, "saturacao": 80, "temperatura": -12, "filme": 12, "vinheta": -2.2}})

    # Gráficos animados (EffectCraft/HTML com alfa) por cima de tudo, fora da correção de cor
    for n, g in enumerate(graficos, 1):
        midias[f"grafico:{n}"] = {"caminho": projeto.pasta / g["arquivo"]}
        ops.append({"op": "colocar", "id": f"g{n}", "midia": f"grafico:{n}", "trilha": "grafismo", "em": g["inicio"]})

    # Sem gráficos: título e palavras em destaque como texto do FilmCraft
    folga = 2 / cfg["video"]["fps"]  # o arredondamento para quadros não pode encostar um texto no outro
    livre = 0.0                       # quando a faixa de texto fica livre
    if e["titulo_inicio"] and plano.get("titulo") and not graficos:
        dur_titulo = min(4.0, cenas[0]["fim"] - 0.6)
        ops.append({"op": "texto", "id": "titulo", "conteudo": plano["titulo"].upper(), "em": 0.6, "dur": dur_titulo,
                    "tamanho": e["destaque_tamanho"] * 0.8 / h, "pos": (0.5, 0.55), "cor": "destaque"})
        livre = 0.6 + dur_titulo + folga
    destaques = [] if graficos or chaves else sorted((d for c in plano["cenas"] for d in c.get("destaques", [])),
                                                     key=lambda d: d["inicio"])
    for n, (d, prox) in enumerate(zip(destaques, destaques[1:] + [None])):
        # um destaque sai antes do seguinte entrar (e não entra sobre o título), na mesma faixa
        ini = max(d["inicio"], livre)
        fim = min(d["inicio"] + e["destaque_segundos"], (prox["inicio"] - folga) if prox else duracao, duracao - 0.1)
        if fim - ini >= 0.8:
            ops.append({"op": "texto", "id": f"d{n}", "conteudo": d["texto"].upper(), "em": ini, "dur": fim - ini,
                        "tamanho": e["destaque_tamanho"] / h, "pos": (0.5, 0.82), "cor": "destaque"})
            livre = fim + folga

    # Palavras-chave com "pop" (chaves.json, já agendadas fora dos gráficos da V4)
    for n, k in enumerate(chaves):
        tam = 118 if len(k["texto"]) <= 12 else 92 if len(k["texto"]) <= 20 else 72
        ops.append({"op": "texto", "id": f"k{n}", "conteudo": k["texto"], "em": k["inicio"], "dur": k["dur"],
                    "tamanho": tam / h, "pos": (0.5, {"baixo": 0.80, "centro": 0.50, "alto": 0.22}[k["pos"]]),
                    "cor": "acento" if k["cor"] == "destaque" else "texto", "estilo": "pop"})

    # Trilha de fundo em loop, com ducking sob a narração
    musica = _caminho(au.get("musica"), "trilha")
    if musica:
        midias["musica"] = {"caminho": musica, "dur": duracao_midia(musica)}
        ops.append({"op": "musica", "ate": duracao, "ganho_db": au["musica_db"]})

    if e["legendas"]:
        midias["legendas"] = {"caminho": projeto.caminho("legendas.srt")}
        ops.append({"op": "legendas", "tamanho": e.get("legenda_tamanho", 54) / h,
                    "margem": e.get("legenda_margem", 0.06)})
    return N1.Montagem.model_validate({"ops": ops}), midias


def _dataset(projeto, plano, doc, rastro, cam, midias=None):
    """A montagem vira registro `montar` (origem `traducao`: veio do código determinístico); nunca derruba a etapa."""
    try:
        from esteira.dataset import registry as R
        cfg = projeto.cfg
        ctx = {"formato": cfg["video"].get("formato", "16:9"), "modo": "apresentador" if cam else "dark",
               "duracao": plano["duracao"], "canal": getattr(projeto, "canal", "") or "",
               "cenas": [{k: c.get(k) for k in ("id", "inicio", "fim", "clima", "midia_tipo", "movimento")}
                         for c in plano["cenas"] if c.get("midia")],
               "graficos": [{k: g.get(k) for k in ("inicio", "modelo", "origem", "ancora")}
                            for g in (projeto.carregar_json("graficos.json")
                                      if projeto.caminho("graficos.json").exists() else [])],
               "chaves": projeto.carregar_json("chaves.json") if projeto.caminho("chaves.json").exists() else [],
               "receita": {"edicao": {k: cfg["edicao"].get(k) for k in ("zoom", "transicao_frames", "legendas",
                                                                          "grade_cor", "titulo_inicio")},
                           "efeitos": cfg.get("efeitos", {}), "musica_db": cfg["audio"].get("musica_db")}}
        R.gravar("montar", grupo=f"ep:{projeto.ep}", contexto=ctx, saida=doc.model_dump(mode="json"),
                 origem="traducao", n0=rastro, versoes={"n1": N1.VERSAO, "app": "filmcraft"},
                 extra={"episodio": projeto.ep, "fcproj": "projeto.fcproj",
                        "midias": {k: Path(str(v["caminho"])).name for k, v in (midias or {}).items()}})
    except Exception as e:  # noqa: BLE001
        events.warning(f"dataset: montagem de {projeto.ep} não gravada ({e})")


def _exportar(fc, projeto, duracao):
    e, au = projeto.cfg["edicao"], projeto.cfg["audio"]
    final = projeto.caminho("final.mp4")
    print("  exportando final.mp4…")
    with _batimento(final, duracao):
        fc.run("file.exportMedia", path=str(final), format="h264", bitrateMode="crf", crf=18,
               hardwareEncoding="auto", loudnessLufs=au["loudness_lufs"],
               burnCaptions=bool(e["legendas"]), wait=True)
    print(f"  {final} ({duracao_midia(final):.1f}s)")


# Edição manual: o .fcproj é do usuário depois de montado. A assinatura registra a versão gerada pela
# esteira; se o arquivo mudou, foi editado à mão e é guardado antes de uma nova montagem.

def _hash(arq):
    import hashlib
    return hashlib.sha1(arq.read_bytes()).hexdigest()


def _assinar(projeto):
    projeto.caminho("log").mkdir(exist_ok=True)
    projeto.caminho("log/fcproj.sha1").write_text(_hash(projeto.caminho("projeto.fcproj")))


def _guardar_edicao_manual(projeto):
    fcproj, assinatura = projeto.caminho("projeto.fcproj"), projeto.caminho("log/fcproj.sha1")
    if not fcproj.exists() or (assinatura.exists() and assinatura.read_text() == _hash(fcproj)):
        return
    copia = fcproj.with_name(f"projeto.manual-{time.strftime('%Y%m%d-%H%M')}.fcproj")
    fcproj.rename(copia)
    events.warning(f"projeto.fcproj tinha edição manual: guardado em {copia.name}")
    try:  # a edição vira dado (corrigir_montagem) antes da nova montagem
        from esteira.dataset import edits
        edits.fcproj_editado(projeto, copia)
    except Exception as e:  # noqa: BLE001
        events.warning(f"dataset: edição manual de {projeto.ep} não levantada ({e})")


def _abrir_religado(fc, projeto):
    """Abre o projeto.fcproj no FilmCraft (MCP); se a pasta do episódio mudou de lugar, religa a mídia pela
    pasta do projeto e salva. Mantém a assinatura se o arquivo ainda era o gerado pela esteira."""
    fcproj, assinatura = projeto.caminho("projeto.fcproj"), projeto.caminho("log/fcproj.sha1")
    if not fcproj.exists():
        raise SystemExit("sem projeto.fcproj: rode `./dark assemble` antes")
    da_esteira = assinatura.exists() and assinatura.read_text() == _hash(fcproj)
    faltando = fc.run("file.open", path=str(fcproj)).get("missingMedia", 0)
    if faltando:
        fc.run("media.autoRelink", folder=str(projeto.pasta))
        fc.run("file.saveAs", path=str(fcproj))
        if da_esteira:
            _assinar(projeto)
        print(f"  {faltando} mídias religadas a partir de {projeto.pasta}")


def exportar_manual(projeto):
    """Reexporta final.mp4 a partir do projeto.fcproj como está (depois de editar à mão no FilmCraft)."""
    fc = FilmCraft()
    try:
        _abrir_religado(fc, projeto)
        _exportar(fc, projeto, projeto.carregar_json("plano.json")["duracao"])
    finally:
        fc.fechar()


def abrir(projeto):
    """Abre o projeto.fcproj na interface do FilmCraft, desacoplado do terminal."""
    fc = FilmCraft()
    try:
        _abrir_religado(fc, projeto)
    finally:
        fc.fechar()
    fcproj = projeto.caminho("projeto.fcproj")
    open_program("filmcraft", str(fcproj))
    print(f"  FilmCraft aberto: {fcproj}\n  depois de editar e salvar: ./dark export {projeto.ep}")
