import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_core/agent_core.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_painel.dart';
import '../modelos.dart';

/// Atalhos de um toque; “anote”/“pesquise” viram comandos no servidor.
const atalhos = ['O que tenho para fazer agora?', 'Estou dentro da disciplina?', 'Anote: ', 'Pesquise na base: '];

/// Teto da foto enviada: com folga sob o limite da conexão VPS → worker (16 MB, já em base64).
const limiteImagem = 1024 * 1024;

/// Reduz qualquer foto a JPEG de até 1600 px e no máximo [limiteImagem], encolhendo lado e qualidade
/// até caber. Roda num isolate ([compute]); nulo se o arquivo não for uma imagem legível.
Uint8List? comprimirImagem(Uint8List bytes) {
  final original = img.decodeImage(bytes);
  if (original == null) return null;
  final foto = img.bakeOrientation(original); // a rotação do EXIF se perderia ao recodificar
  var lado = 1600;
  var qualidade = 80;
  while (true) {
    final reduzida = foto.width >= foto.height
        ? img.copyResize(foto, width: math.min(lado, foto.width))
        : img.copyResize(foto, height: math.min(lado, foto.height));
    final jpg = img.encodeJpg(reduzida, quality: qualidade);
    if (jpg.length <= limiteImagem || lado <= 480) return jpg;
    lado = (lado * 0.75).round();
    qualidade = math.max(50, qualidade - 10);
  }
}

/// Conversa guardada no aparelho para retomar depois pelo histórico.
class ConversaSalva {
  ConversaSalva(this.id, this.atualizada, this.mensagens);

  factory ConversaSalva.fromJson(Map<String, dynamic> j) => ConversaSalva(
    j['id'] as String,
    DateTime.parse(j['atualizada'] as String),
    [for (final m in j['mensagens'] as List) ('${m[0]}', '${m[1]}')],
  );

  final String id;
  final DateTime atualizada;
  final List<(String, String)> mensagens;

  String get titulo {
    final (_, texto) = mensagens.firstWhere((m) => m.$1 == 'usuario', orElse: () => mensagens.first);
    final t = texto.replaceFirst('🎤', '').trim();
    return t.length > 60 ? '${t.substring(0, 60)}…' : t;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'atualizada': atualizada.toIso8601String(),
    'mensagens': [for (final (papel, texto) in mensagens) [papel, texto]],
  };
}

/// Conversa com o cobrador, por texto ou voz. Fica fora do widget para sobreviver à troca de abas.
class ConversaCobrador extends ChangeNotifier {
  ConversaCobrador(this.api) {
    _carregarProvedores();
    _carregarConversas();
  }

  final ApiPainel api;
  final _gravador = AudioRecorder();
  final _player = AudioPlayer();

  /// (`usuario`|`assistente`, texto), na ordem.
  final mensagens = <(String, String)>[];
  List<String> provedores = const ['local'];
  String provedor = 'local';
  bool pensando = false;

  /// Andamento do servidor enquanto [pensando] ("Consultando a cotação das moedas.").
  String? aviso;

  /// Avisos sendo falados em fila; a resposta final espera por eles.
  Future<void> _falaAvisos = Future.value();
  bool gravando = false;
  bool falando = false;

  /// Histórico de conversas, a mais recente primeiro; a atual entra nele a cada resposta.
  final conversas = <ConversaSalva>[];
  String? _idAtual;
  static const _chaveConversas = 'cobrador_conversas';

  /// Muda a cada [encerrar]: o que ainda estava em andamento da rodada anterior é ignorado.
  int _rodada = 0;
  StreamSubscription<Amplitude>? _vigia;

  /// Lê em voz alta cada resposta.
  bool ouvirRespostas = false;

  /// Conversa por voz sem as mãos: responde falando e reabre o microfone ao terminar.
  bool modoConversa = false;
  String? erro;

  static bool get vozSuportada => !kIsWeb;

  /// Há voz em andamento (gravando, falando, esperando resposta que será lida ou modo conversa).
  bool get vozAtiva => gravando || falando || modoConversa || (pensando && ouvirRespostas);

  Future<void> _carregarConversas() async {
    try {
      final p = await SharedPreferences.getInstance();
      final lista = jsonDecode(p.getString(_chaveConversas) ?? '[]') as List;
      conversas.addAll([for (final j in lista) ConversaSalva.fromJson(j as Map<String, dynamic>)]);
      notifyListeners();
    } catch (_) {
      // histórico corrompido ou indisponível: começa vazio
    }
  }

  Future<void> _gravarConversas() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_chaveConversas, jsonEncode([for (final c in conversas) c.toJson()]));
    } catch (_) {}
  }

  Future<void> _guardarAtual() async {
    if (mensagens.isEmpty) return;
    final id = _idAtual ??= '${DateTime.now().millisecondsSinceEpoch}';
    conversas.removeWhere((c) => c.id == id);
    conversas.insert(0, ConversaSalva(id, DateTime.now(), [...mensagens]));
    if (conversas.length > 50) conversas.removeRange(50, conversas.length);
    await _gravarConversas();
  }

  /// Volta a uma conversa do histórico; as próximas mensagens continuam nela.
  Future<void> retomar(ConversaSalva c) async {
    if (pensando) return;
    await encerrar();
    mensagens
      ..clear()
      ..addAll(c.mensagens);
    _idAtual = c.id;
    erro = null;
    notifyListeners();
  }

  void apagarConversa(ConversaSalva c) {
    conversas.remove(c);
    if (_idAtual == c.id) _idAtual = null;
    _gravarConversas();
    notifyListeners();
  }

  Future<void> _carregarProvedores() async {
    try {
      provedores = await api.provedores();
      notifyListeners();
    } on ApiErro {
      // sem servidor agora: fica só o local, o erro aparece na primeira mensagem
    }
  }

  void escolher(String p) {
    provedor = p;
    notifyListeners();
  }

  void alternarOuvir(bool v) {
    ouvirRespostas = v;
    if (!v) encerrar();
    notifyListeners();
  }

  void alternarModoConversa(bool v) {
    if (!v) {
      encerrar();
      return;
    }
    modoConversa = true;
    ouvirRespostas = true;
    notifyListeners();
    if (!gravando && !pensando) alternarGravacao();
  }

  /// Para tudo na hora: descarta a gravação, cala a fala e sai do modo conversa. Respostas que ainda
  /// chegarem desta rodada não são lidas nem reabrem o microfone (a [_rodada] mudou).
  Future<void> encerrar() async {
    _rodada++;
    modoConversa = false;
    falando = false;
    _vigia?.cancel();
    _vigia = null;
    if (gravando) {
      gravando = false;
      try {
        await _gravador.cancel();
      } catch (_) {}
    }
    await _pararFala();
    notifyListeners();
  }

  Future<void> _pararFala() async {
    try {
      await _player.stop();
    } catch (_) {
      // Linux sem nada tocando pode reclamar do stop; não deve impedir de gravar.
    }
  }

  List<(String, String)> get _historico =>
      mensagens.length > 10 ? mensagens.sublist(mensagens.length - 10) : [...mensagens];

  /// [imagem] (bytes, mime): foto anexada; sem texto, pede para descrevê-la.
  Future<void> enviar(String texto, {(List<int>, String)? imagem}) async {
    texto = texto.trim();
    if (texto.isEmpty && imagem != null) texto = 'Descreva esta imagem.';
    if (texto.isEmpty || pensando) return;
    final historico = _historico;
    mensagens.add(('usuario', imagem == null ? texto : '🖼️ $texto'));
    await _aguardar(
      () => api.conversarFluxo(texto, historico, provedor, imagem: imagem, aoAvisar: _aoAvisar),
    );
  }

  /// Toque no microfone: começa a gravar; segundo toque: para e envia o áudio. No modo conversa a
  /// gravação também para sozinha depois de ~1,5 s de silêncio, e a conversa encerra se você não
  /// falar nada em 8 s.
  Future<void> alternarGravacao() async {
    if (pensando) return;
    erro = null;
    if (!gravando) return _comecarGravacao();
    await _pararEEnviar();
  }

  Future<void> _comecarGravacao() async {
    try {
      if (!await _gravador.hasPermission()) {
        erro = 'Sem permissão para usar o microfone.';
        modoConversa = false;
        notifyListeners();
        return;
      }
      falando = false;
      await _pararFala();
      final caminho = '${Directory.systemTemp.path}/cobrador_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _gravador.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        ),
        path: caminho,
      );
    } catch (e) {
      erro = Platform.isLinux
          ? 'Não consegui abrir o microfone ($e). No Linux a gravação usa o parecord e o ffmpeg: '
                'sudo apt install pulseaudio-utils ffmpeg'
          : 'Não consegui abrir o microfone: $e';
      modoConversa = false;
      notifyListeners();
      return;
    }
    gravando = true;
    notifyListeners();
    if (modoConversa) _vigiarSilencio();
  }

  /// Fim da fala pelo volume do microfone (dBFS): acima de -40 é voz.
  void _vigiarSilencio() {
    final rodada = _rodada;
    final inicio = DateTime.now();
    DateTime? ultimaVoz;
    _vigia?.cancel();
    _vigia = _gravador.onAmplitudeChanged(const Duration(milliseconds: 150)).listen((amp) {
      if (rodada != _rodada || !gravando) return;
      final agora = DateTime.now();
      if (amp.current > -40) ultimaVoz = agora;
      if (ultimaVoz == null && agora.difference(inicio) > const Duration(seconds: 8)) {
        erro = 'Conversa encerrada: não ouvi nada.';
        encerrar();
      } else if (ultimaVoz != null && agora.difference(ultimaVoz!) > const Duration(milliseconds: 1500)) {
        _pararEEnviar();
      }
    });
  }

  Future<void> _pararEEnviar() async {
    if (!gravando) return;
    gravando = false;
    _vigia?.cancel();
    _vigia = null;
    String? caminho;
    try {
      caminho = await _gravador.stop();
    } catch (e) {
      erro = 'A gravação falhou: $e';
    }
    if (caminho == null) {
      modoConversa = false;
      notifyListeners();
      return;
    }
    final arquivo = File(caminho);
    final List<int> wav;
    try {
      wav = await arquivo.readAsBytes();
      await arquivo.delete();
    } catch (e) {
      erro = 'Não consegui ler a gravação: $e';
      modoConversa = false;
      notifyListeners();
      return;
    }
    // WAV de 16 kHz mono: menos de ~0,4 s de áudio é toque acidental, não vale mandar.
    if (wav.length < 44 + 16000 * 2 * 0.4) {
      erro = 'Gravação curta demais.';
      modoConversa = false;
      notifyListeners();
      return;
    }
    final historico = _historico;
    mensagens.add(('usuario', '🎤 …'));
    final indice = mensagens.length - 1;
    await _aguardar(
      () => api.vozFluxo(
        wav,
        historico,
        provedor,
        aoAvisar: _aoAvisar,
        aoTranscrever: (t) {
          if (indice < mensagens.length) mensagens[indice] = ('usuario', '🎤 $t');
          notifyListeners();
        },
      ),
      indiceVoz: indice,
    );
  }

  /// Aviso de andamento: aparece no chat e, com a voz ligada, é falado enquanto a resposta não vem.
  void _aoAvisar(String texto) {
    aviso = texto;
    notifyListeners();
    final rodada = _rodada;
    if (!ouvirRespostas || !vozSuportada || texto.trim().isEmpty) return;
    _falaAvisos = _falaAvisos.then((_) => rodada == _rodada ? _falar(texto, rodada, aviso: true) : null);
  }

  Future<void> _aguardar(Future<Resposta> Function() pedido, {int? indiceVoz}) async {
    final rodada = _rodada;
    aviso = null;
    _falaAvisos = Future.value();
    pensando = true;
    notifyListeners();
    Resposta? r;
    try {
      // Áudio passa por transcrição e LLM no PC (via VPS): sem limite, o celular ficava esperando
      // para sempre quando a conexão caía no meio.
      r = await pedido().timeout(const Duration(minutes: 3));
      if (indiceVoz != null) mensagens[indiceVoz] = ('usuario', '🎤 ${r.transcricao ?? ''}');
      mensagens.add(('assistente', r.completa));
    } catch (e) {
      // Qualquer falha (não só da API) precisa aparecer; antes escapava e o chat parecia mudo.
      if (indiceVoz != null) mensagens.removeAt(indiceVoz);
      erro = switch (e) {
        ApiErro(status: 503 || 422 || 413) => e.mensagem,
        TimeoutException() => 'O servidor não respondeu em 3 minutos (o PC com o worker está ligado e conectado?).',
        _ => '$e',
      };
      modoConversa = false;
    } finally {
      pensando = false;
      aviso = null;
      notifyListeners();
    }
    await _falaAvisos; // o "estou consultando…" termina antes da resposta começar
    if (r != null) unawaited(_guardarAtual());
    if (r == null || rodada != _rodada || !ouvirRespostas || !vozSuportada) return;
    // Quando o LLM só executa ações a resposta vem sem texto: lê as ações ou, sem nada a dizer,
    // segue a conversa (antes pedia voz para texto vazio e o servidor recusava com 422).
    final fala = r.falada.trim();
    if (fala.isEmpty) {
      if (modoConversa && !gravando) await alternarGravacao();
      return;
    }
    await _falar(fala, rodada);
  }

  /// Fala por trechos: toca o primeiro assim que fica pronto e já pede o seguinte, em vez de esperar
  /// a resposta inteira virar áudio.
  Future<void> _falar(String texto, int rodada, {bool aviso = false}) async {
    var proximo = api.falar(texto, trecho: 0);
    try {
      for (var i = 0;; i++) {
        final wav = await proximo;
        if (rodada != _rodada || wav.isEmpty) break;
        proximo = api.falar(texto, trecho: i + 1);
        final arquivo = File('${Directory.systemTemp.path}/cobrador_fala_${rodada}_$i.wav');
        await arquivo.writeAsBytes(wav, flush: true);
        if (rodada != _rodada) break;
        falando = true;
        notifyListeners();
        final fim = _player.onPlayerStateChanged.firstWhere(
          (e) => e == PlayerState.completed || e == PlayerState.stopped,
        );
        await _player.play(DeviceFileSource(arquivo.path));
        await fim;
        unawaited(arquivo.delete().catchError((_) => arquivo));
        if (rodada != _rodada || !falando) break;
      }
    } on ApiErro catch (e) {
      erro = 'Sem voz agora: ${e.mensagem}';
      falando = false;
      modoConversa = false;
      notifyListeners();
      return;
    } catch (e) {
      erro = 'Não consegui tocar a resposta: $e';
      falando = false;
      modoConversa = false;
      notifyListeners();
      return;
    } finally {
      proximo.ignore(); // trecho pedido e não tocado (parou no meio): sem erro solto
    }
    if (aviso) {
      falando = false; // o microfone só reabre depois da resposta
      notifyListeners();
    } else if (rodada == _rodada) {
      _aoTerminarFala();
    }
  }

  void _aoTerminarFala() {
    if (!falando) return; // parada à mão: não reabre o microfone
    falando = false;
    notifyListeners();
    if (modoConversa && !gravando && !pensando) alternarGravacao();
  }

  /// Lê de novo uma resposta do chat (sem os links); encerra o modo conversa para não reabrir o microfone.
  Future<void> repetir(String texto) async {
    if (pensando || gravando) return;
    await encerrar();
    final fala = texto
        .split('\n')
        .where((l) => !l.startsWith('🔗'))
        .map((l) => l.replaceFirst(RegExp(r'^[✔✖] '), ''))
        .join('\n')
        .trim();
    if (fala.isNotEmpty) await _falar(fala, _rodada);
  }

  /// "Parar de falar": cala e encerra o modo conversa (senão o microfone reabriria em seguida).
  void calar() => encerrar();

  void limpar() {
    mensagens.clear();
    _idAtual = null;
    erro = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _vigia?.cancel();
    _gravador.dispose();
    _player.dispose();
    super.dispose();
  }
}

class ChatCobrador extends StatefulWidget {
  const ChatCobrador({super.key, required this.conversa});

  final ConversaCobrador conversa;

  @override
  State<ChatCobrador> createState() => _ChatCobradorState();
}

class _ChatCobradorState extends State<ChatCobrador> {
  final _campo = TextEditingController();
  final _rolagem = ScrollController();

  /// Foto escolhida para ir com a próxima mensagem (bytes, mime).
  (Uint8List, String)? _anexo;

  @override
  void initState() {
    super.initState();
    widget.conversa.addListener(_rolarParaFim);
  }

  @override
  void dispose() {
    widget.conversa.removeListener(_rolarParaFim);
    _campo.dispose();
    _rolagem.dispose();
    super.dispose();
  }

  void _rolarParaFim() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_rolagem.hasClients) _rolagem.jumpTo(_rolagem.position.maxScrollExtent);
  });

  void _enviar() {
    widget.conversa.enviar(_campo.text, imagem: _anexo);
    _campo.clear();
    setState(() => _anexo = null);
  }

  /// No celular pergunta câmera ou galeria; no desktop abre direto o seletor de arquivos.
  Future<void> _anexar() async {
    var origem = ImageSource.gallery;
    if (Platform.isAndroid || Platform.isIOS) {
      final escolha = await showModalBottomSheet<ImageSource>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Tirar foto'),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Escolher da galeria'),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        ),
      );
      if (escolha == null) return;
      origem = escolha;
    }
    try {
      // O celular já entrega reduzida; [comprimirImagem] garante o teto em qualquer plataforma.
      final foto = await ImagePicker().pickImage(source: origem, maxWidth: 1600, maxHeight: 1600, imageQuality: 80);
      if (foto == null) return;
      final jpg = await compute(comprimirImagem, await foto.readAsBytes());
      if (jpg == null) throw const FormatException('formato não reconhecido');
      if (mounted) setState(() => _anexo = (jpg, 'image/jpeg'));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Não consegui abrir a imagem: $e')));
    }
  }

  /// Atalho que termina em “: ” só preenche o campo para o usuário completar.
  void _atalho(String a) {
    if (a.endsWith(': ')) {
      _campo.text = a;
      _campo.selection = TextSelection.collapsed(offset: a.length);
    } else {
      widget.conversa.enviar(a);
    }
  }

  void _abrirHistorico(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => ListenableBuilder(
      listenable: widget.conversa,
      builder: (context, _) {
        final c = widget.conversa;
        return SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: c.conversas.isEmpty
              ? const Center(child: Text('Nenhuma conversa guardada ainda.'))
              : ListView(
                  children: [
                    for (final s in c.conversas)
                      ListTile(
                        leading: const Icon(Icons.chat_bubble_outline),
                        title: Text(s.titulo, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${MaterialLocalizations.of(context).formatShortDate(s.atualizada)} '
                          '${TimeOfDay.fromDateTime(s.atualizada).format(context)} · ${s.mensagens.length} mensagens',
                        ),
                        trailing: IconButton(
                          tooltip: 'Apagar',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => c.apagarConversa(s),
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          c.retomar(s);
                        },
                      ),
                  ],
                ),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.conversa,
      builder: (context, _) {
        final c = widget.conversa;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: [
                          for (final p in c.provedores)
                            ButtonSegment(value: p, label: Text(p == 'local' ? 'LLM local' : 'Claude')),
                        ],
                        selected: {c.provedor},
                        onSelectionChanged: (s) => c.escolher(s.first),
                      ),
                    ),
                  ),
                  if (ConversaCobrador.vozSuportada) ...[
                    IconButton(
                      tooltip: 'Ler as respostas em voz alta',
                      isSelected: c.ouvirRespostas,
                      icon: const Icon(Icons.volume_off_outlined),
                      selectedIcon: const Icon(Icons.record_voice_over),
                      onPressed: () => c.alternarOuvir(!c.ouvirRespostas),
                    ),
                    IconButton(
                      tooltip: 'Modo conversa: responde falando e reabre o microfone',
                      isSelected: c.modoConversa,
                      icon: const Icon(Icons.hearing_disabled_outlined),
                      selectedIcon: const Icon(Icons.hearing),
                      onPressed: () => c.alternarModoConversa(!c.modoConversa),
                    ),
                  ],
                  IconButton(
                    tooltip: 'Histórico de conversas',
                    icon: const Icon(Icons.history),
                    onPressed: c.pensando ? null : () => _abrirHistorico(context),
                  ),
                  if (c.mensagens.isNotEmpty)
                    IconButton(tooltip: 'Nova conversa', icon: const Icon(Icons.add_comment_outlined), onPressed: c.limpar),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: _rolagem,
                padding: const EdgeInsets.all(12),
                children: [
                  if (c.mensagens.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Diga o que tem para fazer, peça para anotar algo (“anote …”) ou para pesquisar na base '
                        '(“pesquise …”), por texto ou pelo microfone. O cobrador conhece sua agenda, metas e '
                        'tarefas, e age por você: cria tarefas, mexe na agenda e registra metas.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  for (final (papel, texto) in c.mensagens)
                    _Balao(
                      texto: texto,
                      doUsuario: papel == 'usuario',
                      repetir: papel == 'assistente' && ConversaCobrador.vozSuportada && !c.pensando && !c.gravando
                          ? () => c.repetir(texto)
                          : null,
                    ),
                  if (c.pensando)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          const SizedBox.square(dimension: 22, child: CircularProgressIndicator.adaptive()),
                          if (c.aviso != null) ...[
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(c.aviso!, style: TextStyle(color: cores.primary, fontStyle: FontStyle.italic)),
                            ),
                          ],
                        ],
                      ),
                    ),
                  if (c.erro != null)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(c.erro!, style: TextStyle(color: cores.error)),
                    ),
                ],
              ),
            ),
            if (c.gravando || c.falando)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _OndaVoz(cor: c.gravando ? cores.error : cores.primary),
                    const SizedBox(width: 12),
                    Text(c.gravando ? 'Ouvindo você…' : 'Respondendo…'),
                  ],
                ),
              ),
            if (c.vozAtiva)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: cores.error, foregroundColor: cores.onError),
                    icon: const Icon(Icons.stop),
                    label: const Text('Parar conversa'),
                    onPressed: c.encerrar,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final a in atalhos)
                    ActionChip(label: Text(a.trim()), onPressed: c.pensando ? null : () => _atalho(a)),
                ],
              ),
            ),
            if (_anexo case (final bytes, _))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(bytes, width: 56, height: 56, fit: BoxFit.cover),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('Imagem anexada à próxima mensagem')),
                    IconButton(
                      tooltip: 'Remover imagem',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _anexo = null),
                    ),
                  ],
                ),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _campo,
                  enabled: !c.pensando,
                  textInputAction: TextInputAction.send,
                  minLines: 1,
                  maxLines: 4,
                  onSubmitted: (_) => _enviar(),
                  decoration: InputDecoration(
                    hintText: c.gravando
                        ? (c.modoConversa ? 'Ouvindo… envia sozinho quando você para de falar' : 'Gravando… toque em ■ para enviar')
                        : 'Fale com o cobrador…',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    prefixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (ConversaCobrador.vozSuportada)
                          IconButton(
                            tooltip: c.gravando ? 'Parar e enviar' : 'Falar',
                            icon: Icon(c.gravando ? Icons.stop_circle : Icons.mic_none),
                            color: c.gravando ? cores.error : null,
                            onPressed: c.pensando ? null : c.alternarGravacao,
                          ),
                        if (!kIsWeb)
                          IconButton(
                            tooltip: 'Anexar imagem',
                            icon: const Icon(Icons.add_photo_alternate_outlined),
                            onPressed: c.pensando || c.gravando ? null : _anexar,
                          ),
                      ],
                    ),
                    suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _enviar),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Balao extends StatelessWidget {
  const _Balao({required this.texto, required this.doUsuario, this.repetir});

  final String texto;
  final bool doUsuario;

  /// Ouvir esta resposta de novo; nulo esconde o botão.
  final VoidCallback? repetir;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    return Align(
      alignment: doUsuario ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: doUsuario ? cores.primaryContainer : cores.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (doUsuario)
              SelectableText(texto, style: TextStyle(color: cores.onPrimaryContainer))
            else
              SelectionArea(
                child: VisualizadorMarkdown(
                  texto: texto,
                  estilo: Theme.of(context).textTheme.bodyMedium!.copyWith(color: cores.onSurface, height: 1.45),
                ),
              ),
            if (repetir != null)
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Ouvir de novo',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: const Icon(Icons.replay),
                  onPressed: repetir,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Barras que sobem e descem enquanto o cobrador escuta ou fala.
class _OndaVoz extends StatefulWidget {
  const _OndaVoz({required this.cor});

  final Color cor;

  @override
  State<_OndaVoz> createState() => _OndaVozState();
}

class _OndaVozState extends State<_OndaVoz> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _anim,
    builder: (context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++)
          Container(
            width: 5,
            height: 8 + 18 * (0.5 + 0.5 * math.sin(2 * math.pi * (_anim.value + i / 5))),
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(color: widget.cor, borderRadius: BorderRadius.circular(3)),
          ),
      ],
    ),
  );
}
