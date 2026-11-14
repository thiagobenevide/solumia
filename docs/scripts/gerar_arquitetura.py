# ruff: noqa: E501  (tabelas de caixas e setas: uma por linha)
"""Gera docs/arquitetura.drawio: uma aba por módulo, raias (onde roda) × caixas (componentes) × setas (dados).

Uso (na raiz): python3 docs/scripts/gerar_arquitetura.py docs/arquitetura.drawio
Ao mudar a arquitetura, edite as páginas abaixo e gere de novo (o arquivo .drawio não é editado à mão)."""
import sys
from html import escape
from xml.sax.saxutils import quoteattr

ESTILO = {
    "app": "rounded=1;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;align=left;spacingLeft=8;verticalAlign=top;spacingTop=4;",
    "api": "rounded=1;whiteSpace=wrap;html=1;fillColor=#d5e8d4;strokeColor=#82b366;align=left;spacingLeft=8;verticalAlign=top;spacingTop=4;",
    "pc": "rounded=1;whiteSpace=wrap;html=1;fillColor=#ffe6cc;strokeColor=#d79b00;align=left;spacingLeft=8;verticalAlign=top;spacingTop=4;",
    "ia": "rounded=1;whiteSpace=wrap;html=1;fillColor=#e1d5e7;strokeColor=#9673a6;align=left;spacingLeft=8;verticalAlign=top;spacingTop=4;",
    "dados": "shape=cylinder3;whiteSpace=wrap;html=1;boundedLbl=1;backgroundOutline=1;size=10;fillColor=#fff2cc;strokeColor=#d6b656;align=left;spacingLeft=8;verticalAlign=top;spacingTop=12;",
    "ext": "rounded=1;whiteSpace=wrap;html=1;fillColor=#f5f5f5;strokeColor=#666666;fontColor=#333333;align=left;spacingLeft=8;verticalAlign=top;spacingTop=4;dashed=1;",
    "nota": "shape=note;whiteSpace=wrap;html=1;size=14;fillColor=#fffbe6;strokeColor=#b3a369;align=left;spacingLeft=8;verticalAlign=top;spacingTop=6;",
}
RAIA = "swimlane;startSize=28;html=1;fillColor=#f8f9fa;strokeColor=#adb5bd;fontStyle=1;horizontal=1;rounded=1;"
SETA = "edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;endArrow=block;endFill=1;strokeColor=#495057;fontSize=10;labelBackgroundColor=#ffffff;"
LARG, ESP, X0, Y0, ALT_LINHA = 270, 40, 30, 90, 120


def rotulo(titulo, linhas):
    corpo = "<br>".join(escape(x) for x in linhas)
    return f"<b>{escape(titulo)}</b>" + (f"<br><font style=\"font-size:10px\">{corpo}</font>" if linhas else "")


def pagina(nome, titulo, raias, caixas, setas, nota=None):
    """raias: [nome]; caixas: [(id, raia, linha, titulo, [linhas], tipo, altura_em_linhas=1)]; setas: [(de, para, rótulo)]"""
    cells = ['<mxCell id="0"/>', '<mxCell id="1" parent="0"/>']
    cells.append(f'<mxCell id="t" value={quoteattr(f"<b>{escape(titulo)}</b>")} style="text;html=1;fontSize=18;align=left;" '
                 f'vertex="1" parent="1"><mxGeometry x="{X0}" y="20" width="1400" height="40" as="geometry"/></mxCell>')
    linhas = max(c[2] + (c[6] if len(c) > 6 else 1) for c in caixas)
    altura = linhas * ALT_LINHA + 50
    for i, r in enumerate(raias):
        x = X0 + i * (LARG + ESP)
        cells.append(f'<mxCell id="r{i}" value={quoteattr(escape(r))} style="{RAIA}" vertex="1" parent="1">'
                     f'<mxGeometry x="{x}" y="{Y0 - 30}" width="{LARG + 20}" height="{altura}" as="geometry"/></mxCell>')
    for c in caixas:
        id_, raia, linha, tit, det, tipo = c[:6]
        h = (c[6] if len(c) > 6 else 1) * ALT_LINHA - 25
        x = X0 + 10 + raias.index(raia) * (LARG + ESP)
        y = Y0 + 10 + linha * ALT_LINHA
        cells.append(f'<mxCell id="{id_}" value={quoteattr(rotulo(tit, det))} style="{ESTILO[tipo]}" vertex="1" parent="1">'
                     f'<mxGeometry x="{x}" y="{y}" width="{LARG}" height="{h}" as="geometry"/></mxCell>')
    for k, (a, b, txt) in enumerate(setas):
        cells.append(f'<mxCell id="s{k}" value={quoteattr(escape(txt))} style="{SETA}" edge="1" parent="1" source="{a}" '
                     f'target="{b}"><mxGeometry relative="1" as="geometry"/></mxCell>')
    if nota:
        x = X0 + len(raias) * (LARG + ESP)
        cells.append(f'<mxCell id="nota" value={quoteattr(rotulo(nota[0], nota[1]))} style="{ESTILO["nota"]}" vertex="1" '
                     f'parent="1"><mxGeometry x="{x}" y="{Y0 - 30}" width="320" height="{max(200, 22 * len(nota[1]) + 50)}" '
                     f'as="geometry"/></mxCell>')
    largura = X0 + len(raias) * (LARG + ESP) + (360 if nota else 0)
    return (f'<diagram id="{nome}" name={quoteattr(nome)}><mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" '
            f'guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="{largura}" '
            f'pageHeight="{Y0 + altura + 40}" math="0" shadow="0"><root>' + "".join(cells) + "</root></mxGraphModel></diagram>")


APP, VPS, PC, IA, DADOS = "App (Flutter)", "VPS · backend FastAPI", "PC · worker / esteira", "IA", "Dados ($AGENT_DATA)"
P = []

# ---------------------------------------------------------------- 1. visão geral
P.append(pagina("0 · Visão geral", "Visão geral: quem fala com quem (topologia e fluxo principal)",
    ["Clientes", "VPS (Docker)", "PC em casa (GPU)", "Dados e serviços"],
    [("cli", "Clientes", 0, "App Flutter", ["Android, iOS, tablet, Linux, web", "um pacote por módulo (agent_<m>)", "login: senha + TOTP → JWT"], "app", 2),
     ("oai", "Clientes", 2, "Clientes OpenAI-compatible", ["Claude Code, Cursor…", "chave sk_ em /v1/*"], "ext"),
     ("ntfy", "Clientes", 3, "ntfy (push)", ["alertas do Cobrador e de prazos"], "ext"),
     ("nginx", "VPS (Docker)", 0, "nginx + certbot", ["TLS, /api, /v1, /esteira/"], "api"),
     ("back", "VPS (Docker)", 1, "backend (FastAPI)", ["auth · /v1 · /api/notas · /api/arquivos", "/api/<módulo> (routers dos módulos)", "registro de workers (WebSocket)"], "api", 2),
     ("tunel", "VPS (Docker)", 3, "túnel (sshd)", ["recebe o SSH reverso do PC", "publica a esteira como tunel:8765"], "api"),
     ("collab", "VPS (Docker)", 4, "Collabora (CODE)", ["edita DOCX/XLSX/PPTX via WOPI"], "ext"),
     ("worker", "PC em casa (GPU)", 0, "worker", ["cliente WS: chat, jobs, eventos", "llama.cpp · Claude Code · voz · comandos do PC"], "pc", 2),
     ("esteira", "PC em casa (GPU)", 2, "esteira (./dark, :8765)", ["pipeline de vídeos + API /api/v1", "Craft Apps (CLI/MCP)"], "pc", 2),
     ("llm", "PC em casa (GPU)", 4, "llama-server (llama.cpp)", ["modelos GGUF em ~/agent-data/modelos", "+ adaptadores LoRA por app"], "ia"),
     ("dvps", "Dados e serviços", 0, "$AGENT_DATA na VPS", ["volume agent-data: JSON/JSONL/Markdown", "por módulo: <módulo>/…"], "dados", 2),
     ("dpc", "Dados e serviços", 2, "~/agent-data no PC + vault", ["projetos, acervo, dataset, modelos", "vault Obsidian (roteiros, notas)"], "dados", 2),
     ("drive", "Dados e serviços", 4, "Google Drive", ["backup por módulo (rclone)", "atual + versões (7/4/12)"], "ext")],
    [("cli", "nginx", "HTTPS + JWT"), ("oai", "nginx", "HTTPS sk_"), ("nginx", "back", ""), ("back", "dvps", "lê/grava"),
     ("worker", "back", "WebSocket (o PC inicia)"), ("esteira", "tunel", "SSH reverso"), ("nginx", "tunel", "/esteira/"),
     ("back", "collab", "WOPI"), ("worker", "llm", "inferência"), ("esteira", "llm", "inferência"), ("esteira", "dpc", ""),
     ("dpc", "drive", "backup diário"), ("back", "ntfy", "push")],
    ("Princípios", ["• Nenhuma porta aberta em casa: o PC abre o WebSocket e o túnel.", "• Sem banco central: arquivos por módulo;",
                    "  SQLite só como índice reconstruível.", "• Claude só pelo Claude Code (claude -p) no PC.",
                    "• GPU serializada: uma vaga pesada por vez", "  (nucleo/travas.py).", "• Segredos fora do git (.env, google/)."])))

# ---------------------------------------------------------------- 2. plataforma
P.append(pagina("1 · Plataforma", "Plataforma: backend, worker, protocolo e app principal",
    [APP, VPS, PC, DADOS],
    [("shell", APP, 0, "plataforma/app", ["shell, navegação, tela Modelo de IA", "atualização do app, desligar PC"], "app"),
     ("core", APP, 1, "app_core / app_notas", ["Modulo, ApiCliente, Sondagem, tema", "editor de notas, relações"], "app"),
     ("auth", VPS, 0, "auth", ["scrypt + TOTP + JWT HS256"], "api"),
     ("v1", VPS, 1, "/v1 (OpenAI-compatible)", ["chat/models → worker ou Claude"], "api"),
     ("ws", VPS, 2, "/ws + worker_registry", ["WorkerHello, Heartbeat (CPU/RAM/GPU)", "ChatRequest/Response, WorkerEvent, jobs"], "api"),
     ("notas", VPS, 3, "/api/notas (cofre)", ["Markdown + frontmatter YAML", "índice em memória, [[backlinks]]"], "api"),
     ("inet", VPS, 4, "internet/ferramentas", ["FIPE, moedas, B3, Selic/IPCA, busca web"], "api"),
     ("wk", PC, 2, "worker (ws_client)", ["providers/llamacpp: sobe/troca o llama-server", "codigo.* · contas.* · voz · pc"], "pc", 2),
     ("cc", PC, 4, "shared/claude_code", ["claude -p (assinatura do PC)", "várias contas (CLAUDE_CONFIG_DIR)"], "ia"),
     ("dnotas", DADOS, 3, "cofre de notas", ["$AGENT_DATA/notas/**.md"], "dados"),
     ("dmod", DADOS, 0, "modelos GGUF", ["~/agent-data/modelos"], "dados")],
    [("shell", "auth", "login"), ("core", "notas", "CRUD de notas"), ("shell", "v1", "chat"), ("v1", "ws", "encaminha"),
     ("ws", "wk", "chat_request / job"), ("wk", "ws", "eventos, heartbeat"), ("notas", "dnotas", ""), ("wk", "dmod", "carrega"),
     ("wk", "cc", "tarefas Claude")],
    ("Contratos", ["• backend de módulo = pacote uv agent-<m>", "  com APIRouter montado em /api/<m>.",
                   "• worker de módulo registra executores", "  por tipo de job (<m>.<ação>).",
                   "• app de módulo = pacote Flutter agent_<m>", "  que exporta suas rotas (pub workspace).",
                   "• Troca de modelo bloqueada (409) enquanto", "  outro módulo usa o LLM."])))

# ---------------------------------------------------------------- 3. empreendimento: esteira
P.append(pagina("2 · Empreendimento · esteira", "Empreendimento: esteira de vídeos (roteiro + narração → vídeo final)",
    ["Entradas", "Etapas (./dark <etapa> <canal-NNN>)", "Craft Apps / IA", DADOS],
    [("rot", "Entradas", 0, "Roteiro (vault Obsidian)", ["Notas/Empreendimento/YouTube/<canal>", "citações > [!cite] com DOI"], "ext"),
     ("wav", "Entradas", 1, "Narração (WAV) ou câmera", ["modo dark ou apresentador"], "ext"),
     ("perf", "Entradas", 2, "Perfil do canal", ["perfis/<canal>.toml + config.toml", "estilo do Estúdio"], "ext"),
     ("app", "Entradas", 4, "App (aba Empreendimento)", ["fila, monitor, episódio, editor,", "Estúdio, Dataset, Opções"], "app", 2),
     ("tr", "Etapas (./dark <etapa> <canal-NNN>)", 0, "transcrever · limpar · cortes", ["faster-whisper, alinhamento forçado", "bordas no silêncio, retakes, gaguejos"], "pc"),
     ("cen", "Etapas (./dark <etapa> <canal-NNN>)", 1, "cenas · curar", ["divide em cenas, curadoria por LLM"], "pc"),
     ("bus", "Etapas (./dark <etapa> <canal-NNN>)", 2, "buscar · avaliar", ["bancos abertos; acervo antes das APIs", "visão local dá nota à mídia"], "pc"),
     ("gra", "Etapas (./dark <etapa> <canal-NNN>)", 3, "graficos / Estúdio", ["peças de motion graphics (HTML/EC)", "direção escolhe peça por momento"], "pc"),
     ("mon", "Etapas (./dark <etapa> <canal-NNN>)", 4, "montar · thumb", ["N1 FilmCraft → projeto e render", "N1 PhotoCraft → thumbs A/B"], "pc"),
     ("llm", "Craft Apps / IA", 0, "llama.cpp local", ["por operação (Opções)", "gramática JSON pelo esquema"], "ia"),
     ("cl", "Craft Apps / IA", 1, "Claude Code (claude -p)", ["vaga 'claude' em paralelo", "limite de cota (Opções)"], "ia"),
     ("ec", "Craft Apps / IA", 3, "EffectCraft", ["peça N1 → script JSX → render"], "ext"),
     ("fc", "Craft Apps / IA", 4, "FilmCraft · PhotoCraft", ["MCP / <app>-cli headless"], "ext"),
     ("proj", DADOS, 0, "projetos/<canal>/<NNN>/", ["transcrição, cortes, cenas, mídia,", "gráficos, .fcproj, vídeo final"], "dados", 2),
     ("acv", DADOS, 2, "acervo/ (SQLite + FTS5)", ["todo download com metadados", "notas de visão (não refaz)"], "dados"),
     ("cache", DADOS, 3, "cache/", ["rastro.jsonl, opcoes.json, fila,", "processos.jsonl, cota_claude.json"], "dados"),
     ("ds", DADOS, 4, "dataset/ (ver aba 3)", ["cada decisão vira registro N1"], "dados")],
    [("rot", "tr", ""), ("wav", "tr", ""), ("tr", "cen", ""), ("cen", "bus", ""), ("bus", "gra", ""), ("gra", "mon", ""),
     ("perf", "gra", "estilo"), ("cen", "llm", ""), ("bus", "acv", "consulta/grava"), ("gra", "ec", ""), ("mon", "fc", ""),
     ("tr", "proj", ""), ("mon", "proj", "vídeo final"), ("mon", "ds", ""), ("app", "cache", "API :8765 /api/v1"), ("cen", "cl", "")],
    ("Regras de execução", ["• Uma vaga pesada por vez (travas.py);", "  a vaga 'claude' roda em paralelo.",
                            "• Rastro e eventos → Monitor/grafo do app.", "• Gráfico editado à mão vira manual: true.",
                            "• Configuração: config.toml ← perfil ←", "  config.toml do projeto.",
                            "• Shorts 9:16: id canal-NNNx."])))

# ---------------------------------------------------------------- 4. empreendimento: N1, dataset e fábrica
P.append(pagina("3 · Empreendimento · N1, dataset e fábrica", "Empreendimento: vocabulário N1, dataset das Craft Apps, fábrica de peças e fine-tuning",
    ["Quem decide", "N1 (esteira/n1)", "Dataset (esteira/dataset)", "Treino / modelos"],
    [("cla", "Quem decide", 0, "Claude Code", ["cria ideias em lote (ficha + conceito)", "revisa a prova: problema, causa, regra"], "ia", 2),
     ("loc", "Quem decide", 2, "LLM local (gemma-4)", ["escreve o N1 da peça (porte e ideias)", "até 4 rodadas com o erro do portão"], "ia"),
     ("pes", "Quem decide", 3, "Pessoa (app)", ["aprova/reprova peças, montagem e thumb", "edições manuais no FilmCraft/PhotoCraft"], "app"),
     ("ec", "N1 (esteira/n1)", 0, "effectcraft.py", ["Peca: texto, retângulo, elipse/arco,", "repetir (grade, ativos, fatias), animações", "→ compilador → JSX + núcleo (caber)"], "pc", 2),
     ("fc", "N1 (esteira/n1)", 2, "filmcraft.py", ["Montagem: ops por trilha (V1–V4, A1–A3)", "→ executor → comandos MCP"], "pc"),
     ("pc", "N1 (esteira/n1)", 3, "photocraft.py", ["Composição declarativa, layout relacional", "tratamento [foto] + FotoDecisao"], "pc"),
     ("gate", "N1 (esteira/n1)", 4, "Portão + guia", ["esquema, compila, área segura, visão local", "GUIA_N1_EC.md + Lições (do Claude)"], "pc"),
     ("reg", "Dataset (esteira/dataset)", 0, "registro/<app>/<tarefa>/AAAA-MM.jsonl", ["só acrescenta; contexto, saída N1,", "portão, origem, versões"], "dados", 2),
     ("art", "Dataset (esteira/dataset)", 2, "artefatos/ (por sha256)", ["prompts e N1 grandes"], "dados"),
     ("idx", "Dataset (esteira/dataset)", 3, "indice.db (SQLite)", ["reconstruível; situação por tarefa"], "dados"),
     ("exp", "Dataset (esteira/dataset)", 4, "exportar", ["SFT / DPO / eval (ouro), manifesto", "split por grupo; montar em trechos de 45 s"], "dados"),
     ("tr", "Treino / modelos", 0, "treino_app (QLoRA, unsloth)", ["base ≤ 12B (gemma-4-12b-it)", ".venv-treino; worker parado (VRAM)"], "pc", 2),
     ("ad", "Treino / modelos", 2, "adaptadores/<app>-vN.gguf", ["+ manifesto (perdas, hash da exportação)"], "dados"),
     ("ban", "Treino / modelos", 3, "bancada (n1_*)", ["base × candidato no ouro", "promove <app>-atual só se ganhar"], "pc"),
     ("pre", "Treino / modelos", 4, "llama-server --models-preset", ["base + LoRA por app → inferir.gerar"], "ia")],
    [("cla", "loc", "ideias"), ("loc", "ec", "peca.n1.json"), ("ec", "gate", ""), ("gate", "cla", "passou → revisão"),
     ("cla", "gate", "regras → Lições"), ("gate", "reg", "rodada + veredito"), ("pes", "reg", "vereditos / edições"),
     ("fc", "reg", "montar"), ("pc", "reg", "thumb"), ("reg", "idx", ""), ("reg", "art", ""), ("idx", "exp", ""),
     ("exp", "tr", "SFT"), ("tr", "ad", ""), ("ad", "ban", ""), ("ban", "pre", "promovido")],
    ("Camadas", ["• N2: decisão de alto nível (o que mostrar).", "• N1: vocabulário por app (JSON validado,", "  gramática do llama.cpp).",
                 "• N0: comandos das Craft Apps.", "• Executor/compilador determinístico", "  N1 → N0 (equivalência provada).",
                 "• Mínimos para treinar: peca_animar 500,", "  montar 1500 trechos, thumb 300…"])))

# ---------------------------------------------------------------- 5. youtube
P.append(pagina("4 · Empreendimento · YouTube", "Empreendimento: canais do YouTube como notas do cofre",
    [APP, VPS, DADOS],
    [("ca", APP, 0, "aba Canais (lib/src/youtube)", ["youtube_aba → canal_tela → item_tela", "formulário montado pelo esquema"], "app", 2),
     ("api", VPS, 0, "/api/youtube (youtube/api.py)", ["canais.py: um canal = pasta do cofre", "esquema.py: coleções e campos"], "api", 2),
     ("imp", VPS, 2, "python -m youtube.importar", ["copia o vault para o cofre"], "api"),
     ("cof", DADOS, 0, "cofre: YouTube/<canal>/", ["nota do canal (tipo: canal)", "Temas · História · Roteiros · Método"], "dados", 2),
     ("vault", DADOS, 2, "vault Obsidian", ["Notas/Empreendimento/YouTube/**.md"], "ext")],
    [("ca", "api", "HTTPS + JWT"), ("api", "cof", "Markdown"), ("vault", "imp", ""), ("imp", "cof", "")],
    ("Canais", ["finlumia · benehistory · cosmoatomico", "embarcados · thiagobenevide", "", "Nada fica fora do Markdown;",
                "as notas também aparecem em /api/notas."])))


def modulo(aba, titulo, telas, rotas, pc, dados, setas, nota):
    raias = [APP, VPS] + ([PC] if pc else []) + [DADOS]
    caixas = [(f"a{i}", APP, i, t, d, "app") for i, (t, d) in enumerate(telas)]
    caixas += [(f"b{i}", VPS, i, t, d, "api") for i, (t, d) in enumerate(rotas)]
    caixas += [(f"p{i}", PC, i, t, d, k) for i, (t, d, k) in enumerate(pc or [])]
    caixas += [(f"d{i}", DADOS, i, t, d, "dados") for i, (t, d) in enumerate(dados)]
    P.append(pagina(aba, titulo, raias, caixas, setas, nota))


modulo("5 · Arquivos", "Arquivos: biblioteca de estudo com anotações e edição",
       [("Leitor e anotações", ["PDF com tinta, destaques com texto", "projetos de leitura"]), ("Editores", ["DOCX (revisões), XLSX, PPTX", "Exportar ODT/PDF/CSV/Markdown"])],
       [("/api/arquivos (biblioteca)", ["meta.json, original, documento.pdf", "LibreOffice converte DOCX/PPTX"]), ("WOPI → Collabora", ["edição colaborativa do original"]),
        ("reescrita · mapeamento", ["reescrita de trechos (TCC)", "mapa reverso de citações"])],
       [("Claude Code (worker)", ["claude_json no PC"], "ia")],
       [("arquivos/<id>/", ["meta.json · original.<ext> · documento.pdf", "anotações"])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("b0", "d0", ""), ("b1", "d0", "lê/grava original"), ("b2", "p0", "job"), ("a1", "b2", "")],
       ("Fluxo", ["Upload → conversão para PDF → leitor.", "Trechos marcados alimentam os projetos", "de leitura (módulo Estudos)."]))

modulo("6 · Estudos", "Estudos: leituras, projetos de leitura, idiomas e notas",
       [("Leituras e projetos", ["livros/artigos, trechos marcados"]), ("Idiomas A1–C2", ["trilhas e sessões"]), ("Notas", ["editor com backlinks (app_notas)"])],
       [("/api/estudos", ["estudos.py · projetos.py"]), ("idiomas.py", ["cronograma por regras fixas", "(horas guiadas do QECR)"]), ("/api/notas", ["sínteses e anotações"])],
       None,
       [("estudos/*.json", ["leituras.json · idiomas.json · projetos.json"]), ("arquivos/", ["anotações com campo projetos"]), ("cofre de notas", ["Markdown"])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("a2", "b2", ""), ("b0", "d0", ""), ("b1", "d0", ""), ("b0", "d1", "trechos"), ("b2", "d2", "")],
       ("Observação", ["Sem LLM no cronograma de idiomas:", "regras a partir do nível, minutos/dia", "e dias da semana."]))

modulo("7 · Saúde", "Saúde: físico, mental e espiritual",
       [("Treinos", ["agenda, séries, carga"]), ("Mental", ["hábitos, foco, diário"]), ("Espiritual", ["planos de leitura bíblica"])],
       [("/api/saude (treinos)", ["catálogo da mini-academia", "imagens do free-exercise-db"]), ("/api/saude/mental", ["hábitos, pomodoro, humor"]), ("/api/saude/espiritual", ["escopo dividido em N dias"])],
       None,
       [("saude/", ["exercicios.json · agenda.json · imagens/"]), ("saude/mental/", ["habitos.json · foco.json · diario.json"]), ("saude/planos.json + notas", ["reflexões no cofre"])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("a2", "b2", ""), ("b0", "d0", ""), ("b1", "d1", ""), ("b2", "d2", "")],
       ("Observação", ["Tudo em JSON na pasta do módulo;", "reflexões e teologia como notas."]))

modulo("8 · Rotinas", "Rotinas: Kanban com temporizador",
       [("Quadro Kanban", ["pendente · execução · concluída", "cronômetro por tarefa"])],
       [("/api/rotinas (quadro.py)", ["ordem por coluna, sessões de tempo"])],
       None,
       [("rotinas/tarefas.json", ["sessões {inicio, fim} em ISO UTC"])],
       [("a0", "b0", ""), ("b0", "d0", "")],
       ("Integração", ["O Painel (Cobrador) lê as tarefas", "para medir desempenho e agenda."]))

modulo("9 · Design", "Design: quadro branco, fluxogramas e wireframes",
       [("Quadro branco", ["caneta com pressão, formas, textos"]), ("Fluxos e wireframes", ["gerados ou ajustados pela IA"])],
       [("/api/design (quadros.py)", ["quadros em JSON"]), ("fluxos · wireframe_ia", ["LLM decide só a estrutura (JSON)"]), ("drawio · imagens", [".drawio ↔ quadro; Google Imagens"])],
       [("LLM (worker)", ["estrutura de blocos e ligações"], "ia")],
       [("design/quadros/<id>.json", ["+ wireframes/"])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("b1", "p0", ""), ("b0", "d0", ""), ("b2", "d0", "importa/exporta")],
       ("Observação", ["Layout do fluxo é calculado no código;", "a IA só devolve blocos e ligações."]))

modulo("10 · Eletrônica", "Eletrônica: CAD de circuitos (esquemático, ERC, simulação)",
       [("Editor de esquemático", ["componentes, fios, rótulos, folhas"]), ("Bibliotecas", ["símbolos (KiCad .kicad_sym)"]), ("Simulação", ["resultados ngspice"])],
       [("/api/eletronica (projetos)", ["netlist.py, BOM, erc.py"]), ("bibliotecas · kicad.py", ["KiCad mm/y↑ → µm/y↓"]), ("simulacao · spice.py", ["netlist → executor"])],
       [("worker: ngspice", ["shared/ngspice.py"], "pc")],
       [("eletronica/projetos/<id>.json", []), ("eletronica/bibliotecas/<lib>.json", [])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("a2", "b2", ""), ("b0", "d0", ""), ("b1", "d1", ""), ("b2", "p0", "job")],
       ("Fases", ["1: esquemático (pronto)", "2: placa", "3: simulação no worker"]))

modulo("11 · Código", "Código: Claude Code a distância no repositório",
       [("Abas (sessões)", ["pedido + imagens de referência", "etapas ao vivo"])],
       [("/api/codigo (sessoes.py)", ["meta.json, eventos.jsonl"])],
       [("worker: codigo.*", ["enviar · parar · arvore · arquivo", "lê o stream-json"], "pc"), ("Claude Code no repo", ["claude -p --resume (por aba)", "carrega o CLAUDE.md"], "ia")],
       [("codigo/sessoes/<id>/", ["meta.json · eventos.jsonl · imagens/"])],
       [("a0", "b0", ""), ("b0", "p0", "job codigo.enviar"), ("p0", "p1", ""), ("p0", "b0", "WorkerEvent (etapas)"), ("b0", "d0", "")],
       ("Observação", ["Várias abas rodam ao mesmo tempo;", "contas do Claude trocáveis pelo app", "(contas.*)."]))

modulo("12 · Concursos", "Concursos: editais, plano de estudo, radar e vagas",
       [("Concursos", ["Hoje, Cronograma, Fluxo, Prazos"]), ("Radar e rumores", ["concursos de TI abertos"]), ("Vagas e currículos", ["lista + currículos em Markdown"])],
       [("/api/concursos", ["plano_ia → estrutura do estudo", "cronograma até 1 semana antes"]), ("radar · rumores · geo", ["PCI Concursos, IBGE, OSRM"]), ("/api/vagas", ["curriculos.py"])],
       [("Claude Code", ["lê o edital, pesquisa vagas"], "ia"), ("LLM local", ["lê notícias do radar"], "ia")],
       [("concursos/<id>/", ["edital, plano, calendário"]), ("concursos/radar/", ["rotas/ (cache)"]), ("vagas/curriculos/<id>.md", [])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("a2", "b2", ""), ("b0", "p0", "claude_json"), ("b1", "p1", ""), ("b2", "p0", ""),
        ("b0", "d0", ""), ("b1", "d1", ""), ("b2", "d2", "")],
       ("Alertas", ["Prazos aparecem no app e vão", "por push (ntfy do Painel)."]))

modulo("13 · Finanças", "Finanças: extratos, orçamento, cenários e empresas (CVM)",
       [("Extratos e orçamento", ["OFX/CSV, categorias, 50/30/20"]), ("Cenários", ["comprar à vista × financiar"]), ("Empresas", ["DRE, balanço, indicadores"])],
       [("/api/financas (extrato, relatorios)", ["regras de categorização"]), ("cenarios · ia", ["LLM só interpreta texto;", "as contas são do código"]), ("cvm · analise", ["DFP/ITR/FCA (dados abertos)"])],
       [("LLM (worker)", ["extratos estranhos, categorias"], "ia")],
       [("financas/<colecao>.json", ["armazem.py: esquema por coleção"]), ("cache CVM", ["demonstrativos baixados"])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("a2", "b2", ""), ("b1", "p0", ""), ("b0", "d0", ""), ("b2", "d1", "")],
       ("Observação", ["Sem chave de API na CVM.", "Questionário de setores editável pelo app."]))

modulo("14 · Painel", "Painel: uso das LLMs, Cobrador e alertas",
       [("Dashboard", ["latência, erros, tokens por provedor"]), ("Cobrador", ["metas, agenda do dia, contestação"])],
       [("medidor.py", ["uso.jsonl + memória"]), ("cobrador · agente · desempenho", ["agente pede ações num bloco acoes", "desempenho por janela de dias"]), ("notificador.py", ["alertas novos → ntfy (1×/dia)"])],
       [("LLM (worker ou Claude)", ["redige cobranças"], "ia")],
       [("painel/", ["uso.jsonl · metas · agenda · enviados"]), ("notas (status, prazo, cobra)", ["metas/tarefas do cofre"])],
       [("a0", "b0", ""), ("a1", "b1", ""), ("b1", "p0", ""), ("b0", "d0", ""), ("b1", "d1", "lê"), ("b2", "d0", "")],
       ("Fontes", ["requisições do gateway, rastro da esteira,", "tarefas (Rotinas) e notas com prazo."]))

P.append(pagina("15 · Infra e backup", "Infraestrutura, implantação e backup",
    ["Scripts (infra/scripts)", "VPS", "PC (systemd --user)", "Destinos"],
    [("inst", "Scripts (infra/scripts)", 0, "instalar_vps · atualizar_vps", ["Docker, segredos, nginx, TLS (idempotente)"], "ext"),
     ("con", "Scripts (infra/scripts)", 1, "conectar_vps", ["worker + túnel como serviços"], "ext"),
     ("pub", "Scripts (infra/scripts)", 2, "publicar_app · empacotar_linux", ["atualização dos apps"], "ext"),
     ("bk", "Scripts (infra/scripts)", 3, "backup", ["--instalar · --testar · --restaurar", "rclone sync por módulo"], "ext"),
     ("ver", "Scripts (infra/scripts)", 4, "verificar", ["ruff · pytest · flutter analyze do que mudou"], "ext"),
     ("dc", "VPS", 0, "docker-compose", ["gateway · tunel · collabora · nginx · certbot"], "api", 2),
     ("svc", "PC (systemd --user)", 0, "agent-worker · agent-esteira · agent-tunel", ["serviços do usuário"], "pc", 2),
     ("tim", "PC (systemd --user)", 3, "agent-backup.timer (03:30)", ["+ agent-backup-teste.timer (mensal)"], "pc"),
     ("gd", "Destinos", 3, "gdrive:<módulo>/atual", ["versoes/<data> (7 diárias, 4 semanais, 12 mensais)"], "dados", 2),
     ("est", "Destinos", 0, "plataforma/backup.json", ["estado do último backup (app)"], "dados")],
    [("inst", "dc", ""), ("con", "svc", ""), ("tim", "bk", "dispara"), ("bk", "gd", "rclone"), ("bk", "est", "")],
    ("Observação", ["OAuth próprio do rclone (remote gdrive).", "Conta de serviço não envia arquivos.", "VPS opcional no backup (BACKUP_VPS)."])))

xml = '<?xml version="1.0" encoding="UTF-8"?>\n<mxfile host="app.diagrams.net" type="device">' + "".join(P) + "</mxfile>\n"
with open(sys.argv[1], "w") as saida:
    saida.write(xml)
print(len(P), "abas")
