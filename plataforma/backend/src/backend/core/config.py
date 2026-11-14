from functools import lru_cache
from typing import Literal

from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Configuração do Gateway, lida de variáveis de ambiente (prefixo GATEWAY_)."""

    model_config = SettingsConfigDict(
        env_prefix="GATEWAY_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_name: str = "LLM Gateway"
    environment: Literal["development", "staging", "production"] = "development"
    debug: bool = False

    host: str = "0.0.0.0"
    port: int = 48080

    log_level: Literal["debug", "info", "warning", "error", "critical"] = "info"
    log_format: Literal["json", "console"] = "console"

    cors_origins: str = "*"

    # --- Segredos ---
    # SecretStr para nunca vazar o valor em logs, repr() ou tracebacks.
    client_api_keys: SecretStr = SecretStr("")
    """Chaves aceitas de clientes OpenAI-compatible (formato sk_live_...), separadas por vírgula."""

    worker_api_keys: SecretStr = SecretStr("")
    """Chaves aceitas de workers (formato worker_...), separadas por vírgula."""

    jwt_secret_key: SecretStr = SecretStr("")
    """Chave (mín. 32 caracteres) que assina os tokens de sessão do app."""

    jwt_algorithm: str = "HS256"
    jwt_expire_minutes: int = 720
    """Validade da sessão do app; vencida, o app volta para a tela de login."""

    jwt_lembrar_dias: int = 30
    """Validade da sessão com "manter conectado"; o app renova (`/api/auth/renovar`) ao abrir e uma
    vez por dia, então só pede login de novo depois de 30 dias sem uso."""

    jwt_midia_horas: int = 12
    """Validade do token de mídia (`?token=` das URLs da esteira): só abre `/esteira/`."""

    sessoes_geracao_arquivo: str = "~/agent-data/plataforma/sessoes_geracao"
    """Geração atual das sessões: "sair de todos os aparelhos" a incrementa e os tokens de geração
    menor deixam de valer. Sem o arquivo, a geração é 0 (tokens antigos, sem geração, valem)."""

    codigo_totp_horas: int = 12
    """O módulo Código (comandos no PC) exige um código do Authenticator digitado nas últimas N
    horas: só o token de sessão não basta."""

    # --- Login do app (senha + Google Authenticator) ---
    # Gerar tudo com: .venv/bin/python -m backend.auth.security
    admin_usuario: str = "admin"
    admin_senha_hash: SecretStr = SecretStr("")
    """Hash scrypt da senha; vazio = login desligado (fail-secure)."""

    admin_totp_segredo: SecretStr = SecretStr("")
    """Segredo base32 do Google Authenticator; vazio = login desligado (fail-secure)."""

    login_max_tentativas: int = 5
    login_bloqueio_minutos: int = 15

    # --- Worker (Etapa 3) ---
    worker_heartbeat_interval_seconds: int = 20
    """Intervalo sugerido ao Worker entre heartbeats, enviado no worker_hello_ack."""

    worker_stale_after_seconds: int = 60
    """Tempo sem heartbeat após o qual um worker é considerado morto e desconectado."""

    chat_request_timeout_seconds: float = 120.0
    """Timeout aguardando a resposta do worker para um chat completion."""

    # --- Notas ---
    notas_dir: str = "~/agent-data/notas"
    """Pasta dos Markdown das notas (pode ser o vault do Obsidian ou uma subpasta dele)."""

    # --- Arquivos ---
    arquivos_dir: str = "~/agent-data/arquivos"
    """Pasta da biblioteca de arquivos (PDF, DOCX, PPTX) e das anotações feitas no app."""

    soffice_bin: str = "soffice"
    """LibreOffice usado para converter DOCX/PPTX em PDF."""

    pdftoppm_bin: str = "pdftoppm"
    """Poppler usado para gerar a miniatura da primeira página."""

    # --- Collabora Online (edição de DOCX/XLSX/PPTX no app, via WOPI) ---
    collabora_url: str = ""
    """URL pública do Collabora (a que o navegador/webview abre); vazio = edição desligada."""

    collabora_interno_url: str = ""
    """Por onde o backend lê o discovery (ex. http://collabora:9980); vazio = collabora_url."""

    wopi_base_url: str = "http://localhost:48080"
    """URL pela qual o Collabora alcança este backend (vai no WOPISrc; casa com o aliasgroup1)."""

    wopi_secret: SecretStr = SecretStr("")
    """Assina os access_token do WOPI; vazio = aleatório por processo (tokens caem no reinício)."""

    wopi_token_minutos: int = 600
    """Validade do access_token entregue ao Collabora."""

    # --- Atualização do app ---
    atualizacoes_dir: str = "~/agent-data/atualizacoes"
    """APK, pacote Linux e versao.json publicados por infra/scripts/publicar_app."""

    # --- Saúde ---
    saude_dir: str = "~/agent-data/saude"
    """Catálogo de exercícios, agenda de treinos e imagens do módulo Saúde."""

    saude_baixar_imagens: bool = True
    """Baixa (uma vez) as imagens dos exercícios do free-exercise-db; desligado nos testes."""

    # --- YouTube (Empreendimento) ---
    youtube_vault: str = "~/Documents/github/obsidian"
    """Vault do Obsidian de onde `POST /api/youtube/importar` traz os canais para o cofre."""

    # --- Estudos ---
    estudos_dir: str = "~/agent-data/estudos"
    """Leituras (livros e artigos) e trilhas de idiomas com as sessões registradas."""

    # --- Finanças ---
    financas_dir: str = "~/agent-data/financas"
    """Contas, extrato, orçamento, metas, empresas analisadas e carteira do módulo Finanças."""

    # --- Design ---
    design_dir: str = "~/agent-data/design"
    """Quadros brancos do módulo Design (`quadros/<id>.json`) e imagens (`imagens/`)."""

    # --- Eletrônica ---
    eletronica_dir: str = "~/agent-data/eletronica"
    """Projetos de circuito do módulo Eletrônica (`projetos/<id>.json`) e bibliotecas importadas."""

    # --- Código ---
    codigo_dir: str = "~/agent-data/codigo"
    """Abas do módulo Código (`sessoes/<id>/`: meta, etapas do Claude Code, imagens enviadas)."""

    eletronica_kicad_versao: str = "9.0.9"
    """Tag do repositório kicad-symbols das bibliotecas oficiais (até o 9.x, um arquivo por lib)."""

    eletronica_ngspice_bin: str = "ngspice"
    """ngspice do backend, usado só quando nenhum worker está conectado (o normal é rodar no PC)."""

    eletronica_simulacao_timeout_s: float = 120.0
    """Tempo máximo de uma simulação no ngspice."""

    google_busca_chave: str = ""
    """Chave da API Custom Search do Google (busca de imagens no quadro do Design)."""

    google_busca_cx: str = ""
    """Id do Programmable Search Engine com "Pesquisa de imagens" ligada e "a Web inteira"."""

    # --- Concursos ---
    concursos_dir: str = "~/agent-data/concursos"
    concursos_origem_cidade: str = "Custódia"
    concursos_origem_uf: str = "PE"
    """Cidade do candidato: o radar mede a rota até o local de prova mais próximo a partir dela."""
    concursos_radar_horas: float = 6
    """Intervalo da coleta do radar de concursos de TI (PCI + LLM local); 0 desliga."""

    # --- Rotinas ---
    rotinas_dir: str = "~/agent-data/rotinas"
    """Quadro Kanban (`tarefas.json`) com as sessões do temporizador."""

    rotinas_modelo: str = ""
    """Modelo pedido ao worker pelo assistente de rotinas (vazio = o padrão do worker)."""

    llm_config: str = "~/agent-data/plataforma/llm.json"
    """Modelo do LLM escolhido no app (tela Modelo de IA); sobrepõe GATEWAY_ROTINAS_MODELO."""

    # --- Painel (Cobrador) ---
    painel_dir: str = "~/agent-data/painel"
    """Metas, ações registradas e agendas do dia do cobrador (`cobrador.json`)."""

    painel_fuso: str = "America/Sao_Paulo"
    """Fuso dos horários da agenda e dos alertas do cobrador."""

    painel_ntfy_url: str = ""
    """Tópico do ntfy (ex.: `https://ntfy.sh/meu-topico-secreto`) que recebe as cobranças como push
    no celular/PC mesmo com o app fechado. Vazio = sem push."""

    painel_ntfy_token: SecretStr = SecretStr("")
    """Token de acesso do ntfy, se o tópico for protegido."""

    wol_destino: str = ""
    """DDNS/IP público de casa para o Wake-on-LAN do botão "Ligar o PC" (o roteador encaminha a
    porta UDP para o broadcast da rede). Vazio = usa o último IP de onde o worker conectou."""

    wol_ip_arquivo: str = "~/agent-data/plataforma/ip_casa"
    """Onde fica o último IP público de onde o worker conectou (sobrevive a reinícios)."""

    wol_porta: int = 9

    wol_mac: str = "30:56:0f:98:c2:77"
    """MAC da placa de rede (cabo) do PC."""

    painel_cobranca_minutos: float = 15
    """De quanto em quanto tempo o cobrador confere a disciplina e manda os alertas novos."""

    @property
    def cors_origin_list(self) -> list[str]:
        if self.cors_origins.strip() == "*":
            return ["*"]
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]

    @property
    def login_configurado(self) -> bool:
        return (
            len(self.jwt_secret_key.get_secret_value()) >= 32
            and bool(self.admin_senha_hash.get_secret_value())
            and bool(self.admin_totp_segredo.get_secret_value())
        )

    @property
    def client_api_key_list(self) -> list[str]:
        """Só as chaves (sem o prefixo de escopo); ver `client_api_key_escopos`."""
        return list(self.client_api_key_scopes)

    @property
    def client_api_key_scopes(self) -> dict[str, str]:
        """Chave → escopo. `relogio:<chave>` só abre as rotas do relógio; sem prefixo = tudo
        (escopo vazio, como as chaves antigas)."""
        scopes: dict[str, str] = {}
        for item in self.client_api_keys.get_secret_value().split(","):
            item = item.strip()
            if not item:
                continue
            scope, _, key = item.partition(":") if ":" in item else ("", "", item)
            scopes[key.strip()] = scope.strip()
        return scopes

    @property
    def worker_api_key_list(self) -> list[str]:
        raw = self.worker_api_keys.get_secret_value()
        return [key.strip() for key in raw.split(",") if key.strip()]


@lru_cache
def get_settings() -> Settings:
    """Retorna a instância cacheada de Settings (lida uma única vez por processo)."""
    return Settings()
