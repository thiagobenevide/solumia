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

  test('ffmpeg records without re-encoding and feeds preview and studio', () {
    final h = StreamHeader.parse('SOLUMIA-CAM 1 hevc 1920x1080 60 0')!;
    final args = ffmpegArguments(h, file: '/tmp/x.mkv', previewPort: 5601).join(' ');
    expect(args, contains('-f hevc -framerate 60 -i pipe:0'));
    expect(args, contains('-c copy -f matroska /tmp/x.mkv'));
    expect(args, contains('udp://127.0.0.1:5602'));
    expect(args, isNot(contains('v4l2')));
    expect(ffmpegArguments(h, previewPort: 5601, webcam: '/dev/video9').join(' '), contains('-f v4l2 /dev/video9'));
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
