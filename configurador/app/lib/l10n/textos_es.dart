// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'textos.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class TextosEs extends Textos {
  TextosEs([String locale = 'es']) : super(locale);

  @override
  String get appTitulo => 'Solumia: configurador';

  @override
  String get iniciandoNucleo => 'Abriendo la bóveda e iniciando el núcleo…';

  @override
  String get tentarDeNovo => 'Intentar de nuevo';

  @override
  String get navInicio => 'Inicio';

  @override
  String get navConta => 'Cuenta';

  @override
  String get navVps => 'VPS';

  @override
  String get navPastas => 'Carpetas';

  @override
  String get navCraft => 'Craft Apps';

  @override
  String get navApps => 'Apps';

  @override
  String get navRegistro => 'Historial';

  @override
  String get aparencia => 'Apariencia';

  @override
  String get tema => 'Tema';

  @override
  String get temaSistema => 'Del sistema';

  @override
  String get temaClaro => 'Claro';

  @override
  String get temaEscuro => 'Oscuro';

  @override
  String get idioma => 'Idioma';

  @override
  String inicioVersao(
    Object versao,
    Object protocolo,
    Object so,
    Object arquitetura,
  ) {
    return 'Configurador $versao · protocolo $protocolo · $so $arquitetura';
  }

  @override
  String inicioManifesto(Object caminho) {
    return 'Manifiesto: $caminho';
  }

  @override
  String get itemConta => 'Cuenta y autenticador';

  @override
  String get itemContaDetalhe => 'Usuario, contraseña y 2.º factor';

  @override
  String get itemVpsDetalhe => 'Dirección y dominio';

  @override
  String get itemPastas => 'Carpetas de medios';

  @override
  String get itemPastasDetalhe => 'Imágenes, videos, audio, producción';

  @override
  String itemCraftDetalhe(int instalados, int total) {
    return '$instalados de $total instalados';
  }

  @override
  String get itemApps => 'Apps Solumia';

  @override
  String get itemAppsDetalhe => 'Celular, reloj, PC y portátil';

  @override
  String inicioConvivencia(Object prefixo, Object gateway, Object tunel) {
    return 'Los servicios de Solumia usan nombres y puertos propios (prefijo $prefixo, gateway $gateway, túnel $tunel) y no interfieren con la instalación actual.';
  }

  @override
  String get contaTitulo => 'Cuenta de acceso';

  @override
  String get contaDescricao =>
      'Usuario y contraseña de la app, con segundo factor (Google Authenticator o similar). La contraseña nunca sale de este equipo: solo el hash va a la VPS.';

  @override
  String get usuario => 'Usuario';

  @override
  String get senha => 'Contraseña';

  @override
  String get senhaAjuda =>
      'Mínimo 12 caracteres, mayúsculas, minúsculas y un número';

  @override
  String get confirmarSenha => 'Confirmar contraseña';

  @override
  String get salvarConta => 'Guardar cuenta';

  @override
  String get senhasNaoConferem => 'Las contraseñas no coinciden';

  @override
  String get contaSalva =>
      'Cuenta guardada en la bóveda (solo el hash de la contraseña)';

  @override
  String get qrInstrucao =>
      'Escanéalo con el autenticador. Este QR solo aparece ahora: no se mostrará de nuevo.';

  @override
  String get codigo6 => 'Código de 6 dígitos';

  @override
  String get conferir => 'Verificar';

  @override
  String get totpOk => 'Autenticador configurado correctamente.';

  @override
  String get totpFalhou => 'El código no coincide. Revisa la hora del celular.';

  @override
  String get vpsDescricao =>
      'Instala gateway, túnel, Collabora, nginx y TLS, y refuerza SSH y el firewall. Todo con nombres y puertos de Solumia, sin tocar la instalación actual.';

  @override
  String get topologia => 'Topología';

  @override
  String get topoHibrida => 'Híbrida (VPS + este PC)';

  @override
  String get topoNuvem => 'Solo nube (solo VPS)';

  @override
  String get dominio => 'Dominio';

  @override
  String get dominioAjuda =>
      'ej.: solumia.tudominio.com (registro A apuntando a la VPS)';

  @override
  String get emailTls => 'Correo para el certificado TLS';

  @override
  String get emailTlsAjuda => 'avisos de vencimiento de Let\'s Encrypt';

  @override
  String get cloudflare => 'Dominio detrás de Cloudflare (proxy)';

  @override
  String get acessoSsh => 'Acceso SSH';

  @override
  String get hostVps => 'IP o nombre de la VPS';

  @override
  String get porta => 'Puerto';

  @override
  String get lerImpressao => 'Leer la huella digital de la VPS';

  @override
  String impressaoConfirmada(Object impressao) {
    return 'Confirmada: $impressao';
  }

  @override
  String get conferirImpressao =>
      'Comprueba que es tu VPS antes de confirmar. En el panel del proveedor (consola web) ejecuta:';

  @override
  String get confirmoVps => 'Confirmo: es mi VPS';

  @override
  String get primeiroAcesso => 'Primer acceso';

  @override
  String get primeiroAcessoDescricao =>
      'La contraseña se usa una vez para instalar la clave del configurador y no se guarda. Después el acceso es solo por clave.';

  @override
  String get senhaVps => 'Contraseña de la VPS (solo en el 1.er acceso)';

  @override
  String get senhaSudo => 'Contraseña de sudo (si el usuario no es root)';

  @override
  String get desativarSenha =>
      'Desactivar el inicio de sesión por contraseña en SSH (recomendado)';

  @override
  String get desativarSenhaAjuda =>
      'Se deshace automáticamente en 5 min si falla el acceso por clave';

  @override
  String get nginxAuto => 'detectar';

  @override
  String get nginxDocker => 'en contenedor (VPS dedicada)';

  @override
  String get nginxHost => 'nginx ya instalado en la VPS';

  @override
  String get salvar => 'Guardar';

  @override
  String get verPlano => 'Ver plan de instalación';

  @override
  String get confirmeImpressao => 'Confirma primero la huella digital';

  @override
  String get vpsSalva => 'Configuración de la VPS guardada';

  @override
  String get pastasTitulo => 'Carpetas de medios';

  @override
  String pastasDescricao(Object so) {
    return 'Dónde se guardan imágenes, videos y audio en este equipo ($so). Pueden estar en otro disco. No pueden ser iguales ni estar una dentro de otra.';
  }

  @override
  String get pastaImagens => 'Imágenes';

  @override
  String get pastaVideos => 'Videos';

  @override
  String get pastaAudio => 'Audio';

  @override
  String get pastaProducao => 'Videos para producción';

  @override
  String get pastaProduzidos => 'Videos producidos';

  @override
  String get ajudaImagens =>
      'Imágenes usadas en los videos (acervo y generadas)';

  @override
  String get ajudaVideos => 'Acervo de videos en bruto';

  @override
  String get ajudaAudio => 'Pistas, efectos y narraciones';

  @override
  String get ajudaProducao => 'Videos en producción (entrada del flujo)';

  @override
  String get ajudaProduzidos => 'Videos terminados (salida)';

  @override
  String get escolherPasta => 'Elegir carpeta';

  @override
  String get usarEstaPasta => 'Usar esta carpeta';

  @override
  String get validar => 'Validar';

  @override
  String get salvarECriar => 'Guardar y crear carpetas';

  @override
  String get corrijaPastas => 'Corrige las carpetas marcadas';

  @override
  String get craftDescricao =>
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
  String get consultandoVersao => 'Consultando la última versión…';

  @override
  String ultimaVersao(Object versao, Object arquivo) {
    return 'Última: $versao · $arquivo';
  }

  @override
  String get naoInstalado => 'No instalado';

  @override
  String instaladoEm(Object versao, Object caminho) {
    return 'Instalado: $versao en $caminho';
  }

  @override
  String get formatoPortatil => 'Portátil (sin administrador)';

  @override
  String get formatoMsi => 'Instalador .msi';

  @override
  String get formatoAppimage => 'AppImage (sin administrador)';

  @override
  String get formatoDeb => '.deb (pide administrador)';

  @override
  String get baixarInstalar => 'Descargar e instalar';

  @override
  String get atualizar => 'Actualizar';

  @override
  String get reinstalar => 'Reinstalar';

  @override
  String get appsTitulo => 'Apps Solumia';

  @override
  String get appsDescricao =>
      'La app de Solumia para cada dispositivo, desde las releases oficiales en GitHub. El configurador verifica la firma y el SHA-256 antes de guardar o instalar.';

  @override
  String get appCelular => 'Celular y tableta';

  @override
  String get appCelularDetalhe => 'Android (APK)';

  @override
  String get appRelogio => 'Reloj';

  @override
  String get appRelogioDetalhe => 'Wear OS (APK)';

  @override
  String get appLinux => 'PC y portátil';

  @override
  String get appLinuxDetalhe => 'Linux (AppImage)';

  @override
  String get appWindows => 'PC y portátil';

  @override
  String get appWindowsDetalhe => 'Windows (instalador)';

  @override
  String appsVersao(Object versao) {
    return 'Versión publicada: $versao';
  }

  @override
  String get appsSemRelease =>
      'No se encontró ninguna release. Los archivos aparecerán aquí en cuanto se publiquen.';

  @override
  String get appsSemAssinatura =>
      'Descargas bloqueadas por seguridad: la clave que firma las releases de Solumia aún no está fijada en el configurador.';

  @override
  String appsPasta(Object pasta) {
    return 'Archivos guardados en $pasta';
  }

  @override
  String get abrirReleases => 'Abrir releases en GitHub';

  @override
  String get arquivoIndisponivel => 'Archivo no publicado en esta versión';

  @override
  String get baixarParaEstePc => 'Descargar en este PC';

  @override
  String get instalarNestePc => 'Instalar en este PC';

  @override
  String get mostrarQr => 'QR para el celular';

  @override
  String get qrCelular =>
      'Apunta la cámara del celular para descargar directamente de GitHub. Android verifica la firma del APK al instalar.';

  @override
  String get relogioInstrucao =>
      'Descarga el APK aquí y envíalo al reloj desde la app del celular, o instálalo en el propio reloj.';

  @override
  String get planoNadaAlterado =>
      'Todavía no se cambió nada. Revisa lo que va a pasar:';

  @override
  String planoExecucao(Object estado) {
    return 'Ejecución: $estado';
  }

  @override
  String get codigoDestrutivo => 'Código del autenticador (acción destructiva)';

  @override
  String get cancelar => 'Cancelar';

  @override
  String get aplicar => 'Aplicar';

  @override
  String get pararAposPasso => 'Detener tras el paso actual';

  @override
  String get fechar => 'Cerrar';

  @override
  String get estadoRodando => 'en curso…';

  @override
  String get estadoConcluida => 'completada';

  @override
  String get estadoFalhou =>
      'falló (puedes corregir y aplicar de nuevo: continúa donde se detuvo)';

  @override
  String get estadoCancelada => 'detenida';

  @override
  String get registroTitulo => 'Historial';

  @override
  String get registroVazio => 'Todavía no se aplicó nada.';
}
