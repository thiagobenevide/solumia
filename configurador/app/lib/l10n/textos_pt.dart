// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'textos.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class TextosPt extends Textos {
  TextosPt([String locale = 'pt']) : super(locale);

  @override
  String get appTitulo => 'Solumia: configurador';

  @override
  String get iniciandoNucleo => 'Abrindo o cofre e iniciando o núcleo…';

  @override
  String get tentarDeNovo => 'Tentar de novo';

  @override
  String get navInicio => 'Início';

  @override
  String get navConta => 'Conta';

  @override
  String get navVps => 'VPS';

  @override
  String get navPastas => 'Pastas';

  @override
  String get navCraft => 'Craft Apps';

  @override
  String get navApps => 'Apps';

  @override
  String get navRegistro => 'Registro';

  @override
  String get aparencia => 'Aparência';

  @override
  String get tema => 'Tema';

  @override
  String get temaSistema => 'Do sistema';

  @override
  String get temaClaro => 'Claro';

  @override
  String get temaEscuro => 'Escuro';

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
    return 'Manifesto: $caminho';
  }

  @override
  String get itemConta => 'Conta e autenticador';

  @override
  String get itemContaDetalhe => 'Usuário, senha e 2º fator';

  @override
  String get itemVpsDetalhe => 'Endereço e domínio';

  @override
  String get itemPastas => 'Pastas de mídia';

  @override
  String get itemPastasDetalhe => 'Imagens, vídeos, áudio, produção';

  @override
  String itemCraftDetalhe(int instalados, int total) {
    return '$instalados de $total instalados';
  }

  @override
  String get itemApps => 'Apps Solumia';

  @override
  String get itemAppsDetalhe => 'Celular, relógio, PC e notebook';

  @override
  String inicioConvivencia(Object prefixo, Object gateway, Object tunel) {
    return 'Serviços do Solumia usam nomes e portas próprios (prefixo $prefixo, gateway $gateway, túnel $tunel) e não interferem na instalação atual.';
  }

  @override
  String get contaTitulo => 'Conta de acesso';

  @override
  String get contaDescricao =>
      'Usuário e senha do app, com segundo fator (Google Authenticator ou similar). A senha nunca sai deste computador: só o hash vai para a VPS.';

  @override
  String get usuario => 'Usuário';

  @override
  String get senha => 'Senha';

  @override
  String get senhaAjuda =>
      'Mínimo 12 caracteres, maiúsculas, minúsculas e número';

  @override
  String get confirmarSenha => 'Confirmar senha';

  @override
  String get salvarConta => 'Salvar conta';

  @override
  String get senhasNaoConferem => 'As senhas não conferem';

  @override
  String get contaSalva => 'Conta salva no cofre (só o hash da senha)';

  @override
  String get qrInstrucao =>
      'Escaneie no autenticador. Este QR só aparece agora: ele não é mostrado de novo.';

  @override
  String get codigo6 => 'Código de 6 dígitos';

  @override
  String get conferir => 'Conferir';

  @override
  String get totpOk => 'Autenticador configurado corretamente.';

  @override
  String get totpFalhou => 'Código não confere. Confira o relógio do celular.';

  @override
  String get vpsDescricao =>
      'Instala gateway, túnel, Collabora, nginx e TLS, e endurece SSH e firewall. Tudo com nomes e portas do Solumia, sem tocar na instalação atual.';

  @override
  String get topologia => 'Topologia';

  @override
  String get topoHibrida => 'Híbrida (VPS + este PC)';

  @override
  String get topoNuvem => 'Só nuvem (só VPS)';

  @override
  String get dominio => 'Domínio';

  @override
  String get dominioAjuda =>
      'ex.: solumia.seudominio.com (registro A apontando para a VPS)';

  @override
  String get emailTls => 'E-mail para o certificado TLS';

  @override
  String get emailTlsAjuda => 'avisos de expiração do Let\'s Encrypt';

  @override
  String get cloudflare => 'Domínio atrás da Cloudflare (proxy)';

  @override
  String get acessoSsh => 'Acesso SSH';

  @override
  String get hostVps => 'IP ou nome da VPS';

  @override
  String get porta => 'Porta';

  @override
  String get lerImpressao => 'Ler impressão digital da VPS';

  @override
  String impressaoConfirmada(Object impressao) {
    return 'Confirmada: $impressao';
  }

  @override
  String get conferirImpressao =>
      'Confira se é a sua VPS antes de confirmar. No painel do provedor (console web) rode:';

  @override
  String get confirmoVps => 'Confirmo: é a minha VPS';

  @override
  String get primeiroAcesso => 'Primeiro acesso';

  @override
  String get primeiroAcessoDescricao =>
      'A senha é usada uma vez para instalar a chave do configurador e não é gravada. Depois disso o acesso é só por chave.';

  @override
  String get senhaVps => 'Senha da VPS (só no 1º acesso)';

  @override
  String get senhaSudo => 'Senha do sudo (se o usuário não for root)';

  @override
  String get desativarSenha => 'Desativar login por senha no SSH (recomendado)';

  @override
  String get desativarSenhaAjuda =>
      'Com desfazer automático em 5 min se o acesso por chave falhar';

  @override
  String get nginxAuto => 'detectar';

  @override
  String get nginxDocker => 'em contêiner (VPS dedicada)';

  @override
  String get nginxHost => 'nginx já instalado na VPS';

  @override
  String get salvar => 'Salvar';

  @override
  String get verPlano => 'Ver plano de instalação';

  @override
  String get confirmeImpressao => 'Confirme a impressão digital primeiro';

  @override
  String get vpsSalva => 'Configuração da VPS salva';

  @override
  String get pastasTitulo => 'Pastas de mídia';

  @override
  String pastasDescricao(Object so) {
    return 'Onde ficam imagens, vídeos e áudio neste computador ($so). Podem estar em outro disco. Não podem ser iguais nem uma dentro da outra.';
  }

  @override
  String get pastaImagens => 'Imagens';

  @override
  String get pastaVideos => 'Vídeos';

  @override
  String get pastaAudio => 'Áudio';

  @override
  String get pastaProducao => 'Vídeos para produção';

  @override
  String get pastaProduzidos => 'Vídeos produzidos';

  @override
  String get ajudaImagens => 'Imagens usadas nos vídeos (acervo e geradas)';

  @override
  String get ajudaVideos => 'Acervo de vídeos brutos';

  @override
  String get ajudaAudio => 'Trilhas, efeitos e narrações';

  @override
  String get ajudaProducao => 'Vídeos em produção (entrada da esteira)';

  @override
  String get ajudaProduzidos => 'Vídeos prontos (saída)';

  @override
  String get escolherPasta => 'Escolher pasta';

  @override
  String get usarEstaPasta => 'Usar esta pasta';

  @override
  String get validar => 'Validar';

  @override
  String get salvarECriar => 'Salvar e criar pastas';

  @override
  String get corrijaPastas => 'Corrija as pastas marcadas';

  @override
  String get craftDescricao =>
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
  String get consultandoVersao => 'Consultando a última versão…';

  @override
  String ultimaVersao(Object versao, Object arquivo) {
    return 'Última: $versao · $arquivo';
  }

  @override
  String get naoInstalado => 'Não instalado';

  @override
  String instaladoEm(Object versao, Object caminho) {
    return 'Instalado: $versao em $caminho';
  }

  @override
  String get formatoPortatil => 'Portátil (sem administrador)';

  @override
  String get formatoMsi => 'Instalador .msi';

  @override
  String get formatoAppimage => 'AppImage (sem administrador)';

  @override
  String get formatoDeb => '.deb (pede administrador)';

  @override
  String get baixarInstalar => 'Baixar e instalar';

  @override
  String get atualizar => 'Atualizar';

  @override
  String get reinstalar => 'Reinstalar';

  @override
  String get appsTitulo => 'Apps Solumia';

  @override
  String get appsDescricao =>
      'O app do Solumia para cada dispositivo, das releases oficiais no GitHub. O configurador confere assinatura e SHA-256 antes de salvar ou instalar.';

  @override
  String get appCelular => 'Celular e tablet';

  @override
  String get appCelularDetalhe => 'Android (APK)';

  @override
  String get appRelogio => 'Relógio';

  @override
  String get appRelogioDetalhe => 'Wear OS (APK)';

  @override
  String get appLinux => 'PC e notebook';

  @override
  String get appLinuxDetalhe => 'Linux (AppImage)';

  @override
  String get appWindows => 'PC e notebook';

  @override
  String get appWindowsDetalhe => 'Windows (instalador)';

  @override
  String appsVersao(Object versao) {
    return 'Versão publicada: $versao';
  }

  @override
  String get appsSemRelease =>
      'Nenhuma release encontrada. Os arquivos aparecem aqui assim que forem publicados.';

  @override
  String get appsSemAssinatura =>
      'Downloads bloqueados por segurança: a chave que assina as releases do Solumia ainda não foi fixada no configurador.';

  @override
  String appsPasta(Object pasta) {
    return 'Arquivos salvos em $pasta';
  }

  @override
  String get abrirReleases => 'Abrir releases no GitHub';

  @override
  String get arquivoIndisponivel => 'Arquivo não publicado nesta versão';

  @override
  String get baixarParaEstePc => 'Baixar para este PC';

  @override
  String get instalarNestePc => 'Instalar neste PC';

  @override
  String get mostrarQr => 'QR para o celular';

  @override
  String get qrCelular =>
      'Aponte a câmera do celular para baixar direto do GitHub. O Android confere a assinatura do APK ao instalar.';

  @override
  String get relogioInstrucao =>
      'Baixe o APK aqui e envie ao relógio pelo app do celular ou instale no próprio relógio.';

  @override
  String get planoNadaAlterado =>
      'Nada foi alterado ainda. Confira o que vai acontecer:';

  @override
  String planoExecucao(Object estado) {
    return 'Execução: $estado';
  }

  @override
  String get codigoDestrutivo => 'Código do autenticador (ação destrutiva)';

  @override
  String get cancelar => 'Cancelar';

  @override
  String get aplicar => 'Aplicar';

  @override
  String get pararAposPasso => 'Parar após o passo atual';

  @override
  String get fechar => 'Fechar';

  @override
  String get estadoRodando => 'em andamento…';

  @override
  String get estadoConcluida => 'concluída';

  @override
  String get estadoFalhou =>
      'falhou (pode corrigir e aplicar de novo: retoma de onde parou)';

  @override
  String get estadoCancelada => 'parada';

  @override
  String get registroTitulo => 'Registro';

  @override
  String get registroVazio => 'Nenhuma aplicação ainda.';
}
