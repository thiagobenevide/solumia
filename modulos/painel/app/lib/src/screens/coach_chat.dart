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

import '../panel_api.dart';
import '../models.dart';

/// One-tap shortcuts; “anote”/“pesquise” become commands on the server.
const shortcuts = ['O que tenho para fazer agora?', 'Estou dentro da disciplina?', 'Anote: ', 'Pesquise na base: '];

/// Cap of the sent photo: with margin under the VPS → worker connection limit (16 MB, already in base64).
const imageLimit = 1024 * 1024;

/// Shrinks any photo to a JPEG of up to 1600 px and at most [imageLimit], reducing side and quality
/// until it fits. Runs in an isolate ([compute]); null if the file is not a readable image.
Uint8List? compressImage(Uint8List bytes) {
  final original = img.decodeImage(bytes);
  if (original == null) return null;
  final photo = img.bakeOrientation(original); // the EXIF rotation would be lost on re-encoding
  var side = 1600;
  var quality = 80;
  while (true) {
    final reduced = photo.width >= photo.height
        ? img.copyResize(photo, width: math.min(side, photo.width))
        : img.copyResize(photo, height: math.min(side, photo.height));
    final jpg = img.encodeJpg(reduced, quality: quality);
    if (jpg.length <= imageLimit || side <= 480) return jpg;
    side = (side * 0.75).round();
    quality = math.max(50, quality - 10);
  }
}

/// Conversation stored on the device to resume later from the history.
class SavedConversation {
  SavedConversation(this.id, this.updated, this.messages);

  factory SavedConversation.fromJson(Map<String, dynamic> j) => SavedConversation(
    j['id'] as String,
    DateTime.parse(j['atualizada'] as String),
    [for (final m in j['mensagens'] as List) ('${m[0]}', '${m[1]}')],
  );

  final String id;
  final DateTime updated;
  final List<(String, String)> messages;

  String get title {
    final (_, text) = messages.firstWhere((m) => m.$1 == 'usuario', orElse: () => messages.first);
    final t = text.replaceFirst('🎤', '').trim();
    return t.length > 60 ? '${t.substring(0, 60)}…' : t;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'atualizada': updated.toIso8601String(),
    'mensagens': [for (final (role, text) in messages) [role, text]],
  };
}

/// Conversation with the coach, by text or voice. Lives outside the widget to survive tab switches.
class CoachConversation extends ChangeNotifier {
  CoachConversation(this.api) {
    _loadProviders();
    _loadConversations();
  }

  final PanelApi api;
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();

  /// (`usuario`|`assistente`, text), in order.
  final messages = <(String, String)>[];
  List<String> providers = const ['local'];
  String provider = 'local';
  bool thinking = false;

  /// Server progress while [thinking] ("Consultando a cotação das moedas.").
  String? warning;

  /// Warnings being spoken in a queue; the final reply waits for them.
  Future<void> _speakWarnings = Future.value();
  bool recording = false;
  bool speaking = false;

  /// Conversation history, most recent first; the current one goes in on every reply.
  final conversations = <SavedConversation>[];
  String? _currentId;
  static const _conversationsKey = 'cobrador_conversas';

  /// Changes on every [finish]: whatever was still running from the previous round is ignored.
  int _round = 0;
  StreamSubscription<Amplitude>? _watcher;

  /// Reads every reply aloud.
  bool listenToReplies = false;

  /// Hands-free voice conversation: answers by speaking and reopens the microphone when done.
  bool conversationMode = false;
  String? error;

  static bool get voiceSupported => !kIsWeb;

  /// Voice is in progress (recording, speaking, waiting for a reply to be read, or conversation mode).
  bool get voiceActive => recording || speaking || conversationMode || (thinking && listenToReplies);

  Future<void> _loadConversations() async {
    try {
      final p = await SharedPreferences.getInstance();
      final items = jsonDecode(p.getString(_conversationsKey) ?? '[]') as List;
      conversations.addAll([for (final j in items) SavedConversation.fromJson(j as Map<String, dynamic>)]);
      notifyListeners();
    } catch (_) {
      // corrupted or unavailable history: starts empty
    }
  }

  Future<void> _saveConversations() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_conversationsKey, jsonEncode([for (final c in conversations) c.toJson()]));
    } catch (_) {}
  }

  Future<void> _storeCurrent() async {
    if (messages.isEmpty) return;
    final id = _currentId ??= '${DateTime.now().millisecondsSinceEpoch}';
    conversations.removeWhere((c) => c.id == id);
    conversations.insert(0, SavedConversation(id, DateTime.now(), [...messages]));
    if (conversations.length > 50) conversations.removeRange(50, conversations.length);
    await _saveConversations();
  }

  /// Goes back to a conversation from the history; the next messages continue in it.
  Future<void> retomar(SavedConversation c) async {
    if (thinking) return;
    await finish();
    messages
      ..clear()
      ..addAll(c.messages);
    _currentId = c.id;
    error = null;
    notifyListeners();
  }

  void deleteConversation(SavedConversation c) {
    conversations.remove(c);
    if (_currentId == c.id) _currentId = null;
    _saveConversations();
    notifyListeners();
  }

  Future<void> _loadProviders() async {
    try {
      providers = await api.providers();
      notifyListeners();
    } on ApiErro {
      // no server right now: only the local one stays, the error shows on the first message
    }
  }

  void pick(String p) {
    provider = p;
    notifyListeners();
  }

  void toggleListening(bool v) {
    listenToReplies = v;
    if (!v) finish();
    notifyListeners();
  }

  void toggleConversationMode(bool v) {
    if (!v) {
      finish();
      return;
    }
    conversationMode = true;
    listenToReplies = true;
    notifyListeners();
    if (!recording && !thinking) toggleRecording();
  }

  /// Stops everything at once: discards the recording, hushes the speech and leaves conversation mode. Replies
  /// that still arrive from this round are not read and do not reopen the microphone (the [_round] changed).
  Future<void> finish() async {
    _round++;
    conversationMode = false;
    speaking = false;
    _watcher?.cancel();
    _watcher = null;
    if (recording) {
      recording = false;
      try {
        await _recorder.cancel();
      } catch (_) {}
    }
    await _stopSpeech();
    notifyListeners();
  }

  Future<void> _stopSpeech() async {
    try {
      await _player.stop();
    } catch (_) {
      // Linux with nothing playing may complain about stop; it must not prevent recording.
    }
  }

  List<(String, String)> get _history =>
      messages.length > 10 ? messages.sublist(messages.length - 10) : [...messages];

  /// [image] (bytes, mime): attached photo; without text, asks to describe it.
  Future<void> send(String text, {(List<int>, String)? image}) async {
    text = text.trim();
    if (text.isEmpty && image != null) text = 'Descreva esta imagem.';
    if (text.isEmpty || thinking) return;
    final history = _history;
    messages.add(('usuario', image == null ? text : '🖼️ $text'));
    await _wait(
      () => api.chatStream(text, history, provider, image: image, onWarn: _onWarn),
    );
  }

  /// Tap on the microphone: starts recording; second tap: stops and sends the audio. In conversation mode
  /// recording also stops on its own after ~1.5 s of silence, and the conversation ends if you say
  /// nothing for 8 s.
  Future<void> toggleRecording() async {
    if (thinking) return;
    error = null;
    if (!recording) return _startRecording();
    await _stopAndSend();
  }

  Future<void> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) {
        error = 'Sem permissão para usar o microfone.';
        conversationMode = false;
        notifyListeners();
        return;
      }
      speaking = false;
      await _stopSpeech();
      final path = '${Directory.systemTemp.path}/cobrador_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        ),
        path: path,
      );
    } catch (e) {
      error = Platform.isLinux
          ? 'Não consegui abrir o microfone ($e). No Linux a gravação usa o parecord e o ffmpeg: '
                'sudo apt install pulseaudio-utils ffmpeg'
          : 'Não consegui abrir o microfone: $e';
      conversationMode = false;
      notifyListeners();
      return;
    }
    recording = true;
    notifyListeners();
    if (conversationMode) _watchSilence();
  }

  /// End of speech by the microphone volume (dBFS): above -40 is voice.
  void _watchSilence() {
    final round = _round;
    final start = DateTime.now();
    DateTime? lastVoice;
    _watcher?.cancel();
    _watcher = _recorder.onAmplitudeChanged(const Duration(milliseconds: 150)).listen((amp) {
      if (round != _round || !recording) return;
      final now = DateTime.now();
      if (amp.current > -40) lastVoice = now;
      if (lastVoice == null && now.difference(start) > const Duration(seconds: 8)) {
        error = 'Conversa encerrada: não ouvi nada.';
        finish();
      } else if (lastVoice != null && now.difference(lastVoice!) > const Duration(milliseconds: 1500)) {
        _stopAndSend();
      }
    });
  }

  Future<void> _stopAndSend() async {
    if (!recording) return;
    recording = false;
    _watcher?.cancel();
    _watcher = null;
    String? path;
    try {
      path = await _recorder.stop();
    } catch (e) {
      error = 'A gravação falhou: $e';
    }
    if (path == null) {
      conversationMode = false;
      notifyListeners();
      return;
    }
    final file = File(path);
    final List<int> wav;
    try {
      wav = await file.readAsBytes();
      await file.delete();
    } catch (e) {
      error = 'Não consegui ler a gravação: $e';
      conversationMode = false;
      notifyListeners();
      return;
    }
    // 16 kHz mono WAV: less than ~0.4 s of audio is an accidental tap, not worth sending.
    if (wav.length < 44 + 16000 * 2 * 0.4) {
      error = 'Gravação curta demais.';
      conversationMode = false;
      notifyListeners();
      return;
    }
    final history = _history;
    messages.add(('usuario', '🎤 …'));
    final score = messages.length - 1;
    await _wait(
      () => api.voiceStream(
        wav,
        history,
        provider,
        onWarn: _onWarn,
        aoTranscrever: (t) {
          if (score < messages.length) messages[score] = ('usuario', '🎤 $t');
          notifyListeners();
        },
      ),
      voiceIndex: score,
    );
  }

  /// Progress warning: shows in the chat and, with voice on, is spoken while the reply has not arrived.
  void _onWarn(String text) {
    warning = text;
    notifyListeners();
    final round = _round;
    if (!listenToReplies || !voiceSupported || text.trim().isEmpty) return;
    _speakWarnings = _speakWarnings.then((_) => round == _round ? _speak(text, round, warning: true) : null);
  }

  Future<void> _wait(Future<CoachReply> Function() request, {int? voiceIndex}) async {
    final round = _round;
    warning = null;
    _speakWarnings = Future.value();
    thinking = true;
    notifyListeners();
    CoachReply? r;
    try {
      // Audio goes through transcription and the LLM on the PC (via VPS): without a limit, the phone waited
      // forever when the connection dropped midway.
      r = await request().timeout(const Duration(minutes: 3));
      if (voiceIndex != null) messages[voiceIndex] = ('usuario', '🎤 ${r.transcription ?? ''}');
      messages.add(('assistente', r.fullText));
    } catch (e) {
      // Any failure (not only from the API) must show up; before, it escaped and the chat looked mute.
      if (voiceIndex != null) messages.removeAt(voiceIndex);
      error = switch (e) {
        ApiErro(status: 503 || 422 || 413) => e.mensagem,
        TimeoutException() => 'O servidor não respondeu em 3 minutos (o PC com o worker está ligado e conectado?).',
        _ => '$e',
      };
      conversationMode = false;
    } finally {
      thinking = false;
      warning = null;
      notifyListeners();
    }
    await _speakWarnings; // the "estou consultando…" finishes before the reply starts
    if (r != null) unawaited(_storeCurrent());
    if (r == null || round != _round || !listenToReplies || !voiceSupported) return;
    // When the LLM only runs actions the reply has no text: reads the actions or, with nothing to say,
    // continues the conversation (before, it asked for voice for empty text and the server refused with 422).
    final speech = r.spokenText.trim();
    if (speech.isEmpty) {
      if (conversationMode && !recording) await toggleRecording();
      return;
    }
    await _speak(speech, round);
  }

  /// Speaks in excerpts: plays the first as soon as it is ready and already requests the next, instead of waiting
  /// for the whole reply to become audio.
  Future<void> _speak(String text, int round, {bool warning = false}) async {
    var next = api.speak(text, excerpt: 0);
    try {
      for (var i = 0;; i++) {
        final wav = await next;
        if (round != _round || wav.isEmpty) break;
        next = api.speak(text, excerpt: i + 1);
        final file = File('${Directory.systemTemp.path}/cobrador_fala_${round}_$i.wav');
        await file.writeAsBytes(wav, flush: true);
        if (round != _round) break;
        speaking = true;
        notifyListeners();
        final end = _player.onPlayerStateChanged.firstWhere(
          (e) => e == PlayerState.completed || e == PlayerState.stopped,
        );
        await _player.play(DeviceFileSource(file.path));
        await end;
        unawaited(file.delete().catchError((_) => file));
        if (round != _round || !speaking) break;
      }
    } on ApiErro catch (e) {
      error = 'Sem voz agora: ${e.mensagem}';
      speaking = false;
      conversationMode = false;
      notifyListeners();
      return;
    } catch (e) {
      error = 'Não consegui tocar a resposta: $e';
      speaking = false;
      conversationMode = false;
      notifyListeners();
      return;
    } finally {
      next.ignore(); // excerpt requested and not played (stopped midway): no stray error
    }
    if (warning) {
      speaking = false; // the microphone only reopens after the reply
      notifyListeners();
    } else if (round == _round) {
      _onSpeechEnd();
    }
  }

  void _onSpeechEnd() {
    if (!speaking) return; // stopped by hand: does not reopen the microphone
    speaking = false;
    notifyListeners();
    if (conversationMode && !recording && !thinking) toggleRecording();
  }

  /// Reads a chat reply again (without the links); ends conversation mode so the microphone does not reopen.
  Future<void> repeat(String text) async {
    if (thinking || recording) return;
    await finish();
    final speech = text
        .split('\n')
        .where((l) => !l.startsWith('🔗'))
        .map((l) => l.replaceFirst(RegExp(r'^[✔✖] '), ''))
        .join('\n')
        .trim();
    if (speech.isNotEmpty) await _speak(speech, _round);
  }

  /// "Parar de falar": hushes and ends conversation mode (otherwise the microphone would reopen right after).
  void hush() => finish();

  void clear() {
    messages.clear();
    _currentId = null;
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _watcher?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }
}

class CoachChat extends StatefulWidget {
  const CoachChat({super.key, required this.conversation});

  final CoachConversation conversation;

  @override
  State<CoachChat> createState() => _CoachChatState();
}

class _CoachChatState extends State<CoachChat> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// Photo chosen to go with the next message (bytes, mime).
  (Uint8List, String)? _attachment;

  @override
  void initState() {
    super.initState();
    widget.conversation.addListener(_scrollToEnd);
  }

  @override
  void dispose() {
    widget.conversation.removeListener(_scrollToEnd);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  });

  void _send() {
    widget.conversation.send(_input.text, image: _attachment);
    _input.clear();
    setState(() => _attachment = null);
  }

  /// On the phone asks camera or gallery; on desktop opens the file picker directly.
  Future<void> _attach() async {
    var origin = ImageSource.gallery;
    if (Platform.isAndroid || Platform.isIOS) {
      final choice = await showModalBottomSheet<ImageSource>(
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
      if (choice == null) return;
      origin = choice;
    }
    try {
      // The phone already delivers it reduced; [compressImage] ensures the cap on any platform.
      final photo = await ImagePicker().pickImage(source: origin, maxWidth: 1600, maxHeight: 1600, imageQuality: 80);
      if (photo == null) return;
      final jpg = await compute(compressImage, await photo.readAsBytes());
      if (jpg == null) throw const FormatException('formato não reconhecido');
      if (mounted) setState(() => _attachment = (jpg, 'image/jpeg'));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Não consegui abrir a imagem: $e')));
    }
  }

  /// A shortcut ending in “: ” only fills the field for the user to complete.
  void _shortcut(String a) {
    if (a.endsWith(': ')) {
      _input.text = a;
      _input.selection = TextSelection.collapsed(offset: a.length);
    } else {
      widget.conversation.send(a);
    }
  }

  void _openHistory(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => ListenableBuilder(
      listenable: widget.conversation,
      builder: (context, _) {
        final c = widget.conversation;
        return SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: c.conversations.isEmpty
              ? const Center(child: Text('Nenhuma conversa guardada ainda.'))
              : ListView(
                  children: [
                    for (final s in c.conversations)
                      ListTile(
                        leading: const Icon(Icons.chat_bubble_outline),
                        title: Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${MaterialLocalizations.of(context).formatShortDate(s.updated)} '
                          '${TimeOfDay.fromDateTime(s.updated).format(context)} · ${s.messages.length} mensagens',
                        ),
                        trailing: IconButton(
                          tooltip: 'Apagar',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => c.deleteConversation(s),
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
    final colors = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.conversation,
      builder: (context, _) {
        final c = widget.conversation;
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
                          for (final p in c.providers)
                            ButtonSegment(value: p, label: Text(p == 'local' ? 'LLM local' : 'Claude')),
                        ],
                        selected: {c.provider},
                        onSelectionChanged: (s) => c.pick(s.first),
                      ),
                    ),
                  ),
                  if (CoachConversation.voiceSupported) ...[
                    IconButton(
                      tooltip: 'Ler as respostas em voz alta',
                      isSelected: c.listenToReplies,
                      icon: const Icon(Icons.volume_off_outlined),
                      selectedIcon: const Icon(Icons.record_voice_over),
                      onPressed: () => c.toggleListening(!c.listenToReplies),
                    ),
                    IconButton(
                      tooltip: 'Modo conversa: responde falando e reabre o microfone',
                      isSelected: c.conversationMode,
                      icon: const Icon(Icons.hearing_disabled_outlined),
                      selectedIcon: const Icon(Icons.hearing),
                      onPressed: () => c.toggleConversationMode(!c.conversationMode),
                    ),
                  ],
                  IconButton(
                    tooltip: 'Histórico de conversas',
                    icon: const Icon(Icons.history),
                    onPressed: c.thinking ? null : () => _openHistory(context),
                  ),
                  if (c.messages.isNotEmpty)
                    IconButton(tooltip: 'Nova conversa', icon: const Icon(Icons.add_comment_outlined), onPressed: c.clear),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                children: [
                  if (c.messages.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Diga o que tem para fazer, peça para anotar algo (“anote …”) ou para pesquisar na base '
                        '(“pesquise …”), por texto ou pelo microfone. O cobrador conhece sua agenda, metas e '
                        'tarefas, e age por você: cria tarefas, mexe na agenda e registra metas.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  for (final (role, text) in c.messages)
                    _Bubble(
                      text: text,
                      fromUser: role == 'usuario',
                      repeat: role == 'assistente' && CoachConversation.voiceSupported && !c.thinking && !c.recording
                          ? () => c.repeat(text)
                          : null,
                    ),
                  if (c.thinking)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          const SizedBox.square(dimension: 22, child: CircularProgressIndicator.adaptive()),
                          if (c.warning != null) ...[
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(c.warning!, style: TextStyle(color: colors.primary, fontStyle: FontStyle.italic)),
                            ),
                          ],
                        ],
                      ),
                    ),
                  if (c.error != null)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(c.error!, style: TextStyle(color: colors.error)),
                    ),
                ],
              ),
            ),
            if (c.recording || c.speaking)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _VoiceWave(color: c.recording ? colors.error : colors.primary),
                    const SizedBox(width: 12),
                    Text(c.recording ? 'Ouvindo você…' : 'Respondendo…'),
                  ],
                ),
              ),
            if (c.voiceActive)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: colors.error, foregroundColor: colors.onError),
                    icon: const Icon(Icons.stop),
                    label: const Text('Parar conversa'),
                    onPressed: c.finish,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final a in shortcuts)
                    ActionChip(label: Text(a.trim()), onPressed: c.thinking ? null : () => _shortcut(a)),
                ],
              ),
            ),
            if (_attachment case (final bytes, _))
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
                      onPressed: () => setState(() => _attachment = null),
                    ),
                  ],
                ),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _input,
                  enabled: !c.thinking,
                  textInputAction: TextInputAction.send,
                  minLines: 1,
                  maxLines: 4,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: c.recording
                        ? (c.conversationMode ? 'Ouvindo… envia sozinho quando você para de falar' : 'Gravando… toque em ■ para enviar')
                        : 'Fale com o cobrador…',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    prefixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (CoachConversation.voiceSupported)
                          IconButton(
                            tooltip: c.recording ? 'Parar e enviar' : 'Falar',
                            icon: Icon(c.recording ? Icons.stop_circle : Icons.mic_none),
                            color: c.recording ? colors.error : null,
                            onPressed: c.thinking ? null : c.toggleRecording,
                          ),
                        if (!kIsWeb)
                          IconButton(
                            tooltip: 'Anexar imagem',
                            icon: const Icon(Icons.add_photo_alternate_outlined),
                            onPressed: c.thinking || c.recording ? null : _attach,
                          ),
                      ],
                    ),
                    suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _send),
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

class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.fromUser, this.repeat});

  final String text;
  final bool fromUser;

  /// Listen to this reply again; null hides the button.
  final VoidCallback? repeat;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: fromUser ? colors.primaryContainer : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (fromUser)
              SelectableText(text, style: TextStyle(color: colors.onPrimaryContainer))
            else
              SelectionArea(
                child: VisualizadorMarkdown(
                  texto: text,
                  estilo: Theme.of(context).textTheme.bodyMedium!.copyWith(color: colors.onSurface, height: 1.45),
                ),
              ),
            if (repeat != null)
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Ouvir de novo',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: const Icon(Icons.replay),
                  onPressed: repeat,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Bars that go up and down while the coach listens or speaks.
class _VoiceWave extends StatefulWidget {
  const _VoiceWave({required this.color});

  final Color color;

  @override
  State<_VoiceWave> createState() => _VoiceWaveState();
}

class _VoiceWaveState extends State<_VoiceWave> with SingleTickerProviderStateMixin {
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
            decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(3)),
          ),
      ],
    ),
  );
}
