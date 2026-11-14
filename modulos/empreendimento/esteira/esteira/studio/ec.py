"""Motor EffectCraft das peças do acervo (`docs/PLANO-ACERVO.md`, "Dois motores de geração").

Uma peça com `motor: effectcraft` é `peca.jsx` + `ficha.json`. O script final é `var DADOS = {...}` +
`pecas/_ec/nucleo.jsx` + `peca.jsx` + `pecas/_ec/fim.jsx`; o `effectcraft-cli script` monta o `.ecproj` (camadas com
nomes em português, editáveis à mão no EffectCraft) e a engine renderiza. Na produção a peça vira um WebM VP9 com
transparência que entra na composição do HyperFrames como vídeo (`compilar`); na prova, quadros PNG sobre a cor de
fundo da pele. Fontes: as da pele são copiadas do kit para `~/.local/share/fonts` (o EffectCraft lê as do sistema).
"""
import json
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from esteira.studio import fonts

PIECES = Path(__file__).parent / "pecas"
CORE = PIECES / "_ec" / "nucleo.jsx"
END = PIECES / "_ec" / "fim.jsx"
CLI = "effectcraft-cli"
SOURCES_USER = Path("~/.local/share/fonts").expanduser()
ROLES = {"fD": "fonte_destaque", "fT": "fonte_texto", "fM": "fonte_tecnica", "fE": "fonte_editorial", "fL": "fonte_legenda"}


def available():
    return shutil.which(CLI) is not None


def install_fonts(pele):
    """Copia os arquivos das fontes da pele (kit ou enviadas) para as fontes do usuário. → True se copiou alguma."""
    todas = {**fonts.CATALOG, **fonts._uploaded()}
    copiou = False
    SOURCES_USER.mkdir(parents=True, exist_ok=True)
    for papel in ROLES.values():
        for arquivo, *_ in todas.get(getattr(pele, papel), ([], ""))[0]:
            origem = fonts.path(arquivo)
            if origem and origem.suffix.lower() in (".ttf", ".otf") and not (SOURCES_USER / origem.name).exists():
                shutil.copy(origem, SOURCES_USER / origem.name)
                copiou = True
    return copiou


def data(ficha, encaixes, botoes, batidas, pele, formato, dur, t0=0.3, instantes=(), area=0.03, cauda=0.5):
    """DADOS do script. `cauda`: sobra depois da peça (prova/prévia); na produção 0 (a comp tem o tamanho da cena)."""
    from esteira.studio.piece import DIM
    W, H = DIM[formato]
    cores = {k: getattr(pele, k) for k in ("fundo", "fundo2", "texto", "destaque", "apoio", "acento")}
    return {"encaixes": encaixes, "botoes": botoes, "batidas": batidas, "t0": t0, "dur": round(t0 + dur + cauda, 3),
            "w": W, "h": H, "fps": 30, "pele": {**cores, **{k: fonts.resolve(getattr(pele, v)) for k, v in ROLES.items()}},
            "area": area, "instantes": list(instantes), "tela_cheia": ficha.tela_cheia}


def script(id_, d, rescan=False):
    """Texto do script completo da peça com os DADOS."""
    pre = f"var DADOS = {json.dumps(d, ensure_ascii=False)};\n"
    if rescan:
        pre += 'app.run("text.fonts", {rescan: true});\n'
    return pre + CORE.read_text() + "\n" + body(id_, d) + "\n" + END.read_text()


def body(id_, d):
    """Corpo da peça: o N1 compilado (`peca.n1.json`, preferido) ou o `peca.jsx` escrito à mão (peças antigas)."""
    n1 = PIECES / id_ / "peca.n1.json"
    if n1.exists():
        from esteira.n1 import effectcraft as N1
        try:
            return N1.build(json.loads(n1.read_text()), d)
        except (N1.ErrorN1, ValueError) as e:  # vira erro do portão (a rodada é reprovada), nunca derruba o processo
            raise RuntimeError(f"peca.n1.json não compila com estes dados: {str(e)[:300]}") from e
    return (PIECES / id_ / "peca.jsx").read_text()


def _run(cmd, timeout=300, rotulo=None):
    if rotulo:  # render com `--progress`: alimenta a barra do Monitor (mesmo leitor dos gráficos)
        from esteira.graphics.effectcraft import _run as com_progresso
        return com_progresso(cmd, rotulo, timeout)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if r.returncode:
        raise RuntimeError(f"EffectCraft: {(r.stderr or r.stdout).strip()[-400:]}")
    return r.stdout


def assemble(id_, d, ecproj, pele=None):
    """Monta o `.ecproj` da peça. → (estouros, saída). Erro de script vira RuntimeError com a mensagem da engine."""
    rescan = install_fonts(pele) if pele is not None else False
    with tempfile.TemporaryDirectory(prefix="ecp_") as tmp:
        arq = Path(tmp) / "peca.jsx"
        arq.write_text(script(id_, d, rescan))
        saida = _run([CLI, "script", str(arq), "--save-as", str(ecproj)])
    if "ok " not in saida:
        raise RuntimeError(f"a peça não terminou (falta o 'ok' do fim): {saida.strip()[-300:]}")
    return re.findall(r"^estouro (.+)$", saida, re.M), saida


def frame(ecproj, t, destino, fundo, escala=0.5):
    """Quadro da comp "Peça" no instante t sobre a cor de fundo da pele, em JPG (metade do tamanho)."""
    with tempfile.TemporaryDirectory(prefix="ecq_") as tmp:
        png = Path(tmp) / "q.png"
        _run([CLI, "render-frame", "--project", str(ecproj), "--comp", "Peça", "--time", f"{t:.3f}", "--out", str(png),
                "--transparent"])
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(png), "-f", "lavfi", "-i",
                        f"color=c={fundo.replace('#', '0x')}:s=16x16", "-filter_complex",
                        f"[1][0]scale2ref[f][q];[f][q]overlay,scale=iw*{escala}:-2", "-frames:v", "1", "-q:v", "4",
                        str(destino)], check=True)
    return Path(destino)


def render_webm(ecproj, destino):
    """WebM VP9 com alfa da comp "Peça" (o Chromium do HyperFrames toca com transparência)."""
    _run([CLI, "render", "--project", str(ecproj), "--comp", "Peça", "--out", str(destino), "--format", "webm",
            "--webm-codec", "vp9", "--channels", "rgba", "--quality", "best", "--progress"], timeout=900,
           rotulo=f"EffectCraft: {Path(destino).name}")
    return Path(destino)


def render_mp4(ecproj, destino):
    """MP4 da comp "Peça" (prévia da revisão: sem alfa, sobre o preto)."""
    _run([CLI, "render", "--project", str(ecproj), "--comp", "Peça", "--out", str(destino), "--format", "h264",
            "--quality", "draft", "--progress"], timeout=900, rotulo=f"EffectCraft: {Path(destino).name}")
    return Path(destino)


# ---------------------------------------------------------------- portão

RE_HEX = re.compile(r"#[0-9a-fA-F]{3,8}\b")
RE_RGB = re.compile(r"\[\s*(?:0|1|0?\.\d+)\s*,\s*(?:0|1|0?\.\d+)\s*,\s*(?:0|1|0?\.\d+)\s*\]")
RE_SOURCE = re.compile(r"\bfont\s*:\s*[\"']")
FORBIDDEN = re.compile(r"\b(?:Math\.random|Date\s*\(|new\s+Date|app\.project\.items\.addComp|writeLn)\b")


def check_code(id_, ficha):
    """Checagens estáticas do peca.jsx: existe, sintaxe (node), pele só por papel, encaixes/botões declarados."""
    from esteira.studio import piece as P
    erros, avisos = [], []
    if (PIECES / id_ / "peca.n1.json").exists():
        return check_n1(id_, ficha)
    arq = PIECES / id_ / "peca.jsx"
    if not arq.exists():
        return ["falta peca.jsx ou peca.n1.json"], avisos
    jsx = arq.read_text()
    node = P._node()
    if node:
        with tempfile.TemporaryDirectory() as tmp:
            js = Path(tmp) / "peca.js"
            js.write_text(jsx)
            r = subprocess.run([node, "--check", str(js)], capture_output=True, text=True)
            if r.returncode:
                erros.append("sintaxe do peca.jsx: " + (r.stderr.strip().splitlines() or ["?"])[-1])
    codigo = P._code(jsx)
    if m := RE_HEX.search(codigo) or RE_RGB.search(codigo):
        erros.append(f"peca.jsx: cor fixa ({m.group(0)}); use cor(\"destaque\"), corRGB(\"fundo\") ou mistura(...)")
    if RE_SOURCE.search(codigo):
        erros.append("peca.jsx: fonte fixa; use o papel (bloco/linha com papel: \"fD\" | \"fT\" | \"fM\" | \"fE\")")
    if m := FORBIDDEN.search(codigo):
        erros.append(f"peca.jsx: {m.group(0)} não pode (aleatório/tempo real, comp própria ou saída que o portão lê)")
    usados_e = {a or b for a, b in re.findall(r"\bE\s*(?:\.\s*(\w+)|\[\s*[\"'](\w+)[\"']\s*\])", codigo)}
    usados_b = {a or b for a, b in re.findall(r"\bB\s*(?:\.\s*(\w+)|\[\s*[\"'](\w+)[\"']\s*\])", codigo)}
    nomes_e, nomes_b = {e.nome for e in ficha.encaixes}, {b.nome for b in ficha.botoes}
    if fora := usados_e - nomes_e:
        erros.append(f"peca.jsx usa encaixes que a ficha não declara: {sorted(fora)}")
    if fora := usados_b - nomes_b:
        erros.append(f"peca.jsx usa botões que a ficha não declara: {sorted(fora)}")
    if parados := nomes_e - usados_e:
        avisos.append(f"encaixes declarados e não usados: {sorted(parados)}")
    if parados := nomes_b - usados_b:
        avisos.append(f"botões declarados e não usados: {sorted(parados)}")
    return erros, avisos


def check_n1(id_, ficha):
    """Peça em N1: esquema, compila com os padrões da ficha, sintaxe do script gerado e encaixes/botões declarados."""
    from esteira.n1 import effectcraft as N1
    from esteira.studio import piece as P
    erros, avisos = [], []
    try:
        doc = N1.Piece.model_validate_json((PIECES / id_ / "peca.n1.json").read_text())
    except ValueError as e:
        return [f"peca.n1.json fora do esquema: {str(e)[:400]}"], avisos
    bruto = (PIECES / id_ / "peca.n1.json").read_text()
    todos = list(N1.walk(doc.elementos))  # com o que está dentro de caixas e repetir
    conds = [c for x in [*todos, *doc.animacoes] for c in N1.conditions(x.se)]
    usados_e = set(re.findall(r"\{\{(\w+)\}\}", bruto)) | {c.encaixe for c in conds if c.encaixe}
    usados_e |= {x for e in todos if e.tipo == "repetir" for x in (e.encaixe, e.ativos) if x}
    erros += [f"`repetir` {e.nome!r} com passo [0, 0]: todos os itens ficam no mesmo lugar, um sobre o outro (dê um "
              "passo, ex.: [0, 0.09] para lista vertical)" for e in doc.elementos
              if e.tipo == "repetir" and (e.quantidade or e.maximo) > 1 and not any(e.passo)
              and not any(getattr(x, "fatia", False) for x in e.elementos)]
    erros += [f"`repetir` {r.nome!r}: o molde {x.nome!r} está em x={x.x:g}, y={x.y:g} (canto da tela). x/y do molde são a "
              "posição NA TELA do primeiro item (ex.: x 0.1, y 0.3), não relativa; o `passo` anda a partir dela"
              for r in doc.elementos if r.tipo == "repetir" for x in r.elementos
              if x.x is not None and x.y is not None and x.x < 0.03 and x.y < 0.03]
    listas = {e.nome for e in ficha.encaixes if e.tipo in ("itens", "pares")}
    erros += [f"o encaixe-lista {n!r} da ficha não é usado: faça um `repetir` com \"encaixe\": {n!r} (sem ele os itens "
              "mostram 1, 2, 3 no lugar do texto)" for n in sorted(listas - usados_e)]
    if any(e.tipo == "repetir" for e in todos):
        usados_e.discard("item")  # {{item}} é o valor do item no molde do `repetir`, não um encaixe
    usados_b = {c.botao for c in conds if c.botao}
    if doc.botao_velocidade:
        usados_b.add(doc.botao_velocidade)
    nomes_e, nomes_b = {e.nome for e in ficha.encaixes}, {b.nome for b in ficha.botoes}
    if fora := usados_e - nomes_e:
        listas = [e.nome for e in ficha.encaixes if e.tipo in ("itens", "pares")]
        dica = (f" ({{{{item}}}} só existe dentro de um elemento `repetir` com \"encaixe\": {listas[0]!r}: mova os "
                "elementos do item para `elementos` do repetir e use `passo` para espaçar)") if "item" in fora and listas else ""
        erros.append(f"peca.n1.json usa encaixes que a ficha não declara: {sorted(fora)}{dica}")
    if fora := usados_b - nomes_b:
        erros.append(f"peca.n1.json usa botões que a ficha não declara: {sorted(fora)}")
    if parados := nomes_e - usados_e:
        avisos.append(f"encaixes declarados e não usados: {sorted(parados)}")
    exemplo = {"numero": "R$ 8.888", "pares": [{"rotulo": "XXXX", "valor": "8"}] * 3, "itens": ["XXXX"] * 3}
    d = {"encaixes": {e.nome: exemplo.get(e.tipo, "X" * min(e.max_car, 12)) for e in ficha.encaixes},
         "botoes": {b.nome: b.padrao for b in ficha.botoes}, "batidas": {}, "t0": 0.3, "dur": 6, "w": 1920,
         "h": 1080, "fps": 30, "tela_cheia": ficha.tela_cheia}
    try:
        js = N1.build(doc, d)
    except N1.ErrorN1 as e:
        return [f"peca.n1.json não compila: {e}"], avisos
    node = P._node()
    if node:
        with tempfile.TemporaryDirectory() as tmp:
            arq = Path(tmp) / "peca.js"
            arq.write_text(js)
            r = subprocess.run([node, "--check", str(arq)], capture_output=True, text=True)
            if r.returncode:
                erros.append("script gerado do N1 com erro de sintaxe: " + (r.stderr.strip().splitlines() or ["?"])[-1])
    return erros, avisos


COLORS_STRONG = ("destaque", "acento", "apoio")


def _layout_bad(nos, doc, N1) -> list[str]:
    """Defeitos de caixa que a revisão do Claude reprovava sempre (traço que vira bloco, texto sem contraste sobre
    forma colorida, texto colado na borda, coluna de níveis misturados sem pesos): pegos aqui de graça."""
    erros = []
    for e, mae in nos:
        if not isinstance(mae, N1.Box):
            continue
        disp = mae.disposicao
        if (isinstance(e, N1.Rectangle) and not e.proporcional and disp in ("coluna", "linha", "fluxo")
                and not any(isinstance(x, N1.Repeat) for x in mae.filhos)):
            # no `fluxo` a caixa é linha no 16:9 e coluna no 9:16: precisa dos dois lados
            falta = next((k for k in {"coluna": "h", "linha": "w", "fluxo": "hw"}[disp] if getattr(e, k) is None), "")
            if falta:
                pesos = list(mae.pesos or [])[:len(mae.filhos)]
                pesos += [1.0] * (len(mae.filhos) - len(pesos))
                parte = pesos[mae.filhos.index(e)] / (sum(pesos) or 1)
                if e.cor in ("fundo", "fundo2") or e.opacidade <= 40:
                    continue  # painel de fundo discreto, não bloco de cor
                if parte > 0.12 and len(mae.filhos) == 1:
                    erros.append(f"retângulo {e.nome!r} sozinho na caixa {mae.nome!r} vira um bloco de cor do tamanho "
                                 "dela: tire o retângulo (e a caixa, se ficar vazia) ou dê `w` e `h` a ele")
                elif parte > 0.12:
                    erros.append(f"retângulo {e.nome!r} sem `{falta}` numa `{disp}` ocupa {parte:.0%} da caixa "
                                 f"{mae.nome!r} e vira um bloco: dê `{falta}` pequeno (traço: 0.006) ou peso mínimo "
                                 "à célula dele nos `pesos`")
    for e, _ in nos:  # forma de dado (barra, fatia) na cor do fundo some
        if (getattr(e, "proporcional", False) or getattr(e, "fatia", False)) and e.cor in ("fundo", "fundo2"):
            erros.append(f"forma de dado {e.nome!r} na cor `{e.cor}` some no fundo: use `destaque` (ou `acento`)")
    for cx, mae in ((e, m) for e, m in nos if isinstance(e, N1.Box)):
        formas = [x for x in cx.filhos if isinstance(x, (N1.Rectangle, N1.Ellipse)) and x.cor in COLORS_STRONG
                  and not getattr(x, "contorno", 0)]
        if cx.disposicao == "camadas" and formas:
            if (isinstance(mae, N1.Box) and mae.disposicao in ("linha", "fluxo")
                    and (r := next((x for x in formas if isinstance(x, N1.Rectangle) and not (x.w and x.h)), None))):
                erros.append(f"retângulo {r.nome!r} sem `w` e `h` no bloco {cx.nome!r} de uma `{mae.disposicao}` "
                             "vira uma tira da altura toda: dê `w` e `h` (bloco quadrado: w = h, ex.: 0.34)")
            for t in (x for x in cx.filhos if isinstance(x, N1.Text)):
                if t.cor not in ("fundo", "fundo2") or t.peso < 700:
                    erros.append(f"texto {t.nome!r} em cor `{t.cor}`, peso {t.peso}, sobre a forma {formas[0].nome!r} "
                                 f"(`{formas[0].cor}`) some: texto sobre forma colorida usa cor `fundo`, peso 700+ "
                                 "(o N1 não tem variante por pele)")
        if cx.disposicao == "coluna" and not cx.pesos and len(cx.filhos) >= 3:
            niveis = {x.nivel or "corpo" for x in cx.filhos if isinstance(x, N1.Text)}
            if len(niveis) >= 2 and niveis & {"titulo", "destaque", "numero"}:  # título que precisa quebrar
                erros.append(f"coluna {cx.nome!r} com {len(cx.filhos)} filhos de níveis diferentes e sem `pesos`: "
                             "todos ganham a mesma altura (o título corta, o traço fica longe). Dê `pesos` (título "
                             "o maior, rótulo/traço os menores)")
    for cx in doc.elementos:
        if cx.tipo == "caixa" and cx.regiao == "tela" and all(
                isinstance(x, N1.Text) for x, _ in _descendants(cx, N1) if not isinstance(x, N1.Box)):
            erros.append(f"caixa {cx.nome!r} só de texto em `regiao: tela` cola o texto na borda: use `centro` "
                         "(ou topo/base); `tela` é para fundo/faixa com forma")
    return erros


def _small(doc, ficha, N1) -> list[str]:
    """Compila com o texto máximo nos formatos da ficha: texto que a célula espreme vira rótulo ilegível (o Claude
    reprovava; o `caber` do EffectCraft ainda encolhe mais)."""
    from esteira.studio import piece as P
    cena = P._scene(ficha, 4.0)
    achados: dict[str, list[str]] = {}
    for fmt, (w, h) in P.DIM.items():
        if fmt not in ficha.formatos:
            continue
        c = N1.Compiler(doc, {"encaixes": cena["encaixes"], "botoes": cena["botoes"], "batidas": cena["batidas"],
                                "t0": 0.3, "dur": 4.0, "w": w, "h": h, "fps": 30, "tela_cheia": ficha.tela_cheia})
        try:
            c.compilar()
        except Exception:  # noqa: BLE001 — erro de compilação é do portão técnico, com a mensagem dele
            continue
        for n in dict.fromkeys(c.miudos):
            achados.setdefault(n, []).append(fmt)
    return [f"texto {n!r} fica minúsculo no {'/'.join(f)} com o texto máximo: a célula dele é baixa ou estreita "
            "demais. Dê mais peso a essa célula nos `pesos` da caixa-mãe (ou tire peso das vizinhas)"
            for n, f in achados.items()]


def _descendants(cx, N1):
    for x in cx.filhos:
        yield x, cx
        if isinstance(x, N1.Box):
            yield from _descendants(x, N1)
        elif isinstance(x, N1.Repeat):
            yield from ((y, x) for y in x.elementos)


def check_structure(doc, ficha) -> list[str]:
    """Portão estrutural, antes do render (de graça): o que compila mas sai vazio ou quebrado na tela. Eram esses
    os defeitos que só a revisão do Claude pegava (caixa vazia, encaixe obrigatório invisível, fileira de bolinhas,
    `se` com valor que o botão não tem, regiões sobrepostas)."""
    from esteira.n1 import effectcraft as N1
    erros = []

    def andar(els, mae=None):
        for e in els:
            yield e, mae
            if isinstance(e, N1.Box):
                yield from andar(e.filhos, e)
            elif isinstance(e, N1.Repeat):
                yield from andar(e.elementos, e)

    nos = list(andar(doc.elementos))
    for e, mae in nos:
        if e.tipo == "caixa" and not e.filhos:
            erros.append(f"caixa {e.nome!r} sem filhos: vazia não desenha nada (ponha os elementos dentro dela ou tire-a)")
        if e.tipo != "repetir":
            continue
        textos = [x for x in e.elementos if x.tipo == "texto"]
        forma_de_dado = any(getattr(x, "fatia", False) or getattr(x, "proporcional", False) for x in e.elementos)
        if not e.elementos:
            erros.append(f"`repetir` {e.nome!r} sem elementos no molde")
        elif e.encaixe and not textos and not forma_de_dado:
            erros.append(f"o molde do `repetir` {e.nome!r} não tem texto: cada item precisa mostrar o próprio conteúdo "
                         "({{item}} ou {{item.rotulo}}); só formas viram blocos de cor sem significado")
        elif not e.encaixe and not textos and not (isinstance(mae, N1.Box) and mae.disposicao == "grade"):
            erros.append(f"`repetir` {e.nome!r} de formas sem texto fora de caixa `grade`: os itens viram uma fileira "
                         "(ponha numa caixa `grade` com `colunas`, ou mostre texto em cada item)")
    erros += _layout_bad(nos, doc, N1)
    erros += _small(doc, ficha, N1)
    conteudo = " ".join(x.conteudo for x, _ in nos if x.tipo == "texto")
    visiveis = {e.encaixe for e, _ in nos if e.tipo == "repetir" and e.encaixe and any(
        x.tipo == "texto" or getattr(x, "fatia", False) or getattr(x, "proporcional", False) for x in e.elementos)}
    for enc in ficha.encaixes:
        if not enc.obrigatorio:
            continue
        if enc.tipo in ("itens", "pares") and enc.nome not in visiveis:
            erros.append(f"o encaixe-lista obrigatório {enc.nome!r} não aparece: faça um `repetir` com \"encaixe\": "
                         f"{enc.nome!r} e um texto {{{{item}}}} no molde")
        elif enc.tipo in ("texto", "numero", "tematico", "icone") and not re.search(
                r"\{\{" + re.escape(enc.nome) + r"(\.\w+)?\}\}", conteudo):
            erros.append(f"o encaixe obrigatório {enc.nome!r} não aparece: ponha um texto com "
                         f"\"conteudo\": \"{{{{{enc.nome}}}}}\"")
    botoes = {b.nome: [str(v) for v in b.valores] for b in ficha.botoes}
    encaixes = {e.nome for e in ficha.encaixes}
    valores = {v: b for b, vs in botoes.items() for v in vs}
    for x in [*(e for e, _ in nos), *doc.animacoes, *(a for e, _ in nos if e.tipo == "repetir" for a in e.animacoes)]:
        for c in N1.conditions(x.se):
            if c.botao and c.botao not in botoes:
                dica = (f" ({c.botao!r} é valor do botão {valores[c.botao]!r}: use {{\"botao\": {valores[c.botao]!r}, "
                        f"\"igual\": {c.botao!r}}})" if c.botao in valores else
                        f" ({c.botao!r} é encaixe: use {{\"encaixe\": {c.botao!r}}})" if c.botao in encaixes else
                        f" (botões da ficha: {sorted(botoes)})")
                erros.append(f"`se` de {x.nome if hasattr(x, 'nome') else x.alvo!r} usa o botão {c.botao!r}, que a "
                             f"ficha não tem{dica}")
            elif c.botao and c.igual is not None and str(c.igual) not in botoes[c.botao]:
                erros.append(f"`se` com botão {c.botao!r} igual a {c.igual!r}: esse valor não existe (valores: "
                             f"{botoes[c.botao]})")
            if c.encaixe and c.encaixe not in encaixes:
                dica = f" ({c.encaixe!r} é botão: use {{\"botao\": {c.encaixe!r}, \"igual\": …}})" \
                    if c.encaixe in botoes else f" (encaixes da ficha: {sorted(encaixes)})"
                erros.append(f"`se` usa o encaixe {c.encaixe!r}, que a ficha não tem{dica}")
    regioes = [e.regiao for e in doc.elementos if e.tipo == "caixa" and e.se is None]
    if dup := sorted({r for r in regioes if regioes.count(r) > 1 and r != "tela"}):
        erros.append(f"duas caixas na mesma região {dup}: ficam uma sobre a outra (junte numa caixa só, com "
                     "`disposicao`, ou use outra região)")
    if {"esquerda", "direita"} & set(regioes) and {"centro", "base"} & set(regioes):
        erros.append("as regiões esquerda/direita vão do centro até a base: não use junto com `centro` ou `base` "
                     "(use topo + esquerda + direita)")
    telas = [c for c in doc.elementos if c.tipo == "caixa" and c.regiao == "tela"
             and any(x.tipo == "texto" for x, _ in andar(c.filhos))]
    if telas and len(set(regioes)) > 1:
        # a LLM quase nunca escreve "tela": ela cria uma caixa nova sem `regiao` (o padrão é tela) e não achava qual era
        sem = [c.nome for c in telas if "regiao" not in c.model_fields_set]
        erros.append(f"caixa `tela` com texto junto de outras regiões ({[c.nome for c in telas]}"
                     + (f"; {sem} estão sem `regiao`, e sem ela a caixa vira `tela`" if sem else "")
                     + "): o texto fica por cima delas. Ponha o conteúdo dela dentro da caixa da região certa "
                       "(ex.: a de `centro`) ou dê a ela uma região livre; na `tela` só formas de fundo, ou só ela")
    return erros


def prove(id_, ficha):
    """Texto máximo nas duas peles de prova × formatos: monta, mede o estouro em INSTANTES e fotografa o meio.
    → (erros, quadros, segundos de montagem + quadro)."""
    from esteira.studio import piece as P
    erros, quadros = [], []
    prova = PIECES / id_ / "prova"
    shutil.rmtree(prova, ignore_errors=True)
    prova.mkdir(parents=True)
    dur = min(ficha.duracao_max, max(ficha.duracao_min, 4.0))
    cena = P._scene(ficha, dur)
    t0 = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="ecprova_") as tmp:
        for nome_pele, pele in P.SKINS_PROOF.items():
            for fmt in ficha.formatos:
                inst = [round(cena["t"] + f * dur, 2) for f in P.INSTANTS]
                d = data(ficha, cena["encaixes"], cena["botoes"], cena["batidas"], pele, fmt, dur, cena["t"], inst,
                          P.AREA_SAFE)
                ecproj = Path(tmp) / f"{nome_pele}_{fmt.replace(':', 'x')}.ecproj"
                try:
                    estouros, _ = assemble(id_, d, ecproj, pele)
                except (RuntimeError, subprocess.TimeoutExpired) as e:
                    erros.append(f"{nome_pele} {fmt}: {str(e)[:300]}")
                    continue
                if estouros:
                    dica = (" (itens de `repetir`: reduza o `passo` ou suba o y; no 9:16 use `vertical` no repetir)"
                            if any(re.search(r" \d+$", x) for x in estouros) else
                            " (use `largura` para quebrar em parágrafo, reduza `tam` ou afaste da borda; no 9:16 use `vertical`)")
                    erros.append(f"{nome_pele} {fmt}: sai da área segura com o texto máximo: {estouros[:4]}{dica}")
                arq = prova / f"{nome_pele}_{fmt.replace(':', 'x')}.jpg"
                frame(ecproj, cena["t"] + 0.6 * dur, arq, pele.fundo)
                quadros.append(arq.name)
    return erros, quadros, round(time.monotonic() - t0, 2)


def preview(id_, est, formato):
    """MP4 da peça (preenchimento de exemplo) na pele do estilo, para a revisão."""
    from esteira.studio import piece as P
    ficha = P.load(id_)
    dur = min(ficha.duracao_max, max(ficha.duracao_min, 5.0))
    cena = P._scene(ficha, dur, encaixes=P.examples(ficha))
    d = data(ficha, cena["encaixes"], cena["botoes"], cena["batidas"], est.pele, formato, dur, cena["t"])
    saida = P.previews_dir(id_) / f"{est.id}_{formato.replace(':', 'x')}.mp4"
    saida.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ecprev_") as tmp:
        ecproj = Path(tmp) / "p.ecproj"
        assemble(id_, d, ecproj, est.pele)
        render_mp4(ecproj, saida)
    return saida


def to_production(id_, cena, est, formato, destino_webm):
    """Renderiza a peça para uma cena do mapa (encaixes/botões da cena, pele do estilo) → WebM com alfa do tamanho
    da cena; o `.ecproj` fica ao lado para edição à mão."""
    from esteira.studio import piece as P
    ficha = P.load(id_)
    dur = max(0.6, cena["ate"] - cena["t"])
    d = data(ficha, cena.get("encaixes") or {}, {**P.defaults(ficha), **(cena.get("botoes") or {})},
              {k: round(v - cena["t"], 3) for k, v in (cena.get("batidas") or {}).items()}, est.pele, formato, dur, 0.0, cauda=0.0)
    ecproj = Path(destino_webm).with_suffix(".ecproj")
    assemble(id_, d, ecproj, est.pele)
    return render_webm(ecproj, destino_webm)
