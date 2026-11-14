"""Catálogo de fontes do Estúdio: as livres (OFL) que vêm no kit + as enviadas pelo app.

O estilo escolhe uma fonte por papel (títulos, texto, rótulos, legenda); o compilador copia só as usadas para a
produção e gera `assets/fontes.css`. Fonte que não está no catálogo vira aviso (nunca troca escondido).
Enviadas ficam em `$AGENT_DATA/empreendimento/estudio/fontes/` (nome da fonte = nome do arquivo sem extensão).
"""
import re
import shutil
from pathlib import Path

from esteira.project import DATA

KIT = Path(__file__).parent / "kit" / "fonts"
UPLOADED = DATA / "estudio" / "fontes"
DEFAULT = "Plus Jakarta Sans"

# nome → ([(arquivo, pesos[, estilo])], tipo); pesos "100 900" = fonte variável; estilo "italic" = arquivo do itálico
CATALOG = {
    "Plus Jakarta Sans": ([("PlusJakartaSans.ttf", "200 800")], "sem serifa"),
    "Inter": ([("Inter.ttf", "100 900")], "sem serifa"),
    "Montserrat": ([("Montserrat.ttf", "100 900")], "sem serifa"),
    "Poppins": ([("Poppins-Regular.ttf", "400"), ("Poppins-Medium.ttf", "500"), ("Poppins-SemiBold.ttf", "600"),
                 ("Poppins-Bold.ttf", "700"), ("Poppins-ExtraBold.ttf", "800")], "sem serifa"),
    "DM Sans": ([("DMSans.ttf", "100 1000")], "sem serifa"),
    "Outfit": ([("Outfit.ttf", "100 900")], "sem serifa"),
    "Sora": ([("Sora.ttf", "100 800")], "sem serifa"),
    "Space Grotesk": ([("SpaceGrotesk.ttf", "300 700")], "sem serifa"),
    "Bebas Neue": ([("BebasNeue.ttf", "400")], "título condensado"),
    "Anton": ([("Anton.ttf", "400")], "título condensado"),
    "Oswald": ([("Oswald.ttf", "200 700")], "título condensado"),
    "Archivo Black": ([("ArchivoBlack.ttf", "400")], "título pesado"),
    "Anybody": ([("Anybody.ttf", "100 900")], "título expandido"),
    "Playfair Display": ([("PlayfairDisplay.ttf", "400 900"), ("PlayfairDisplay-Italic.woff2", "400 900", "italic")],
                         "serifa"),
    "Lora": ([("Lora.ttf", "400 700")], "serifa"),
    "JetBrains Mono": ([("JetBrainsMono.ttf", "100 800")], "mono"),
}
EXT = (".ttf", ".otf")


def _uploaded():
    return {a.stem: ([(a.name, "100 900")], "enviada") for a in sorted(UPLOADED.glob("*")) if a.suffix.lower() in EXT}


def list_all():
    """[{nome, tipo, arquivos:[...], enviada}] para o seletor do app."""
    everything = {**CATALOG, **_uploaded()}
    return [{"nome": n, "tipo": t, "arquivos": [a for a, _, *it in arqs if not it], "enviada": t == "enviada"}
            for n, (arqs, t) in everything.items()]


def path(arquivo):
    """Arquivo de fonte do kit ou enviado (para a prévia no app); None se não existir."""
    for base in (KIT, UPLOADED):
        p = base / Path(arquivo).name
        if p.is_file():
            return p
    return None


def send(name_file, dados):
    name = Path(name_file).name
    if Path(name).suffix.lower() not in EXT or not re.fullmatch(r"[\w .()+-]{1,80}", name):
        raise ValueError("envie um arquivo .ttf ou .otf com nome simples")
    if dados[:4] not in (b"\x00\x01\x00\x00", b"OTTO", b"true"):
        raise ValueError("o arquivo não parece uma fonte TrueType/OpenType")
    UPLOADED.mkdir(parents=True, exist_ok=True)
    (UPLOADED / name).write_bytes(dados)
    return Path(name).stem


def missing(nomes):
    everything = {**CATALOG, **_uploaded()}
    return sorted({n for n in nomes if n not in everything})


def css(nomes, destino):
    """Copia as fontes usadas para `destino/fonts` e devolve o CSS com os @font-face; fonte fora do catálogo
    cai na padrão (com aviso no log)."""
    from esteira.core import events
    everything = {**CATALOG, **_uploaded()}
    for n in missing(nomes):
        events.warning(f"fonte '{n}' não está no catálogo do Estúdio: usando {DEFAULT} (envie o .ttf pela aba Estúdio)")
        print(f"  ! fonte '{n}' fora do catálogo → {DEFAULT}")
    (destino / "fonts").mkdir(parents=True, exist_ok=True)
    rules = []
    for n in sorted({n if n in everything else DEFAULT for n in nomes}):
        for file, weights, *it in everything[n][0]:
            shutil.copy(path(file), destino / "fonts" / file)
            esticar = " font-stretch: 50% 150%;" if n == "Anybody" else ""
            italico = " font-style: italic;" if it else ""
            rules.append(f'@font-face {{ font-family: "{n}"; src: url("fonts/{file}"); font-weight: {weights};{esticar}{italico} }}')
    return "\n".join(rules) + "\n"


def resolve(nome):
    """Nome que vai para o CSS: o pedido, se existir; senão a padrão."""
    return nome if nome in {**CATALOG, **_uploaded()} else DEFAULT
