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
      'name': '千私云电脑',
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

    expect(status.hostName, '千私云电脑');
    expect(status.fileBrowserRunning, isTrue);
    expect(status.fileBrowserBaseUrl, 'http://127.0.0.1:38080');
    expect(status.sharedRoot, 'C:/share');
    expect(status.storage, isNotNull);
    expect(status.storage!.driveName, 'C:\\');
    expect(status.storage!.totalBytes, 500);
    expect(status.storage!.usedBytes, 200);
    expect(status.storage!.freeBytes, 300);
  });

  test('serializes local note json', () {
    final source = LocalNote(
      id: '1',
      title: '测试',
      content: '内容',
      updatedAt: DateTime.parse('2026-04-30T12:00:00Z'),
    );

    final restored = LocalNote.fromJson(source.toJson());

    expect(restored.id, '1');
    expect(restored.title, '测试');
    expect(restored.content, '内容');
    expect(restored.updatedAt.toUtc(), DateTime.parse('2026-04-30T12:00:00Z'));
  });

  test('hides dot-prefixed directories from file lists', () {
    final directory = FileBrowserDirectory.fromJson({
      'path': '/',
      'items': [
        {'name': '.note', 'path': '/.note/', 'isDir': true, 'size': 0},
        {'name': '照片', 'path': '/照片/', 'isDir': true, 'size': 0},
        {'name': '.env', 'path': '/.env', 'isDir': false, 'size': 12},
      ],
    });

    expect(directory.items.map((entry) => entry.name).toList(), ['照片', '.env']);
  });

  testWidgets('renders NAS host probe shell', (tester) async {
    await tester.pumpWidget(const NasPhoneApp());

    expect(find.text('查看并连接你的设备'), findsOneWidget);
    expect(find.text('扫码获取授权和注册'), findsOneWidget);
    expect(find.text('扫一扫'), findsOneWidget);
    expect(find.text('文件列表'), findsNothing);
  });
}
