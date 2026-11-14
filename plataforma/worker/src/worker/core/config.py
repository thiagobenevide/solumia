from functools import lru_cache
from typing import Literal

from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class WorkerSettings(BaseSettings):
    """Configuração do Worker, lida de variáveis de ambiente (prefixo WORKER_)."""

    model_config = SettingsConfigDict(
        env_prefix="WORKER_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    name: str = "worker-local"
    """Nome exibido nos logs do Gateway e nos logs locais deste Worker."""

    gateway_url: str = "ws://localhost:48080/ws/worker"
    """Endpoint WebSocket do Gateway. Use wss:// em produção (atrás do nginx/TLS)."""

    api_key: SecretStr = SecretStr("")
    """Deve ser um dos valores presentes em GATEWAY_WORKER_API_KEYS no Gateway."""

    llama_server_bin: str = "llama-server"
    """Executável do llama.cpp (no PATH ou caminho completo)."""

    modelos_dir: str = "~/agent-data/modelos"
    """Pasta com os `.gguf`; cada arquivo é um modelo que o app pode escolher."""

    llama_porta: int = 8081
    """Porta local do llama-server (só 127.0.0.1)."""

    llama_args: str = "--models-max 1 --fit on -c 16384 --jinja --sleep-idle-seconds 600"
    """Argumentos do roteador: um modelo na VRAM por vez, camadas na GPU, contexto, template de chat
    e descarga após 10 min parado. Valem também quando a esteira sobe o servidor."""

    provider_timeout_seconds: float = 120.0
    """Timeout aguardando resposta do llama-server por requisição."""

    heartbeat_interval_seconds: int = 20
    reconnect_min_backoff_seconds: float = 1.0
    reconnect_max_backoff_seconds: float = 30.0

    # --- Voz (tarefas `transcrever` e `falar`) ---
    whisper_modelo: str = ""
    """Modelo do faster-whisper (tiny … large-v3, large-v3-turbo); vazio = large-v3-turbo na GPU e
    small na CPU."""

    whisper_dispositivo: str = "auto"
    """`cuda`, `cpu` ou `auto` (GPU se as libs CUDA carregarem: extra `voz-gpu`; senão CPU)."""

    whisper_prompt: str = (
        "Conversa em português do Brasil com o Cobrador, um assistente de agenda, metas e tarefas. "
        "Anote, pesquise na base, disciplina, compromisso, reunião, academia, estudo."
    )
    """Contexto inicial do Whisper: acerta os termos do app em vez de palavras parecidas."""

    fala_max_caracteres: int = 1200
    """Resposta lida em voz alta é cortada no fim da frase perto daqui (texto longo demora)."""

    voz_idioma: str = "pt"
    """Idioma quando a detecção falha."""

    voz_idiomas: str = "pt,en"
    """Idiomas aceitos na fala: o Whisper detecta só entre eles (um só = sem detecção)."""

    whisper_beam: int = 1
    """1 = busca gulosa (rápida); 5 acerta um pouco mais em áudio ruim e demora 2–3x."""

    whisper_aquecer: bool = True
    """Carrega o Whisper ao ligar o worker, em vez de na primeira fala."""

    xtts_python: str = ""
    """Python do venv do XTTS-v2 (`infra/scripts/instalar_xtts`); vazio = `xtts/.venv` do worker.
    Sem o venv, a fala usa o Kokoro."""

    pronuncia_python: str = ""
    """Python com torch + transformers para a pronúncia por fonema (wav2vec2); vazio = o mesmo
    venv do XTTS. Sem ele, a leitura em voz alta avalia só palavras, ritmo e pausas."""

    xtts_voz: str = "Ana Florence"
    """Locutora do XTTS: a mais clara e natural em pt-BR nos testes (Whisper + UTMOS)."""

    xtts_referencia: str = "~/agent-data/modelos/voz/referencia_ptbr.wav"
    """Gravação de 10–30 s de uma voz brasileira; existindo, o XTTS clona ela no lugar da
    locutora (as embutidas não são brasileiras e puxam o sotaque para Portugal)."""

    kokoro_modelo: str ="~/agent-data/modelos/voz/kokoro-v1.0.onnx"
    kokoro_vozes: str = "~/agent-data/modelos/voz/voices-v1.0.bin"
    """Kokoro (extra `voz`): pronúncia pt-BR bem mais clara que o Piper; sem os arquivos, usa o
    Piper."""

    kokoro_voz: str = "pf_dora"
    """`pf_dora` (mulher), `pm_alex` ou `pm_santa` (homens)."""

    kokoro_velocidade: float = 1.0

    piper_bin: str = "piper"
    piper_modelo: str = ""
    """Arquivo .onnx de uma voz pt_BR do Piper (reserva do Kokoro); vazio = usa o espeak-ng."""

    piper_lentidao: float = 1.15
    """`--length-scale` do Piper: acima de 1 fala mais devagar e embola menos."""

    espeak_bin: str = "espeak-ng"
    espeak_voz: str = "pt-br"

    # --- Código (sessões do Claude Code pedidas pelo app) ---
    codigo_dir: str = "~/Documents/github/agent"
    """Repositório onde o `claude` roda (carrega o CLAUDE.md de lá)."""

    codigo_claude_bin: str = "claude"
    codigo_permissao: str = "bypassPermissions"
    """`--permission-mode` do Claude Code. `bypassPermissions`: qualquer comando, sem aprovação
    (não há ninguém no terminal). `acceptEdits` restringe os comandos a `codigo_ferramentas`."""

    codigo_ferramentas: str = (
        "Bash(infra/scripts/verificar:*),Bash(git status:*),Bash(git diff:*),Bash(git log:*),"
        "Bash(git add:*),Bash(git commit:*),Bash(git push:*),Bash(grep:*),Bash(rg:*),Bash(wc:*),"
        "Bash(sed -n:*),Bash(ls:*),Bash(find:*),Bash(jq:*),Bash(head:*),Bash(tail:*),"
        "Bash(uv sync:*),Bash(~/development/flutter/bin/flutter pub get:*),"
        "Bash(infra/scripts/publicar_app:*),Bash(infra/scripts/atualizar_vps:*)"
    )
    """`--allowedTools` (separados por vírgula): comandos liberados sem aprovação."""

    codigo_ferramentas_proibidas: str = (
        "Bash(sudo:*),Bash(su:*),Bash(ssh:*),Bash(scp:*),Bash(sftp:*),Bash(rsync:*),"
        "Bash(curl:*),Bash(wget:*),Bash(nc:*),Bash(ncat:*),Bash(rclone:*),"
        "Bash(rm -rf /:*),Bash(rm -rf ~:*),Bash(rm -rf $HOME:*),"
        "Bash(git push --force:*),Bash(git push -f:*),Bash(git remote:*),"
        "Read(~/.ssh/**),Edit(~/.ssh/**),Read(~/.config/rclone/**),Read(~/.config/agent/**),"
        "Read(~/agent-data/claude/**),Read(~/agent-data/emails/**),Read(**/.env),Read(**/.env.*),"
        "Edit(**/.env),Edit(**/.env.*),Read(**/client_secret*.json),Read(**/service-account.json)"
    )
    """`--disallowedTools`: valem mesmo em `bypassPermissions`. Barram tirar dados do PC (rede,
    chaves, credenciais) e estragos sem volta; é uma camada a mais, a trava principal é o código
    do Authenticator que o backend exige para o Código."""

    codigo_imagens_dir: str = "~/agent-data/codigo/imagens"
    """Imagens de referência enviadas pelo app, uma pasta por sessão."""

    claude_contas_dir: str = "~/agent-data/claude/contas"
    """Contas extras do Claude Code (uma `CLAUDE_CONFIG_DIR` cada) e a ativa, trocada pelo app."""

    log_level: Literal["debug", "info", "warning", "error", "critical"] = "info"
    log_format: Literal["json", "console"] = "console"


@lru_cache
def get_settings() -> WorkerSettings:
    """Retorna a instância cacheada de WorkerSettings (lida uma única vez por processo)."""
    return WorkerSettings()
