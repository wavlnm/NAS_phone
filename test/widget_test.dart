import 'package:flutter_test/flutter_test.dart';

import 'package:nas_phone/main.dart';

void main() {
  test('detects previewable image paths', () {
    expect(isPreviewableImagePath('/photo.JPG'), isTrue);
    expect(isPreviewableImagePath('/cover.png'), isTrue);
    expect(isPreviewableImagePath('/clip.mp4'), isFalse);
    expect(isPreviewableImagePath('/notes.txt'), isFalse);
  });

  test('detects previewable audio paths', () {
    expect(isPreviewableAudioPath('/track.MP3'), isTrue);
    expect(isPreviewableAudioPath('/voice.m4a'), isTrue);
    expect(isPreviewableAudioPath('/photo.jpg'), isFalse);
    expect(isPreviewableAudioPath('/notes.txt'), isFalse);
  });

  test('detects previewable video paths', () {
    expect(isPreviewableVideoPath('/movie.MP4'), isTrue);
    expect(isPreviewableVideoPath('/clip.mkv'), isTrue);
    expect(isPreviewableVideoPath('/voice.m4a'), isFalse);
    expect(isPreviewableVideoPath('/notes.txt'), isFalse);
  });

  testWidgets('renders NAS host probe shell', (tester) async {
    await tester.pumpWidget(const NasPhoneApp());

    expect(find.text('连接你的 loal_NAS 宿主'), findsOneWidget);
    expect(find.text('宿主地址'), findsOneWidget);
    expect(find.text('连接并加载文件'), findsOneWidget);
    expect(find.text('尚未探测'), findsOneWidget);
    expect(find.text('探测结果'), findsOneWidget);
    expect(find.text('文件列表'), findsNothing);
  });
}
