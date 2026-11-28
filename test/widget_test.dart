import 'package:flutter/material.dart';
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

  test('detects previewable markdown paths', () {
    expect(isPreviewableMarkdownPath('/README.MD'), isTrue);
    expect(isPreviewableMarkdownPath('/guide.markdown'), isTrue);
    expect(isPreviewableMarkdownPath('/notes.txt'), isFalse);
    expect(isPreviewableMarkdownPath('/photo.png'), isFalse);
  });

  test('detects common document paths', () {
    expect(isCommonDocumentPath('/report.PDF'), isTrue);
    expect(isCommonDocumentPath('/sheet.xlsx'), isTrue);
    expect(isCommonDocumentPath('/slides.pptx'), isTrue);
    expect(isCommonDocumentPath('/README.markdown'), isTrue);
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

  test('parses pending agent question payload', () {
    final question = AgentPendingQuestion.fromJson({
      'formId': 'frm_abc123',
      'title': 'Questions',
      'questions': [
        {
          'key': 'q0',
          'header': '方向',
          'question': '接下来先做哪一项？',
          'multiple': false,
          'custom': true,
          'required': true,
          'options': [
            {'value': 'A', 'label': '选项 A', 'description': '先做 A'},
            {'value': 'B', 'label': '选项 B', 'description': ''},
          ],
        },
      ],
    });

    expect(question.formId, 'frm_abc123');
    expect(question.questions, hasLength(1));
    expect(question.questions.first.key, 'q0');
    expect(question.questions.first.header, '方向');
    expect(question.questions.first.multiple, isFalse);
    expect(question.questions.first.options, hasLength(2));
    expect(question.questions.first.options.first.label, '选项 A');
  });

  test('builds shared lyrics key and display text', () {
    expect(lyricsKeyFromFileName('01 - 晴天.flac'), '晴天');
    expect(lyricsKeyFromFileName('02 夜曲.mp3'), '夜曲');
    expect(lyricsKeyFromFileName('7 Rings.mp3'), '7 Rings');
    expect(
      lyricsResourcePath('01 - 晴天.flac'),
      '/音乐播放器/lyrics/晴天.lrc',
    );
    expect(
      stripLrcForDisplay('[ti:晴天]\n[00:01.00]Hello\n[00:03.50]世界\n'),
      'Hello\n世界',
    );

    final lines = parseLyrics('[00:01.00]第一行\n[00:03.50]第二行\n');
    expect(lines, hasLength(2));
    expect(lines.first.time, const Duration(seconds: 1));
    expect(lines.last.text, '第二行');

    expect(
      lyricsKeysForFileName('出山-花粥.mp3'),
      ['出山-花粥', '出山', '花粥'],
    );
    expect(lyricLineCount('[00:01.00]一句'), 1);
    expect(isUsableLyrics('[00:01.00]一句'), isFalse);
  });

  testWidgets('renders markdown preview content', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MarkdownPreviewPage(
          title: 'README.md',
          loadMarkdown: () async => '# 标题\n\n正文',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('标题', findRichText: true), findsOneWidget);
    expect(find.textContaining('正文', findRichText: true), findsOneWidget);
  });

  testWidgets('renders NAS host probe shell', (tester) async {
    await tester.pumpWidget(const NasPhoneApp());

    expect(find.text('查看并连接你的设备'), findsOneWidget);
    expect(find.text('扫码获取授权和注册'), findsOneWidget);
    expect(find.text('扫一扫'), findsOneWidget);
    expect(find.text('文件列表'), findsNothing);
  });
}
