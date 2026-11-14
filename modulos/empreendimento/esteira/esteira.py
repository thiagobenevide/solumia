#!/usr/bin/env python3
"""Esteira de vídeos dark: narração + roteiro → cenas → mídia → edição no FilmCraft → thumbnail.

Uso:
  ./dark tudo  <projeto>          roda todas as etapas em sequência
  ./dark transcrever <projeto>    1. narração → transcricao.json (palavras com tempo)
  ./dark limpar <projeto>         1b. corta retakes e falas fora do roteiro → narracao.wav + cortes.txt
  ./dark partes <projeto>         roteiro em partes numeradas para gravar com "Corte/Cancela parte N"
  ./dark cenas <projeto>          2. roteiro + transcrição → plano.json (cenas e termos de busca)
  ./dark curar <projeto> [--refazer]   2b. LLM local: termo de busca, tipo de mídia e clima de cada cena
  ./dark avaliar <projeto>        3a. visão local dá nota à mídia de cada cena e troca a que não combina
  ./dark graficos <projeto> [--so-render]   3b. gráficos animados (citações, números, capítulos) → graficos/
  ./dark buscar <projeto> [--refazer] [--cenas 3,5]
                                  3. baixa imagens/vídeos de cada cena para midia/
  ./dark revisar <projeto> [--cenas 3,5]   folhas revisao_NN.jpg (16 cenas cada) para conferir a mídia
  ./dark resumo <projeto> [--cenas 3,5] [--sem-texto]   plano em uma linha por cena
  ./dark palavras <projeto> [--de S] [--ate S]   tempo de cada palavra falada
  ./dark ajustar <projeto> [arquivo.jsonl]   aplica edições parciais ao plano (JSON Lines, ou stdin)
  ./dark quadros <projeto> [--n 8]   folha quadros.jpg com quadros do final.mp4
  ./dark montar <projeto>         4. monta a timeline no FilmCraft → projeto.fcproj + final.mp4
  ./dark abrir <projeto>          abre o projeto.fcproj no FilmCraft (edição manual)
  ./dark exportar <projeto>       reexporta final.mp4 do projeto.fcproj editado à mão
  ./dark thumb <projeto>          5. thumbnails (conceitos → RealVisXL → 3 variantes para teste A/B)
  ./dark roteiros [canal] [--status S]   roteiros do vault Obsidian
  ./dark importar <canal:NNN[letra] | arquivo.md> [--audio X.wav]   cria o projeto (roteiro, fontes, áudio);
                                  canal:5a = Short 005a (9:16), canal:5 = vídeo longo 005 (16:9)
  ./dark roteiro <canal:N> [--ate M]   escreve roteiros do plano no vault (LLM local, fontes abertas, sem Claude)
  ./dark acervo [stats|buscar termos|importar|descrever]   mídia guardada e reaproveitada entre vídeos
  ./dark painel [--porta 8765]    painel web (selecionar roteiros, acompanhar, revisar cortes e cenas)
  ./dark status [<projeto>]       etapas: feitas, rodando (com previsão), com erro
  ./dark log <projeto> [--etapa montar] [--erros] [--debug]   últimos eventos

<projeto> é o episódio "canal-NNN" (pasta projetos/<canal>/<NNN>/, criada por `importar`) ou um caminho.
"""

import argparse
import sys
from pathlib import Path

from esteira.nucleo import eventos
from esteira.projeto import RAIZ, Projeto, episodios, pasta_ep


def resolver(nome):
    p = Path(nome)
    return Projeto(p if p.exists() and "/" in nome else pasta_ep(nome))


def etapa(nome):
    def rodar(a):
        p = resolver(a.projeto)
        print(f"▶ {nome}: {p.ep}")
        with eventos.etapa(p, nome):
            _rodar(nome, p, a)
    return rodar


def _rodar(nome, p, a):
    if nome == "transcrever":
        from esteira.transcrever import transcrever
        transcrever(p, p.cfg)
    elif nome == "limpar":
        from esteira.cortes import aplicar
        aplicar(p, refazer=a.refazer)
    elif nome == "cenas":
        from esteira.cenas import gerar_cenas
        gerar_cenas(p)
    elif nome == "buscar":
        from esteira.midia import buscar
        cenas = [int(x) for x in a.cenas.split(",")] if a.cenas else None
        buscar(p, refazer=a.refazer, cenas=cenas)
    elif nome == "revisar":
        from esteira.midia import revisar
        revisar(p, cenas=[int(x) for x in a.cenas.split(",")] if a.cenas else None)
    elif nome == "quadros":
        from esteira.midia import quadros
        quadros(p, a.n)
    elif nome == "curar":
        from esteira.curadoria import curar
        curar(p, refazer=a.refazer)
    elif nome == "avaliar":
        from esteira.avaliar import avaliar
        avaliar(p)
    elif nome == "graficos":
        from esteira.graficos import plano
        if not a.so_render:
            from esteira.graficos import chaves
            chaves.planejar(p, plano.planejar(p), refazer=True)  # palavras-chave animadas nos vãos dos gráficos
        plano.renderizar(p)
    elif nome == "montar":
        from esteira.montar import montar
        montar(p, exportar=not a.sem_exportar)
    elif nome == "estudio":  # só pelo `tudo`: a ordem de produzir tudo vale pelos portões do corte e do apontamento
        from esteira import estudio
        from esteira.descricao import gerar as gerar_descricao
        from esteira.estudio import corte
        corte.analisar(p)
        if n := corte.estado(p).get("cortadas"):
            raise SystemExit(f"corte pelo som cortou {n} palavra(s): reverta as emendas em volta delas "
                             "(aba Estúdio → Corte) e produza pelo Estúdio")
        estudio.produzir(a.projeto, sem_portao=True)
        print(f"  descrição com os links das fontes: {gerar_descricao(p).name}")
    elif nome == "thumb":
        from esteira.thumbs import thumbs
        thumbs(p)
    elif nome == "exportar":
        from esteira.montar import exportar_manual
        exportar_manual(p)


def cmd_compacto(a):
    # Sem a linha "▶ etapa": a saída é lida pelo Claude, cada linha custa tokens.
    from esteira import resumo as r
    p = resolver(a.projeto)
    if a.cmd == "resumo":
        r.resumo(p, a.cenas, a.sem_texto)
    elif a.cmd == "palavras":
        r.palavras(p, a.de, a.ate)
    else:
        r.ajustar(p, a.arquivo)


def cmd_partes(a):
    from esteira import claquete
    p = resolver(a.projeto)
    if not p.roteiro():
        raise SystemExit("o projeto não tem roteiro.txt")
    partes = claquete.do_projeto(p)
    destino = p.caminho("partes.txt")
    destino.write_text(claquete.texto_para_leitura(partes))
    print(f"{len(partes)} partes → {destino}")


def cmd_tudo(a):
    do_zero = getattr(a, "refazer", False)
    a.sem_exportar, a.cenas, a.so_render = False, None, False
    from esteira import estudio
    # canal com estilo no Estúdio: a edição sai do acervo de peças (direção por bloco pelas falas), não do FilmCraft
    finais = ("estudio", "thumb") if estudio.estilo_padrao(resolver(a.projeto)) else ("graficos", "montar", "thumb")
    for nome in ("limpar", "cenas", "curar", "buscar", "avaliar", *finais):
        # do zero: cortes e curadoria são decididos de novo; a busca não troca mídia boa de cena que não mudou
        a.refazer = do_zero and nome in ("limpar", "curar")
        try:
            etapa(nome)(a)
        except Exception as e:
            _diagnosticar(resolver(a.projeto), nome, e)
            raise


def _diagnosticar(p, nome, erro):
    """Erro numa etapa do `tudo`: o Claude lê o traceback + o fim do log e registra causa e ação sugerida."""
    import traceback
    from pydantic import BaseModel
    from esteira.ia import claude
    from esteira.nucleo import status

    class Diagnostico(BaseModel):
        causa: str
        acao: str

    log = "\n".join(f"{e['etapa']} {e['tipo']} {e['msg'][:160]}" for e in status.eventos(p.pasta)[-25:])
    d = claude.consultar(f"A etapa '{nome}' da esteira de vídeo falhou.\n\nTraceback:\n"
                         f"{traceback.format_exc(limit=8)[-2500:]}\n\nÚltimos eventos:\n{log}\n\n"
                         "Diga a causa provável (1 frase) e a ação concreta para o operador (1-2 frases).",
                         Diagnostico, p.cfg, p.ep, f"diagnóstico: erro em {nome}")
    if d:  # só o aviso: a etapa continua marcada como erro no status
        print(f"  ! diagnóstico: {d.causa} → {d.acao}")
        eventos.Etapa(p, nome).gravar("aviso", f"diagnóstico: {d.causa} → {d.acao}")


def cmd_status(a):
    from esteira.nucleo import status
    if a.projeto:
        status.imprimir_status(resolver(a.projeto).pasta)
        return
    for pasta in episodios():
        if (pasta / "log" / "eventos.jsonl").exists():
            status.imprimir_status(pasta)


def cmd_log(a):
    from esteira.nucleo import status
    status.imprimir_log(resolver(a.projeto).pasta, a.etapa, a.n, a.erros, a.debug)


def _cfg_fontes():
    import tomllib
    return tomllib.loads((RAIZ / "config.toml").read_text())["fontes"]


def cmd_roteiros(a):
    from esteira.fontes import obsidian
    for r in obsidian.listar(_cfg_fontes()["vault"], a.canal):
        if not a.status or r["status"] == a.status:
            print(f"{r['canal']:15} {str(r['numero'] or '-') + r['short']:>5} {r['formato']:5} {r['status']:10} {r['titulo'][:66]}")


def cmd_importar(a):
    from esteira.fontes import obsidian
    from esteira.fontes.importar import importar
    md = Path(a.roteiro)
    if not md.exists():  # "finlumia:3" → roteiro de número 3 do canal
        canal, _, num = a.roteiro.partition(":")
        achados = [r for r in obsidian.listar(_cfg_fontes()["vault"], canal)
                   if f"{r['numero']}{r['short']}" == num.lstrip("0")]
        if len(achados) != 1:
            raise SystemExit(f"roteiro não encontrado: {a.roteiro} (use canal:numero ou o caminho do .md)")
        md = Path(achados[0]["caminho"])
    importar(md, a.audio, a.nome, a.camera, a.modo)


def cmd_acervo(a):
    from esteira import acervo
    if a.acao == "importar":
        print(f"  {acervo.importar_projetos()} mídias dos episódios registradas no acervo")
    elif a.acao == "descrever":
        print(f"  {acervo.descrever(a.n)} itens descritos pelo modelo de visão local")
    elif a.acao == "buscar":
        for r in acervo.listar(" ".join(a.termos), limite=a.n):
            print(f"{r['id']:28} {r['tipo']:6} {r['orientacao']:8} {len(r['usos'])} usos  {', '.join(r['termos'])[:60]}")
    else:
        e = acervo.estatisticas()
        print(f"  acervo {acervo.pasta()}: {e['itens']} itens ({e['videos']} vídeos, {e['imagens']} imagens), "
              f"{e['gb']} GB; {e['descritos']} descritos; {e['usos']} usos ({e['reusados']} mídias usadas)")
        for k, v in sorted(e["por_provedor"].items()):
            print(f"    {k:20} {v}")


def cmd_bancada(a):
    from esteira import bancada
    if a.acao == "gerar":
        print(f"  gabarito: {bancada.gerar()}")
        return
    if a.acao == "rodar":
        from esteira.ia import llama
        todos = [m["id"] for m in llama.modelos() or []]
        bancada.rodar(a.modelos.split(",") if a.modelos else todos, a.tarefas.split(",") if a.tarefas else None, a.n,
                      progresso=lambda m: print(f"  {m}", flush=True))
    print("\n".join(bancada.tabela()))


def cmd_estudio(a):
    from esteira import estudio
    formatos = a.formatos.split(",") if a.formatos else None
    etapas = a.etapas.split(",") if a.etapas else estudio.ETAPAS
    intensidade = dict(x.split("=", 1) for x in a.intensidade.split(",")) if a.intensidade else None
    estudio.produzir(a.projeto, a.estilo, formatos, etapas, a.sem_portao, intensidade)


def cmd_estudio_corte(a):
    from esteira.estudio import corte
    from esteira.projeto import Projeto, pasta_ep
    corte.analisar(Projeto(pasta_ep(a.projeto)))


def cmd_estudio_instalar(a):
    from esteira.estudio import motor
    print(f"  {motor.instalar(lambda m: print(f'  {m}', flush=True))}")


def cmd_estudio_estilo(a):
    from esteira.estudio import identidade
    e = identidade.propor(a.alvo, a.nicho or "")
    print(f"  estilo {e.id} v{e.versao}: {e.pele.destaque} · {len(e.exemplos)} exemplos")


def cmd_estudio_fabrica(a):
    from esteira.estudio import fabrica
    pid = a.alvo.removeprefix("fabrica:")
    p = fabrica.rodar(pid, visual=not a.sem_visao)
    print(f"  fábrica {pid}: {p.situacao} · {len(p.pecas)} peça(s) · {p.descartadas} descartada(s) · US$ {p.gasto_usd:.2f}")


def cmd_estudio_peca_previa(a):
    from esteira.estudio import peca
    print(f"  prévia: {peca.previa(a.alvo.split(':')[1] if ':' in a.alvo else a.alvo, a.estilo, a.formato)}")


def cmd_estudio_prova_canais(a):
    from esteira.estudio import peca
    r = peca.prova_canais(a.estilos)
    print(f"  prova de pele: {len(r['pecas'])} peça(s) × {len(a.estilos)} estilo(s) · {len(r['problemas'])} problema(s)")
    for x in r["problemas"]:
        print(f"    {x['peca']} · {x['estilo']} · {x['formato']}: {x['erro']}")


def cmd_estudio_bloco(a):
    from esteira import estudio
    estudio.renderizar_bloco(a.ep, a.bloco, a.formatos or None)


def cmd_treino(a):
    from esteira.estudio import treino
    if a.acao == "exportar":
        r = treino.exportar()
        print(f"  base de treino em {r['pasta']}: " + ", ".join(f"{t} {x['treino']}+{x['validacao']}"
                                                            for t, x in r["tarefas"].items()))
    else:
        print(f"  modelo treinado: {treino.treinar(a.base, a.epocas)} (escolha em Opções)")


def cmd_dataset(a):
    from esteira.dataset import indice
    if a.acao == "reindexar":
        print(f"  {indice.reindexar()} registros no índice")
        return
    if a.acao == "exportar":
        from esteira.dataset import exportar
        r = exportar.exportar(a.tarefas.split(",") if a.tarefas else None)
        print(f"  exportação em {r['pasta']}: " + ", ".join(f"{t} {x['sft']}+{x['val']} sft, {x['dpo']} dpo, {x['eval']} eval"
                                                       for t, x in r["tarefas"].items()))
        return
    if a.acao == "traduzir":
        from esteira.dataset import traduzir
        for linha in traduzir.tudo():
            print(f"  {linha}")
        return
    if a.acao == "edicoes":
        from esteira.dataset import edicoes
        for linha in edicoes.varrer():
            print(f"  {linha}")
        return
    if a.acao == "treinar":
        from esteira.dataset import treino_app
        m = treino_app.treinar(a.app, a.base, a.epocas, forcar=a.forcar)
        print(f"  adaptador {m['nome']} ({m['casos_treino']} casos, perda {m['perda']}); promover: "
              f"./dark dataset promover --app {a.app} --nome {m['nome']}")
        return
    if a.acao == "promover":
        from esteira.dataset import treino_app
        r = treino_app.promover(a.app, a.nome, a.n)
        print(f"  {r['nome']}: {'PROMOVIDO' if r['promovido'] else 'não promovido'} · notas {r['notas']}")
        return
    for t, x in indice.situacao().items():
        print(f"  {t:18} {x['total']:5} registros · sft {x.get('sft', 0):4}/{x['minimo']:<5} · dpo {x.get('dpo_ruim', 0):4}"
              f" · pendentes {x.get('pendente', 0):4}{'  PRONTA' if x['pronta'] else ''}")


def cmd_estudio_amostra(a):
    from esteira.estudio import amostra
    amostra.gerar(a.alvo)


def cmd_roteiro(a):
    from esteira.roteirista import gerar
    gerar(a.alvo, a.ate)


def cmd_painel(a):
    import uvicorn
    print(f"painel em http://localhost:{a.porta}  (Ctrl+C para sair)")
    uvicorn.run("esteira.web.app:app", host=a.host, port=a.porta, log_level="warning")


LEVES = {"partes", "status", "log", "resumo", "palavras", "roteiros", "painel", "ajustar", "importar", "abrir"}  # sem vaga


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    for nome in ("transcrever", "limpar", "cenas", "curar", "buscar", "avaliar", "revisar", "graficos", "quadros", "montar", "thumb",
                 "exportar"):
        s = sub.add_parser(nome)
        s.add_argument("projeto")
        if nome in ("buscar", "revisar"):
            s.add_argument("--cenas", help="só estas cenas, ex.: 3,5,8")
        if nome == "quadros":
            s.add_argument("--n", type=int, default=8, help="quantos quadros")
        if nome == "buscar":
            s.add_argument("--refazer", action="store_true", help="troca a mídia por outro resultado")
        if nome == "curar":
            s.add_argument("--refazer", action="store_true", help="cura de novo também as cenas já curadas")
            s.add_argument("--motor", choices=["local", "claude"],
                           help="claude: não usa a GPU e roda junto com outro processo (conta no teto de [claude])")
        if nome == "limpar":
            s.add_argument("--refazer", action="store_true", help="decide os cortes de novo (ignora cortes.json)")
        if nome == "graficos":
            s.add_argument("--so-render", action="store_true", help="não replaneja; só renderiza graficos.json")
        if nome == "montar":
            s.add_argument("--sem-exportar", action="store_true", help="só salva o projeto .fcproj")
        s.set_defaults(f=etapa(nome))

    s = sub.add_parser("abrir", help="abre o projeto.fcproj no FilmCraft para editar à mão")
    s.add_argument("projeto")
    s.set_defaults(f=lambda a: __import__("esteira.montar", fromlist=["abrir"]).abrir(resolver(a.projeto)))

    s = sub.add_parser("partes", help="roteiro em partes numeradas para gravar com \"Corte parte N\"")
    s.add_argument("projeto")
    s.set_defaults(f=cmd_partes)

    s = sub.add_parser("resumo", help="plano em uma linha por cena")
    s.add_argument("projeto")
    s.add_argument("--cenas", help="só estas cenas, ex.: 3,5,8")
    s.add_argument("--sem-texto", action="store_true", help="omite o texto falado")
    s.set_defaults(f=cmd_compacto)

    s = sub.add_parser("palavras", help="tempo de cada palavra falada")
    s.add_argument("projeto")
    s.add_argument("--de", type=float, default=0.0)
    s.add_argument("--ate", type=float)
    s.set_defaults(f=cmd_compacto)

    s = sub.add_parser("ajustar", help="aplica edições parciais (JSON Lines) ao plano.json")
    s.add_argument("projeto")
    s.add_argument("arquivo", nargs="?", help="arquivo .jsonl (padrão: stdin)")
    s.set_defaults(f=cmd_compacto)

    s = sub.add_parser("roteiros", help="roteiros do vault Obsidian")
    s.add_argument("canal", nargs="?")
    s.add_argument("--status", help="ex.: rascunho, gravado")
    s.set_defaults(f=cmd_roteiros)

    s = sub.add_parser("roteiro", help="escreve roteiro(s) do plano no vault com LLM local e fontes abertas")
    s.add_argument("alvo", help="canal:N (ex.: finlumia:41)")
    s.add_argument("--ate", type=int, help="até o vídeo M (lote)")
    s.add_argument("--motor", choices=["local", "claude"],
                   help="claude: escreve com o Claude (não usa a GPU; roda junto com outro processo; conta no teto)")
    s.set_defaults(f=cmd_roteiro)

    s = sub.add_parser("acervo", help="mídia baixada e reaproveitável (estatísticas, busca, importar, descrever)")
    s.add_argument("acao", nargs="?", default="stats", choices=["stats", "buscar", "importar", "descrever"])
    s.add_argument("termos", nargs="*")
    s.add_argument("--n", type=int, default=20)
    s.set_defaults(f=cmd_acervo)

    s = sub.add_parser("estudio", help="produz o vídeo do episódio no Estúdio (estilo → mapa → render → portão final)")
    s.add_argument("projeto")
    s.add_argument("--estilo", help="id do estilo (padrão: o do canal no modo do episódio)")
    s.add_argument("--formatos", help="16:9,9:16 (padrão: os do estilo)")
    s.add_argument("--etapas", help="dirigir,compilar,render,audio,verificar (padrão: todas)")
    s.add_argument("--sem-portao", action="store_true", help="não exige o corte aprovado (teste)")
    s.add_argument("--intensidade", help="só nesta produção: sfx=alta,motion=baixa,efeitos=media")
    s.set_defaults(f=cmd_estudio)

    s = sub.add_parser("estudio-corte", help="corte pelo som da narração editada (vícios, respirações, pausas) → portão 1")
    s.add_argument("projeto")
    s.set_defaults(f=cmd_estudio_corte)

    s = sub.add_parser("estudio-instalar", help="instala Node, HyperFrames e Chromium do motor de render")
    s.add_argument("alvo", nargs="?", default="motor")
    s.set_defaults(f=cmd_estudio_instalar)

    s = sub.add_parser("estudio-estilo", help="Fluxo A: o Claude propõe a identidade do estilo pelas referências")
    s.add_argument("alvo", help="id do estilo")
    s.add_argument("--nicho")
    s.add_argument("--motor", choices=["claude"], default="claude")
    s.set_defaults(f=cmd_estudio_estilo)

    s = sub.add_parser("estudio-fabrica", help="fábrica de peças: o Claude gera peças do pedido, o portão confere")
    s.add_argument("alvo", help="fabrica:<id do pedido>")
    s.add_argument("--sem-visao", action="store_true", help="pula a checagem visual local dos quadros da prova")
    s.add_argument("--motor", choices=["claude"], default="claude")
    s.set_defaults(f=cmd_estudio_fabrica)

    s = sub.add_parser("estudio-peca-previa", help="MP4 curto de uma peça do acervo na pele de um estilo")
    s.add_argument("alvo", help="peca:<id>")
    s.add_argument("--estilo", required=True)
    s.add_argument("--formato", choices=["16:9", "9:16"])
    s.set_defaults(f=cmd_estudio_peca_previa)

    s = sub.add_parser("estudio-prova-canais", help="todas as peças aprovadas na pele de cada estilo (troca de pele)")
    s.add_argument("alvo", nargs="?", default="acervo")
    s.add_argument("--estilos", nargs="+", required=True)
    s.set_defaults(f=cmd_estudio_prova_canais)

    s = sub.add_parser("estudio-bloco", help="render só do bloco alterado: trecho → emenda no bruto → loudness e prévia")
    s.add_argument("ep")
    s.add_argument("--bloco", type=int, required=True)
    s.add_argument("--formatos", nargs="*", choices=["16:9", "9:16"])
    s.set_defaults(f=cmd_estudio_bloco)

    s = sub.add_parser("treino", help="base de aprovações → conversas de treino; treina o LoRA do modelo local (GPU)")
    s.add_argument("alvo", help="rótulo da fila (ex.: treino:lora); ignorado")
    s.add_argument("acao", choices=["exportar", "treinar"])
    s.add_argument("--base", default="unsloth/gemma-4-12b-it")
    s.add_argument("--epocas", type=float, default=2.0)
    s.set_defaults(f=cmd_treino)

    s = sub.add_parser("dataset", help="dataset das Craft Apps: situação, reindexar, exportar, traduzir, edicoes")
    s.add_argument("acao", nargs="?", default="situacao",
                   choices=["situacao", "reindexar", "exportar", "traduzir", "edicoes", "treinar", "promover"])
    s.add_argument("--tarefas", help="tarefas separadas por vírgula (exportar)")
    s.add_argument("--app", choices=["effectcraft", "filmcraft", "photocraft"])
    s.add_argument("--base", default="unsloth/gemma-4-12b-it")
    s.add_argument("--epocas", type=float, default=2.0)
    s.add_argument("--forcar", action="store_true", help="treina abaixo do mínimo (teste de fumaça)")
    s.add_argument("--nome", help="adaptador a promover (ex.: fc-v1)")
    s.add_argument("--n", type=int, help="casos do ouro na bancada da promoção")
    s.set_defaults(f=cmd_dataset)
    s = sub.add_parser("estudio-amostra", help="exemplo de 30 s do template nos formatos dele (vertical e horizontal)")
    s.add_argument("alvo", help="id do estilo ou id@versão")
    s.set_defaults(f=cmd_estudio_amostra)

    s = sub.add_parser("bancada", help="mede os modelos locais nas tarefas do Estúdio (gabarito em bancada/)")
    s.add_argument("acao", nargs="?", default="ver", choices=["ver", "gerar", "rodar"])
    s.add_argument("--modelos", help="ids do roteador separados por vírgula (padrão: todos)")
    s.add_argument("--tarefas", help="intencao,cena,legenda,corte,visao (padrão: todas)")
    s.add_argument("--n", type=int, help="só os N primeiros casos de cada tarefa")
    s.set_defaults(f=cmd_bancada)

    s = sub.add_parser("importar", help="cria o projeto a partir de um roteiro do vault")
    s.add_argument("roteiro", help="canal:numero (ex.: finlumia:3) ou caminho do .md")
    s.add_argument("--audio", help="WAV da narração (padrão: o mais provável em ~/Music/Youtube)")
    s.add_argument("--nome", help="nome da pasta do projeto (padrão: canal-NNN)")
    s.add_argument("--camera", help="vídeo da câmera (modo apresentador; padrão: o mais provável junto do WAV)")
    s.add_argument("--modo", choices=["dark", "apresentador"], help="padrão: `modo:` do roteiro ou do perfil")
    s.set_defaults(f=cmd_importar)

    s = sub.add_parser("status", help="estado de cada etapa (todos os projetos se omitido)")
    s.add_argument("projeto", nargs="?")
    s.set_defaults(f=cmd_status)

    s = sub.add_parser("log", help="últimos eventos de um projeto")
    s.add_argument("projeto")
    s.add_argument("--etapa")
    s.add_argument("--n", type=int, default=20)
    s.add_argument("--erros", action="store_true", help="só erros e avisos")
    s.add_argument("--debug", action="store_true", help="inclui chamadas ao FilmCraft e progresso")
    s.set_defaults(f=cmd_log)

    s = sub.add_parser("painel", help="painel web: biblioteca, produção ao vivo, cortes, cenas, custos")
    s.add_argument("--porta", type=int, default=8765)
    s.add_argument("--host", default="127.0.0.1")
    s.set_defaults(f=cmd_painel)

    s = sub.add_parser("tudo")
    s.add_argument("projeto")
    s.add_argument("--refazer", action="store_true",
                   help="do zero: retranscreve e decide os cortes de novo, refaz a curadoria e todas as etapas")
    s.set_defaults(f=cmd_tudo)

    a = ap.parse_args()
    if a.cmd in LEVES or (a.cmd == "acervo" and a.acao in ("stats", "buscar")) or (a.cmd == "bancada" and a.acao != "rodar"):
        return a.f(a)
    # processo pesado: registra (Monitor → Processos) e espera a vaga da máquina (ou a do Claude)
    import os
    import signal
    from esteira.nucleo import processos, travas
    from esteira.nucleo import opcoes
    motor = getattr(a, "motor", None) or opcoes.ler()["motor"]
    os.environ["ESTEIRA_MOTOR"] = motor
    if getattr(a, "motor", None):
        os.environ["ESTEIRA_MOTOR_FIXO"] = "1"  # --motor explícito vale para todas as operações
    if getattr(a, "projeto", None) and pasta_ep(a.projeto).is_dir():
        os.environ["ESTEIRA_EP"] = a.projeto
    alvo = getattr(a, "projeto", None) or getattr(a, "alvo", None) or ""
    v = travas.vaga(a.cmd, motor)
    os.environ["ESTEIRA_VAGA"] = v
    pid_id = processos.registrar(a.cmd, alvo, sys.argv[2:], v, motor)

    def _cancelado(*_):  # Cancelar no painel manda SIGTERM: sai pelo caminho normal (registro, rastro, vaga)
        processos.cancelado()
        sys.exit(143)
    signal.signal(signal.SIGTERM, _cancelado)
    travas.ocupar(v, " ".join(sys.argv[1:])[:120], proc=pid_id)
    try:
        a.f(a)
    except BaseException as e:
        if not (isinstance(e, SystemExit) and e.code in (0, None)):
            processos.falhou(e)
        raise


if __name__ == "__main__":
    sys.exit(main())
