import 'dart:typed_data';

import 'package:agent_empreendimento/src/recording/camera_pro.dart';
import 'package:agent_empreendimento/src/recording/capture_api.dart';
import 'package:agent_empreendimento/src/recording/protocol.dart';
import 'package:agent_empreendimento/src/recording/studio_item_panel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PC announcement round trip', () {
    final a = PcAnnouncement.parse(const PcAnnouncement(5600, 'my pc').encode());
    expect(a?.port, 5600);
    expect(a?.name, 'my pc');
    expect(PcAnnouncement.parse('something else 1 2'), isNull);
  });

  test('stream header', () {
    final h = StreamHeader.parse('SOLUMIA-CAM 1 hevc 3840x2160 60 1\n')!;
    expect(h.ffmpegFormat, 'hevc');
    expect((h.width, h.height, h.fps, h.hlg), (3840, 2160, 60, true));
    expect(StreamHeader.parse('SOLUMIA-CAM 1 avc 1920x1080 60 0')?.ffmpegFormat, 'h264');
    expect(StreamHeader.parse('SOLUMIA-CAM 1 vp9 1920x1080 60 0'), isNull);
    expect(StreamHeader.parse('SOLUMIA-CAM 1 hevc 1920 60 0'), isNull);
  });

  test('live process feeds preview and studio without delay, take records without re-encoding', () {
    final h = StreamHeader.parse('SOLUMIA-CAM 1 hevc 1920x1080 60 0')!;
    final live = ffmpegArguments(h, previewPort: 5601).join(' ');
    expect(live, contains('-r 60 -f hevc -framerate 60 -i pipe:0'));
    expect(live, contains('-muxdelay 0 -muxpreload 0 -flush_packets 1 -f mpegts udp://127.0.0.1:5601'));
    expect(live, contains('udp://127.0.0.1:5602'));
    expect(live, isNot(contains('matroska')));
    expect(live, isNot(contains('v4l2')));
    expect(ffmpegArguments(h, previewPort: 5601, webcam: '/dev/video9').join(' '), contains('-f v4l2 /dev/video9'));
    final take = takeArguments(h, file: '/tmp/x.mkv').join(' ');
    expect(take, contains('-map 0:v -c copy -f matroska /tmp/x.mkv'));
    expect(take, isNot(contains('udp://')));
  });

  test('audio token turns on the framed stream and the audio input of the take', () {
    final h = StreamHeader.parse('SOLUMIA-CAM 1 hevc 3840x2160 30 0 pcm48000x2')!;
    expect((h.hasAudio, h.audioRate, h.audioChannels), (true, 48000, 2));
    expect(StreamHeader.parse('SOLUMIA-CAM 1 hevc 3840x2160 30 0')!.hasAudio, false);
    final args = takeArguments(h, file: '/tmp/x.mkv', audioPort: 4000).join(' ');
    expect(args, contains('-f s16le -ar 48000 -ac 2 -i tcp://127.0.0.1:4000'));
    expect(args, contains('-map 0:v -map 1:a -c copy -f matroska /tmp/x.mkv'));
    expect(ffmpegArguments(h, previewPort: 5601).join(' '), isNot(contains('s16le')));
  });

  test('frame splitter survives any chunk boundary', () {
    final video = <int>[];
    final audio = <int>[];
    final splitter = FrameSplitter(onVideo: video.addAll, onAudio: audio.addAll);
    final stream = <int>[0x56, 0, 0, 0, 3, 1, 2, 3, 0x41, 0, 0, 0, 2, 9, 8, 0x56, 0, 0, 0, 1, 4];
    for (final byte in stream) {
      expect(splitter.add(Uint8List.fromList([byte])), true);
    }
    expect(video, [1, 2, 3, 4]);
    expect(audio, [9, 8]);
    expect(splitter.add(Uint8List.fromList([0x58, 0, 0, 0, 0])), false);
  });

  test('control token turns on the framed stream even without audio', () {
    final h = StreamHeader.parse('SOLUMIA-CAM 1 hevc 1920x1080 60 0 ctl')!;
    expect((h.control, h.hasAudio, h.framed), (true, false, true));
    final both = StreamHeader.parse('SOLUMIA-CAM 1 hevc 1920x1080 60 0 pcm48000x2 ctl')!;
    expect((both.control, both.hasAudio, both.audioRate), (true, true, 48000));
    expect(StreamHeader.parse('SOLUMIA-CAM 1 hevc 1920x1080 60 0')!.framed, false);
  });

  test('frame splitter hands control frames apart', () {
    final video = <int>[];
    final control = <int>[];
    final splitter = FrameSplitter(onVideo: video.addAll, onAudio: (_) {}, onControl: control.addAll);
    final stream = <int>[0x43, 0, 0, 0, 2, 123, 125, 0x56, 0, 0, 0, 1, 7];
    expect(splitter.add(Uint8List.fromList(stream)), true);
    expect(control, [123, 125]);
    expect(video, [7]);
  });

  test('remote settings change only the keys sent, with the right types', () {
    final s = CameraSettings();
    s.apply({'iso': 800.0, 'manualExposure': true, 'awb': 'manual', 'kelvin': 99999, 'pointX': 0.25, 'bogus': 1});
    expect((s.iso, s.manualExposure, s.awb, s.kelvin, s.pointX), (800, true, 'manual', 10000, 0.25));
    expect(s.zoom, 1);
    s.apply({'iso': 'not a number'});
    expect(s.iso, 800);
    expect(s.toMap()['kelvin'], 10000);
  });

  test('camera info keeps the map it came from for the PC', () {
    final info = CameraInfo.fromJson({'id': '0', 'kelvin': true, 'point': true, 'isoMax': 3200});
    expect((info.kelvin, info.point, info.isoMax), (true, true, 3200));
    expect(CameraInfo.fromJson(info.raw).isoMax, 3200);
  });

  test('remux copies every track and tags HEVC for MOV', () {
    final args = remuxArguments('a.mkv', 'a.mov', hevc: true).join(' ');
    expect(args, contains('-map 0 -c copy -tag:v hvc1 a.mov'));
    expect(remuxArguments('a.mkv', 'a.mov', hevc: false).join(' '), isNot(contains('hvc1')));
  });

  test('item shapes keep the center', () {
    final item = SceneItem(source: 'c', x: 100, y: 100, w: 400, h: 225);
    applyShape(item, 'circle');
    expect((item.w, item.h, item.radius), (225, 225, 112.5));
    expect(item.circle, isTrue);
    expect(item.x + item.w / 2, closeTo(300, 1));
    applyShape(item, 'vertical');
    expect(item.w, (225 * 9 / 16).round());
  });

  test('corner position fits the canvas', () {
    final item = SceneItem(source: 'c', w: 1920, h: 1080);
    applyPosition(item, 'bottom_right', 1920, 1080);
    expect(item.x + item.w, lessThan(1920));
    expect(item.y + item.h, lessThan(1080));
    expect(item.w, 576);
  });
}
