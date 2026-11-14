// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_text.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppTextPt extends AppText {
  AppTextPt([String locale = 'pt']) : super(locale);

  @override
  String get appTitle => 'Solumia: configurador';

  @override
  String get startingCore => 'Abrindo o cofre e iniciando o núcleo…';

  @override
  String get tryAgain => 'Tentar de novo';

  @override
  String get navHome => 'Início';

  @override
  String get navAccount => 'Conta';

  @override
  String get navVps => 'VPS';

  @override
  String get navFolders => 'Pastas';

  @override
  String get navCraft => 'Craft Apps';

  @override
  String get navApps => 'Apps';

  @override
  String get navRunLog => 'Registro';

  @override
  String get appearance => 'Aparência';

  @override
  String get theme => 'Tema';

  @override
  String get themeSystem => 'Do sistema';

  @override
  String get themeLight => 'Claro';

  @override
  String get themeDark => 'Escuro';

  @override
  String get language => 'Idioma';

  @override
  String homeVersion(
    Object versao,
    Object protocolo,
    Object so,
    Object arquitetura,
  ) {
    return 'Configurador $versao · protocolo $protocolo · $so $arquitetura';
  }

  @override
  String homeManifest(Object caminho) {
    return 'Manifesto: $caminho';
  }

  @override
  String get itemAccount => 'Conta e autenticador';

  @override
  String get itemAccountDetail => 'Usuário, senha e 2º fator';

  @override
  String get itemVpsDetail => 'Endereço e domínio';

  @override
  String get itemFolders => 'Pastas de mídia';

  @override
  String get itemFoldersDetail => 'Imagens, vídeos, áudio, produção';

  @override
  String itemCraftDetail(int instalados, int total) {
    return '$instalados de $total instalados';
  }

  @override
  String get itemApps => 'Apps Solumia';

  @override
  String get itemAppsDetail => 'Celular, relógio, PC e notebook';

  @override
  String homeCoexistence(Object prefixo, Object gateway, Object tunel) {
    return 'Serviços do Solumia usam nomes e portas próprios (prefixo $prefixo, gateway $gateway, túnel $tunel) e não interferem na instalação atual.';
  }

  @override
  String get accountTitle => 'Conta de acesso';

  @override
  String get accountDescription =>
      'Usuário e senha do app, com segundo fator (Google Authenticator ou similar). A senha nunca sai deste computador: só o hash vai para a VPS.';

  @override
  String get user => 'Usuário';

  @override
  String get password => 'Senha';

  @override
  String get passwordHelp =>
      'Mínimo 12 caracteres, maiúsculas, minúsculas e número';

  @override
  String get confirmPassword => 'Confirmar senha';

  @override
  String get saveAccount => 'Salvar conta';

  @override
  String get passwordsDoNotMatch => 'As senhas não conferem';

  @override
  String get accountSaved => 'Conta salva no cofre (só o hash da senha)';

  @override
  String get qrInstruction =>
      'Escaneie no autenticador. Este QR só aparece agora: ele não é mostrado de novo.';

  @override
  String get code6 => 'Código de 6 dígitos';

  @override
  String get check => 'Conferir';

  @override
  String get totpOk => 'Autenticador configurado corretamente.';

  @override
  String get totpFailed => 'Código não confere. Confira o relógio do celular.';

  @override
  String get vpsDescription =>
      'Instala gateway, túnel, Collabora, nginx e TLS, e endurece SSH e firewall. Tudo com nomes e portas do Solumia, sem tocar na instalação atual.';

  @override
  String get topology => 'Topologia';

  @override
  String get topologyHybrid => 'Híbrida (VPS + este PC)';

  @override
  String get topologyCloud => 'Só nuvem (só VPS)';

  @override
  String get domain => 'Domínio';

  @override
  String get domainHelp =>
      'ex.: solumia.seudominio.com (registro A apontando para a VPS)';

  @override
  String get emailTls => 'E-mail para o certificado TLS';

  @override
  String get emailTlsHelp => 'avisos de expiração do Let\'s Encrypt';

  @override
  String get cloudflare => 'Domínio atrás da Cloudflare (proxy)';

  @override
  String get sshAccess => 'Acesso SSH';

  @override
  String get vpsHost => 'IP ou nome da VPS';

  @override
  String get port => 'Porta';

  @override
  String get readFingerprint => 'Ler impressão digital da VPS';

  @override
  String fingerprintConfirmed(Object impressao) {
    return 'Confirmada: $impressao';
  }

  @override
  String get checkFingerprint =>
      'Confira se é a sua VPS antes de confirmar. No painel do provedor (console web) rode:';

  @override
  String get confirmVps => 'Confirmo: é a minha VPS';

  @override
  String get firstAccess => 'Primeiro acesso';

  @override
  String get firstAccessDescription =>
      'A senha é usada uma vez para instalar a chave do configurador e não é gravada. Depois disso o acesso é só por chave.';

  @override
  String get vpsPassword => 'Senha da VPS (só no 1º acesso)';

  @override
  String get sudoPassword => 'Senha do sudo (se o usuário não for root)';

  @override
  String get disablePassword =>
      'Desativar login por senha no SSH (recomendado)';

  @override
  String get disablePasswordHelp =>
      'Com desfazer automático em 5 min se o acesso por chave falhar';

  @override
  String get nginxAuto => 'detectar';

  @override
  String get nginxDocker => 'em contêiner (VPS dedicada)';

  @override
  String get nginxHost => 'nginx já instalado na VPS';

  @override
  String get save => 'Salvar';

  @override
  String get viewPlan => 'Ver plano de instalação';

  @override
  String get confirmFingerprint => 'Confirme a impressão digital primeiro';

  @override
  String get vpsSaved => 'Configuração da VPS salva';

  @override
  String get foldersTitle => 'Pastas de mídia';

  @override
  String foldersDescription(Object so) {
    return 'Onde ficam imagens, vídeos e áudio neste computador ($so). Podem estar em outro disco. Não podem ser iguais nem uma dentro da outra.';
  }

  @override
  String get folderImages => 'Imagens';

  @override
  String get folderVideos => 'Vídeos';

  @override
  String get folderAudio => 'Áudio';

  @override
  String get folderProduction => 'Vídeos para produção';

  @override
  String get folderProduced => 'Vídeos produzidos';

  @override
  String get helpImages => 'Imagens usadas nos vídeos (acervo e geradas)';

  @override
  String get helpVideos => 'Acervo de vídeos brutos';

  @override
  String get helpAudio => 'Trilhas, efeitos e narrações';

  @override
  String get helpProduction => 'Vídeos em produção (entrada da esteira)';

  @override
  String get helpProduced => 'Vídeos prontos (saída)';

  @override
  String get pickFolder => 'Escolher pasta';

  @override
  String get useThisFolder => 'Usar esta pasta';

  @override
  String get validate => 'Validar';

  @override
  String get saveAndCreate => 'Salvar e criar pastas';

  @override
  String get fixFolders => 'Corrija as pastas marcadas';

  @override
  String get craftDescription =>
      'Baixados do GitHub de cada projeto. Antes de instalar, o configurador confere a assinatura (chave fixada) e o SHA-256: um arquivo adulterado nunca é instalado.';

  @override
  String get craftFilmcraft => 'Editor de vídeo não linear';

  @override
  String get craftSoundcraft => 'Estação de áudio digital (DAW)';

  @override
  String get craftEffectcraft => 'Motion graphics e composição';

  @override
  String get craftPhotocraft => 'Editor de fotos';

  @override
  String get checkingVersion => 'Consultando a última versão…';

  @override
  String latestVersion(Object versao, Object arquivo) {
    return 'Última: $versao · $arquivo';
  }

  @override
  String get notInstalled => 'Não instalado';

  @override
  String installedAt(Object versao, Object caminho) {
    return 'Instalado: $versao em $caminho';
  }

  @override
  String get formatPortable => 'Portátil (sem administrador)';

  @override
  String get formatMsi => 'Instalador .msi';

  @override
  String get formatAppimage => 'AppImage (sem administrador)';

  @override
  String get formatDeb => '.deb (pede administrador)';

  @override
  String get downloadInstall => 'Baixar e instalar';

  @override
  String get update => 'Atualizar';

  @override
  String get reinstall => 'Reinstalar';

  @override
  String get appsTitle => 'Apps Solumia';

  @override
  String get appsDescription =>
      'O app do Solumia para cada dispositivo, das releases oficiais no GitHub. O configurador confere assinatura e SHA-256 antes de salvar ou instalar.';

  @override
  String get appPhone => 'Celular e tablet';

  @override
  String get appPhoneDetail => 'Android (APK)';

  @override
  String get appWatch => 'Relógio';

  @override
  String get appWatchDetail => 'Wear OS (APK)';

  @override
  String get appLinux => 'PC e notebook';

  @override
  String get appLinuxDetail => 'Linux (AppImage)';

  @override
  String get appWindows => 'PC e notebook';

  @override
  String get appWindowsDetail => 'Windows (instalador)';

  @override
  String appsVersion(Object versao) {
    return 'Versão publicada: $versao';
  }

  @override
  String get appsNoRelease =>
      'Nenhuma release encontrada. Os arquivos aparecem aqui assim que forem publicados.';

  @override
  String get appsUnsigned =>
      'Downloads bloqueados por segurança: a chave que assina as releases do Solumia ainda não foi fixada no configurador.';

  @override
  String appsFolder(Object pasta) {
    return 'Arquivos salvos em $pasta';
  }

  @override
  String get openReleases => 'Abrir releases no GitHub';

  @override
  String get fileUnavailable => 'Arquivo não publicado nesta versão';

  @override
  String get downloadToThisPc => 'Baixar para este PC';

  @override
  String get installOnThisPc => 'Instalar neste PC';

  @override
  String get showQr => 'QR para o celular';

  @override
  String get qrPhone =>
      'Aponte a câmera do celular para baixar direto do GitHub. O Android confere a assinatura do APK ao instalar.';

  @override
  String get watchInstruction =>
      'Instale direto no relógio pela rede Wi‑Fi, ou baixe o APK aqui.';

  @override
  String get planNothingChanged =>
      'Nada foi alterado ainda. Confira o que vai acontecer:';

  @override
  String planRun(Object estado) {
    return 'Execução: $estado';
  }

  @override
  String get destructiveCode => 'Código do autenticador (ação destrutiva)';

  @override
  String get cancel => 'Cancelar';

  @override
  String get apply => 'Aplicar';

  @override
  String get stopAfterStep => 'Parar após o passo atual';

  @override
  String get close => 'Fechar';

  @override
  String get stateRunning => 'em andamento…';

  @override
  String get stateFinished => 'concluída';

  @override
  String get stateFailed =>
      'falhou (pode corrigir e aplicar de novo: retoma de onde parou)';

  @override
  String get stateCancelled => 'parada';

  @override
  String get runLogTitle => 'Registro';

  @override
  String get runLogEmpty => 'Nenhuma aplicação ainda.';

  @override
  String get navWorker => 'Worker';

  @override
  String get navAssistant => 'Assistente';

  @override
  String get itemWorker => 'Worker neste PC';

  @override
  String get itemWorkerDetail =>
      'Serviço solumia-worker, em paralelo ao agent-worker';

  @override
  String get workerIntro =>
      'O worker roda neste PC como serviço do usuário e conecta ao gateway da sua VPS. Ele tem nome, porta e configuração próprios: o worker da instalação antiga continua como está.';

  @override
  String workerState(String unidade, String estado) {
    return '$unidade: $estado';
  }

  @override
  String workerLlama(String porta) {
    return 'llama-server do Solumia na porta $porta (o antigo usa 8081). Os dois dividem a GPU: evite usar os dois ao mesmo tempo com modelos grandes.';
  }

  @override
  String get workerInstall => 'Instalar ou atualizar o worker';

  @override
  String get assistantIntro =>
      'O Claude Code deste PC ajuda você a seguir as etapas. Ele não tem ferramentas: não lê arquivos, não roda comandos e não aplica nada. Recebe só o estado resumido abaixo, sem senhas, chaves, IPs, domínio ou usuários, e a conversa fica só na memória desta sessão.';

  @override
  String get assistantUnavailable =>
      'Claude Code não encontrado neste computador. Instale e faça login no Claude Code para usar o assistente.';

  @override
  String get assistantHint => 'Pergunte, por exemplo: por onde eu começo?';

  @override
  String get assistantSend => 'Enviar';

  @override
  String get assistantClear => 'Limpar conversa';

  @override
  String get assistantContext => 'O que o Claude recebe';

  @override
  String get assistantOpenScreen => 'Abrir a tela sugerida';

  @override
  String get assistantThinking => 'O Claude está pensando…';

  @override
  String get assistantNoSecrets =>
      'Não cole senhas, chaves ou códigos aqui: o que parecer segredo é ocultado antes de sair do PC.';

  @override
  String get updateConfigurator => 'Atualizar o configurador';

  @override
  String get updateConfiguratorDetail =>
      'Compila e reinstala a partir do código deste repositório; a versão nova abre no próximo início.';

  @override
  String get updateButton => 'Atualizar';

  @override
  String get watchInstallButton => 'Instalar no relógio (Wi‑Fi)';

  @override
  String get watchInstallTitle => 'Instalar no relógio pela rede';

  @override
  String get watchSteps =>
      '1. No relógio: Configurações › Sobre › Software, toque 7 vezes em \"Versão do software\" para liberar as Opções do desenvolvedor.\n2. Em Opções do desenvolvedor, ligue \"Depuração ADB\" e \"Depuração por Wi‑Fi\" (relógio e PC na mesma rede).\n3. Na primeira vez: em Depuração por Wi‑Fi › \"Parear novo dispositivo\", preencha o IP, a porta e o código mostrados e toque em Parear.\n4. Depois: preencha a porta mostrada na tela Depuração por Wi‑Fi (IP:porta) e toque em Instalar.';

  @override
  String get watchIp => 'IP do relógio';

  @override
  String get watchPairPort => 'Porta de pareamento';

  @override
  String get watchPairCode => 'Código de 6 dígitos';

  @override
  String get watchConnectPort => 'Porta de conexão';

  @override
  String get watchPair => 'Parear';

  @override
  String get watchPaired =>
      'Relógio pareado. Agora preencha a porta de conexão e toque em Instalar.';

  @override
  String get watchInstall => 'Instalar';

  @override
  String get watchFillFields => 'Preencha o IP e as portas com números.';
}
