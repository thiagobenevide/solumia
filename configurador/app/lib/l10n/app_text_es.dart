// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_text.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppTextEs extends AppText {
  AppTextEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'Solumia: configurador';

  @override
  String get startingCore => 'Abriendo la bóveda e iniciando el núcleo…';

  @override
  String get tryAgain => 'Intentar de nuevo';

  @override
  String get navHome => 'Inicio';

  @override
  String get navAccount => 'Cuenta';

  @override
  String get navVps => 'VPS';

  @override
  String get navFolders => 'Carpetas';

  @override
  String get navCraft => 'Craft Apps';

  @override
  String get navApps => 'Apps';

  @override
  String get navRunLog => 'Historial';

  @override
  String get appearance => 'Apariencia';

  @override
  String get theme => 'Tema';

  @override
  String get themeSystem => 'Del sistema';

  @override
  String get themeLight => 'Claro';

  @override
  String get themeDark => 'Oscuro';

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
    return 'Manifiesto: $caminho';
  }

  @override
  String get itemAccount => 'Cuenta y autenticador';

  @override
  String get itemAccountDetail => 'Usuario, contraseña y 2.º factor';

  @override
  String get itemVpsDetail => 'Dirección y dominio';

  @override
  String get itemFolders => 'Carpetas de medios';

  @override
  String get itemFoldersDetail => 'Imágenes, videos, audio, producción';

  @override
  String itemCraftDetail(int instalados, int total) {
    return '$instalados de $total instalados';
  }

  @override
  String get itemApps => 'Apps Solumia';

  @override
  String get itemAppsDetail => 'Celular, reloj, PC y portátil';

  @override
  String homeCoexistence(Object prefixo, Object gateway, Object tunel) {
    return 'Los servicios de Solumia usan nombres y puertos propios (prefijo $prefixo, gateway $gateway, túnel $tunel) y no interfieren con la instalación actual.';
  }

  @override
  String get accountTitle => 'Cuenta de acceso';

  @override
  String get accountDescription =>
      'Usuario y contraseña de la app, con segundo factor (Google Authenticator o similar). La contraseña nunca sale de este equipo: solo el hash va a la VPS.';

  @override
  String get user => 'Usuario';

  @override
  String get password => 'Contraseña';

  @override
  String get passwordHelp =>
      'Mínimo 12 caracteres, mayúsculas, minúsculas y un número';

  @override
  String get confirmPassword => 'Confirmar contraseña';

  @override
  String get saveAccount => 'Guardar cuenta';

  @override
  String get passwordsDoNotMatch => 'Las contraseñas no coinciden';

  @override
  String get accountSaved =>
      'Cuenta guardada en la bóveda (solo el hash de la contraseña)';

  @override
  String get qrInstruction =>
      'Escanéalo con el autenticador. Este QR solo aparece ahora: no se mostrará de nuevo.';

  @override
  String get code6 => 'Código de 6 dígitos';

  @override
  String get check => 'Verificar';

  @override
  String get totpOk => 'Autenticador configurado correctamente.';

  @override
  String get totpFailed => 'El código no coincide. Revisa la hora del celular.';

  @override
  String get vpsDescription =>
      'Instala gateway, túnel, Collabora, nginx y TLS, y refuerza SSH y el firewall. Todo con nombres y puertos de Solumia, sin tocar la instalación actual.';

  @override
  String get topology => 'Topología';

  @override
  String get topologyHybrid => 'Híbrida (VPS + este PC)';

  @override
  String get topologyCloud => 'Solo nube (solo VPS)';

  @override
  String get domain => 'Dominio';

  @override
  String get domainHelp =>
      'ej.: solumia.tudominio.com (registro A apuntando a la VPS)';

  @override
  String get emailTls => 'Correo para el certificado TLS';

  @override
  String get emailTlsHelp => 'avisos de vencimiento de Let\'s Encrypt';

  @override
  String get cloudflare => 'Dominio detrás de Cloudflare (proxy)';

  @override
  String get sshAccess => 'Acceso SSH';

  @override
  String get vpsHost => 'IP o nombre de la VPS';

  @override
  String get port => 'Puerto';

  @override
  String get readFingerprint => 'Leer la huella digital de la VPS';

  @override
  String fingerprintConfirmed(Object impressao) {
    return 'Confirmada: $impressao';
  }

  @override
  String get checkFingerprint =>
      'Comprueba que es tu VPS antes de confirmar. En el panel del proveedor (consola web) ejecuta:';

  @override
  String get confirmVps => 'Confirmo: es mi VPS';

  @override
  String get firstAccess => 'Primer acceso';

  @override
  String get firstAccessDescription =>
      'La contraseña se usa una vez para instalar la clave del configurador y no se guarda. Después el acceso es solo por clave.';

  @override
  String get vpsPassword => 'Contraseña de la VPS (solo en el 1.er acceso)';

  @override
  String get sudoPassword => 'Contraseña de sudo (si el usuario no es root)';

  @override
  String get disablePassword =>
      'Desactivar el inicio de sesión por contraseña en SSH (recomendado)';

  @override
  String get disablePasswordHelp =>
      'Se deshace automáticamente en 5 min si falla el acceso por clave';

  @override
  String get nginxAuto => 'detectar';

  @override
  String get nginxDocker => 'en contenedor (VPS dedicada)';

  @override
  String get nginxHost => 'nginx ya instalado en la VPS';

  @override
  String get save => 'Guardar';

  @override
  String get viewPlan => 'Ver plan de instalación';

  @override
  String get confirmFingerprint => 'Confirma primero la huella digital';

  @override
  String get vpsSaved => 'Configuración de la VPS guardada';

  @override
  String get foldersTitle => 'Carpetas de medios';

  @override
  String foldersDescription(Object so) {
    return 'Dónde se guardan imágenes, videos y audio en este equipo ($so). Pueden estar en otro disco. No pueden ser iguales ni estar una dentro de otra.';
  }

  @override
  String get folderImages => 'Imágenes';

  @override
  String get folderVideos => 'Videos';

  @override
  String get folderAudio => 'Audio';

  @override
  String get folderProduction => 'Videos para producción';

  @override
  String get folderProduced => 'Videos producidos';

  @override
  String get helpImages => 'Imágenes usadas en los videos (acervo y generadas)';

  @override
  String get helpVideos => 'Acervo de videos en bruto';

  @override
  String get helpAudio => 'Pistas, efectos y narraciones';

  @override
  String get helpProduction => 'Videos en producción (entrada del flujo)';

  @override
  String get helpProduced => 'Videos terminados (salida)';

  @override
  String get pickFolder => 'Elegir carpeta';

  @override
  String get useThisFolder => 'Usar esta carpeta';

  @override
  String get validate => 'Validar';

  @override
  String get saveAndCreate => 'Guardar y crear carpetas';

  @override
  String get fixFolders => 'Corrige las carpetas marcadas';

  @override
  String get craftDescription =>
      'Descargados del GitHub de cada proyecto. Antes de instalar, el configurador verifica la firma (clave fijada) y el SHA-256: un archivo alterado nunca se instala.';

  @override
  String get craftFilmcraft => 'Editor de video no lineal';

  @override
  String get craftSoundcraft => 'Estación de audio digital (DAW)';

  @override
  String get craftEffectcraft => 'Motion graphics y composición';

  @override
  String get craftPhotocraft => 'Editor de fotos';

  @override
  String get checkingVersion => 'Consultando la última versión…';

  @override
  String latestVersion(Object versao, Object arquivo) {
    return 'Última: $versao · $arquivo';
  }

  @override
  String get notInstalled => 'No instalado';

  @override
  String installedAt(Object versao, Object caminho) {
    return 'Instalado: $versao en $caminho';
  }

  @override
  String get formatPortable => 'Portátil (sin administrador)';

  @override
  String get formatMsi => 'Instalador .msi';

  @override
  String get formatAppimage => 'AppImage (sin administrador)';

  @override
  String get formatDeb => '.deb (pide administrador)';

  @override
  String get downloadInstall => 'Descargar e instalar';

  @override
  String get update => 'Actualizar';

  @override
  String get reinstall => 'Reinstalar';

  @override
  String get appsTitle => 'Apps Solumia';

  @override
  String get appsDescription =>
      'La app de Solumia para cada dispositivo, desde las releases oficiales en GitHub. El configurador verifica la firma y el SHA-256 antes de guardar o instalar.';

  @override
  String get appPhone => 'Celular y tableta';

  @override
  String get appPhoneDetail => 'Android (APK)';

  @override
  String get appWatch => 'Reloj';

  @override
  String get appWatchDetail => 'Wear OS (APK)';

  @override
  String get appLinux => 'PC y portátil';

  @override
  String get appLinuxDetail => 'Linux (AppImage)';

  @override
  String get appWindows => 'PC y portátil';

  @override
  String get appWindowsDetail => 'Windows (instalador)';

  @override
  String appsVersion(Object versao) {
    return 'Versión publicada: $versao';
  }

  @override
  String get appsNoRelease =>
      'No se encontró ninguna release. Los archivos aparecerán aquí en cuanto se publiquen.';

  @override
  String get appsUnsigned =>
      'Descargas bloqueadas por seguridad: la clave que firma las releases de Solumia aún no está fijada en el configurador.';

  @override
  String appsFolder(Object pasta) {
    return 'Archivos guardados en $pasta';
  }

  @override
  String get openReleases => 'Abrir releases en GitHub';

  @override
  String get fileUnavailable => 'Archivo no publicado en esta versión';

  @override
  String get downloadToThisPc => 'Descargar en este PC';

  @override
  String get installOnThisPc => 'Instalar en este PC';

  @override
  String get showQr => 'QR para el celular';

  @override
  String get qrPhone =>
      'Apunta la cámara del celular para descargar directamente de GitHub. Android verifica la firma del APK al instalar.';

  @override
  String get watchInstruction =>
      'Instálalo directo en el reloj por Wi‑Fi, o descarga el APK aquí.';

  @override
  String get planNothingChanged =>
      'Todavía no se cambió nada. Revisa lo que va a pasar:';

  @override
  String planRun(Object estado) {
    return 'Ejecución: $estado';
  }

  @override
  String get destructiveCode => 'Código del autenticador (acción destructiva)';

  @override
  String get cancel => 'Cancelar';

  @override
  String get apply => 'Aplicar';

  @override
  String get stopAfterStep => 'Detener tras el paso actual';

  @override
  String get close => 'Cerrar';

  @override
  String get stateRunning => 'en curso…';

  @override
  String get stateFinished => 'completada';

  @override
  String get stateFailed =>
      'falló (puedes corregir y aplicar de nuevo: continúa donde se detuvo)';

  @override
  String get stateCancelled => 'detenida';

  @override
  String get runLogTitle => 'Historial';

  @override
  String get runLogEmpty => 'Todavía no se aplicó nada.';

  @override
  String get navWorker => 'Worker';

  @override
  String get navAssistant => 'Asistente';

  @override
  String get itemWorker => 'Worker en este PC';

  @override
  String get itemWorkerDetail =>
      'Servicio solumia-worker, en paralelo con agent-worker';

  @override
  String get workerIntro =>
      'El worker corre en este PC como servicio del usuario y se conecta al gateway de tu VPS. Tiene nombre, puerto y configuración propios: el worker de la instalación anterior sigue como está.';

  @override
  String workerState(String unidade, String estado) {
    return '$unidade: $estado';
  }

  @override
  String workerLlama(String porta) {
    return 'llama-server de Solumia en el puerto $porta (el anterior usa 8081). Ambos comparten la GPU: evita usar los dos a la vez con modelos grandes.';
  }

  @override
  String get workerInstall => 'Instalar o actualizar el worker';

  @override
  String get assistantIntro =>
      'El Claude Code de este PC te ayuda a seguir los pasos. No tiene herramientas: no lee archivos, no ejecuta comandos ni aplica nada. Solo recibe el estado resumido de abajo, sin contraseñas, claves, IPs, dominio ni usuarios, y la conversación vive solo en la memoria de esta sesión.';

  @override
  String get assistantUnavailable =>
      'No se encontró Claude Code en este computador. Instálalo e inicia sesión para usar el asistente.';

  @override
  String get assistantHint => 'Pregunta, por ejemplo: ¿por dónde empiezo?';

  @override
  String get assistantSend => 'Enviar';

  @override
  String get assistantClear => 'Limpiar conversación';

  @override
  String get assistantContext => 'Lo que recibe Claude';

  @override
  String get assistantOpenScreen => 'Abrir la pantalla sugerida';

  @override
  String get assistantThinking => 'Claude está pensando…';

  @override
  String get assistantNoSecrets =>
      'No pegues contraseñas, claves ni códigos aquí: lo que parezca secreto se oculta antes de salir del PC.';

  @override
  String get updateConfigurator => 'Actualizar el configurador';

  @override
  String get updateConfiguratorDetail =>
      'Compila y reinstala desde el código de este repositorio; la versión nueva abre en el próximo inicio.';

  @override
  String get updateButton => 'Actualizar';

  @override
  String get watchInstallButton => 'Instalar en el reloj (Wi‑Fi)';

  @override
  String get watchInstallTitle => 'Instalar en el reloj por la red';

  @override
  String get watchSteps =>
      '1. En el reloj: Ajustes › Acerca de › Software, toca 7 veces \"Versión de software\" para activar las Opciones de desarrollador.\n2. En Opciones de desarrollador, activa \"Depuración ADB\" y \"Depuración por Wi‑Fi\" (reloj y PC en la misma red).\n3. La primera vez: en Depuración por Wi‑Fi › \"Vincular nuevo dispositivo\", completa la IP, el puerto y el código que muestra y toca Vincular.\n4. Después: completa el puerto que aparece en la pantalla Depuración por Wi‑Fi (IP:puerto) y toca Instalar.';

  @override
  String get watchIp => 'IP del reloj';

  @override
  String get watchPairPort => 'Puerto de vinculación';

  @override
  String get watchPairCode => 'Código de 6 dígitos';

  @override
  String get watchConnectPort => 'Puerto de conexión';

  @override
  String get watchPair => 'Vincular';

  @override
  String get watchPaired =>
      'Reloj vinculado. Ahora completa el puerto de conexión y toca Instalar.';

  @override
  String get watchInstall => 'Instalar';

  @override
  String get watchFillFields => 'Completa la IP y los puertos con números.';
}
