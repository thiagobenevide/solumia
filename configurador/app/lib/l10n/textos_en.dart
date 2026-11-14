// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'textos.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class TextosEn extends Textos {
  TextosEn([String locale = 'en']) : super(locale);

  @override
  String get appTitulo => 'Solumia: configurator';

  @override
  String get iniciandoNucleo => 'Opening the vault and starting the core…';

  @override
  String get tentarDeNovo => 'Try again';

  @override
  String get navInicio => 'Home';

  @override
  String get navConta => 'Account';

  @override
  String get navVps => 'VPS';

  @override
  String get navPastas => 'Folders';

  @override
  String get navCraft => 'Craft Apps';

  @override
  String get navApps => 'Apps';

  @override
  String get navRegistro => 'History';

  @override
  String get aparencia => 'Appearance';

  @override
  String get tema => 'Theme';

  @override
  String get temaSistema => 'System';

  @override
  String get temaClaro => 'Light';

  @override
  String get temaEscuro => 'Dark';

  @override
  String get idioma => 'Language';

  @override
  String inicioVersao(
    Object versao,
    Object protocolo,
    Object so,
    Object arquitetura,
  ) {
    return 'Configurator $versao · protocol $protocolo · $so $arquitetura';
  }

  @override
  String inicioManifesto(Object caminho) {
    return 'Manifest: $caminho';
  }

  @override
  String get itemConta => 'Account and authenticator';

  @override
  String get itemContaDetalhe => 'Username, password and 2nd factor';

  @override
  String get itemVpsDetalhe => 'Address and domain';

  @override
  String get itemPastas => 'Media folders';

  @override
  String get itemPastasDetalhe => 'Images, videos, audio, production';

  @override
  String itemCraftDetalhe(int instalados, int total) {
    return '$instalados of $total installed';
  }

  @override
  String get itemApps => 'Solumia apps';

  @override
  String get itemAppsDetalhe => 'Phone, watch, PC and laptop';

  @override
  String inicioConvivencia(Object prefixo, Object gateway, Object tunel) {
    return 'Solumia services use their own names and ports (prefix $prefixo, gateway $gateway, tunnel $tunel) and do not interfere with the current installation.';
  }

  @override
  String get contaTitulo => 'Access account';

  @override
  String get contaDescricao =>
      'App username and password, with a second factor (Google Authenticator or similar). The password never leaves this computer: only its hash goes to the VPS.';

  @override
  String get usuario => 'Username';

  @override
  String get senha => 'Password';

  @override
  String get senhaAjuda =>
      'At least 12 characters, upper and lower case and a number';

  @override
  String get confirmarSenha => 'Confirm password';

  @override
  String get salvarConta => 'Save account';

  @override
  String get senhasNaoConferem => 'Passwords do not match';

  @override
  String get contaSalva => 'Account saved in the vault (password hash only)';

  @override
  String get qrInstrucao =>
      'Scan it with your authenticator. This QR is shown only now: it will not be shown again.';

  @override
  String get codigo6 => '6-digit code';

  @override
  String get conferir => 'Check';

  @override
  String get totpOk => 'Authenticator configured correctly.';

  @override
  String get totpFalhou => 'Code does not match. Check your phone\'s clock.';

  @override
  String get vpsDescricao =>
      'Installs gateway, tunnel, Collabora, nginx and TLS, and hardens SSH and the firewall. All with Solumia names and ports, without touching the current installation.';

  @override
  String get topologia => 'Topology';

  @override
  String get topoHibrida => 'Hybrid (VPS + this PC)';

  @override
  String get topoNuvem => 'Cloud only (VPS only)';

  @override
  String get dominio => 'Domain';

  @override
  String get dominioAjuda =>
      'e.g. solumia.yourdomain.com (A record pointing to the VPS)';

  @override
  String get emailTls => 'E-mail for the TLS certificate';

  @override
  String get emailTlsAjuda => 'Let\'s Encrypt expiry notices';

  @override
  String get cloudflare => 'Domain behind Cloudflare (proxy)';

  @override
  String get acessoSsh => 'SSH access';

  @override
  String get hostVps => 'VPS IP or hostname';

  @override
  String get porta => 'Port';

  @override
  String get lerImpressao => 'Read the VPS fingerprint';

  @override
  String impressaoConfirmada(Object impressao) {
    return 'Confirmed: $impressao';
  }

  @override
  String get conferirImpressao =>
      'Make sure it is your VPS before confirming. In your provider\'s panel (web console) run:';

  @override
  String get confirmoVps => 'I confirm: this is my VPS';

  @override
  String get primeiroAcesso => 'First access';

  @override
  String get primeiroAcessoDescricao =>
      'The password is used once to install the configurator key and is not stored. After that, access is key-only.';

  @override
  String get senhaVps => 'VPS password (first access only)';

  @override
  String get senhaSudo => 'sudo password (if the user is not root)';

  @override
  String get desativarSenha => 'Disable SSH password login (recommended)';

  @override
  String get desativarSenhaAjuda =>
      'Automatically undone after 5 min if key access fails';

  @override
  String get nginxAuto => 'detect';

  @override
  String get nginxDocker => 'in a container (dedicated VPS)';

  @override
  String get nginxHost => 'nginx already installed on the VPS';

  @override
  String get salvar => 'Save';

  @override
  String get verPlano => 'View installation plan';

  @override
  String get confirmeImpressao => 'Confirm the fingerprint first';

  @override
  String get vpsSalva => 'VPS settings saved';

  @override
  String get pastasTitulo => 'Media folders';

  @override
  String pastasDescricao(Object so) {
    return 'Where images, videos and audio are kept on this computer ($so). They can be on another disk. They cannot be the same or nested inside each other.';
  }

  @override
  String get pastaImagens => 'Images';

  @override
  String get pastaVideos => 'Videos';

  @override
  String get pastaAudio => 'Audio';

  @override
  String get pastaProducao => 'Videos for production';

  @override
  String get pastaProduzidos => 'Produced videos';

  @override
  String get ajudaImagens => 'Images used in videos (library and generated)';

  @override
  String get ajudaVideos => 'Raw video library';

  @override
  String get ajudaAudio => 'Music, sound effects and narration';

  @override
  String get ajudaProducao => 'Videos in production (pipeline input)';

  @override
  String get ajudaProduzidos => 'Finished videos (output)';

  @override
  String get escolherPasta => 'Choose folder';

  @override
  String get usarEstaPasta => 'Use this folder';

  @override
  String get validar => 'Validate';

  @override
  String get salvarECriar => 'Save and create folders';

  @override
  String get corrijaPastas => 'Fix the highlighted folders';

  @override
  String get craftDescricao =>
      'Downloaded from each project\'s GitHub. Before installing, the configurator checks the signature (pinned key) and the SHA-256: a tampered file is never installed.';

  @override
  String get craftFilmcraft => 'Non-linear video editor';

  @override
  String get craftSoundcraft => 'Digital audio workstation (DAW)';

  @override
  String get craftEffectcraft => 'Motion graphics and compositing';

  @override
  String get craftPhotocraft => 'Photo editor';

  @override
  String get consultandoVersao => 'Checking the latest version…';

  @override
  String ultimaVersao(Object versao, Object arquivo) {
    return 'Latest: $versao · $arquivo';
  }

  @override
  String get naoInstalado => 'Not installed';

  @override
  String instaladoEm(Object versao, Object caminho) {
    return 'Installed: $versao at $caminho';
  }

  @override
  String get formatoPortatil => 'Portable (no administrator)';

  @override
  String get formatoMsi => '.msi installer';

  @override
  String get formatoAppimage => 'AppImage (no administrator)';

  @override
  String get formatoDeb => '.deb (asks for administrator)';

  @override
  String get baixarInstalar => 'Download and install';

  @override
  String get atualizar => 'Update';

  @override
  String get reinstalar => 'Reinstall';

  @override
  String get appsTitulo => 'Solumia apps';

  @override
  String get appsDescricao =>
      'The Solumia app for each device, from the official GitHub releases. The configurator checks the signature and SHA-256 before saving or installing.';

  @override
  String get appCelular => 'Phone and tablet';

  @override
  String get appCelularDetalhe => 'Android (APK)';

  @override
  String get appRelogio => 'Watch';

  @override
  String get appRelogioDetalhe => 'Wear OS (APK)';

  @override
  String get appLinux => 'PC and laptop';

  @override
  String get appLinuxDetalhe => 'Linux (AppImage)';

  @override
  String get appWindows => 'PC and laptop';

  @override
  String get appWindowsDetalhe => 'Windows (installer)';

  @override
  String appsVersao(Object versao) {
    return 'Published version: $versao';
  }

  @override
  String get appsSemRelease =>
      'No release found. Files will show up here as soon as they are published.';

  @override
  String get appsSemAssinatura =>
      'Downloads blocked for security: the key that signs Solumia releases has not been pinned in the configurator yet.';

  @override
  String appsPasta(Object pasta) {
    return 'Files saved to $pasta';
  }

  @override
  String get abrirReleases => 'Open releases on GitHub';

  @override
  String get arquivoIndisponivel => 'File not published in this version';

  @override
  String get baixarParaEstePc => 'Download to this PC';

  @override
  String get instalarNestePc => 'Install on this PC';

  @override
  String get mostrarQr => 'QR for the phone';

  @override
  String get qrCelular =>
      'Point your phone camera here to download straight from GitHub. Android checks the APK signature when installing.';

  @override
  String get relogioInstrucao =>
      'Download the APK here and send it to the watch through the phone app, or install it on the watch itself.';

  @override
  String get planoNadaAlterado =>
      'Nothing has been changed yet. Review what will happen:';

  @override
  String planoExecucao(Object estado) {
    return 'Run: $estado';
  }

  @override
  String get codigoDestrutivo => 'Authenticator code (destructive action)';

  @override
  String get cancelar => 'Cancel';

  @override
  String get aplicar => 'Apply';

  @override
  String get pararAposPasso => 'Stop after the current step';

  @override
  String get fechar => 'Close';

  @override
  String get estadoRodando => 'in progress…';

  @override
  String get estadoConcluida => 'completed';

  @override
  String get estadoFalhou =>
      'failed (you can fix it and apply again: it resumes where it stopped)';

  @override
  String get estadoCancelada => 'stopped';

  @override
  String get registroTitulo => 'History';

  @override
  String get registroVazio => 'Nothing applied yet.';
}
