// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_text.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppTextEn extends AppText {
  AppTextEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Solumia: configurator';

  @override
  String get startingCore => 'Opening the vault and starting the core…';

  @override
  String get tryAgain => 'Try again';

  @override
  String get navHome => 'Home';

  @override
  String get navAccount => 'Account';

  @override
  String get navVps => 'VPS';

  @override
  String get navFolders => 'Folders';

  @override
  String get navCraft => 'Craft Apps';

  @override
  String get navApps => 'Apps';

  @override
  String get navRunLog => 'History';

  @override
  String get appearance => 'Appearance';

  @override
  String get theme => 'Theme';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get language => 'Language';

  @override
  String homeVersion(
    Object versao,
    Object protocolo,
    Object so,
    Object arquitetura,
  ) {
    return 'Configurator $versao · protocol $protocolo · $so $arquitetura';
  }

  @override
  String homeManifest(Object caminho) {
    return 'Manifest: $caminho';
  }

  @override
  String get itemAccount => 'Account and authenticator';

  @override
  String get itemAccountDetail => 'Username, password and 2nd factor';

  @override
  String get itemVpsDetail => 'Address and domain';

  @override
  String get itemFolders => 'Media folders';

  @override
  String get itemFoldersDetail => 'Images, videos, audio, production';

  @override
  String itemCraftDetail(int instalados, int total) {
    return '$instalados of $total installed';
  }

  @override
  String get itemApps => 'Solumia apps';

  @override
  String get itemAppsDetail => 'Phone, watch, PC and laptop';

  @override
  String homeCoexistence(Object prefixo, Object gateway, Object tunel) {
    return 'Solumia services use their own names and ports (prefix $prefixo, gateway $gateway, tunnel $tunel) and do not interfere with the current installation.';
  }

  @override
  String get accountTitle => 'Access account';

  @override
  String get accountDescription =>
      'App username and password, with a second factor (Google Authenticator or similar). The password never leaves this computer: only its hash goes to the VPS.';

  @override
  String get user => 'Username';

  @override
  String get password => 'Password';

  @override
  String get passwordHelp =>
      'At least 12 characters, upper and lower case and a number';

  @override
  String get confirmPassword => 'Confirm password';

  @override
  String get saveAccount => 'Save account';

  @override
  String get passwordsDoNotMatch => 'Passwords do not match';

  @override
  String get accountSaved => 'Account saved in the vault (password hash only)';

  @override
  String get qrInstruction =>
      'Scan it with your authenticator. This QR is shown only now: it will not be shown again.';

  @override
  String get code6 => '6-digit code';

  @override
  String get check => 'Check';

  @override
  String get totpOk => 'Authenticator configured correctly.';

  @override
  String get totpFailed => 'Code does not match. Check your phone\'s clock.';

  @override
  String get vpsDescription =>
      'Installs gateway, tunnel, Collabora, nginx and TLS, and hardens SSH and the firewall. All with Solumia names and ports, without touching the current installation.';

  @override
  String get topology => 'Topology';

  @override
  String get topologyHybrid => 'Hybrid (VPS + this PC)';

  @override
  String get topologyCloud => 'Cloud only (VPS only)';

  @override
  String get domain => 'Domain';

  @override
  String get domainHelp =>
      'e.g. solumia.yourdomain.com (A record pointing to the VPS)';

  @override
  String get emailTls => 'E-mail for the TLS certificate';

  @override
  String get emailTlsHelp => 'Let\'s Encrypt expiry notices';

  @override
  String get cloudflare => 'Domain behind Cloudflare (proxy)';

  @override
  String get sshAccess => 'SSH access';

  @override
  String get vpsHost => 'VPS IP or hostname';

  @override
  String get port => 'Port';

  @override
  String get readFingerprint => 'Read the VPS fingerprint';

  @override
  String fingerprintConfirmed(Object impressao) {
    return 'Confirmed: $impressao';
  }

  @override
  String get checkFingerprint =>
      'Make sure it is your VPS before confirming. In your provider\'s panel (web console) run:';

  @override
  String get confirmVps => 'I confirm: this is my VPS';

  @override
  String get firstAccess => 'First access';

  @override
  String get firstAccessDescription =>
      'The password is used once to install the configurator key and is not stored. After that, access is key-only.';

  @override
  String get vpsPassword => 'VPS password (first access only)';

  @override
  String get sudoPassword => 'sudo password (if the user is not root)';

  @override
  String get disablePassword => 'Disable SSH password login (recommended)';

  @override
  String get disablePasswordHelp =>
      'Automatically undone after 5 min if key access fails';

  @override
  String get nginxAuto => 'detect';

  @override
  String get nginxDocker => 'in a container (dedicated VPS)';

  @override
  String get nginxHost => 'nginx already installed on the VPS';

  @override
  String get save => 'Save';

  @override
  String get viewPlan => 'View installation plan';

  @override
  String get confirmFingerprint => 'Confirm the fingerprint first';

  @override
  String get vpsSaved => 'VPS settings saved';

  @override
  String get foldersTitle => 'Media folders';

  @override
  String foldersDescription(Object so) {
    return 'Where images, videos and audio are kept on this computer ($so). They can be on another disk. They cannot be the same or nested inside each other.';
  }

  @override
  String get folderImages => 'Images';

  @override
  String get folderVideos => 'Videos';

  @override
  String get folderAudio => 'Audio';

  @override
  String get folderProduction => 'Videos for production';

  @override
  String get folderProduced => 'Produced videos';

  @override
  String get helpImages => 'Images used in videos (library and generated)';

  @override
  String get helpVideos => 'Raw video library';

  @override
  String get helpAudio => 'Music, sound effects and narration';

  @override
  String get helpProduction => 'Videos in production (pipeline input)';

  @override
  String get helpProduced => 'Finished videos (output)';

  @override
  String get pickFolder => 'Choose folder';

  @override
  String get useThisFolder => 'Use this folder';

  @override
  String get validate => 'Validate';

  @override
  String get saveAndCreate => 'Save and create folders';

  @override
  String get fixFolders => 'Fix the highlighted folders';

  @override
  String get craftDescription =>
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
  String get checkingVersion => 'Checking the latest version…';

  @override
  String latestVersion(Object versao, Object arquivo) {
    return 'Latest: $versao · $arquivo';
  }

  @override
  String get notInstalled => 'Not installed';

  @override
  String installedAt(Object versao, Object caminho) {
    return 'Installed: $versao at $caminho';
  }

  @override
  String get formatPortable => 'Portable (no administrator)';

  @override
  String get formatMsi => '.msi installer';

  @override
  String get formatAppimage => 'AppImage (no administrator)';

  @override
  String get formatDeb => '.deb (asks for administrator)';

  @override
  String get downloadInstall => 'Download and install';

  @override
  String get update => 'Update';

  @override
  String get reinstall => 'Reinstall';

  @override
  String get appsTitle => 'Solumia apps';

  @override
  String get appsDescription =>
      'The Solumia app for each device, from the official GitHub releases. The configurator checks the signature and SHA-256 before saving or installing.';

  @override
  String get appPhone => 'Phone and tablet';

  @override
  String get appPhoneDetail => 'Android (APK)';

  @override
  String get appWatch => 'Watch';

  @override
  String get appWatchDetail => 'Wear OS (APK)';

  @override
  String get appLinux => 'PC and laptop';

  @override
  String get appLinuxDetail => 'Linux (AppImage)';

  @override
  String get appWindows => 'PC and laptop';

  @override
  String get appWindowsDetail => 'Windows (installer)';

  @override
  String appsVersion(Object versao) {
    return 'Published version: $versao';
  }

  @override
  String get appsNoRelease =>
      'No release found. Files will show up here as soon as they are published.';

  @override
  String get appsUnsigned =>
      'Downloads blocked for security: the key that signs Solumia releases has not been pinned in the configurator yet.';

  @override
  String appsFolder(Object pasta) {
    return 'Files saved to $pasta';
  }

  @override
  String get openReleases => 'Open releases on GitHub';

  @override
  String get fileUnavailable => 'File not published in this version';

  @override
  String get downloadToThisPc => 'Download to this PC';

  @override
  String get installOnThisPc => 'Install on this PC';

  @override
  String get showQr => 'QR for the phone';

  @override
  String get qrPhone =>
      'Point your phone camera here to download straight from GitHub. Android checks the APK signature when installing.';

  @override
  String get watchInstruction =>
      'Install it straight on the watch over Wi‑Fi, or download the APK here.';

  @override
  String get planNothingChanged =>
      'Nothing has been changed yet. Review what will happen:';

  @override
  String planRun(Object estado) {
    return 'Run: $estado';
  }

  @override
  String get destructiveCode => 'Authenticator code (destructive action)';

  @override
  String get cancel => 'Cancel';

  @override
  String get apply => 'Apply';

  @override
  String get stopAfterStep => 'Stop after the current step';

  @override
  String get close => 'Close';

  @override
  String get stateRunning => 'in progress…';

  @override
  String get stateFinished => 'completed';

  @override
  String get stateFailed =>
      'failed (you can fix it and apply again: it resumes where it stopped)';

  @override
  String get stateCancelled => 'stopped';

  @override
  String get runLogTitle => 'History';

  @override
  String get runLogEmpty => 'Nothing applied yet.';

  @override
  String get navWorker => 'Worker';

  @override
  String get navAssistant => 'Assistant';

  @override
  String get itemWorker => 'Worker on this PC';

  @override
  String get itemWorkerDetail =>
      'solumia-worker service, in parallel with agent-worker';

  @override
  String get workerIntro =>
      'The worker runs on this PC as a user service and connects to your VPS gateway. It has its own name, port and configuration: the worker of the older installation stays as it is.';

  @override
  String workerState(String unidade, String estado) {
    return '$unidade: $estado';
  }

  @override
  String workerLlama(String porta) {
    return 'Solumia llama-server on port $porta (the older one uses 8081). Both share the GPU: avoid running both at once with large models.';
  }

  @override
  String get workerInstall => 'Install or update the worker';

  @override
  String get assistantIntro =>
      'This PC\'s Claude Code helps you follow the steps. It has no tools: it does not read files, run commands or apply anything. It only receives the summarized state below, without passwords, keys, IPs, domain or user names, and the conversation lives only in this session\'s memory.';

  @override
  String get assistantUnavailable =>
      'Claude Code was not found on this computer. Install it and log in to use the assistant.';

  @override
  String get assistantHint => 'Ask, for example: where do I start?';

  @override
  String get assistantSend => 'Send';

  @override
  String get assistantClear => 'Clear conversation';

  @override
  String get assistantContext => 'What Claude receives';

  @override
  String get assistantOpenScreen => 'Open the suggested screen';

  @override
  String get assistantThinking => 'Claude is thinking…';

  @override
  String get assistantNoSecrets =>
      'Do not paste passwords, keys or codes here: anything that looks like a secret is hidden before leaving the PC.';

  @override
  String get updateConfigurator => 'Update the configurator';

  @override
  String get updateConfiguratorDetail =>
      'Rebuilds and reinstalls from this repository\'s code; the new version opens on the next start.';

  @override
  String get updateButton => 'Update';

  @override
  String get watchInstallButton => 'Install on the watch (Wi‑Fi)';

  @override
  String get watchInstallTitle => 'Install on the watch over the network';

  @override
  String get watchSteps =>
      '1. On the watch: Settings › About › Software, tap \"Software version\" 7 times to unlock Developer options.\n2. In Developer options, turn on \"ADB debugging\" and \"Debug over Wi‑Fi\" (watch and PC on the same network).\n3. The first time: in Debug over Wi‑Fi › \"Pair new device\", fill in the IP, port and code it shows and tap Pair.\n4. Then: fill in the port shown on the Debug over Wi‑Fi screen (IP:port) and tap Install.';

  @override
  String get watchIp => 'Watch IP';

  @override
  String get watchPairPort => 'Pairing port';

  @override
  String get watchPairCode => '6-digit code';

  @override
  String get watchConnectPort => 'Connection port';

  @override
  String get watchPair => 'Pair';

  @override
  String get watchPaired =>
      'Watch paired. Now fill in the connection port and tap Install.';

  @override
  String get watchInstall => 'Install';

  @override
  String get watchFillFields => 'Fill in the IP and the ports with numbers.';
}
