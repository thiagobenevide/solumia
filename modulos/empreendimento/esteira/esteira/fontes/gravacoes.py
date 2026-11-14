"""Acha o WAV exportado de um roteiro em `~/Music/Youtube/<Canal>/...` (e, no modo apresentador, o vídeo
da câmera na mesma pasta: `exts=producao.VIDEO_EXT`).

Os nomes das pastas não seguem um padrão fixo (a pasta "002 - ..." pode guardar o episódio 003), então cada
WAV recebe uma nota: número do episódio no caminho + semelhança do título. Takes da sessão (pastas
"Audio Files") valem um pouco menos que um WAV exportado. A tela mostra os candidatos para a escolha final.
"""
import re
import unicodedata
from difflib import SequenceMatcher
from pathlib import Path


def _norm(s):
    s = unicodedata.normalize("NFKD", s.lower())
    return re.sub(r"[^a-z0-9 ]", " ", "".join(c for c in s if not unicodedata.combining(c)))


def _numero_do_caminho(rel):
    """Número do episódio pela pasta/arquivo mais profundo que tem um (a pasta "002 - ..." pode conter a
    sessão "finlumia_003_..."). Takes genéricos ("Audio 1_01") e a pasta "Audio Files" não contam."""
    partes = [p for p in Path(rel).with_suffix("").parts if p != "Audio Files"]
    for parte in reversed(partes):
        if re.match(r"(?i)^audio\s*\d+_\d+$", parte):
            continue
        achados = re.findall(r"\b(\d{1,3})\b", _norm(parte))
        if achados:
            return {int(x) for x in achados}
    return set()


def candidatos(raiz, canal, numero, titulo, n=5, short=False, exts=(".wav",)):
    """[{caminho, nota, mb, modificado}] do mais provável para o menos. O WAV de um Short tem "short" no
    caminho (ex.: `<Canal>/Shorts/005a - ...`); o do vídeo longo, não."""
    raiz = Path(raiz).expanduser()
    pastas = [p for p in raiz.iterdir() if p.is_dir() and _norm(p.name).strip() == _norm(canal).strip()] \
        if raiz.exists() else []
    saida = []
    for pasta in pastas:
        for wav in (f for f in pasta.rglob("*") if f.suffix.lower() in exts):
            rel = _norm(str(wav.relative_to(pasta)))
            nums = _numero_do_caminho(wav.relative_to(pasta))
            nota = (0.6 if numero in nums else 0) + 0.4 * SequenceMatcher(None, _norm(titulo), rel).ratio()
            nota -= 0.1 if "Audio Files" in wav.parts else 0
            nota += 0.3 if ("short" in rel) == short else -0.3
            st = wav.stat()
            saida.append({"caminho": str(wav), "nota": round(nota, 3), "mb": round(st.st_size / 1e6, 1),
                          "modificado": st.st_mtime})
    return sorted(saida, key=lambda c: (-c["nota"], -c["modificado"]))[:n]


def atualizar(projeto):
    """Antes do limpar: se em `~/Music/Youtube/<Canal>/` há um WAV do episódio mais novo que a gravação já
    usada, copia-o como `narracao.wav` (o limpar o trata como gravação nova). A origem fica em
    `origem_audio.json`; WAV ainda sendo gravado (mexido há menos de 1 min) é ignorado."""
    import json
    import shutil
    import time

    rot = projeto.caminho("roteiro.json")
    if not rot.exists() or projeto.cfg.get("producao", {}).get("modo") == "apresentador":
        return None  # apresentador: câmera e WAV são sincronizados na importação
    r = json.loads(rot.read_text())
    cands = [c for c in candidatos(projeto.cfg["fontes"]["gravacoes"], r["canal"], r["numero"], r["titulo"],
                                   short=bool(r.get("short")))
             if c["nota"] >= 0.5 and time.time() - c["modificado"] > 60]
    if not cands:
        return None
    novo = max(cands, key=lambda c: c["modificado"])
    st = Path(novo["caminho"]).stat()
    origem = {"caminho": novo["caminho"], "tamanho": st.st_size, "modificado": st.st_mtime}
    reg = projeto.caminho("origem_audio.json")
    if reg.exists():
        ant = json.loads(reg.read_text())
        if (ant["caminho"], ant["tamanho"]) == (novo["caminho"], st.st_size) or st.st_mtime <= ant["modificado"]:
            return None
    else:  # episódio importado antes deste registro: compara com a gravação que está no projeto
        atual = next(iter(sorted(projeto.pasta.glob("narracao_bruta.*"))), None) or \
            next((p for p in sorted(projeto.pasta.glob("narracao.*")) if p.suffix.lower() == ".wav"), None)
        if atual and atual.stat().st_size == st.st_size:  # é a mesma gravação: só registra a origem
            reg.write_text(json.dumps(origem, ensure_ascii=False))
            return None
        if atual and st.st_mtime <= atual.stat().st_mtime:
            return None
    shutil.copy(novo["caminho"], projeto.caminho("narracao.wav"))  # mtime novo: o limpar vê como gravação nova
    reg.write_text(json.dumps(origem, ensure_ascii=False))
    return Path(novo["caminho"])
