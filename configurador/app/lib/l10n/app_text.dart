import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_text_en.dart';
import 'app_text_es.dart';
import 'app_text_pt.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppText
/// returned by `AppText.of(context)`.
///
/// Applications need to include `AppText.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_text.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppText.localizationsDelegates,
///   supportedLocales: AppText.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppText.supportedLocales
/// property.
abstract class AppText {
  AppText(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppText of(BuildContext context) {
    return Localizations.of<AppText>(context, AppText)!;
  }

  static const LocalizationsDelegate<AppText> delegate = _AppTextDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
    Locale('pt'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In pt, this message translates to:
  /// **'Solumia: configurador'**
  String get appTitle;

  /// No description provided for @startingCore.
  ///
  /// In pt, this message translates to:
  /// **'Abrindo o cofre e iniciando o núcleo…'**
  String get startingCore;

  /// No description provided for @tryAgain.
  ///
  /// In pt, this message translates to:
  /// **'Tentar de novo'**
  String get tryAgain;

  /// No description provided for @navHome.
  ///
  /// In pt, this message translates to:
  /// **'Início'**
  String get navHome;

  /// No description provided for @navAccount.
  ///
  /// In pt, this message translates to:
  /// **'Conta'**
  String get navAccount;

  /// No description provided for @navVps.
  ///
  /// In pt, this message translates to:
  /// **'VPS'**
  String get navVps;

  /// No description provided for @navFolders.
  ///
  /// In pt, this message translates to:
  /// **'Pastas'**
  String get navFolders;

  /// No description provided for @navCraft.
  ///
  /// In pt, this message translates to:
  /// **'Craft Apps'**
  String get navCraft;

  /// No description provided for @navApps.
  ///
  /// In pt, this message translates to:
  /// **'Apps'**
  String get navApps;

  /// No description provided for @navRunLog.
  ///
  /// In pt, this message translates to:
  /// **'Registro'**
  String get navRunLog;

  /// No description provided for @appearance.
  ///
  /// In pt, this message translates to:
  /// **'Aparência'**
  String get appearance;

  /// No description provided for @theme.
  ///
  /// In pt, this message translates to:
  /// **'Tema'**
  String get theme;

  /// No description provided for @themeSystem.
  ///
  /// In pt, this message translates to:
  /// **'Do sistema'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In pt, this message translates to:
  /// **'Claro'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In pt, this message translates to:
  /// **'Escuro'**
  String get themeDark;

  /// No description provided for @language.
  ///
  /// In pt, this message translates to:
  /// **'Idioma'**
  String get language;

  /// No description provided for @homeVersion.
  ///
  /// In pt, this message translates to:
  /// **'Configurador {versao} · protocolo {protocolo} · {so} {arquitetura}'**
  String homeVersion(
    Object versao,
    Object protocolo,
    Object so,
    Object arquitetura,
  );

  /// No description provided for @homeManifest.
  ///
  /// In pt, this message translates to:
  /// **'Manifesto: {caminho}'**
  String homeManifest(Object caminho);

  /// No description provided for @itemAccount.
  ///
  /// In pt, this message translates to:
  /// **'Conta e autenticador'**
  String get itemAccount;

  /// No description provided for @itemAccountDetail.
  ///
  /// In pt, this message translates to:
  /// **'Usuário, senha e 2º fator'**
  String get itemAccountDetail;

  /// No description provided for @itemVpsDetail.
  ///
  /// In pt, this message translates to:
  /// **'Endereço e domínio'**
  String get itemVpsDetail;

  /// No description provided for @itemFolders.
  ///
  /// In pt, this message translates to:
  /// **'Pastas de mídia'**
  String get itemFolders;

  /// No description provided for @itemFoldersDetail.
  ///
  /// In pt, this message translates to:
  /// **'Imagens, vídeos, áudio, produção'**
  String get itemFoldersDetail;

  /// No description provided for @itemCraftDetail.
  ///
  /// In pt, this message translates to:
  /// **'{instalados} de {total} instalados'**
  String itemCraftDetail(int instalados, int total);

  /// No description provided for @itemApps.
  ///
  /// In pt, this message translates to:
  /// **'Apps Solumia'**
  String get itemApps;

  /// No description provided for @itemAppsDetail.
  ///
  /// In pt, this message translates to:
  /// **'Celular, relógio, PC e notebook'**
  String get itemAppsDetail;

  /// No description provided for @homeCoexistence.
  ///
  /// In pt, this message translates to:
  /// **'Serviços do Solumia usam nomes e portas próprios (prefixo {prefixo}, gateway {gateway}, túnel {tunel}) e não interferem na instalação atual.'**
  String homeCoexistence(Object prefixo, Object gateway, Object tunel);

  /// No description provided for @accountTitle.
  ///
  /// In pt, this message translates to:
  /// **'Conta de acesso'**
  String get accountTitle;

  /// No description provided for @accountDescription.
  ///
  /// In pt, this message translates to:
  /// **'Usuário e senha do app, com segundo fator (Google Authenticator ou similar). A senha nunca sai deste computador: só o hash vai para a VPS.'**
  String get accountDescription;

  /// No description provided for @user.
  ///
  /// In pt, this message translates to:
  /// **'Usuário'**
  String get user;

  /// No description provided for @password.
  ///
  /// In pt, this message translates to:
  /// **'Senha'**
  String get password;

  /// No description provided for @passwordHelp.
  ///
  /// In pt, this message translates to:
  /// **'Mínimo 12 caracteres, maiúsculas, minúsculas e número'**
  String get passwordHelp;

  /// No description provided for @confirmPassword.
  ///
  /// In pt, this message translates to:
  /// **'Confirmar senha'**
  String get confirmPassword;

  /// No description provided for @saveAccount.
  ///
  /// In pt, this message translates to:
  /// **'Salvar conta'**
  String get saveAccount;

  /// No description provided for @passwordsDoNotMatch.
  ///
  /// In pt, this message translates to:
  /// **'As senhas não conferem'**
  String get passwordsDoNotMatch;

  /// No description provided for @accountSaved.
  ///
  /// In pt, this message translates to:
  /// **'Conta salva no cofre (só o hash da senha)'**
  String get accountSaved;

  /// No description provided for @qrInstruction.
  ///
  /// In pt, this message translates to:
  /// **'Escaneie no autenticador. Este QR só aparece agora: ele não é mostrado de novo.'**
  String get qrInstruction;

  /// No description provided for @code6.
  ///
  /// In pt, this message translates to:
  /// **'Código de 6 dígitos'**
  String get code6;

  /// No description provided for @check.
  ///
  /// In pt, this message translates to:
  /// **'Conferir'**
  String get check;

  /// No description provided for @totpOk.
  ///
  /// In pt, this message translates to:
  /// **'Autenticador configurado corretamente.'**
  String get totpOk;

  /// No description provided for @totpFailed.
  ///
  /// In pt, this message translates to:
  /// **'Código não confere. Confira o relógio do celular.'**
  String get totpFailed;

  /// No description provided for @vpsDescription.
  ///
  /// In pt, this message translates to:
  /// **'Instala gateway, túnel, Collabora, nginx e TLS, e endurece SSH e firewall. Tudo com nomes e portas do Solumia, sem tocar na instalação atual.'**
  String get vpsDescription;

  /// No description provided for @topology.
  ///
  /// In pt, this message translates to:
  /// **'Topologia'**
  String get topology;

  /// No description provided for @topologyHybrid.
  ///
  /// In pt, this message translates to:
  /// **'Híbrida (VPS + este PC)'**
  String get topologyHybrid;

  /// No description provided for @topologyCloud.
  ///
  /// In pt, this message translates to:
  /// **'Só nuvem (só VPS)'**
  String get topologyCloud;

  /// No description provided for @domain.
  ///
  /// In pt, this message translates to:
  /// **'Domínio'**
  String get domain;

  /// No description provided for @domainHelp.
  ///
  /// In pt, this message translates to:
  /// **'ex.: solumia.seudominio.com (registro A apontando para a VPS)'**
  String get domainHelp;

  /// No description provided for @emailTls.
  ///
  /// In pt, this message translates to:
  /// **'E-mail para o certificado TLS'**
  String get emailTls;

  /// No description provided for @emailTlsHelp.
  ///
  /// In pt, this message translates to:
  /// **'avisos de expiração do Let\'s Encrypt'**
  String get emailTlsHelp;

  /// No description provided for @cloudflare.
  ///
  /// In pt, this message translates to:
  /// **'Domínio atrás da Cloudflare (proxy)'**
  String get cloudflare;

  /// No description provided for @sshAccess.
  ///
  /// In pt, this message translates to:
  /// **'Acesso SSH'**
  String get sshAccess;

  /// No description provided for @vpsHost.
  ///
  /// In pt, this message translates to:
  /// **'IP ou nome da VPS'**
  String get vpsHost;

  /// No description provided for @port.
  ///
  /// In pt, this message translates to:
  /// **'Porta'**
  String get port;

  /// No description provided for @readFingerprint.
  ///
  /// In pt, this message translates to:
  /// **'Ler impressão digital da VPS'**
  String get readFingerprint;

  /// No description provided for @fingerprintConfirmed.
  ///
  /// In pt, this message translates to:
  /// **'Confirmada: {impressao}'**
  String fingerprintConfirmed(Object impressao);

  /// No description provided for @checkFingerprint.
  ///
  /// In pt, this message translates to:
  /// **'Confira se é a sua VPS antes de confirmar. No painel do provedor (console web) rode:'**
  String get checkFingerprint;

  /// No description provided for @confirmVps.
  ///
  /// In pt, this message translates to:
  /// **'Confirmo: é a minha VPS'**
  String get confirmVps;

  /// No description provided for @firstAccess.
  ///
  /// In pt, this message translates to:
  /// **'Primeiro acesso'**
  String get firstAccess;

  /// No description provided for @firstAccessDescription.
  ///
  /// In pt, this message translates to:
  /// **'A senha é usada uma vez para instalar a chave do configurador e não é gravada. Depois disso o acesso é só por chave.'**
  String get firstAccessDescription;

  /// No description provided for @vpsPassword.
  ///
  /// In pt, this message translates to:
  /// **'Senha da VPS (só no 1º acesso)'**
  String get vpsPassword;

  /// No description provided for @sudoPassword.
  ///
  /// In pt, this message translates to:
  /// **'Senha do sudo (se o usuário não for root)'**
  String get sudoPassword;

  /// No description provided for @disablePassword.
  ///
  /// In pt, this message translates to:
  /// **'Desativar login por senha no SSH (recomendado)'**
  String get disablePassword;

  /// No description provided for @disablePasswordHelp.
  ///
  /// In pt, this message translates to:
  /// **'Com desfazer automático em 5 min se o acesso por chave falhar'**
  String get disablePasswordHelp;

  /// No description provided for @nginxAuto.
  ///
  /// In pt, this message translates to:
  /// **'detectar'**
  String get nginxAuto;

  /// No description provided for @nginxDocker.
  ///
  /// In pt, this message translates to:
  /// **'em contêiner (VPS dedicada)'**
  String get nginxDocker;

  /// No description provided for @nginxHost.
  ///
  /// In pt, this message translates to:
  /// **'nginx já instalado na VPS'**
  String get nginxHost;

  /// No description provided for @save.
  ///
  /// In pt, this message translates to:
  /// **'Salvar'**
  String get save;

  /// No description provided for @viewPlan.
  ///
  /// In pt, this message translates to:
  /// **'Ver plano de instalação'**
  String get viewPlan;

  /// No description provided for @confirmFingerprint.
  ///
  /// In pt, this message translates to:
  /// **'Confirme a impressão digital primeiro'**
  String get confirmFingerprint;

  /// No description provided for @vpsSaved.
  ///
  /// In pt, this message translates to:
  /// **'Configuração da VPS salva'**
  String get vpsSaved;

  /// No description provided for @foldersTitle.
  ///
  /// In pt, this message translates to:
  /// **'Pastas de mídia'**
  String get foldersTitle;

  /// No description provided for @foldersDescription.
  ///
  /// In pt, this message translates to:
  /// **'Onde ficam imagens, vídeos e áudio neste computador ({so}). Podem estar em outro disco. Não podem ser iguais nem uma dentro da outra.'**
  String foldersDescription(Object so);

  /// No description provided for @folderImages.
  ///
  /// In pt, this message translates to:
  /// **'Imagens'**
  String get folderImages;

  /// No description provided for @folderVideos.
  ///
  /// In pt, this message translates to:
  /// **'Vídeos'**
  String get folderVideos;

  /// No description provided for @folderAudio.
  ///
  /// In pt, this message translates to:
  /// **'Áudio'**
  String get folderAudio;

  /// No description provided for @folderProduction.
  ///
  /// In pt, this message translates to:
  /// **'Vídeos para produção'**
  String get folderProduction;

  /// No description provided for @folderProduced.
  ///
  /// In pt, this message translates to:
  /// **'Vídeos produzidos'**
  String get folderProduced;

  /// No description provided for @helpImages.
  ///
  /// In pt, this message translates to:
  /// **'Imagens usadas nos vídeos (acervo e geradas)'**
  String get helpImages;

  /// No description provided for @helpVideos.
  ///
  /// In pt, this message translates to:
  /// **'Acervo de vídeos brutos'**
  String get helpVideos;

  /// No description provided for @helpAudio.
  ///
  /// In pt, this message translates to:
  /// **'Trilhas, efeitos e narrações'**
  String get helpAudio;

  /// No description provided for @helpProduction.
  ///
  /// In pt, this message translates to:
  /// **'Vídeos em produção (entrada da esteira)'**
  String get helpProduction;

  /// No description provided for @helpProduced.
  ///
  /// In pt, this message translates to:
  /// **'Vídeos prontos (saída)'**
  String get helpProduced;

  /// No description provided for @pickFolder.
  ///
  /// In pt, this message translates to:
  /// **'Escolher pasta'**
  String get pickFolder;

  /// No description provided for @useThisFolder.
  ///
  /// In pt, this message translates to:
  /// **'Usar esta pasta'**
  String get useThisFolder;

  /// No description provided for @validate.
  ///
  /// In pt, this message translates to:
  /// **'Validar'**
  String get validate;

  /// No description provided for @saveAndCreate.
  ///
  /// In pt, this message translates to:
  /// **'Salvar e criar pastas'**
  String get saveAndCreate;

  /// No description provided for @fixFolders.
  ///
  /// In pt, this message translates to:
  /// **'Corrija as pastas marcadas'**
  String get fixFolders;

  /// No description provided for @craftDescription.
  ///
  /// In pt, this message translates to:
  /// **'Baixados do GitHub de cada projeto. Antes de instalar, o configurador confere a assinatura (chave fixada) e o SHA-256: um arquivo adulterado nunca é instalado.'**
  String get craftDescription;

  /// No description provided for @craftFilmcraft.
  ///
  /// In pt, this message translates to:
  /// **'Editor de vídeo não linear'**
  String get craftFilmcraft;

  /// No description provided for @craftSoundcraft.
  ///
  /// In pt, this message translates to:
  /// **'Estação de áudio digital (DAW)'**
  String get craftSoundcraft;

  /// No description provided for @craftEffectcraft.
  ///
  /// In pt, this message translates to:
  /// **'Motion graphics e composição'**
  String get craftEffectcraft;

  /// No description provided for @craftPhotocraft.
  ///
  /// In pt, this message translates to:
  /// **'Editor de fotos'**
  String get craftPhotocraft;

  /// No description provided for @checkingVersion.
  ///
  /// In pt, this message translates to:
  /// **'Consultando a última versão…'**
  String get checkingVersion;

  /// No description provided for @latestVersion.
  ///
  /// In pt, this message translates to:
  /// **'Última: {versao} · {arquivo}'**
  String latestVersion(Object versao, Object arquivo);

  /// No description provided for @notInstalled.
  ///
  /// In pt, this message translates to:
  /// **'Não instalado'**
  String get notInstalled;

  /// No description provided for @installedAt.
  ///
  /// In pt, this message translates to:
  /// **'Instalado: {versao} em {caminho}'**
  String installedAt(Object versao, Object caminho);

  /// No description provided for @formatPortable.
  ///
  /// In pt, this message translates to:
  /// **'Portátil (sem administrador)'**
  String get formatPortable;

  /// No description provided for @formatMsi.
  ///
  /// In pt, this message translates to:
  /// **'Instalador .msi'**
  String get formatMsi;

  /// No description provided for @formatAppimage.
  ///
  /// In pt, this message translates to:
  /// **'AppImage (sem administrador)'**
  String get formatAppimage;

  /// No description provided for @formatDeb.
  ///
  /// In pt, this message translates to:
  /// **'.deb (pede administrador)'**
  String get formatDeb;

  /// No description provided for @downloadInstall.
  ///
  /// In pt, this message translates to:
  /// **'Baixar e instalar'**
  String get downloadInstall;

  /// No description provided for @update.
  ///
  /// In pt, this message translates to:
  /// **'Atualizar'**
  String get update;

  /// No description provided for @reinstall.
  ///
  /// In pt, this message translates to:
  /// **'Reinstalar'**
  String get reinstall;

  /// No description provided for @appsTitle.
  ///
  /// In pt, this message translates to:
  /// **'Apps Solumia'**
  String get appsTitle;

  /// No description provided for @appsDescription.
  ///
  /// In pt, this message translates to:
  /// **'O app do Solumia para cada dispositivo, das releases oficiais no GitHub. O configurador confere assinatura e SHA-256 antes de salvar ou instalar.'**
  String get appsDescription;

  /// No description provided for @appPhone.
  ///
  /// In pt, this message translates to:
  /// **'Celular e tablet'**
  String get appPhone;

  /// No description provided for @appPhoneDetail.
  ///
  /// In pt, this message translates to:
  /// **'Android (APK)'**
  String get appPhoneDetail;

  /// No description provided for @appWatch.
  ///
  /// In pt, this message translates to:
  /// **'Relógio'**
  String get appWatch;

  /// No description provided for @appWatchDetail.
  ///
  /// In pt, this message translates to:
  /// **'Wear OS (APK)'**
  String get appWatchDetail;

  /// No description provided for @appLinux.
  ///
  /// In pt, this message translates to:
  /// **'PC e notebook'**
  String get appLinux;

  /// No description provided for @appLinuxDetail.
  ///
  /// In pt, this message translates to:
  /// **'Linux (AppImage)'**
  String get appLinuxDetail;

  /// No description provided for @appWindows.
  ///
  /// In pt, this message translates to:
  /// **'PC e notebook'**
  String get appWindows;

  /// No description provided for @appWindowsDetail.
  ///
  /// In pt, this message translates to:
  /// **'Windows (instalador)'**
  String get appWindowsDetail;

  /// No description provided for @appsVersion.
  ///
  /// In pt, this message translates to:
  /// **'Versão publicada: {versao}'**
  String appsVersion(Object versao);

  /// No description provided for @appsNoRelease.
  ///
  /// In pt, this message translates to:
  /// **'Nenhuma release encontrada. Os arquivos aparecem aqui assim que forem publicados.'**
  String get appsNoRelease;

  /// No description provided for @appsUnsigned.
  ///
  /// In pt, this message translates to:
  /// **'Downloads bloqueados por segurança: a chave que assina as releases do Solumia ainda não foi fixada no configurador.'**
  String get appsUnsigned;

  /// No description provided for @appsFolder.
  ///
  /// In pt, this message translates to:
  /// **'Arquivos salvos em {pasta}'**
  String appsFolder(Object pasta);

  /// No description provided for @openReleases.
  ///
  /// In pt, this message translates to:
  /// **'Abrir releases no GitHub'**
  String get openReleases;

  /// No description provided for @fileUnavailable.
  ///
  /// In pt, this message translates to:
  /// **'Arquivo não publicado nesta versão'**
  String get fileUnavailable;

  /// No description provided for @downloadToThisPc.
  ///
  /// In pt, this message translates to:
  /// **'Baixar para este PC'**
  String get downloadToThisPc;

  /// No description provided for @installOnThisPc.
  ///
  /// In pt, this message translates to:
  /// **'Instalar neste PC'**
  String get installOnThisPc;

  /// No description provided for @showQr.
  ///
  /// In pt, this message translates to:
  /// **'QR para o celular'**
  String get showQr;

  /// No description provided for @qrPhone.
  ///
  /// In pt, this message translates to:
  /// **'Aponte a câmera do celular para baixar direto do GitHub. O Android confere a assinatura do APK ao instalar.'**
  String get qrPhone;

  /// No description provided for @watchInstruction.
  ///
  /// In pt, this message translates to:
  /// **'Instale direto no relógio pela rede Wi‑Fi, ou baixe o APK aqui.'**
  String get watchInstruction;

  /// No description provided for @planNothingChanged.
  ///
  /// In pt, this message translates to:
  /// **'Nada foi alterado ainda. Confira o que vai acontecer:'**
  String get planNothingChanged;

  /// No description provided for @planRun.
  ///
  /// In pt, this message translates to:
  /// **'Execução: {estado}'**
  String planRun(Object estado);

  /// No description provided for @destructiveCode.
  ///
  /// In pt, this message translates to:
  /// **'Código do autenticador (ação destrutiva)'**
  String get destructiveCode;

  /// No description provided for @cancel.
  ///
  /// In pt, this message translates to:
  /// **'Cancelar'**
  String get cancel;

  /// No description provided for @apply.
  ///
  /// In pt, this message translates to:
  /// **'Aplicar'**
  String get apply;

  /// No description provided for @stopAfterStep.
  ///
  /// In pt, this message translates to:
  /// **'Parar após o passo atual'**
  String get stopAfterStep;

  /// No description provided for @close.
  ///
  /// In pt, this message translates to:
  /// **'Fechar'**
  String get close;

  /// No description provided for @stateRunning.
  ///
  /// In pt, this message translates to:
  /// **'em andamento…'**
  String get stateRunning;

  /// No description provided for @stateFinished.
  ///
  /// In pt, this message translates to:
  /// **'concluída'**
  String get stateFinished;

  /// No description provided for @stateFailed.
  ///
  /// In pt, this message translates to:
  /// **'falhou (pode corrigir e aplicar de novo: retoma de onde parou)'**
  String get stateFailed;

  /// No description provided for @stateCancelled.
  ///
  /// In pt, this message translates to:
  /// **'parada'**
  String get stateCancelled;

  /// No description provided for @runLogTitle.
  ///
  /// In pt, this message translates to:
  /// **'Registro'**
  String get runLogTitle;

  /// No description provided for @runLogEmpty.
  ///
  /// In pt, this message translates to:
  /// **'Nenhuma aplicação ainda.'**
  String get runLogEmpty;

  /// No description provided for @navWorker.
  ///
  /// In pt, this message translates to:
  /// **'Worker'**
  String get navWorker;

  /// No description provided for @navAssistant.
  ///
  /// In pt, this message translates to:
  /// **'Assistente'**
  String get navAssistant;

  /// No description provided for @itemWorker.
  ///
  /// In pt, this message translates to:
  /// **'Worker neste PC'**
  String get itemWorker;

  /// No description provided for @itemWorkerDetail.
  ///
  /// In pt, this message translates to:
  /// **'Serviço solumia-worker, em paralelo ao agent-worker'**
  String get itemWorkerDetail;

  /// No description provided for @workerIntro.
  ///
  /// In pt, this message translates to:
  /// **'O worker roda neste PC como serviço do usuário e conecta ao gateway da sua VPS. Ele tem nome, porta e configuração próprios: o worker da instalação antiga continua como está.'**
  String get workerIntro;

  /// No description provided for @workerState.
  ///
  /// In pt, this message translates to:
  /// **'{unidade}: {estado}'**
  String workerState(String unidade, String estado);

  /// No description provided for @workerLlama.
  ///
  /// In pt, this message translates to:
  /// **'llama-server do Solumia na porta {porta} (o antigo usa 8081). Os dois dividem a GPU: evite usar os dois ao mesmo tempo com modelos grandes.'**
  String workerLlama(String porta);

  /// No description provided for @workerInstall.
  ///
  /// In pt, this message translates to:
  /// **'Instalar ou atualizar o worker'**
  String get workerInstall;

  /// No description provided for @assistantIntro.
  ///
  /// In pt, this message translates to:
  /// **'O Claude Code deste PC ajuda você a seguir as etapas. Ele não tem ferramentas: não lê arquivos, não roda comandos e não aplica nada. Recebe só o estado resumido abaixo, sem senhas, chaves, IPs, domínio ou usuários, e a conversa fica só na memória desta sessão.'**
  String get assistantIntro;

  /// No description provided for @assistantUnavailable.
  ///
  /// In pt, this message translates to:
  /// **'Claude Code não encontrado neste computador. Instale e faça login no Claude Code para usar o assistente.'**
  String get assistantUnavailable;

  /// No description provided for @assistantHint.
  ///
  /// In pt, this message translates to:
  /// **'Pergunte, por exemplo: por onde eu começo?'**
  String get assistantHint;

  /// No description provided for @assistantSend.
  ///
  /// In pt, this message translates to:
  /// **'Enviar'**
  String get assistantSend;

  /// No description provided for @assistantClear.
  ///
  /// In pt, this message translates to:
  /// **'Limpar conversa'**
  String get assistantClear;

  /// No description provided for @assistantContext.
  ///
  /// In pt, this message translates to:
  /// **'O que o Claude recebe'**
  String get assistantContext;

  /// No description provided for @assistantOpenScreen.
  ///
  /// In pt, this message translates to:
  /// **'Abrir a tela sugerida'**
  String get assistantOpenScreen;

  /// No description provided for @assistantThinking.
  ///
  /// In pt, this message translates to:
  /// **'O Claude está pensando…'**
  String get assistantThinking;

  /// No description provided for @assistantNoSecrets.
  ///
  /// In pt, this message translates to:
  /// **'Não cole senhas, chaves ou códigos aqui: o que parecer segredo é ocultado antes de sair do PC.'**
  String get assistantNoSecrets;

  /// No description provided for @updateConfigurator.
  ///
  /// In pt, this message translates to:
  /// **'Atualizar o configurador'**
  String get updateConfigurator;

  /// No description provided for @updateConfiguratorDetail.
  ///
  /// In pt, this message translates to:
  /// **'Compila e reinstala a partir do código deste repositório; a versão nova abre no próximo início.'**
  String get updateConfiguratorDetail;

  /// No description provided for @updateButton.
  ///
  /// In pt, this message translates to:
  /// **'Atualizar'**
  String get updateButton;

  /// No description provided for @watchInstallButton.
  ///
  /// In pt, this message translates to:
  /// **'Instalar no relógio (Wi‑Fi)'**
  String get watchInstallButton;

  /// No description provided for @watchInstallTitle.
  ///
  /// In pt, this message translates to:
  /// **'Instalar no relógio pela rede'**
  String get watchInstallTitle;

  /// No description provided for @watchSteps.
  ///
  /// In pt, this message translates to:
  /// **'1. No relógio: Configurações › Sobre › Software, toque 7 vezes em \"Versão do software\" para liberar as Opções do desenvolvedor.\n2. Em Opções do desenvolvedor, ligue \"Depuração ADB\" e \"Depuração por Wi‑Fi\". Deixe o relógio no carregador, com a tela ligada, para o Wi‑Fi não dormir.\n3. Primeira vez: em Depuração por Wi‑Fi › \"Parear novo dispositivo\", preencha o IP, a porta e o código mostrados.\n4. Toque em Instalar. Das próximas vezes basta o IP: deixe a porta e o código em branco.'**
  String get watchSteps;

  /// No description provided for @watchIp.
  ///
  /// In pt, this message translates to:
  /// **'IP do relógio'**
  String get watchIp;

  /// No description provided for @watchPairPort.
  ///
  /// In pt, this message translates to:
  /// **'Porta de pareamento (só na 1ª vez)'**
  String get watchPairPort;

  /// No description provided for @watchPairCode.
  ///
  /// In pt, this message translates to:
  /// **'Código (só na 1ª vez)'**
  String get watchPairCode;

  /// No description provided for @watchPaired.
  ///
  /// In pt, this message translates to:
  /// **'Relógio pareado. Instalando…'**
  String get watchPaired;

  /// No description provided for @watchInstall.
  ///
  /// In pt, this message translates to:
  /// **'Instalar'**
  String get watchInstall;

  /// No description provided for @watchFillFields.
  ///
  /// In pt, this message translates to:
  /// **'Preencha o IP do relógio; na primeira vez, também a porta de pareamento e o código.'**
  String get watchFillFields;
}

class _AppTextDelegate extends LocalizationsDelegate<AppText> {
  const _AppTextDelegate();

  @override
  Future<AppText> load(Locale locale) {
    return SynchronousFuture<AppText>(lookupAppText(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppTextDelegate old) => false;
}

AppText lookupAppText(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppTextEn();
    case 'es':
      return AppTextEs();
    case 'pt':
      return AppTextPt();
  }

  throw FlutterError(
    'AppText.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
