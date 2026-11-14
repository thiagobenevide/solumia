import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'textos_en.dart';
import 'textos_es.dart';
import 'textos_pt.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of Textos
/// returned by `Textos.of(context)`.
///
/// Applications need to include `Textos.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/textos.dart';
///
/// return MaterialApp(
///   localizationsDelegates: Textos.localizationsDelegates,
///   supportedLocales: Textos.supportedLocales,
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
/// be consistent with the languages listed in the Textos.supportedLocales
/// property.
abstract class Textos {
  Textos(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static Textos of(BuildContext context) {
    return Localizations.of<Textos>(context, Textos)!;
  }

  static const LocalizationsDelegate<Textos> delegate = _TextosDelegate();

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

  /// No description provided for @appTitulo.
  ///
  /// In pt, this message translates to:
  /// **'Solumia: configurador'**
  String get appTitulo;

  /// No description provided for @iniciandoNucleo.
  ///
  /// In pt, this message translates to:
  /// **'Abrindo o cofre e iniciando o núcleo…'**
  String get iniciandoNucleo;

  /// No description provided for @tentarDeNovo.
  ///
  /// In pt, this message translates to:
  /// **'Tentar de novo'**
  String get tentarDeNovo;

  /// No description provided for @navInicio.
  ///
  /// In pt, this message translates to:
  /// **'Início'**
  String get navInicio;

  /// No description provided for @navConta.
  ///
  /// In pt, this message translates to:
  /// **'Conta'**
  String get navConta;

  /// No description provided for @navVps.
  ///
  /// In pt, this message translates to:
  /// **'VPS'**
  String get navVps;

  /// No description provided for @navPastas.
  ///
  /// In pt, this message translates to:
  /// **'Pastas'**
  String get navPastas;

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

  /// No description provided for @navRegistro.
  ///
  /// In pt, this message translates to:
  /// **'Registro'**
  String get navRegistro;

  /// No description provided for @aparencia.
  ///
  /// In pt, this message translates to:
  /// **'Aparência'**
  String get aparencia;

  /// No description provided for @tema.
  ///
  /// In pt, this message translates to:
  /// **'Tema'**
  String get tema;

  /// No description provided for @temaSistema.
  ///
  /// In pt, this message translates to:
  /// **'Do sistema'**
  String get temaSistema;

  /// No description provided for @temaClaro.
  ///
  /// In pt, this message translates to:
  /// **'Claro'**
  String get temaClaro;

  /// No description provided for @temaEscuro.
  ///
  /// In pt, this message translates to:
  /// **'Escuro'**
  String get temaEscuro;

  /// No description provided for @idioma.
  ///
  /// In pt, this message translates to:
  /// **'Idioma'**
  String get idioma;

  /// No description provided for @inicioVersao.
  ///
  /// In pt, this message translates to:
  /// **'Configurador {versao} · protocolo {protocolo} · {so} {arquitetura}'**
  String inicioVersao(
    Object versao,
    Object protocolo,
    Object so,
    Object arquitetura,
  );

  /// No description provided for @inicioManifesto.
  ///
  /// In pt, this message translates to:
  /// **'Manifesto: {caminho}'**
  String inicioManifesto(Object caminho);

  /// No description provided for @itemConta.
  ///
  /// In pt, this message translates to:
  /// **'Conta e autenticador'**
  String get itemConta;

  /// No description provided for @itemContaDetalhe.
  ///
  /// In pt, this message translates to:
  /// **'Usuário, senha e 2º fator'**
  String get itemContaDetalhe;

  /// No description provided for @itemVpsDetalhe.
  ///
  /// In pt, this message translates to:
  /// **'Endereço e domínio'**
  String get itemVpsDetalhe;

  /// No description provided for @itemPastas.
  ///
  /// In pt, this message translates to:
  /// **'Pastas de mídia'**
  String get itemPastas;

  /// No description provided for @itemPastasDetalhe.
  ///
  /// In pt, this message translates to:
  /// **'Imagens, vídeos, áudio, produção'**
  String get itemPastasDetalhe;

  /// No description provided for @itemCraftDetalhe.
  ///
  /// In pt, this message translates to:
  /// **'{instalados} de {total} instalados'**
  String itemCraftDetalhe(int instalados, int total);

  /// No description provided for @itemApps.
  ///
  /// In pt, this message translates to:
  /// **'Apps Solumia'**
  String get itemApps;

  /// No description provided for @itemAppsDetalhe.
  ///
  /// In pt, this message translates to:
  /// **'Celular, relógio, PC e notebook'**
  String get itemAppsDetalhe;

  /// No description provided for @inicioConvivencia.
  ///
  /// In pt, this message translates to:
  /// **'Serviços do Solumia usam nomes e portas próprios (prefixo {prefixo}, gateway {gateway}, túnel {tunel}) e não interferem na instalação atual.'**
  String inicioConvivencia(Object prefixo, Object gateway, Object tunel);

  /// No description provided for @contaTitulo.
  ///
  /// In pt, this message translates to:
  /// **'Conta de acesso'**
  String get contaTitulo;

  /// No description provided for @contaDescricao.
  ///
  /// In pt, this message translates to:
  /// **'Usuário e senha do app, com segundo fator (Google Authenticator ou similar). A senha nunca sai deste computador: só o hash vai para a VPS.'**
  String get contaDescricao;

  /// No description provided for @usuario.
  ///
  /// In pt, this message translates to:
  /// **'Usuário'**
  String get usuario;

  /// No description provided for @senha.
  ///
  /// In pt, this message translates to:
  /// **'Senha'**
  String get senha;

  /// No description provided for @senhaAjuda.
  ///
  /// In pt, this message translates to:
  /// **'Mínimo 12 caracteres, maiúsculas, minúsculas e número'**
  String get senhaAjuda;

  /// No description provided for @confirmarSenha.
  ///
  /// In pt, this message translates to:
  /// **'Confirmar senha'**
  String get confirmarSenha;

  /// No description provided for @salvarConta.
  ///
  /// In pt, this message translates to:
  /// **'Salvar conta'**
  String get salvarConta;

  /// No description provided for @senhasNaoConferem.
  ///
  /// In pt, this message translates to:
  /// **'As senhas não conferem'**
  String get senhasNaoConferem;

  /// No description provided for @contaSalva.
  ///
  /// In pt, this message translates to:
  /// **'Conta salva no cofre (só o hash da senha)'**
  String get contaSalva;

  /// No description provided for @qrInstrucao.
  ///
  /// In pt, this message translates to:
  /// **'Escaneie no autenticador. Este QR só aparece agora: ele não é mostrado de novo.'**
  String get qrInstrucao;

  /// No description provided for @codigo6.
  ///
  /// In pt, this message translates to:
  /// **'Código de 6 dígitos'**
  String get codigo6;

  /// No description provided for @conferir.
  ///
  /// In pt, this message translates to:
  /// **'Conferir'**
  String get conferir;

  /// No description provided for @totpOk.
  ///
  /// In pt, this message translates to:
  /// **'Autenticador configurado corretamente.'**
  String get totpOk;

  /// No description provided for @totpFalhou.
  ///
  /// In pt, this message translates to:
  /// **'Código não confere. Confira o relógio do celular.'**
  String get totpFalhou;

  /// No description provided for @vpsDescricao.
  ///
  /// In pt, this message translates to:
  /// **'Instala gateway, túnel, Collabora, nginx e TLS, e endurece SSH e firewall. Tudo com nomes e portas do Solumia, sem tocar na instalação atual.'**
  String get vpsDescricao;

  /// No description provided for @topologia.
  ///
  /// In pt, this message translates to:
  /// **'Topologia'**
  String get topologia;

  /// No description provided for @topoHibrida.
  ///
  /// In pt, this message translates to:
  /// **'Híbrida (VPS + este PC)'**
  String get topoHibrida;

  /// No description provided for @topoNuvem.
  ///
  /// In pt, this message translates to:
  /// **'Só nuvem (só VPS)'**
  String get topoNuvem;

  /// No description provided for @dominio.
  ///
  /// In pt, this message translates to:
  /// **'Domínio'**
  String get dominio;

  /// No description provided for @dominioAjuda.
  ///
  /// In pt, this message translates to:
  /// **'ex.: solumia.seudominio.com (registro A apontando para a VPS)'**
  String get dominioAjuda;

  /// No description provided for @emailTls.
  ///
  /// In pt, this message translates to:
  /// **'E-mail para o certificado TLS'**
  String get emailTls;

  /// No description provided for @emailTlsAjuda.
  ///
  /// In pt, this message translates to:
  /// **'avisos de expiração do Let\'s Encrypt'**
  String get emailTlsAjuda;

  /// No description provided for @cloudflare.
  ///
  /// In pt, this message translates to:
  /// **'Domínio atrás da Cloudflare (proxy)'**
  String get cloudflare;

  /// No description provided for @acessoSsh.
  ///
  /// In pt, this message translates to:
  /// **'Acesso SSH'**
  String get acessoSsh;

  /// No description provided for @hostVps.
  ///
  /// In pt, this message translates to:
  /// **'IP ou nome da VPS'**
  String get hostVps;

  /// No description provided for @porta.
  ///
  /// In pt, this message translates to:
  /// **'Porta'**
  String get porta;

  /// No description provided for @lerImpressao.
  ///
  /// In pt, this message translates to:
  /// **'Ler impressão digital da VPS'**
  String get lerImpressao;

  /// No description provided for @impressaoConfirmada.
  ///
  /// In pt, this message translates to:
  /// **'Confirmada: {impressao}'**
  String impressaoConfirmada(Object impressao);

  /// No description provided for @conferirImpressao.
  ///
  /// In pt, this message translates to:
  /// **'Confira se é a sua VPS antes de confirmar. No painel do provedor (console web) rode:'**
  String get conferirImpressao;

  /// No description provided for @confirmoVps.
  ///
  /// In pt, this message translates to:
  /// **'Confirmo: é a minha VPS'**
  String get confirmoVps;

  /// No description provided for @primeiroAcesso.
  ///
  /// In pt, this message translates to:
  /// **'Primeiro acesso'**
  String get primeiroAcesso;

  /// No description provided for @primeiroAcessoDescricao.
  ///
  /// In pt, this message translates to:
  /// **'A senha é usada uma vez para instalar a chave do configurador e não é gravada. Depois disso o acesso é só por chave.'**
  String get primeiroAcessoDescricao;

  /// No description provided for @senhaVps.
  ///
  /// In pt, this message translates to:
  /// **'Senha da VPS (só no 1º acesso)'**
  String get senhaVps;

  /// No description provided for @senhaSudo.
  ///
  /// In pt, this message translates to:
  /// **'Senha do sudo (se o usuário não for root)'**
  String get senhaSudo;

  /// No description provided for @desativarSenha.
  ///
  /// In pt, this message translates to:
  /// **'Desativar login por senha no SSH (recomendado)'**
  String get desativarSenha;

  /// No description provided for @desativarSenhaAjuda.
  ///
  /// In pt, this message translates to:
  /// **'Com desfazer automático em 5 min se o acesso por chave falhar'**
  String get desativarSenhaAjuda;

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

  /// No description provided for @salvar.
  ///
  /// In pt, this message translates to:
  /// **'Salvar'**
  String get salvar;

  /// No description provided for @verPlano.
  ///
  /// In pt, this message translates to:
  /// **'Ver plano de instalação'**
  String get verPlano;

  /// No description provided for @confirmeImpressao.
  ///
  /// In pt, this message translates to:
  /// **'Confirme a impressão digital primeiro'**
  String get confirmeImpressao;

  /// No description provided for @vpsSalva.
  ///
  /// In pt, this message translates to:
  /// **'Configuração da VPS salva'**
  String get vpsSalva;

  /// No description provided for @pastasTitulo.
  ///
  /// In pt, this message translates to:
  /// **'Pastas de mídia'**
  String get pastasTitulo;

  /// No description provided for @pastasDescricao.
  ///
  /// In pt, this message translates to:
  /// **'Onde ficam imagens, vídeos e áudio neste computador ({so}). Podem estar em outro disco. Não podem ser iguais nem uma dentro da outra.'**
  String pastasDescricao(Object so);

  /// No description provided for @pastaImagens.
  ///
  /// In pt, this message translates to:
  /// **'Imagens'**
  String get pastaImagens;

  /// No description provided for @pastaVideos.
  ///
  /// In pt, this message translates to:
  /// **'Vídeos'**
  String get pastaVideos;

  /// No description provided for @pastaAudio.
  ///
  /// In pt, this message translates to:
  /// **'Áudio'**
  String get pastaAudio;

  /// No description provided for @pastaProducao.
  ///
  /// In pt, this message translates to:
  /// **'Vídeos para produção'**
  String get pastaProducao;

  /// No description provided for @pastaProduzidos.
  ///
  /// In pt, this message translates to:
  /// **'Vídeos produzidos'**
  String get pastaProduzidos;

  /// No description provided for @ajudaImagens.
  ///
  /// In pt, this message translates to:
  /// **'Imagens usadas nos vídeos (acervo e geradas)'**
  String get ajudaImagens;

  /// No description provided for @ajudaVideos.
  ///
  /// In pt, this message translates to:
  /// **'Acervo de vídeos brutos'**
  String get ajudaVideos;

  /// No description provided for @ajudaAudio.
  ///
  /// In pt, this message translates to:
  /// **'Trilhas, efeitos e narrações'**
  String get ajudaAudio;

  /// No description provided for @ajudaProducao.
  ///
  /// In pt, this message translates to:
  /// **'Vídeos em produção (entrada da esteira)'**
  String get ajudaProducao;

  /// No description provided for @ajudaProduzidos.
  ///
  /// In pt, this message translates to:
  /// **'Vídeos prontos (saída)'**
  String get ajudaProduzidos;

  /// No description provided for @escolherPasta.
  ///
  /// In pt, this message translates to:
  /// **'Escolher pasta'**
  String get escolherPasta;

  /// No description provided for @usarEstaPasta.
  ///
  /// In pt, this message translates to:
  /// **'Usar esta pasta'**
  String get usarEstaPasta;

  /// No description provided for @validar.
  ///
  /// In pt, this message translates to:
  /// **'Validar'**
  String get validar;

  /// No description provided for @salvarECriar.
  ///
  /// In pt, this message translates to:
  /// **'Salvar e criar pastas'**
  String get salvarECriar;

  /// No description provided for @corrijaPastas.
  ///
  /// In pt, this message translates to:
  /// **'Corrija as pastas marcadas'**
  String get corrijaPastas;

  /// No description provided for @craftDescricao.
  ///
  /// In pt, this message translates to:
  /// **'Baixados do GitHub de cada projeto. Antes de instalar, o configurador confere a assinatura (chave fixada) e o SHA-256: um arquivo adulterado nunca é instalado.'**
  String get craftDescricao;

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

  /// No description provided for @consultandoVersao.
  ///
  /// In pt, this message translates to:
  /// **'Consultando a última versão…'**
  String get consultandoVersao;

  /// No description provided for @ultimaVersao.
  ///
  /// In pt, this message translates to:
  /// **'Última: {versao} · {arquivo}'**
  String ultimaVersao(Object versao, Object arquivo);

  /// No description provided for @naoInstalado.
  ///
  /// In pt, this message translates to:
  /// **'Não instalado'**
  String get naoInstalado;

  /// No description provided for @instaladoEm.
  ///
  /// In pt, this message translates to:
  /// **'Instalado: {versao} em {caminho}'**
  String instaladoEm(Object versao, Object caminho);

  /// No description provided for @formatoPortatil.
  ///
  /// In pt, this message translates to:
  /// **'Portátil (sem administrador)'**
  String get formatoPortatil;

  /// No description provided for @formatoMsi.
  ///
  /// In pt, this message translates to:
  /// **'Instalador .msi'**
  String get formatoMsi;

  /// No description provided for @formatoAppimage.
  ///
  /// In pt, this message translates to:
  /// **'AppImage (sem administrador)'**
  String get formatoAppimage;

  /// No description provided for @formatoDeb.
  ///
  /// In pt, this message translates to:
  /// **'.deb (pede administrador)'**
  String get formatoDeb;

  /// No description provided for @baixarInstalar.
  ///
  /// In pt, this message translates to:
  /// **'Baixar e instalar'**
  String get baixarInstalar;

  /// No description provided for @atualizar.
  ///
  /// In pt, this message translates to:
  /// **'Atualizar'**
  String get atualizar;

  /// No description provided for @reinstalar.
  ///
  /// In pt, this message translates to:
  /// **'Reinstalar'**
  String get reinstalar;

  /// No description provided for @appsTitulo.
  ///
  /// In pt, this message translates to:
  /// **'Apps Solumia'**
  String get appsTitulo;

  /// No description provided for @appsDescricao.
  ///
  /// In pt, this message translates to:
  /// **'O app do Solumia para cada dispositivo, das releases oficiais no GitHub. O configurador confere assinatura e SHA-256 antes de salvar ou instalar.'**
  String get appsDescricao;

  /// No description provided for @appCelular.
  ///
  /// In pt, this message translates to:
  /// **'Celular e tablet'**
  String get appCelular;

  /// No description provided for @appCelularDetalhe.
  ///
  /// In pt, this message translates to:
  /// **'Android (APK)'**
  String get appCelularDetalhe;

  /// No description provided for @appRelogio.
  ///
  /// In pt, this message translates to:
  /// **'Relógio'**
  String get appRelogio;

  /// No description provided for @appRelogioDetalhe.
  ///
  /// In pt, this message translates to:
  /// **'Wear OS (APK)'**
  String get appRelogioDetalhe;

  /// No description provided for @appLinux.
  ///
  /// In pt, this message translates to:
  /// **'PC e notebook'**
  String get appLinux;

  /// No description provided for @appLinuxDetalhe.
  ///
  /// In pt, this message translates to:
  /// **'Linux (AppImage)'**
  String get appLinuxDetalhe;

  /// No description provided for @appWindows.
  ///
  /// In pt, this message translates to:
  /// **'PC e notebook'**
  String get appWindows;

  /// No description provided for @appWindowsDetalhe.
  ///
  /// In pt, this message translates to:
  /// **'Windows (instalador)'**
  String get appWindowsDetalhe;

  /// No description provided for @appsVersao.
  ///
  /// In pt, this message translates to:
  /// **'Versão publicada: {versao}'**
  String appsVersao(Object versao);

  /// No description provided for @appsSemRelease.
  ///
  /// In pt, this message translates to:
  /// **'Nenhuma release encontrada. Os arquivos aparecem aqui assim que forem publicados.'**
  String get appsSemRelease;

  /// No description provided for @appsSemAssinatura.
  ///
  /// In pt, this message translates to:
  /// **'Downloads bloqueados por segurança: a chave que assina as releases do Solumia ainda não foi fixada no configurador.'**
  String get appsSemAssinatura;

  /// No description provided for @appsPasta.
  ///
  /// In pt, this message translates to:
  /// **'Arquivos salvos em {pasta}'**
  String appsPasta(Object pasta);

  /// No description provided for @abrirReleases.
  ///
  /// In pt, this message translates to:
  /// **'Abrir releases no GitHub'**
  String get abrirReleases;

  /// No description provided for @arquivoIndisponivel.
  ///
  /// In pt, this message translates to:
  /// **'Arquivo não publicado nesta versão'**
  String get arquivoIndisponivel;

  /// No description provided for @baixarParaEstePc.
  ///
  /// In pt, this message translates to:
  /// **'Baixar para este PC'**
  String get baixarParaEstePc;

  /// No description provided for @instalarNestePc.
  ///
  /// In pt, this message translates to:
  /// **'Instalar neste PC'**
  String get instalarNestePc;

  /// No description provided for @mostrarQr.
  ///
  /// In pt, this message translates to:
  /// **'QR para o celular'**
  String get mostrarQr;

  /// No description provided for @qrCelular.
  ///
  /// In pt, this message translates to:
  /// **'Aponte a câmera do celular para baixar direto do GitHub. O Android confere a assinatura do APK ao instalar.'**
  String get qrCelular;

  /// No description provided for @relogioInstrucao.
  ///
  /// In pt, this message translates to:
  /// **'Baixe o APK aqui e envie ao relógio pelo app do celular ou instale no próprio relógio.'**
  String get relogioInstrucao;

  /// No description provided for @planoNadaAlterado.
  ///
  /// In pt, this message translates to:
  /// **'Nada foi alterado ainda. Confira o que vai acontecer:'**
  String get planoNadaAlterado;

  /// No description provided for @planoExecucao.
  ///
  /// In pt, this message translates to:
  /// **'Execução: {estado}'**
  String planoExecucao(Object estado);

  /// No description provided for @codigoDestrutivo.
  ///
  /// In pt, this message translates to:
  /// **'Código do autenticador (ação destrutiva)'**
  String get codigoDestrutivo;

  /// No description provided for @cancelar.
  ///
  /// In pt, this message translates to:
  /// **'Cancelar'**
  String get cancelar;

  /// No description provided for @aplicar.
  ///
  /// In pt, this message translates to:
  /// **'Aplicar'**
  String get aplicar;

  /// No description provided for @pararAposPasso.
  ///
  /// In pt, this message translates to:
  /// **'Parar após o passo atual'**
  String get pararAposPasso;

  /// No description provided for @fechar.
  ///
  /// In pt, this message translates to:
  /// **'Fechar'**
  String get fechar;

  /// No description provided for @estadoRodando.
  ///
  /// In pt, this message translates to:
  /// **'em andamento…'**
  String get estadoRodando;

  /// No description provided for @estadoConcluida.
  ///
  /// In pt, this message translates to:
  /// **'concluída'**
  String get estadoConcluida;

  /// No description provided for @estadoFalhou.
  ///
  /// In pt, this message translates to:
  /// **'falhou (pode corrigir e aplicar de novo: retoma de onde parou)'**
  String get estadoFalhou;

  /// No description provided for @estadoCancelada.
  ///
  /// In pt, this message translates to:
  /// **'parada'**
  String get estadoCancelada;

  /// No description provided for @registroTitulo.
  ///
  /// In pt, this message translates to:
  /// **'Registro'**
  String get registroTitulo;

  /// No description provided for @registroVazio.
  ///
  /// In pt, this message translates to:
  /// **'Nenhuma aplicação ainda.'**
  String get registroVazio;
}

class _TextosDelegate extends LocalizationsDelegate<Textos> {
  const _TextosDelegate();

  @override
  Future<Textos> load(Locale locale) {
    return SynchronousFuture<Textos>(lookupTextos(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_TextosDelegate old) => false;
}

Textos lookupTextos(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return TextosEn();
    case 'es':
      return TextosEs();
    case 'pt':
      return TextosPt();
  }

  throw FlutterError(
    'Textos.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
