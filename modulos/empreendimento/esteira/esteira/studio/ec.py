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
    everything = {**fonts.CATALOG, **fonts._uploaded()}
    copiou = False
    SOURCES_USER.mkdir(parents=True, exist_ok=True)
    for role in ROLES.values():
        for file, *_ in everything.get(getattr(pele, role), ([], ""))[0]:
            origin = fonts.path(file)
            if origin and origin.suffix.lower() in (".ttf", ".otf") and not (SOURCES_USER / origin.name).exists():
                shutil.copy(origin, SOURCES_USER / origin.name)
                copiou = True
    return copiou


def data(ficha, encaixes, botoes, batidas, pele, fmt, dur, t0=0.3, instants=(), area=0.03, cauda=0.5):
    """DADOS do script. `cauda`: sobra depois da peça (prova/prévia); na produção 0 (a comp tem o tamanho da cena)."""
    from esteira.studio.piece import DIM
    W, H = DIM[fmt]
    colors = {k: getattr(pele, k) for k in ("fundo", "fundo2", "texto", "destaque", "apoio", "acento")}
    return {"encaixes": encaixes, "botoes": botoes, "batidas": batidas, "t0": t0, "dur": round(t0 + dur + cauda, 3),
            "w": W, "h": H, "fps": 30, "pele": {**colors, **{k: fonts.resolve(getattr(pele, v)) for k, v in ROLES.items()}},
            "area": area, "instantes": list(instants), "tela_cheia": ficha.tela_cheia}


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
        file = Path(tmp) / "peca.jsx"
        file.write_text(script(id_, d, rescan))
        output = _run([CLI, "script", str(file), "--save-as", str(ecproj)])
    if "ok " not in output:
        raise RuntimeError(f"a peça não terminou (falta o 'ok' do fim): {output.strip()[-300:]}")
    return re.findall(r"^estouro (.+)$", output, re.M), output


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
    errors, warnings = [], []
    if (PIECES / id_ / "peca.n1.json").exists():
        return check_n1(id_, ficha)
    file = PIECES / id_ / "peca.jsx"
    if not file.exists():
        return ["falta peca.jsx ou peca.n1.json"], warnings
    jsx = file.read_text()
    node = P._node()
    if node:
        with tempfile.TemporaryDirectory() as tmp:
            js = Path(tmp) / "peca.js"
            js.write_text(jsx)
            r = subprocess.run([node, "--check", str(js)], capture_output=True, text=True)
            if r.returncode:
                errors.append("sintaxe do peca.jsx: " + (r.stderr.strip().splitlines() or ["?"])[-1])
    code = P._code(jsx)
    if m := RE_HEX.search(code) or RE_RGB.search(code):
        errors.append(f"peca.jsx: cor fixa ({m.group(0)}); use cor(\"destaque\"), corRGB(\"fundo\") ou mistura(...)")
    if RE_SOURCE.search(code):
        errors.append("peca.jsx: fonte fixa; use o papel (bloco/linha com papel: \"fD\" | \"fT\" | \"fM\" | \"fE\")")
    if m := FORBIDDEN.search(code):
        errors.append(f"peca.jsx: {m.group(0)} não pode (aleatório/tempo real, comp própria ou saída que o portão lê)")
    used_and = {a or b for a, b in re.findall(r"\bE\s*(?:\.\s*(\w+)|\[\s*[\"'](\w+)[\"']\s*\])", code)}
    used_b = {a or b for a, b in re.findall(r"\bB\s*(?:\.\s*(\w+)|\[\s*[\"'](\w+)[\"']\s*\])", code)}
    names_and, names_b = {e.nome for e in ficha.encaixes}, {b.nome for b in ficha.botoes}
    if outside := used_and - names_and:
        errors.append(f"peca.jsx usa encaixes que a ficha não declara: {sorted(outside)}")
    if outside := used_b - names_b:
        errors.append(f"peca.jsx usa botões que a ficha não declara: {sorted(outside)}")
    if stopped := names_and - used_and:
        warnings.append(f"encaixes declarados e não usados: {sorted(stopped)}")
    if stopped := names_b - used_b:
        warnings.append(f"botões declarados e não usados: {sorted(stopped)}")
    return errors, warnings


def check_n1(id_, ficha):
    """Peça em N1: esquema, compila com os padrões da ficha, sintaxe do script gerado e encaixes/botões declarados."""
    from esteira.n1 import effectcraft as N1
    from esteira.studio import piece as P
    errors, warnings = [], []
    try:
        doc = N1.Piece.model_validate_json((PIECES / id_ / "peca.n1.json").read_text())
    except ValueError as e:
        return [f"peca.n1.json fora do esquema: {str(e)[:400]}"], warnings
    raw = (PIECES / id_ / "peca.n1.json").read_text()
    everything = list(N1.walk(doc.elementos))  # com o que está dentro de caixas e repetir
    conds = [c for x in [*everything, *doc.animacoes] for c in N1.conditions(x.se)]
    used_and = set(re.findall(r"\{\{(\w+)\}\}", raw)) | {c.encaixe for c in conds if c.encaixe}
    used_and |= {x for e in everything if e.tipo == "repetir" for x in (e.encaixe, e.ativos) if x}
    errors += [f"`repetir` {e.nome!r} com passo [0, 0]: todos os itens ficam no mesmo lugar, um sobre o outro (dê um "
              "passo, ex.: [0, 0.09] para lista vertical)" for e in doc.elementos
              if e.tipo == "repetir" and (e.quantidade or e.maximo) > 1 and not any(e.passo)
              and not any(getattr(x, "fatia", False) for x in e.elementos)]
    errors += [f"`repetir` {r.nome!r}: o molde {x.nome!r} está em x={x.x:g}, y={x.y:g} (canto da tela). x/y do molde são a "
              "posição NA TELA do primeiro item (ex.: x 0.1, y 0.3), não relativa; o `passo` anda a partir dela"
              for r in doc.elementos if r.tipo == "repetir" for x in r.elementos
              if x.x is not None and x.y is not None and x.x < 0.03 and x.y < 0.03]
    lists = {e.nome for e in ficha.encaixes if e.tipo in ("itens", "pares")}
    errors += [f"o encaixe-lista {n!r} da ficha não é usado: faça um `repetir` com \"encaixe\": {n!r} (sem ele os itens "
              "mostram 1, 2, 3 no lugar do texto)" for n in sorted(lists - used_and)]
    if any(e.tipo == "repetir" for e in everything):
        used_and.discard("item")  # {{item}} é o valor do item no molde do `repetir`, não um encaixe
    used_b = {c.botao for c in conds if c.botao}
    if doc.botao_velocidade:
        used_b.add(doc.botao_velocidade)
    names_and, names_b = {e.nome for e in ficha.encaixes}, {b.nome for b in ficha.botoes}
    if outside := used_and - names_and:
        lists = [e.nome for e in ficha.encaixes if e.tipo in ("itens", "pares")]
        hint = (f" ({{{{item}}}} só existe dentro de um elemento `repetir` com \"encaixe\": {lists[0]!r}: mova os "
                "elementos do item para `elementos` do repetir e use `passo` para espaçar)") if "item" in outside and lists else ""
        errors.append(f"peca.n1.json usa encaixes que a ficha não declara: {sorted(outside)}{hint}")
    if outside := used_b - names_b:
        errors.append(f"peca.n1.json usa botões que a ficha não declara: {sorted(outside)}")
    if stopped := names_and - used_and:
        warnings.append(f"encaixes declarados e não usados: {sorted(stopped)}")
    example = {"numero": "R$ 8.888", "pares": [{"rotulo": "XXXX", "valor": "8"}] * 3, "itens": ["XXXX"] * 3}
    d = {"encaixes": {e.nome: example.get(e.tipo, "X" * min(e.max_car, 12)) for e in ficha.encaixes},
         "botoes": {b.nome: b.padrao for b in ficha.botoes}, "batidas": {}, "t0": 0.3, "dur": 6, "w": 1920,
         "h": 1080, "fps": 30, "tela_cheia": ficha.tela_cheia}
    try:
        js = N1.build(doc, d)
    except N1.ErrorN1 as e:
        return [f"peca.n1.json não compila: {e}"], warnings
    node = P._node()
    if node:
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / "peca.js"
            file.write_text(js)
            r = subprocess.run([node, "--check", str(file)], capture_output=True, text=True)
            if r.returncode:
                errors.append("script gerado do N1 com erro de sintaxe: " + (r.stderr.strip().splitlines() or ["?"])[-1])
    return errors, warnings


COLORS_STRONG = ("destaque", "acento", "apoio")


def _layout_bad(nos, doc, N1) -> list[str]:
    """Defeitos de caixa que a revisão do Claude reprovava sempre (traço que vira bloco, texto sem contraste sobre
    forma colorida, texto colado na borda, coluna de níveis misturados sem pesos): pegos aqui de graça."""
    errors = []
    for e, parent in nos:
        if not isinstance(parent, N1.Box):
            continue
        disp = parent.disposicao
        if (isinstance(e, N1.Rectangle) and not e.proporcional and disp in ("coluna", "linha", "fluxo")
                and not any(isinstance(x, N1.Repeat) for x in parent.filhos)):
            # no `fluxo` a caixa é linha no 16:9 e coluna no 9:16: precisa dos dois lados
            missing = next((k for k in {"coluna": "h", "linha": "w", "fluxo": "hw"}[disp] if getattr(e, k) is None), "")
            if missing:
                weights = list(parent.pesos or [])[:len(parent.filhos)]
                weights += [1.0] * (len(parent.filhos) - len(weights))
                part = weights[parent.filhos.index(e)] / (sum(weights) or 1)
                if e.cor in ("fundo", "fundo2") or e.opacidade <= 40:
                    continue  # painel de fundo discreto, não bloco de cor
                if part > 0.12 and len(parent.filhos) == 1:
                    errors.append(f"retângulo {e.nome!r} sozinho na caixa {parent.nome!r} vira um bloco de cor do tamanho "
                                 "dela: tire o retângulo (e a caixa, se ficar vazia) ou dê `w` e `h` a ele")
                elif part > 0.12:
                    errors.append(f"retângulo {e.nome!r} sem `{missing}` numa `{disp}` ocupa {part:.0%} da caixa "
                                 f"{parent.nome!r} e vira um bloco: dê `{missing}` pequeno (traço: 0.006) ou peso mínimo "
                                 "à célula dele nos `pesos`")
    for e, _ in nos:  # forma de dado (barra, fatia) na cor do fundo some
        if (getattr(e, "proporcional", False) or getattr(e, "fatia", False)) and e.cor in ("fundo", "fundo2"):
            errors.append(f"forma de dado {e.nome!r} na cor `{e.cor}` some no fundo: use `destaque` (ou `acento`)")
    for cx, parent in ((e, m) for e, m in nos if isinstance(e, N1.Box)):
        shapes = [x for x in cx.filhos if isinstance(x, (N1.Rectangle, N1.Ellipse)) and x.cor in COLORS_STRONG
                  and not getattr(x, "contorno", 0)]
        if cx.disposicao == "camadas" and shapes:
            if (isinstance(parent, N1.Box) and parent.disposicao in ("linha", "fluxo")
                    and (r := next((x for x in shapes if isinstance(x, N1.Rectangle) and not (x.w and x.h)), None))):
                errors.append(f"retângulo {r.nome!r} sem `w` e `h` no bloco {cx.nome!r} de uma `{parent.disposicao}` "
                             "vira uma tira da altura toda: dê `w` e `h` (bloco quadrado: w = h, ex.: 0.34)")
            for t in (x for x in cx.filhos if isinstance(x, N1.Text)):
                if t.cor not in ("fundo", "fundo2") or t.peso < 700:
                    errors.append(f"texto {t.nome!r} em cor `{t.cor}`, peso {t.peso}, sobre a forma {shapes[0].nome!r} "
                                 f"(`{shapes[0].cor}`) some: texto sobre forma colorida usa cor `fundo`, peso 700+ "
                                 "(o N1 não tem variante por pele)")
        if cx.disposicao == "coluna" and not cx.pesos and len(cx.filhos) >= 3:
            levels = {x.nivel or "corpo" for x in cx.filhos if isinstance(x, N1.Text)}
            if len(levels) >= 2 and levels & {"titulo", "destaque", "numero"}:  # título que precisa quebrar
                errors.append(f"coluna {cx.nome!r} com {len(cx.filhos)} filhos de níveis diferentes e sem `pesos`: "
                             "todos ganham a mesma altura (o título corta, o traço fica longe). Dê `pesos` (título "
                             "o maior, rótulo/traço os menores)")
    for cx in doc.elementos:
        if cx.tipo == "caixa" and cx.regiao == "tela" and all(
                isinstance(x, N1.Text) for x, _ in _descendants(cx, N1) if not isinstance(x, N1.Box)):
            errors.append(f"caixa {cx.nome!r} só de texto em `regiao: tela` cola o texto na borda: use `centro` "
                         "(ou topo/base); `tela` é para fundo/faixa com forma")
    return errors


def _small(doc, ficha, N1) -> list[str]:
    """Compila com o texto máximo nos formatos da ficha: texto que a célula espreme vira rótulo ilegível (o Claude
    reprovava; o `caber` do EffectCraft ainda encolhe mais)."""
    from esteira.studio import piece as P
    scene = P._scene(ficha, 4.0)
    found: dict[str, list[str]] = {}
    for fmt, (w, h) in P.DIM.items():
        if fmt not in ficha.formatos:
            continue
        c = N1.Compiler(doc, {"encaixes": scene["encaixes"], "botoes": scene["botoes"], "batidas": scene["batidas"],
                                "t0": 0.3, "dur": 4.0, "w": w, "h": h, "fps": 30, "tela_cheia": ficha.tela_cheia})
        try:
            c.compilar()
        except Exception:  # noqa: BLE001 — erro de compilação é do portão técnico, com a mensagem dele
            continue
        for n in dict.fromkeys(c.small):
            found.setdefault(n, []).append(fmt)
    return [f"texto {n!r} fica minúsculo no {'/'.join(f)} com o texto máximo: a célula dele é baixa ou estreita "
            "demais. Dê mais peso a essa célula nos `pesos` da caixa-mãe (ou tire peso das vizinhas)"
            for n, f in found.items()]


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
    errors = []

    def andar(els, parent=None):
        for e in els:
            yield e, parent
            if isinstance(e, N1.Box):
                yield from andar(e.filhos, e)
            elif isinstance(e, N1.Repeat):
                yield from andar(e.elementos, e)

    nodes = list(andar(doc.elementos))
    for e, parent in nodes:
        if e.tipo == "caixa" and not e.filhos:
            errors.append(f"caixa {e.nome!r} sem filhos: vazia não desenha nada (ponha os elementos dentro dela ou tire-a)")
        if e.tipo != "repetir":
            continue
        texts = [x for x in e.elementos if x.tipo == "texto"]
        forma_of_given = any(getattr(x, "fatia", False) or getattr(x, "proporcional", False) for x in e.elementos)
        if not e.elementos:
            errors.append(f"`repetir` {e.nome!r} sem elementos no molde")
        elif e.encaixe and not texts and not forma_of_given:
            errors.append(f"o molde do `repetir` {e.nome!r} não tem texto: cada item precisa mostrar o próprio conteúdo "
                         "({{item}} ou {{item.rotulo}}); só formas viram blocos de cor sem significado")
        elif not e.encaixe and not texts and not (isinstance(parent, N1.Box) and parent.disposicao == "grade"):
            errors.append(f"`repetir` {e.nome!r} de formas sem texto fora de caixa `grade`: os itens viram uma fileira "
                         "(ponha numa caixa `grade` com `colunas`, ou mostre texto em cada item)")
    errors += _layout_bad(nodes, doc, N1)
    errors += _small(doc, ficha, N1)
    content = " ".join(x.conteudo for x, _ in nodes if x.tipo == "texto")
    visiveis = {e.encaixe for e, _ in nodes if e.tipo == "repetir" and e.encaixe and any(
        x.tipo == "texto" or getattr(x, "fatia", False) or getattr(x, "proporcional", False) for x in e.elementos)}
    for enc in ficha.encaixes:
        if not enc.obrigatorio:
            continue
        if enc.tipo in ("itens", "pares") and enc.nome not in visiveis:
            errors.append(f"o encaixe-lista obrigatório {enc.nome!r} não aparece: faça um `repetir` com \"encaixe\": "
                         f"{enc.nome!r} e um texto {{{{item}}}} no molde")
        elif enc.tipo in ("texto", "numero", "tematico", "icone") and not re.search(
                r"\{\{" + re.escape(enc.nome) + r"(\.\w+)?\}\}", content):
            errors.append(f"o encaixe obrigatório {enc.nome!r} não aparece: ponha um texto com "
                         f"\"conteudo\": \"{{{{{enc.nome}}}}}\"")
    buttons = {b.nome: [str(v) for v in b.valores] for b in ficha.botoes}
    fits = {e.nome for e in ficha.encaixes}
    values = {v: b for b, vs in buttons.items() for v in vs}
    for x in [*(e for e, _ in nodes), *doc.animacoes, *(a for e, _ in nodes if e.tipo == "repetir" for a in e.animacoes)]:
        for c in N1.conditions(x.se):
            if c.botao and c.botao not in buttons:
                hint = (f" ({c.botao!r} é valor do botão {values[c.botao]!r}: use {{\"botao\": {values[c.botao]!r}, "
                        f"\"igual\": {c.botao!r}}})" if c.botao in values else
                        f" ({c.botao!r} é encaixe: use {{\"encaixe\": {c.botao!r}}})" if c.botao in fits else
                        f" (botões da ficha: {sorted(buttons)})")
                errors.append(f"`se` de {x.nome if hasattr(x, 'nome') else x.alvo!r} usa o botão {c.botao!r}, que a "
                             f"ficha não tem{hint}")
            elif c.botao and c.igual is not None and str(c.igual) not in buttons[c.botao]:
                errors.append(f"`se` com botão {c.botao!r} igual a {c.igual!r}: esse valor não existe (valores: "
                             f"{buttons[c.botao]})")
            if c.encaixe and c.encaixe not in fits:
                hint = f" ({c.encaixe!r} é botão: use {{\"botao\": {c.encaixe!r}, \"igual\": …}})" \
                    if c.encaixe in buttons else f" (encaixes da ficha: {sorted(fits)})"
                errors.append(f"`se` usa o encaixe {c.encaixe!r}, que a ficha não tem{hint}")
    regions = [e.regiao for e in doc.elementos if e.tipo == "caixa" and e.se is None]
    if dup := sorted({r for r in regions if regions.count(r) > 1 and r != "tela"}):
        errors.append(f"duas caixas na mesma região {dup}: ficam uma sobre a outra (junte numa caixa só, com "
                     "`disposicao`, ou use outra região)")
    if {"esquerda", "direita"} & set(regions) and {"centro", "base"} & set(regions):
        errors.append("as regiões esquerda/direita vão do centro até a base: não use junto com `centro` ou `base` "
                     "(use topo + esquerda + direita)")
    telas = [c for c in doc.elementos if c.tipo == "caixa" and c.regiao == "tela"
             and any(x.tipo == "texto" for x, _ in andar(c.filhos))]
    if telas and len(set(regions)) > 1:
        # a LLM quase nunca escreve "tela": ela cria uma caixa nova sem `regiao` (o padrão é tela) e não achava qual era
        sem = [c.nome for c in telas if "regiao" not in c.model_fields_set]
        errors.append(f"caixa `tela` com texto junto de outras regiões ({[c.nome for c in telas]}"
                     + (f"; {sem} estão sem `regiao`, e sem ela a caixa vira `tela`" if sem else "")
                     + "): o texto fica por cima delas. Ponha o conteúdo dela dentro da caixa da região certa "
                       "(ex.: a de `centro`) ou dê a ela uma região livre; na `tela` só formas de fundo, ou só ela")
    return errors


def prove(id_, ficha):
    """Texto máximo nas duas peles de prova × formatos: monta, mede o estouro em INSTANTES e fotografa o meio.
    → (erros, quadros, segundos de montagem + quadro)."""
    from esteira.studio import piece as P
    errors, frames = [], []
    proof = PIECES / id_ / "prova"
    shutil.rmtree(proof, ignore_errors=True)
    proof.mkdir(parents=True)
    duration = min(ficha.duracao_max, max(ficha.duracao_min, 4.0))
    scene = P._scene(ficha, duration)
    t0 = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="ecprova_") as tmp:
        for name_skin, skin in P.SKINS_PROOF.items():
            for fmt in ficha.formatos:
                inst = [round(scene["t"] + f * duration, 2) for f in P.INSTANTS]
                d = data(ficha, scene["encaixes"], scene["botoes"], scene["batidas"], skin, fmt, duration, scene["t"], inst,
                          P.AREA_SAFE)
                ecproj = Path(tmp) / f"{name_skin}_{fmt.replace(':', 'x')}.ecproj"
                try:
                    overflows, _ = assemble(id_, d, ecproj, skin)
                except (RuntimeError, subprocess.TimeoutExpired) as e:
                    errors.append(f"{name_skin} {fmt}: {str(e)[:300]}")
                    continue
                if overflows:
                    hint = (" (itens de `repetir`: reduza o `passo` ou suba o y; no 9:16 use `vertical` no repetir)"
                            if any(re.search(r" \d+$", x) for x in overflows) else
                            " (use `largura` para quebrar em parágrafo, reduza `tam` ou afaste da borda; no 9:16 use `vertical`)")
                    errors.append(f"{name_skin} {fmt}: sai da área segura com o texto máximo: {overflows[:4]}{hint}")
                file = proof / f"{name_skin}_{fmt.replace(':', 'x')}.jpg"
                frame(ecproj, scene["t"] + 0.6 * duration, file, skin.fundo)
                frames.append(file.name)
    return errors, frames, round(time.monotonic() - t0, 2)


def preview(id_, est, fmt):
    """MP4 da peça (preenchimento de exemplo) na pele do estilo, para a revisão."""
    from esteira.studio import piece as P
    card = P.load(id_)
    duration = min(card.duracao_max, max(card.duracao_min, 5.0))
    scene = P._scene(card, duration, encaixes=P.examples(card))
    d = data(card, scene["encaixes"], scene["botoes"], scene["batidas"], est.pele, fmt, duration, scene["t"])
    output = P.previews_dir(id_) / f"{est.id}_{fmt.replace(':', 'x')}.mp4"
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ecprev_") as tmp:
        ecproj = Path(tmp) / "p.ecproj"
        assemble(id_, d, ecproj, est.pele)
        render_mp4(ecproj, output)
    return output


def to_production(id_, cena, est, fmt, destination_webm):
    """Renderiza a peça para uma cena do mapa (encaixes/botões da cena, pele do estilo) → WebM com alfa do tamanho
    da cena; o `.ecproj` fica ao lado para edição à mão."""
    from esteira.studio import piece as P
    card = P.load(id_)
    duration = max(0.6, cena["ate"] - cena["t"])
    d = data(card, cena.get("encaixes") or {}, {**P.defaults(card), **(cena.get("botoes") or {})},
              {k: round(v - cena["t"], 3) for k, v in (cena.get("batidas") or {}).items()}, est.pele, fmt, duration, 0.0, cauda=0.0)
    ecproj = Path(destination_webm).with_suffix(".ecproj")
    assemble(id_, d, ecproj, est.pele)
    return render_webm(ecproj, destination_webm)
