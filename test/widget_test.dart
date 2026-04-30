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

  test('detects common document paths', () {
    expect(isCommonDocumentPath('/report.PDF'), isTrue);
    expect(isCommonDocumentPath('/sheet.xlsx'), isTrue);
    expect(isCommonDocumentPath('/slides.pptx'), isTrue);
    expect(isCommonDocumentPath('/movie.mp4'), isFalse);
    expect(isCommonDocumentPath('/archive.zip'), isFalse);
  });

  test('parses host status with storage information', () {
    final status = NasHostStatus.fromJson({
      'name': 'loal_NAS MVP host',
      'fileBrowser': {
        'running': true,
        'baseUrl': 'http://127.0.0.1:38080',
        'sharedRoot': 'C:/share',
      },
      'storage': {
        'driveName': 'C:\\',
        'totalBytes': 500,
        'usedBytes': 200,
        'freeBytes': 300,
      },
      'fileBrowserRunning': false,
      'fileBrowserBaseUrl': 'ignored',
      'sharedRootPath': 'ignored',
    });

    expect(status.hostName, 'loal_NAS MVP host');
    expect(status.fileBrowserRunning, isTrue);
    expect(status.fileBrowserBaseUrl, 'http://127.0.0.1:38080');
    expect(status.sharedRoot, 'C:/share');
    expect(status.storage, isNotNull);
    expect(status.storage!.driveName, 'C:\\');
    expect(status.storage!.totalBytes, 500);
    expect(status.storage!.usedBytes, 200);
    expect(status.storage!.freeBytes, 300);
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
