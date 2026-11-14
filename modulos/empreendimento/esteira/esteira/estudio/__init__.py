"""Estúdio: produção de vídeo por estilo (vídeo + estilo → corte aprovado → diretor → render → portão final).

Plano e decisões: `docs/PLANO-ESTUDIO.md`. Fluxo de uma produção (`./dark estudio <ep>`, ou o botão Produzir da aba
Estúdio): `corte.analisar` (corte pelo som da narração editada) → portão 1 (emendas revisadas e corte aprovado) →
apontamento no roteiro (`apontamento.py`: cena por trecho, confirmado pela pessoa) → `diretor.dirigir` (mapa.json, IA local) → por formato: `compilar` →
`render` (HyperFrames, GPU) → `audio` (−14 LUFS) → `verificar` (relatório; portão final).
Aprovações ficam em `<ep>/estudio/aprovacoes.json` e cada uma vira dado em `bancada/aprovacoes.jsonl`.
"""
import json
from datetime import datetime

from esteira.projeto import Projeto, pasta_ep

ETAPAS = ("dirigir", "compilar", "render", "audio", "verificar")
PORTOES = ("corte", "mapa", "final_16x9", "final_9x16")


def _aprov_arq(projeto):
    return projeto.pasta / "estudio" / "aprovacoes.json"


def aprovacoes(projeto):
    arq = _aprov_arq(projeto)
    return json.loads(arq.read_text()) if arq.exists() else {}


def aprovar(ep, portao, aprovado=True, nota=""):
    """Grava a decisão do portão e a guarda na base de aprovações (gabarito futuro / fine-tune)."""
    from esteira.bancada import PASTA
    if portao not in PORTOES:
        raise ValueError(f"portão inválido: {portao}")
    projeto = Projeto(pasta_ep(ep))
    if portao == "corte" and aprovado:
        from esteira.estudio import corte
        e = corte.estado(projeto)
        if not e["feito"] or not e["atualizado"]:
            raise ValueError("faça (ou refaça) o corte pelo som antes de aprovar: aba Estúdio → Corte → Cortar pelo som")
        if e.get("cortadas"):
            raise ValueError(f"{e['cortadas']} palavra(s) cortada(s) no corte pelo som: reverta as emendas em volta "
                             "delas (aba Estúdio → Corte) antes de aprovar")
    if portao == "mapa" and aprovado:  # direção por bloco: as escolhas aprovadas ensinam a bancada
        arq = projeto.pasta / "estudio" / "mapa.json"
        if arq.exists() and (m := json.loads(arq.read_text())).get("direcao") == "blocos":
            from esteira.estudio import direcao
            direcao.aprovar_mapa(ep, m)
    d = aprovacoes(projeto)
    reg = {"aprovado": aprovado, "nota": nota, "em": datetime.now().isoformat(timespec="seconds")}
    d[portao] = reg
    _aprov_arq(projeto).parent.mkdir(exist_ok=True)
    _aprov_arq(projeto).write_text(json.dumps(d, ensure_ascii=False, indent=1))
    PASTA.mkdir(parents=True, exist_ok=True)
    with open(PASTA / "aprovacoes.jsonl", "a") as f:
        f.write(json.dumps({"ep": ep, "portao": portao, **reg}, ensure_ascii=False) + "\n")
    return d


def template(projeto):
    """Template (`id@N`) escolhido para o episódio na aba Roteiros, ou None."""
    arq = projeto.pasta / "estudio" / "template.json"
    return json.loads(arq.read_text()).get("estilo") if arq.exists() else None


def escolher_template(projeto, ref):
    arq = projeto.pasta / "estudio" / "template.json"
    arq.parent.mkdir(parents=True, exist_ok=True)
    arq.write_text(json.dumps({"estilo": ref}))


def estilo_padrao(projeto):
    from esteira.estudio import estilo
    if ref := template(projeto):
        try:
            return estilo.carregar(ref)
        except KeyError:
            pass
    modo = projeto.cfg.get("producao", {}).get("modo", "dark")
    candidatos = estilo.listar(projeto.canal)
    return next((e for e in candidatos if e.modo == modo), candidatos[0] if candidatos else None)


def situacao(ep):
    """O que já existe da produção (para o app): mapa, e por formato compilado/render/final/relatório."""
    projeto = Projeto(pasta_ep(ep))
    base = projeto.pasta / "estudio"
    mapa = base / "mapa.json"
    from esteira.estudio import corte
    from esteira.estudio import apontamento
    ap = apontamento.carregar(projeto)
    from esteira.estudio import ritmo
    r = {"ep": ep, "canal": projeto.canal, "aprovacoes": aprovacoes(projeto), "mapa": None, "formatos": {},
         "ritmo": ritmo.id_do(projeto), "modo": projeto.cfg.get("producao", {}).get("modo", "dark"),
         "corte": corte.estado(projeto), "camera": None, "template": template(projeto),
         "apontamento": {"confirmado": ap.get("confirmado", False), "marcas": len(ap.get("marcas", {}))}}
    from esteira import producao
    if producao.camera(projeto):
        r["camera"] = producao.info_camera(projeto)
    if mapa.exists():
        m = json.loads(mapa.read_text())
        r["mapa"] = {"cenas": len(m["cenas"]), "estilo": m["estilo"], "versao": m["versao"], "decisoes": m.get("decisoes"),
                     "ritmo": m.get("ritmo")}
    for fmt in ("16x9", "9x16"):
        p = base / fmt
        if not p.exists():
            continue
        rel = p / "relatorio.json"
        r["formatos"][fmt] = {"compilado": (p / "index.html").exists(), "render": (p / "render" / "bruto.mp4").exists(),
                              "final": (p / "final.mp4").exists(), "previa": (p / "previa.mp4").exists(), "folha": (p / "folha.jpg").exists(),
                              "relatorio": json.loads(rel.read_text()) if rel.exists() else None}
    return r


def estilo_do_mapa(projeto, mapa):
    """O estilo com que o mapa foi dirigido (versão guardada), no modo e no ritmo do vídeo."""
    from esteira import producao
    from esteira.estudio import estilo, ritmo
    try:
        base = estilo.carregar(f"{mapa['estilo']}@{mapa['versao']}")
    except KeyError:  # versão antiga não guardada: a atual, avisando
        from esteira.nucleo import eventos
        eventos.aviso(f"estilo {mapa['estilo']} v{mapa['versao']} não está guardado; usando a versão atual")
        base = estilo.carregar(mapa["estilo"])
    est = estilo.com_modo(base, producao.modo(projeto))
    return ritmo.aplicar(est, ritmo.perfil_do(projeto))


def janela_do_bloco(mapa, bloco):
    """[de, ate] do bloco no vídeo (direção por bloco), com uma folga que cai na pausa entre blocos."""
    bls = mapa.get("blocos") or []
    b = next((x for x in bls if x["i"] == bloco), None)
    if b is None:
        raise ValueError(f"bloco inexistente: {bloco}")
    seguinte = next((x for x in bls if x["i"] == bloco + 1), None)
    anterior = next((x for x in bls if x["i"] == bloco - 1), None)
    de = max(0.0, (anterior["fim"] + b["ini"]) / 2 if anterior else 0.0)
    ate = min(mapa["duracao"], (b["fim"] + seguinte["ini"]) / 2 if seguinte else mapa["duracao"])
    return round(de, 3), round(ate, 3)


def renderizar_bloco(ep, bloco, formatos=None):
    """Render só do bloco alterado: trecho [de, ate] → emenda no bruto → loudness e prévia de novo."""
    from esteira.estudio import compilar
    from esteira.ia import local
    projeto = Projeto(pasta_ep(ep))
    mapa = json.loads((projeto.pasta / "estudio" / "mapa.json").read_text())
    est = estilo_do_mapa(projeto, mapa)
    de, ate = janela_do_bloco(mapa, bloco)
    feitos = []
    for fmt in formatos or [f.replace("x", ":") for f in ("16x9", "9x16") if (compilar.pasta(projeto, f.replace("x", ":")) / "render" / "bruto.mp4").exists()]:
        local.liberar_gpu()
        trecho = compilar.render_trecho(projeto, est, fmt, de, ate, f"bloco{bloco:03d}")
        compilar.emendar(projeto, fmt, de, ate, trecho)
        compilar.audio(projeto, est, fmt)
        feitos.append(fmt)
        print(f"  bloco {bloco} ({de:.1f}–{ate:.1f} s) refeito em {fmt}")
    if not feitos:
        raise SystemExit("nenhum formato com render completo para emendar")
    return feitos


def produzir(ep, estilo_id=None, formatos=None, etapas=ETAPAS, sem_portao=False, intensidade=None):
    """`intensidade` ({"sfx"|"motion"|"efeitos": "baixa"|"media"|"alta"}) vale só para esta produção."""
    from esteira.estudio import compilar, diretor, estilo, motor
    from esteira.ia import local
    from esteira.nucleo import eventos
    projeto = Projeto(pasta_ep(ep))
    est = estilo.carregar(estilo_id) if estilo_id else estilo_padrao(projeto)
    if not est:
        raise SystemExit(f"nenhum estilo para o canal {projeto.canal}: crie um na aba Estúdio")
    est = estilo.com_niveis(est, intensidade)
    from esteira import producao
    est = estilo.com_modo(est, producao.modo(projeto))  # o modo é do vídeo (roteiro), não da configuração do canal
    from esteira.estudio import ritmo
    perfil = ritmo.perfil_do(projeto)  # longo ou curto: o ritmo também é do vídeo
    est = ritmo.aplicar(est, perfil)
    formatos = formatos or est.formatos
    if not sem_portao and not aprovacoes(projeto).get("corte", {}).get("aprovado"):
        raise SystemExit("portão 1: aprove o corte do áudio antes (aba Estúdio → Corte)")
    from esteira.estudio import apontamento
    if not sem_portao and "dirigir" in etapas and not apontamento.confirmado(projeto):
        raise SystemExit("apontamento: marque as cenas no roteiro e confirme (aba Estúdio → Apontamento)")
    if any(e in etapas for e in ("render", "audio")) and not motor.pronto():
        raise SystemExit("motor de render incompleto: instale as dependências (aba Estúdio → Dependências)")
    print(f"  estúdio: {ep} · estilo {est.id} v{est.versao} · {', '.join(formatos)} · níveis {est.regras.niveis} · "
          f"ritmo {perfil.id} · modo {est.modo}")
    if "dirigir" in etapas:
        from esteira.nucleo import opcoes
        with eventos.etapa(projeto, "estudio-dirigir"):
            if opcoes.ler().get("direcao", "blocos") == "blocos":  # direção por bloco com o acervo de peças
                from esteira.estudio import direcao
                direcao.dirigir(projeto, est, perfil, formatos)
            else:
                diretor.dirigir(projeto, est, perfil)
    for fmt in formatos:
        if "compilar" in etapas:
            with eventos.etapa(projeto, f"estudio-compilar-{fmt}"):
                compilar.compilar(projeto, est, fmt)
        if "render" in etapas:
            local.liberar_gpu()
            with eventos.etapa(projeto, f"estudio-render-{fmt}"):
                compilar.render(projeto, fmt)
        if "audio" in etapas:
            with eventos.etapa(projeto, f"estudio-audio-{fmt}"):
                compilar.audio(projeto, est, fmt)
        if "verificar" in etapas:
            with eventos.etapa(projeto, f"estudio-verificar-{fmt}"):
                compilar.verificar(projeto, est, fmt)
    return situacao(ep)
