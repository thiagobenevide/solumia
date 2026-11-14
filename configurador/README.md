# Configurador do Solumia

Programa único para instalar, configurar e operar o Solumia sem terminal. Implementa o desenho de
[`docs/CONFIGURATOR.md`](../docs/CONFIGURATOR.md).

```
configurador/
├── core/   núcleo Python: manifesto, cofre, plano/aplicação, SSH, VPS, pastas, Craft Apps, API local
└── app/    interface Flutter desktop (Linux e Windows) que só conversa com o núcleo
```

## Rodar em desenvolvimento

```bash
cd configurador/core && uv sync --extra dev        # ambiente isolado em core/.venv
cd ../app && ~/development/flutter/bin/flutter run -d linux
```

A interface inicia o núcleo (`core/.venv/bin/solumia-configurador servir`) sozinha e o encerra ao
fechar. Para apontar outro executável: `SOLUMIA_CORE=/caminho/solumia-configurador`.

Testes: `cd core && .venv/bin/python -m pytest -q` · `cd app && flutter analyze && flutter test`.

## Telas

| Tela | O que faz |
|---|---|
| Início | o que já está configurado e atalhos para o que falta |
| Conta | usuário, senha (só o hash sai do PC) e TOTP com QR |
| VPS | topologia, domínio, TLS, SSH com impressão digital confirmada, plano de instalação completo |
| Pastas | imagens, vídeos, áudio, vídeos para produção e produzidos (Linux e Windows) |
| Craft Apps | FilmCraft, SoundCraft, EffectCraft e PhotoCraft direto do GitHub Releases |
| Apps | app do Solumia para celular/tablet e relógio (APK), PC e notebook (Linux/Windows), das releases de `thiagobenevide/solumia`; QR para o celular |
| Registro | todas as aplicações, com estado final |

Aparência e idioma (botão no pé do menu): tema claro, escuro ou do sistema, com a paleta própria do Solumia (`app/lib/tema.dart`); português, inglês e espanhol (`app/lib/l10n/*.arb`). Mensagens que vêm do núcleo (passos do plano, logs, erros) ainda saem em português.

Toda mudança aparece primeiro como **plano**; nada roda sem "Aplicar". Uma aplicação que falha pode
ser repetida e retoma do passo que parou.

## Convivência com a instalação atual

Tudo do Solumia tem nome, porta e caminho próprios (fonte única: `core/src/solumia_configurador/nomes.py`):

| | Atual | Solumia |
|---|---|---|
| Projeto compose / contêineres | `docker` (padrão) | `solumia` |
| Gateway (127.0.0.1) | 48080 | 48180 |
| Túnel SSH (aberto no firewall) | 2222 | 2223 |
| Esteira via túnel / Collabora (127.0.0.1) | 18765 / 9980 | 18865 / 9981 |
| Esteira / llama-server no PC | 8765 / 8081 | 8865 / 8181 |
| Pasta na VPS | `/opt/agent` | `/opt/solumia` |
| Unidades systemd | `agent-*` | `solumia-*` |
| nginx do host | `agent-<domínio>.conf`, zona `agent_login` | `solumia-<domínio>.conf`, zona `solumia_login` |

Limitação: as portas 80/443 só podem ser de um nginx. Numa VPS onde a instalação atual roda o
nginx **em contêiner**, o plano para no passo "portas" e explica; use uma VPS separada para testar
ou o modo "nginx já instalado na VPS".

## Segurança

- **Núcleo local**: só `127.0.0.1`, porta aleatória, token de 256 bits por sessão entregue só à
  interface que iniciou o processo; `Host` conferido (DNS rebinding) e qualquer `Origin` recusado.
- **Cofre**: AES-256-GCM; chave no chaveiro do sistema (Secret Service / Credential Manager);
  arquivo 0600; a API devolve só nomes, nunca valores; todo log passa por máscara de segredos.
- **VPS**: impressão digital da chave do servidor confirmada pela pessoa e exigida em toda conexão;
  senha usada só no 1º acesso, em memória; chave ed25519 do configurador; desfazer automático de
  5 min em SSH/firewall; firewall só com SSH, 80, 443 e 2223; arquivos com segredo em 0600;
  envio por pasta temporária `mktemp -d` (sem corrida de symlink); pacote de código conferido por
  SHA-256 e sem `.env`, chaves, testes ou caches.
- **Craft Apps**: só repositórios do catálogo; só hosts do GitHub por HTTPS; `SHA256SUMS`
  assinado por chave com **impressão fixada** (`2B76741B414AAD6CD33E631213A005C0B9D7C3ED`,
  ArtCraft Release Signing Key) e SHA-256 do arquivo conferidos antes de instalar; extração
  protegida contra zip/tar slip; instalação na pasta do usuário.
- **Ações destrutivas** exigem o código TOTP; aplicar exige o `hash` do plano mostrado.

## Ainda não implementado (próximas fases do roadmap)

Entrega da VPS por pacote isolado (`agent-node`), adopt da instalação atual, worker/esteira/túnel
como serviços `solumia-*` no host (geradores prontos em `gerar.py`), pareamento por QR, IA local e
nuvem, módulos, backup, empacotamento (AppImage/instalador Windows) e CI.
