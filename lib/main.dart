import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  runApp(const NasPhoneApp());
}

enum EntryMenuAction {
  delete,
  move,
  rename,
  download,
}

enum MainTab {
  home,
  recent,
  tools,
  mine,
}

enum SpaceScope {
  personal,
  family,
}

enum FileCategoryFilter {
  image,
  video,
  audio,
  document,
}

class FileCategoryShortcut {
  const FileCategoryShortcut({
    required this.filter,
    required this.label,
    required this.icon,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final FileCategoryFilter filter;
  final String label;
  final IconData icon;
  final Color backgroundColor;
  final Color foregroundColor;
}

const List<FileCategoryShortcut> _fileCategoryShortcuts = [
  FileCategoryShortcut(
    filter: FileCategoryFilter.image,
    label: '图片',
    icon: Icons.image_outlined,
    backgroundColor: Color(0xFFE0F2FE),
    foregroundColor: Color(0xFF0369A1),
  ),
  FileCategoryShortcut(
    filter: FileCategoryFilter.video,
    label: '视频',
    icon: Icons.play_circle_outline,
    backgroundColor: Color(0xFFFFEDD5),
    foregroundColor: Color(0xFFEA580C),
  ),
  FileCategoryShortcut(
    filter: FileCategoryFilter.audio,
    label: '音乐',
    icon: Icons.music_note_outlined,
    backgroundColor: Color(0xFFEEE7FF),
    foregroundColor: Color(0xFF6D28D9),
  ),
  FileCategoryShortcut(
    filter: FileCategoryFilter.document,
    label: '文档',
    icon: Icons.description_outlined,
    backgroundColor: Color(0xFFDCFCE7),
    foregroundColor: Color(0xFF15803D),
  ),
];

class NasPhoneApp extends StatelessWidget {
  const NasPhoneApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0F766E),
      brightness: Brightness.light,
    );

    return MaterialApp(
      title: 'NAS Phone',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFFF3F7F6),
        useMaterial3: true,
      ),
      home: const NasHomePage(),
    );
  }
}

class NasHomePage extends StatefulWidget {
  const NasHomePage({super.key});

  @override
  State<NasHomePage> createState() => _NasHomePageState();
}

class _NasHomePageState extends State<NasHomePage> {
  static const MethodChannel _systemOpenChannel = MethodChannel('nas_phone/system_open');

  final TextEditingController _hostController = TextEditingController();

  ProbeState _probeState = const ProbeState.idle();
  bool _isProbing = false;
  bool _isLoadingFiles = false;
  bool _isUploading = false;
  bool _isCreatingFolder = false;

  Uri? _baseUri;
  String? _authToken;
  String _currentDirectory = '/';
  List<FileBrowserEntry> _entries = const [];
  String? _fileError;
  String? _busyEntryPath;
  bool _showMainShell = false;
  MainTab _selectedTab = MainTab.home;
  SpaceScope _selectedSpace = SpaceScope.personal;

  bool get _hasFileSession => _baseUri != null && _authToken != null;
  bool get _canGoUp => _hasFileSession && _currentDirectory != '/';

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  Future<void> _probeHost() async {
    final baseUri = _buildBaseUri(_hostController.text);
    if (baseUri == null) {
      _resetFileSession();
      setState(() {
        _probeState = const ProbeState.error('请输入可访问的宿主地址，例如 http://192.168.1.10:5034。');
      });
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isProbing = true;
      _probeState = const ProbeState.loading();
      _fileError = null;
    });

    try {
      final status = await _fetchHostStatus(baseUri);

      String? token;
      FileBrowserDirectory? directory;
      String? fileError;

      try {
        token = await _loginToFileBrowser(baseUri);
        directory = await _fetchDirectory(baseUri, token, '/');
      } on NasApiException catch (error) {
        fileError = error.message;
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _baseUri = baseUri;
        _authToken = token;
        _currentDirectory = directory?.path ?? '/';
        _entries = directory?.items ?? const [];
        _fileError = fileError;
        _showMainShell = token != null && directory != null;
        _selectedTab = MainTab.home;
        _selectedSpace = SpaceScope.personal;
        _probeState = ProbeState.success(
          endpoint: baseUri.origin,
          hostName: status.hostName,
          detail: _buildProbeDetail(status, fileError: fileError),
        );
      });
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      _resetFileSession();
      setState(() {
        _showMainShell = false;
        _probeState = ProbeState.error(error.message);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isProbing = false;
        });
      }
    }
  }

  Future<void> _refreshFiles({String? path, bool showLoading = true}) async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      return;
    }

    if (showLoading) {
      setState(() {
        _isLoadingFiles = true;
        _fileError = null;
      });
    }

    try {
      final directory = await _fetchDirectory(baseUri, token, path ?? _currentDirectory);
      if (!mounted) {
        return;
      }

      setState(() {
        _currentDirectory = directory.path;
        _entries = directory.items;
        _fileError = null;
      });
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fileError = error.message;
      });
    } finally {
      if (mounted && showLoading) {
        setState(() {
          _isLoadingFiles = false;
        });
      }
    }
  }

  Future<void> _pickAndUploadFiles() async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null || _isUploading) {
      return;
    }

    final files = await openFiles();
    if (files.isEmpty) {
      return;
    }

    setState(() {
      _isUploading = true;
      _fileError = null;
    });

    try {
      for (final file in files) {
        await _uploadFile(baseUri, token, _currentDirectory, file);
      }

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已上传 ${files.length} 个文件。')),
      );
      await _refreshFiles(showLoading: false);
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fileError = error.message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  Future<void> _createFolder() async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null || _isCreatingFolder) {
      return;
    }

    final controller = TextEditingController();
    final folderName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '输入文件夹名称',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (!mounted) {
      return;
    }

    if (folderName == null || folderName.isEmpty) {
      return;
    }

    final validationError = _validateEntryName(folderName);
    if (validationError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(validationError)),
      );
      return;
    }

    setState(() {
      _isCreatingFolder = true;
      _fileError = null;
    });

    try {
      await _createDirectory(baseUri, token, _joinDirectoryPath(_currentDirectory, folderName));
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('文件夹“$folderName”已创建。')),
      );
      await _refreshFiles(showLoading: false);
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fileError = error.message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isCreatingFolder = false;
        });
      }
    }
  }

  Future<void> _handleEntryAction(FileBrowserEntry entry, EntryMenuAction action) async {
    if (_busyEntryPath != null) {
      return;
    }

    switch (action) {
      case EntryMenuAction.delete:
        await _deleteEntry(entry);
      case EntryMenuAction.move:
        await _moveEntry(entry);
      case EntryMenuAction.rename:
        await _renameEntry(entry);
      case EntryMenuAction.download:
        await _downloadEntry(entry);
    }
  }

  Future<void> _renameEntry(FileBrowserEntry entry) async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      return;
    }

    final controller = TextEditingController(text: entry.name);
    final nextName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '输入新的名称',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (!mounted || nextName == null) {
      return;
    }

    final validationError = _validateEntryName(nextName);
    if (validationError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(validationError)),
      );
      return;
    }

    final parentDirectory = _parentDirectoryPath(entry.path);
    final destinationPath = entry.isDir
        ? _joinDirectoryPath(parentDirectory, nextName)
        : _joinResourcePath(parentDirectory, nextName);
    if (destinationPath == entry.path) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名称未变化。')),
      );
      return;
    }

    setState(() {
      _busyEntryPath = entry.path;
      _fileError = null;
    });

    try {
      await _moveResource(baseUri, token, entry.path, destinationPath);
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${entry.name} 已重命名为 $nextName。')),
      );
      await _refreshFiles(showLoading: false);
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fileError = error.message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyEntryPath = null;
        });
      }
    }
  }

  Future<void> _moveEntry(FileBrowserEntry entry) async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      return;
    }

    final targetDirectory = await showDialog<String>(
      context: context,
      builder: (dialogContext) => RemoteDirectoryPickerDialog(
        initialDirectory: _parentDirectoryPath(entry.path),
        fetchDirectory: (path) => _fetchDirectory(baseUri, token, path),
      ),
    );

    if (!mounted || targetDirectory == null) {
      return;
    }

    final destinationPath = entry.isDir
        ? _joinDirectoryPath(targetDirectory, entry.name)
        : _joinResourcePath(targetDirectory, entry.name);
    if (destinationPath == entry.path) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('目标目录未变化。')),
      );
      return;
    }

    setState(() {
      _busyEntryPath = entry.path;
      _fileError = null;
    });

    try {
      await _moveResource(baseUri, token, entry.path, destinationPath);
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${entry.name} 已移动到 $targetDirectory。')),
      );
      await _refreshFiles(showLoading: false);
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fileError = error.message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyEntryPath = null;
        });
      }
    }
  }

  Future<void> _downloadEntry(FileBrowserEntry entry) async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      return;
    }

    final selectedDirectory = await getDirectoryPath();
    if (!mounted || selectedDirectory == null || selectedDirectory.isEmpty) {
      return;
    }

    setState(() {
      _busyEntryPath = entry.path;
      _fileError = null;
    });

    try {
      final downloadedFiles = await _downloadEntryToLocal(
        baseUri,
        token,
        entry,
        selectedDirectory,
      );
      if (!mounted) {
        return;
      }

      final message = entry.isDir
          ? '${entry.name} 已下载到本地，共 $downloadedFiles 个文件。'
          : '${entry.name} 已下载到本地。';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fileError = error.message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyEntryPath = null;
        });
      }
    }
  }

  Future<void> _deleteEntry(FileBrowserEntry entry) async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除确认'),
        content: Text('确定要删除 ${entry.name} 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() {
      _busyEntryPath = entry.path;
      _fileError = null;
    });

    try {
      await _deleteResource(baseUri, token, entry.path);
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${entry.name} 已删除。')),
      );
      await _refreshFiles(showLoading: false);
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fileError = error.message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyEntryPath = null;
        });
      }
    }
  }

  Future<void> _openEntry(FileBrowserEntry entry) async {
    if (entry.isDir) {
      await _refreshFiles(path: entry.path);
      return;
    }

    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      return;
    }

    if (entry.isPreviewableImage) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => ImagePreviewPage(
            title: entry.name,
            imageUri: _buildRawResourceUri(baseUri, entry.path),
            authToken: token,
          ),
        ),
      );
      return;
    }

    if (entry.isPreviewableAudio) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => AudioPreviewPage(
            title: entry.name,
            audioUri: _buildRawDownloadUri(baseUri, entry.path),
            authToken: token,
          ),
        ),
      );
      return;
    }

    if (entry.isPreviewableVideo) {
      await _openVideoExternally(entry);
      return;
    }

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('当前支持图片、音频和视频。视频会调用系统播放器打开。')),
    );
  }

  Future<void> _openVideoExternally(FileBrowserEntry entry) async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      return;
    }

    setState(() {
      _busyEntryPath = entry.path;
      _fileError = null;
    });

    try {
      final relayUri = await _createMediaRelayUri(baseUri, token, entry.path);
      final launched = await _systemOpenChannel.invokeMethod<bool>('openVideoUrl', {
        'url': relayUri.toString(),
      });
      if (!mounted) {
        return;
      }

      if (launched != true) {
        throw const NasApiException('系统没有可用的外部播放器来打开这个视频。');
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已交给系统播放器打开 ${entry.name}。')),
      );
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fileError = error.message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      final message = error.message?.trim();
      final detail = message == null || message.isEmpty ? '调用系统播放器失败。' : message;
      setState(() {
        _fileError = detail;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(detail)),
      );
    } on MissingPluginException {
      if (!mounted) {
        return;
      }

      const detail = '当前平台暂未接入外部视频打开能力。';
      setState(() {
        _fileError = detail;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(detail)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyEntryPath = null;
        });
      }
    }
  }

  Uri? _buildBaseUri(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final normalized = trimmed.contains('://') ? trimmed : 'http://$trimmed';
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }

    return Uri.parse(uri.origin);
  }

  Future<NasHostStatus> _fetchHostStatus(Uri baseUri) async {
    final response = await _sendTextRequest(
      baseUri.replace(path: '/api/system/status'),
      headers: const {HttpHeaders.acceptHeader: 'application/json'},
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NasApiException('宿主返回了 ${response.statusCode}。${_compactBody(response.body)}');
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Unexpected response');
      }

      return NasHostStatus.fromJson(decoded);
    } on FormatException {
      throw const NasApiException('宿主状态接口返回了非 JSON 内容。');
    }
  }

  Future<String> _loginToFileBrowser(Uri baseUri) async {
    final response = await _sendTextRequest(baseUri.replace(path: '/api/filebrowser/login'));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NasApiException('FileBrowser 登录失败：${response.statusCode}。${_compactBody(response.body)}');
    }

    final token = response.body.trim();
    if (token.isEmpty) {
      throw const NasApiException('FileBrowser 登录失败：token 为空。');
    }

    return token;
  }

  Future<FileBrowserDirectory> _fetchDirectory(Uri baseUri, String token, String resourcePath) async {
    final response = await _sendTextRequest(
      _buildResourceUri(baseUri, resourcePath),
      headers: {'X-Auth': token, HttpHeaders.acceptHeader: 'application/json'},
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NasApiException('读取文件列表失败：${response.statusCode}。${_compactBody(response.body)}');
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Unexpected response');
      }

      return FileBrowserDirectory.fromJson(decoded);
    } on FormatException {
      throw const NasApiException('文件列表接口返回了无法解析的内容。');
    }
  }

  Future<void> _uploadFile(Uri baseUri, String token, String directoryPath, XFile file) async {
    final targetPath = _joinResourcePath(directoryPath, file.name);
    final uri = _buildResourceUri(baseUri, targetPath, queryParameters: const {'override': 'true'});
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);

    try {
      final request = await client.postUrl(uri).timeout(const Duration(seconds: 15));
      request.headers.set('X-Auth', token);
      request.headers.contentType = ContentType.binary;
      request.contentLength = await file.length();
      await request.addStream(file.openRead()).timeout(const Duration(seconds: 30));

      final response = await request.close().timeout(const Duration(seconds: 30));
      final body = await utf8.decodeStream(response).timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NasApiException('上传 ${file.name} 失败：${response.statusCode}。${_compactBody(body)}');
      }
    } on TimeoutException {
      throw NasApiException('上传 ${file.name} 超时。');
    } on SocketException catch (error) {
      throw NasApiException('上传 ${file.name} 失败：${error.message}');
    } on HttpException catch (error) {
      throw NasApiException('上传 ${file.name} 失败：${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _createDirectory(Uri baseUri, String token, String directoryPath) async {
    final response = await _sendTextRequest(
      _buildResourceUri(baseUri, directoryPath),
      method: 'POST',
      headers: {'X-Auth': token},
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NasApiException('创建文件夹失败：${response.statusCode}。${_compactBody(response.body)}');
    }
  }

  Future<void> _deleteResource(Uri baseUri, String token, String resourcePath) async {
    final response = await _sendTextRequest(
      _buildResourceUri(baseUri, resourcePath),
      method: 'DELETE',
      headers: {'X-Auth': token},
    );

    if (response.statusCode != 204 && response.statusCode != 200) {
      throw NasApiException('删除失败：${response.statusCode}。${_compactBody(response.body)}');
    }
  }

  Future<void> _moveResource(
    Uri baseUri,
    String token,
    String sourcePath,
    String destinationPath,
  ) async {
    final response = await _sendTextRequest(
      _buildResourceUri(
        baseUri,
        sourcePath,
        queryParameters: {
          'action': 'rename',
          'destination': destinationPath,
        },
      ),
      method: 'PATCH',
      headers: {'X-Auth': token},
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    if (response.statusCode == 409) {
      throw const NasApiException('目标位置已存在同名文件或目录。');
    }

    throw NasApiException('移动或重命名失败：${response.statusCode}。${_compactBody(response.body)}');
  }

  Future<int> _downloadEntryToLocal(
    Uri baseUri,
    String token,
    FileBrowserEntry entry,
    String localParentDirectory,
  ) async {
    if (entry.isDir) {
      final localDirectoryPath = _joinLocalPath(localParentDirectory, entry.name);
      await Directory(localDirectoryPath).create(recursive: true);

      final directory = await _fetchDirectory(baseUri, token, entry.path);
      var downloadedFiles = 0;
      for (final child in directory.items) {
        downloadedFiles += await _downloadEntryToLocal(baseUri, token, child, localDirectoryPath);
      }

      return downloadedFiles;
    }

    final localFilePath = _joinLocalPath(localParentDirectory, entry.name);
    await _downloadRemoteFileToLocal(baseUri, token, entry.path, localFilePath);
    return 1;
  }

  Future<void> _downloadRemoteFileToLocal(
    Uri baseUri,
    String token,
    String resourcePath,
    String localFilePath,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);

    try {
      final request = await client.getUrl(_buildRawDownloadUri(baseUri, resourcePath)).timeout(
        const Duration(seconds: 15),
      );
      request.headers.set('X-Auth', token);

      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await utf8.decodeStream(response).timeout(const Duration(seconds: 30));
        throw NasApiException('下载失败：${response.statusCode}。${_compactBody(body)}');
      }

      final outputFile = File(localFilePath);
      await outputFile.parent.create(recursive: true);
      await response.pipe(outputFile.openWrite()).timeout(const Duration(seconds: 2 * 60));
    } on TimeoutException {
      throw const NasApiException('下载超时，请稍后重试。');
    } on SocketException catch (error) {
      throw NasApiException('下载失败：${error.message}');
    } on HttpException catch (error) {
      throw NasApiException('下载失败：${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<SimpleHttpResponse> _sendTextRequest(
    Uri uri, {
    String method = 'GET',
    Map<String, String>? headers,
    String? requestBody,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);

    try {
      late HttpClientRequest request;
      switch (method) {
        case 'DELETE':
          request = await client.deleteUrl(uri).timeout(const Duration(seconds: 8));
          break;
        case 'GET':
          request = await client.getUrl(uri).timeout(const Duration(seconds: 8));
          break;
        default:
          request = await client.openUrl(method, uri).timeout(const Duration(seconds: 8));
      }

      headers?.forEach(request.headers.set);
      if (requestBody != null) {
        final bytes = utf8.encode(requestBody);
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(const Duration(seconds: 8));
      final responseBody = await utf8.decodeStream(response).timeout(const Duration(seconds: 8));
      return SimpleHttpResponse(response.statusCode, responseBody);
    } on TimeoutException {
      throw const NasApiException('请求超时，请确认宿主仍然在线。');
    } on SocketException catch (error) {
      throw NasApiException('无法连接宿主：${error.message}');
    } on HttpException catch (error) {
      throw NasApiException('请求失败：${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Uri _buildResourceUri(Uri baseUri, String resourcePath, {Map<String, String>? queryParameters}) {
    final encodedPath = _encodeResourcePath(resourcePath);
    return baseUri.replace(
      path: '/api/filebrowser/resources$encodedPath',
      queryParameters: queryParameters,
    );
  }

  Uri _buildRawResourceUri(Uri baseUri, String resourcePath) {
    final encodedPath = _encodeResourcePath(resourcePath);
    return baseUri.replace(
      path: '/api/filebrowser/raw$encodedPath',
      queryParameters: const {'inline': 'true'},
    );
  }

  Uri _buildRawDownloadUri(Uri baseUri, String resourcePath) {
    final encodedPath = _encodeResourcePath(resourcePath);
    return baseUri.replace(path: '/api/filebrowser/raw$encodedPath');
  }

  Uri _buildThumbPreviewUri(Uri baseUri, String resourcePath) {
    final encodedPath = _encodeResourcePath(resourcePath);
    return baseUri.replace(path: '/api/filebrowser/preview/thumb$encodedPath');
  }

  Future<Uri> _createMediaRelayUri(Uri baseUri, String token, String resourcePath) async {
    final response = await _sendTextRequest(
      baseUri.replace(path: '/api/system/media-tickets'),
      method: 'POST',
      headers: {
        'X-Auth': token,
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
      },
      requestBody: jsonEncode({'path': resourcePath}),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NasApiException('创建视频播放链接失败：${response.statusCode}。${_compactBody(response.body)}');
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Unexpected response');
      }

      final url = decoded['url']?.toString();
      if (url == null || url.isEmpty) {
        throw const FormatException('Missing url');
      }

      final relayUri = Uri.tryParse(url);
      if (relayUri == null) {
        throw const FormatException('Invalid url');
      }

      return relayUri.hasScheme ? relayUri : baseUri.resolveUri(relayUri);
    } on FormatException {
      throw const NasApiException('视频播放链接接口返回了无法解析的内容。');
    }
  }

  Widget _buildEntryLeading(FileBrowserEntry entry) {
    if (!entry.isPreviewableImage || _baseUri == null || _authToken == null) {
      return CircleAvatar(
        backgroundColor: entry.isDir
            ? const Color(0xFFD1FAE5)
            : entry.isPreviewableImage
                ? const Color(0xFFFFEDD5)
                : entry.isPreviewableAudio
                    ? const Color(0xFFEEE7FF)
            : entry.isPreviewableVideo
              ? const Color(0xFFE0E7FF)
                : const Color(0xFFE0F2FE),
        child: Icon(
          entry.isDir
              ? Icons.folder_outlined
              : entry.isPreviewableImage
                  ? Icons.image_outlined
                  : entry.isPreviewableAudio
                      ? Icons.music_note_outlined
              : entry.isPreviewableVideo
                ? Icons.movie_outlined
                  : Icons.description_outlined,
          color: entry.isDir
              ? const Color(0xFF0F766E)
              : entry.isPreviewableImage
                  ? const Color(0xFFEA580C)
                  : entry.isPreviewableAudio
                      ? const Color(0xFF6D28D9)
              : entry.isPreviewableVideo
                ? const Color(0xFF3730A3)
                  : const Color(0xFF0369A1),
        ),
      );
    }

    return SizedBox(
      width: 44,
      height: 44,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          _buildThumbPreviewUri(_baseUri!, entry.path).toString(),
          headers: {'X-Auth': _authToken!},
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return Container(
              color: const Color(0xFFFFEDD5),
              alignment: Alignment.center,
              child: const Icon(Icons.image_outlined, color: Color(0xFFEA580C)),
            );
          },
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) {
              return child;
            }

            return Container(
              color: const Color(0xFFFFEDD5),
              alignment: Alignment.center,
              child: const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          },
        ),
      ),
    );
  }

  String _buildProbeDetail(NasHostStatus status, {String? fileError}) {
    final lines = <String>[
      '状态接口可达。',
      if (status.fileBrowserRunning != null)
        'FileBrowser: ${status.fileBrowserRunning! ? '运行中' : '未运行'}',
      if (status.fileBrowserBaseUrl != null && status.fileBrowserBaseUrl!.isNotEmpty)
        '内部地址: ${status.fileBrowserBaseUrl}',
      if (status.sharedRoot != null && status.sharedRoot!.isNotEmpty)
        '共享目录: ${status.sharedRoot}',
      if (fileError == null)
        '已连接 FileBrowser，可浏览、上传、下载和管理文件。'
      else
        '宿主在线，但文件接口连接失败：$fileError',
    ];

    return lines.join('\n');
  }

  void _resetFileSession() {
    _baseUri = null;
    _authToken = null;
    _currentDirectory = '/';
    _entries = const [];
    _fileError = null;
    _busyEntryPath = null;
    _showMainShell = false;
    _selectedTab = MainTab.home;
    _selectedSpace = SpaceScope.personal;
  }

  void _returnToConnectionPage() {
    setState(() {
      _showMainShell = false;
    });
  }

  void _changeSpaceScope(SpaceScope? nextScope) {
    if (nextScope == null || nextScope == _selectedSpace) {
      return;
    }

    setState(() {
      _selectedSpace = nextScope;
    });

    if (nextScope == SpaceScope.family) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('家庭空间还没接入，当前先保留占位。')),
      );
    }
  }

  bool _matchesCategory(FileBrowserEntry entry, FileCategoryFilter filter) {
    if (entry.isDir) {
      return false;
    }

    switch (filter) {
      case FileCategoryFilter.image:
        return entry.isPreviewableImage;
      case FileCategoryFilter.video:
        return entry.isPreviewableVideo;
      case FileCategoryFilter.audio:
        return entry.isPreviewableAudio;
      case FileCategoryFilter.document:
        return entry.isCommonDocument;
    }
  }

  Future<List<FileBrowserEntry>> _loadCategoryEntries(FileCategoryFilter filter) async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      throw const NasApiException('当前还没有有效的文件会话，请先重新连接宿主。');
    }

    final collectedEntries = <FileBrowserEntry>[];
    final visitedDirectories = <String>{};

    Future<void> visitDirectory(String path) async {
      final normalizedPath = _normalizeDirectoryPath(path);
      if (!visitedDirectories.add(normalizedPath)) {
        return;
      }

      final directory = await _fetchDirectory(baseUri, token, normalizedPath);
      for (final entry in directory.items) {
        if (entry.isDir) {
          await visitDirectory(entry.path);
          continue;
        }

        if (_matchesCategory(entry, filter)) {
          collectedEntries.add(entry);
        }
      }
    }

    await visitDirectory('/');
    collectedEntries.sort((left, right) {
      final leftParent = _parentDirectoryPath(left.path).toLowerCase();
      final rightParent = _parentDirectoryPath(right.path).toLowerCase();
      final byParent = leftParent.compareTo(rightParent);
      if (byParent != 0) {
        return byParent;
      }

      return left.name.toLowerCase().compareTo(right.name.toLowerCase());
    });

    return collectedEntries;
  }

  String _buildEntrySubtitle(FileBrowserEntry entry) {
    if (entry.isDir) {
      return '目录';
    }

    if (entry.isPreviewableImage) {
      return '图片 · ${_formatFileSize(entry.size)}';
    }

    if (entry.isPreviewableAudio) {
      return '音频 · ${_formatFileSize(entry.size)}';
    }

    if (entry.isPreviewableVideo) {
      return '视频 · ${_formatFileSize(entry.size)}';
    }

    if (entry.isCommonDocument) {
      return '文档 · ${_formatFileSize(entry.size)}';
    }

    return '文件 · ${_formatFileSize(entry.size)}';
  }

  Future<void> _openCategoryPage(FileCategoryShortcut shortcut) async {
    if (_selectedSpace != SpaceScope.personal) {
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => CategoryEntriesPage(
          title: shortcut.label,
          scopeLabel: '个人空间 · 全部目录',
          emptyHint: '整个个人空间里还没有符合这个分类的文件。',
          loadEntries: () => _loadCategoryEntries(shortcut.filter),
          buildLeading: _buildEntryLeading,
          buildSubtitle: _buildEntrySubtitle,
          onOpenEntry: _openEntry,
          onHandleEntryAction: _handleEntryAction,
        ),
      ),
    );
  }

  Widget _buildSectionCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F0F172A),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildConnectionPage(ThemeData theme) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF134E4A), Color(0xFF0F766E)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(32),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '连接你的 loal_NAS 宿主',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(
                    '先连上宿主，再进入首页。连接成功后会自动跳转，并继续复用现在这套 FileBrowser 接口。',
                    style: TextStyle(
                      color: Color(0xFFD1FAE5),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _buildSectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('宿主地址', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _hostController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'http://192.168.1.10:5034 或 http://[IPv6]:5034',
                    ),
                    onSubmitted: (_) {
                      if (!_isProbing) {
                        _probeHost();
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isProbing ? null : _probeHost,
                      icon: _isProbing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering),
                      label: Text(_isProbing ? '连接中...' : '连接并加载文件'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '提示：IPv6 地址必须带中括号，例如 http://[fc00::55:ca]:5034。',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('探测结果', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Text(
                    _probeState.headline,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: _probeState.color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(_probeState.detail),
                  if (_probeState.endpoint != null) ...[
                    const SizedBox(height: 12),
                    Text('目标宿主: ${_probeState.endpoint}'),
                  ],
                  if (_probeState.hostName != null) ...[
                    const SizedBox(height: 8),
                    Text('宿主名称: ${_probeState.hostName}'),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFFFFF), Color(0xFFF5FBFA)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(30),
        boxShadow: const [
          BoxShadow(
            color: Color(0x120F172A),
            blurRadius: 28,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '我的 NAS',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<SpaceScope>(
                      value: _selectedSpace,
                      isDense: true,
                      items: const [
                        DropdownMenuItem(
                          value: SpaceScope.personal,
                          child: Text('个人空间'),
                        ),
                        DropdownMenuItem(
                          value: SpaceScope.family,
                          child: Text('家庭空间'),
                        ),
                      ],
                      onChanged: _changeSpaceScope,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _probeState.hostName ?? 'loal_NAS 宿主',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF475569),
                  ),
                ),
                if (_baseUri != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _baseUri!.origin,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF64748B),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(
            width: 52,
            height: 52,
            decoration: const BoxDecoration(
              color: Color(0xFFDCFCE7),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.cloud_done_outlined, color: Color(0xFF15803D)),
          ),
        ],
      ),
    );
  }

  Widget _buildCategorySection(ThemeData theme) {
    return _buildSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('常用分类', style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          Row(
            children: [
              for (var index = 0; index < _fileCategoryShortcuts.length; index++) ...[
                if (index > 0) const SizedBox(width: 10),
                Expanded(
                  child: _CategoryShortcutButton(
                    shortcut: _fileCategoryShortcuts[index],
                    onTap: () => _openCategoryPage(_fileCategoryShortcuts[index]),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDirectorySection(ThemeData theme) {
    return _buildSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('当前目录', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                      _currentDirectory,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF475569),
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _hasFileSession && !_isLoadingFiles ? () => _refreshFiles() : null,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _canGoUp && !_isLoadingFiles
                    ? () => _refreshFiles(path: _parentDirectoryPath(_currentDirectory))
                    : null,
                icon: const Icon(Icons.arrow_upward),
                label: const Text('上级目录'),
              ),
              FilledButton.icon(
                onPressed: _hasFileSession && !_isUploading ? _pickAndUploadFiles : null,
                icon: _isUploading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.upload_file),
                label: Text(_isUploading ? '上传中...' : '上传文件'),
              ),
              FilledButton.tonalIcon(
                onPressed: _hasFileSession && !_isCreatingFolder ? _createFolder : null,
                icon: _isCreatingFolder
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.create_new_folder_outlined),
                label: Text(_isCreatingFolder ? '创建中...' : '新建文件夹'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_isLoadingFiles) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
          ],
          if (_fileError != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFEE4E2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                _fileError!,
                style: const TextStyle(color: Color(0xFFB42318)),
              ),
            ),
          ] else if (_entries.isEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('当前目录为空。'),
            ),
          ] else ...[
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = _entries[index];
                final isBusy = _busyEntryPath == entry.path;

                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: _buildEntryLeading(entry),
                  title: Text(entry.name),
                  subtitle: Text(_buildEntrySubtitle(entry)),
                  onTap: () => _openEntry(entry),
                  trailing: isBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : PopupMenuButton<EntryMenuAction>(
                          tooltip: '更多操作',
                          onSelected: (action) => _handleEntryAction(entry, action),
                          itemBuilder: (context) => const [
                            PopupMenuItem<EntryMenuAction>(
                              value: EntryMenuAction.delete,
                              child: Text('删除'),
                            ),
                            PopupMenuItem<EntryMenuAction>(
                              value: EntryMenuAction.move,
                              child: Text('移动'),
                            ),
                            PopupMenuItem<EntryMenuAction>(
                              value: EntryMenuAction.rename,
                              child: Text('重命名'),
                            ),
                            PopupMenuItem<EntryMenuAction>(
                              value: EntryMenuAction.download,
                              child: Text('下载'),
                            ),
                          ],
                          icon: const Icon(Icons.more_horiz),
                        ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFamilyPlaceholder(ThemeData theme) {
    return _buildSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('家庭空间', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          const Text('入口先保留，但文件列表、成员和共享规则这一阶段还没接进来。'),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: () => _changeSpaceScope(SpaceScope.personal),
            child: const Text('返回个人空间'),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeTab(ThemeData theme) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          _buildHomeHeader(theme),
          const SizedBox(height: 16),
          if (_selectedSpace == SpaceScope.personal) ...[
            _buildCategorySection(theme),
            const SizedBox(height: 16),
            _buildDirectorySection(theme),
          ] else ...[
            _buildFamilyPlaceholder(theme),
          ],
        ],
      ),
    );
  }

  Widget _buildSimpleTab({
    required ThemeData theme,
    required String title,
    required String description,
    IconData icon = Icons.hourglass_bottom_outlined,
    List<Widget> extraChildren = const [],
  }) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          _buildSectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: const Color(0xFFE2E8F0),
                  child: Icon(icon, color: const Color(0xFF334155)),
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(description, style: theme.textTheme.bodyLarge),
                for (final child in extraChildren) ...[
                  const SizedBox(height: 16),
                  child,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolsTab(ThemeData theme) {
    return _buildSimpleTab(
      theme: theme,
      title: '工具',
      description: '这里先放当前阶段最常用的操作入口，后面再往这个页签继续扩。',
      icon: Icons.grid_view_rounded,
      extraChildren: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: _hasFileSession && !_isLoadingFiles ? () => _refreshFiles() : null,
              icon: const Icon(Icons.refresh),
              label: const Text('刷新文件'),
            ),
            FilledButton.icon(
              onPressed: _hasFileSession && !_isUploading ? _pickAndUploadFiles : null,
              icon: const Icon(Icons.upload_file),
              label: const Text('上传文件'),
            ),
            FilledButton.tonalIcon(
              onPressed: _hasFileSession && !_isCreatingFolder ? _createFolder : null,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('新建文件夹'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMineTab(ThemeData theme) {
    return _buildSimpleTab(
      theme: theme,
      title: '我的',
      description: '这里先保留当前连接信息和返回连接页入口，后面再接账户、空间和设置。',
      icon: Icons.person_outline,
      extraChildren: [
        Text('宿主名称: ${_probeState.hostName ?? '未连接'}'),
        Text('连接地址: ${_baseUri?.origin ?? '未连接'}'),
        FilledButton.tonalIcon(
          onPressed: _returnToConnectionPage,
          icon: const Icon(Icons.settings_ethernet),
          label: const Text('返回连接页'),
        ),
      ],
    );
  }

  Widget _buildMainShell(ThemeData theme) {
    Widget body;
    switch (_selectedTab) {
      case MainTab.home:
        body = _buildHomeTab(theme);
        break;
      case MainTab.recent:
        body = _buildSimpleTab(
          theme: theme,
          title: '最近',
          description: '最近访问和下载任务下一阶段再接。先把导航位置留出来，首页文件浏览优先完成。',
          icon: Icons.history,
        );
        break;
      case MainTab.tools:
        body = _buildToolsTab(theme);
        break;
      case MainTab.mine:
        body = _buildMineTab(theme);
        break;
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab.index,
        onDestinationSelected: (index) {
          setState(() {
            _selectedTab = MainTab.values[index];
          });
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '首页'),
          NavigationDestination(icon: Icon(Icons.access_time_outlined), selectedIcon: Icon(Icons.access_time_filled), label: '最近'),
          NavigationDestination(icon: Icon(Icons.grid_view_outlined), selectedIcon: Icon(Icons.grid_view_rounded), label: '工具'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: '我的'),
        ],
      ),
    );
  }

  String _compactBody(String body) {
    final singleLine = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (singleLine.isEmpty) {
      return '';
    }

    return singleLine.length <= 120 ? singleLine : '${singleLine.substring(0, 120)}...';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_showMainShell) {
      return _buildConnectionPage(theme);
    }

    return _buildMainShell(theme);
  }
}

class _CategoryShortcutButton extends StatelessWidget {
  const _CategoryShortcutButton({
    required this.shortcut,
    required this.onTap,
  });

  final FileCategoryShortcut shortcut;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: shortcut.backgroundColor,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(shortcut.icon, color: shortcut.foregroundColor),
              const SizedBox(height: 10),
              Text(
                shortcut.label,
                style: TextStyle(
                  color: shortcut.foregroundColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CategoryEntriesPage extends StatefulWidget {
  const CategoryEntriesPage({
    required this.title,
    required this.scopeLabel,
    required this.emptyHint,
    required this.loadEntries,
    required this.buildLeading,
    required this.buildSubtitle,
    required this.onOpenEntry,
    required this.onHandleEntryAction,
    super.key,
  });

  final String title;
  final String scopeLabel;
  final String emptyHint;
  final Future<List<FileBrowserEntry>> Function() loadEntries;
  final Widget Function(FileBrowserEntry entry) buildLeading;
  final String Function(FileBrowserEntry entry) buildSubtitle;
  final Future<void> Function(FileBrowserEntry entry) onOpenEntry;
  final Future<void> Function(FileBrowserEntry entry, EntryMenuAction action) onHandleEntryAction;

  @override
  State<CategoryEntriesPage> createState() => _CategoryEntriesPageState();
}

class _CategoryEntriesPageState extends State<CategoryEntriesPage> {
  List<FileBrowserEntry> _entries = const [];
  bool _isLoading = true;
  String? _error;
  String? _busyEntryPath;

  @override
  void initState() {
    super.initState();
    unawaited(_loadEntries());
  }

  Future<void> _loadEntries({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final entries = await widget.loadEntries();
      if (!mounted) {
        return;
      }

      setState(() {
        _entries = entries;
        _error = null;
      });
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = error.message;
      });
    } finally {
      if (mounted && showLoading) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _runEntryAction(FileBrowserEntry entry, EntryMenuAction action) async {
    setState(() {
      _busyEntryPath = entry.path;
    });

    try {
      await widget.onHandleEntryAction(entry, action);
      await _loadEntries(showLoading: false);
    } finally {
      if (mounted) {
        setState(() {
          _busyEntryPath = null;
        });
      }
    }
  }

  Future<void> _runOpenEntry(FileBrowserEntry entry) async {
    await widget.onOpenEntry(entry);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    '范围: ${widget.scopeLabel}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: const Color(0xFF475569)),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _isLoading ? null : _loadEntries,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_isLoading)
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('正在扫描整个空间，请稍候...'),
                  ],
                ),
              )
            else if (_error != null)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFFB42318)),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _loadEntries,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              )
            else if (_entries.isEmpty)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Text(widget.emptyHint),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    final isBusy = _busyEntryPath == entry.path;

                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: widget.buildLeading(entry),
                      title: Text(entry.name),
                      subtitle: Text('${widget.buildSubtitle(entry)}\n位置: ${_parentDirectoryPath(entry.path)}'),
                      onTap: () => _runOpenEntry(entry),
                      trailing: isBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : PopupMenuButton<EntryMenuAction>(
                              tooltip: '更多操作',
                              onSelected: (action) => _runEntryAction(entry, action),
                              itemBuilder: (context) => const [
                                PopupMenuItem<EntryMenuAction>(
                                  value: EntryMenuAction.delete,
                                  child: Text('删除'),
                                ),
                                PopupMenuItem<EntryMenuAction>(
                                  value: EntryMenuAction.move,
                                  child: Text('移动'),
                                ),
                                PopupMenuItem<EntryMenuAction>(
                                  value: EntryMenuAction.rename,
                                  child: Text('重命名'),
                                ),
                                PopupMenuItem<EntryMenuAction>(
                                  value: EntryMenuAction.download,
                                  child: Text('下载'),
                                ),
                              ],
                              icon: const Icon(Icons.more_horiz),
                            ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ProbeState {
  const ProbeState._({
    required this.headline,
    required this.detail,
    required this.color,
    this.endpoint,
    this.hostName,
  });

  const ProbeState.idle()
      : this._(
          headline: '尚未探测',
          detail: '输入宿主地址后点击“连接并加载文件”，先确认手机和 NAS 宿主之间的基础联通。',
          color: const Color(0xFF475569),
        );

  const ProbeState.loading()
      : this._(
          headline: '正在连接',
          detail: '正在请求 /api/system/status，并登录 FileBrowser ...',
          color: const Color(0xFF0F766E),
        );

  const ProbeState.error(String message)
      : this._(
          headline: '连接失败',
          detail: message,
          color: const Color(0xFFB42318),
        );

  const ProbeState.success({
    required String endpoint,
    required String hostName,
    required String detail,
  }) : this._(
          headline: '宿主在线',
          detail: detail,
          color: const Color(0xFF0F766E),
          endpoint: endpoint,
          hostName: hostName,
        );

  final String headline;
  final String detail;
  final Color color;
  final String? endpoint;
  final String? hostName;
}

class NasHostStatus {
  const NasHostStatus({
    required this.hostName,
    this.fileBrowserRunning,
    this.fileBrowserBaseUrl,
    this.sharedRoot,
  });

  factory NasHostStatus.fromJson(Map<String, dynamic> json) {
    final fileBrowser = json['fileBrowser'];
    final fileBrowserMap = fileBrowser is Map<String, dynamic>
        ? fileBrowser
        : fileBrowser is Map
            ? Map<String, dynamic>.from(fileBrowser)
            : const <String, dynamic>{};
    final running = fileBrowserMap['running'];

    return NasHostStatus(
      hostName: json['name']?.toString() ?? 'loal_NAS 宿主',
      fileBrowserRunning: running is bool ? running : null,
      fileBrowserBaseUrl: fileBrowserMap['baseUrl']?.toString(),
      sharedRoot: fileBrowserMap['sharedRoot']?.toString(),
    );
  }

  final String hostName;
  final bool? fileBrowserRunning;
  final String? fileBrowserBaseUrl;
  final String? sharedRoot;
}

class FileBrowserDirectory {
  const FileBrowserDirectory({required this.path, required this.items});

  factory FileBrowserDirectory.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = rawItems is List
        ? rawItems
            .whereType<Map>()
            .map((item) => FileBrowserEntry.fromJson(Map<String, dynamic>.from(item)))
            .toList()
        : <FileBrowserEntry>[];

    items.sort((left, right) {
      if (left.isDir != right.isDir) {
        return left.isDir ? -1 : 1;
      }

      return left.name.toLowerCase().compareTo(right.name.toLowerCase());
    });

    return FileBrowserDirectory(
      path: _normalizeDirectoryPath(json['path']?.toString() ?? '/'),
      items: items,
    );
  }

  final String path;
  final List<FileBrowserEntry> items;
}

class FileBrowserEntry {
  const FileBrowserEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
  });

  factory FileBrowserEntry.fromJson(Map<String, dynamic> json) {
    final isDir = json['isDir'] == true;
    final rawSize = json['size'];
    final size = rawSize is num ? rawSize.toInt() : 0;

    return FileBrowserEntry(
      name: json['name']?.toString() ?? '(unnamed)',
      path: _normalizeResourcePath(json['path']?.toString() ?? '', isDirectory: isDir),
      isDir: isDir,
      size: size,
    );
  }

  final String name;
  final String path;
  final bool isDir;
  final int size;

  bool get isPreviewableImage => !isDir && isPreviewableImagePath(name);
  bool get isPreviewableAudio => !isDir && isPreviewableAudioPath(name);
  bool get isPreviewableVideo => !isDir && isPreviewableVideoPath(name);
  bool get isCommonDocument => !isDir && isCommonDocumentPath(name);
}

class ImagePreviewPage extends StatelessWidget {
  const ImagePreviewPage({
    required this.title,
    required this.imageUri,
    required this.authToken,
    super.key,
  });

  final String title;
  final Uri imageUri;
  final String authToken;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      backgroundColor: Colors.black,
      body: Center(
        child: InteractiveViewer(
          minScale: 0.8,
          maxScale: 5,
          child: Image.network(
            imageUri.toString(),
            headers: {'X-Auth': authToken},
            fit: BoxFit.contain,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) {
                return child;
              }

              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    '正在加载图片...',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white),
                  ),
                ],
              );
            },
            errorBuilder: (context, error, stackTrace) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.broken_image_outlined, size: 64, color: Colors.white70),
                    const SizedBox(height: 16),
                    Text(
                      '图片预览失败，请稍后重试。',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class AudioPreviewPage extends StatefulWidget {
  const AudioPreviewPage({
    required this.title,
    required this.audioUri,
    required this.authToken,
    super.key,
  });

  final String title;
  final Uri audioUri;
  final String authToken;

  @override
  State<AudioPreviewPage> createState() => _AudioPreviewPageState();
}

class _AudioPreviewPageState extends State<AudioPreviewPage> {
  final AudioPlayer _player = AudioPlayer();

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;

  Directory? _tempAudioDirectory;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double? _dragValueMs;
  bool _isPreparing = true;
  bool _isPlaying = false;
  String? _error;

  @override
  void initState() {
    super.initState();

    _positionSubscription = _player.positionStream.listen((position) {
      if (!mounted || _dragValueMs != null) {
        return;
      }

      setState(() {
        _position = position;
      });
    });

    _durationSubscription = _player.durationStream.listen((duration) {
      if (!mounted || duration == null) {
        return;
      }

      setState(() {
        _duration = duration;
      });
    });

    _playerStateSubscription = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        unawaited(_player.pause());
        unawaited(_player.seek(Duration.zero));
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _isPlaying = state.playing;
      });
    });

    unawaited(_initializeAudio());
  }

  Future<void> _initializeAudio() async {
    try {
      final duration = Platform.isWindows
          ? await _loadWindowsAudioFromTempFile()
          : await _player.setUrl(
              widget.audioUri.toString(),
              headers: {'X-Auth': widget.authToken},
            );
      if (!mounted) {
        return;
      }

      setState(() {
        _duration = duration ?? Duration.zero;
        _isPreparing = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isPreparing = false;
        _error = _describeAudioError(error, fallback: '音频加载失败，请稍后重试。');
      });
    }
  }

  Future<Duration?> _loadWindowsAudioFromTempFile() async {
    final tempDirectory = await Directory.systemTemp.createTemp('nas_phone_audio_');
    final localFilePath = _joinLocalPath(tempDirectory.path, _safeLocalFileName(widget.title));
    final localFile = File(localFilePath);

    await _downloadAudioToLocalFile(localFile);

    final previousTempDirectory = _tempAudioDirectory;
    _tempAudioDirectory = tempDirectory;
    if (previousTempDirectory != null) {
      unawaited(_deleteDirectoryQuietly(previousTempDirectory));
    }

    return _player.setFilePath(localFile.path);
  }

  Future<void> _downloadAudioToLocalFile(File localFile) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);

    try {
      final request = await client.getUrl(widget.audioUri).timeout(const Duration(seconds: 15));
      request.headers.set('X-Auth', widget.authToken);

      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await utf8.decodeStream(response).timeout(const Duration(seconds: 30));
        throw NasApiException('音频下载失败：${response.statusCode}。${_compactAudioErrorBody(body)}');
      }

      await localFile.parent.create(recursive: true);
      await response.pipe(localFile.openWrite()).timeout(const Duration(seconds: 2 * 60));
    } on TimeoutException {
      throw const NasApiException('音频下载超时，请稍后重试。');
    } on SocketException catch (error) {
      throw NasApiException('音频下载失败：${error.message}');
    } on HttpException catch (error) {
      throw NasApiException('音频下载失败：${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _togglePlayback() async {
    if (_isPreparing || _error != null) {
      return;
    }

    try {
      if (_isPlaying) {
        await _player.pause();
        return;
      }

      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }

      await _player.play();
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = '音频播放失败，请稍后重试。';
      });
    }
  }

  Future<void> _seekTo(double value) async {
    final target = Duration(milliseconds: value.round());
    try {
      await _player.seek(target);
      if (!mounted) {
        return;
      }

      setState(() {
        _position = target;
        _dragValueMs = null;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _dragValueMs = null;
        _error = '跳转进度失败，请稍后重试。';
      });
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playerStateSubscription?.cancel();
    final tempAudioDirectory = _tempAudioDirectory;
    if (tempAudioDirectory != null) {
      unawaited(_deleteDirectoryQuietly(tempAudioDirectory));
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalMs = _duration.inMilliseconds.toDouble();
    final hasKnownDuration = totalMs > 0;
    final sliderMax = hasKnownDuration ? totalMs : 1.0;
    final displayedPositionMs = _dragValueMs ?? _position.inMilliseconds.toDouble();
    final sliderValue = hasKnownDuration ? displayedPositionMs.clamp(0.0, sliderMax) : 0.0;
    final canSeek = !_isPreparing && _error == null && hasKnownDuration;
    final effectivePosition = Duration(milliseconds: displayedPositionMs.round());

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const CircleAvatar(
                        radius: 36,
                        backgroundColor: Color(0xFFEEE7FF),
                        child: Icon(
                          Icons.music_note_outlined,
                          size: 36,
                          color: Color(0xFF6D28D9),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        widget.title,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _error ?? (_isPlaying ? '正在播放' : (_isPreparing ? '正在加载音频...' : '已暂停')),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _error == null ? const Color(0xFF475569) : const Color(0xFFB42318),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Slider(
                        min: 0,
                        max: sliderMax,
                        value: sliderValue,
                        onChanged: canSeek
                            ? (value) {
                                setState(() {
                                  _dragValueMs = value;
                                });
                              }
                            : null,
                        onChangeEnd: canSeek ? _seekTo : null,
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_formatMediaDuration(effectivePosition)),
                          Text(hasKnownDuration ? _formatMediaDuration(_duration) : '--:--'),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Center(
                        child: IconButton.filledTonal(
                          onPressed: _error == null && !_isPreparing ? _togglePlayback : null,
                          iconSize: 34,
                          icon: Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RemoteDirectoryPickerDialog extends StatefulWidget {
  const RemoteDirectoryPickerDialog({
    required this.initialDirectory,
    required this.fetchDirectory,
    super.key,
  });

  final String initialDirectory;
  final Future<FileBrowserDirectory> Function(String path) fetchDirectory;

  @override
  State<RemoteDirectoryPickerDialog> createState() => _RemoteDirectoryPickerDialogState();
}

class _RemoteDirectoryPickerDialogState extends State<RemoteDirectoryPickerDialog> {
  late String _currentDirectory;
  List<FileBrowserEntry> _directories = const [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _currentDirectory = _normalizeDirectoryPath(widget.initialDirectory);
    unawaited(_loadDirectory(_currentDirectory));
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final directory = await widget.fetchDirectory(path);
      if (!mounted) {
        return;
      }

      setState(() {
        _currentDirectory = directory.path;
        _directories = directory.items.where((item) => item.isDir).toList();
      });
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = error.message;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择目标目录'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前目录: $_currentDirectory'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _isLoading || _currentDirectory == '/'
                      ? null
                      : () => _loadDirectory(_parentDirectoryPath(_currentDirectory)),
                  icon: const Icon(Icons.arrow_upward),
                  label: const Text('上级目录'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _isLoading ? null : () => _loadDirectory(_currentDirectory),
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 280,
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Color(0xFFB42318)),
                              ),
                              const SizedBox(height: 12),
                              FilledButton.tonal(
                                onPressed: () => _loadDirectory(_currentDirectory),
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        )
                      : _directories.isEmpty
                          ? const Center(child: Text('这个目录下没有子目录。'))
                          : ListView.separated(
                              itemCount: _directories.length,
                              separatorBuilder: (_, _) => const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final directory = _directories[index];
                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const CircleAvatar(
                                    backgroundColor: Color(0xFFD1FAE5),
                                    child: Icon(
                                      Icons.folder_outlined,
                                      color: Color(0xFF0F766E),
                                    ),
                                  ),
                                  title: Text(directory.name),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => _loadDirectory(directory.path),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(_currentDirectory),
          child: const Text('移动到当前目录'),
        ),
      ],
    );
  }
}

class SimpleHttpResponse {
  const SimpleHttpResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

class NasApiException implements Exception {
  const NasApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

bool isPreviewableImagePath(String path) {
  final normalized = path.toLowerCase();
  return normalized.endsWith('.jpg') ||
      normalized.endsWith('.jpeg') ||
      normalized.endsWith('.png') ||
      normalized.endsWith('.gif') ||
      normalized.endsWith('.webp') ||
      normalized.endsWith('.bmp') ||
      normalized.endsWith('.heic') ||
      normalized.endsWith('.heif');
}

    bool isPreviewableAudioPath(String path) {
      final normalized = path.toLowerCase();
      return normalized.endsWith('.mp3') ||
      normalized.endsWith('.m4a') ||
      normalized.endsWith('.aac') ||
      normalized.endsWith('.wav') ||
      normalized.endsWith('.flac') ||
      normalized.endsWith('.ogg') ||
      normalized.endsWith('.oga') ||
      normalized.endsWith('.opus');
    }

    bool isPreviewableVideoPath(String path) {
      final normalized = path.toLowerCase();
      return normalized.endsWith('.mp4') ||
      normalized.endsWith('.m4v') ||
      normalized.endsWith('.mov') ||
      normalized.endsWith('.mkv') ||
      normalized.endsWith('.webm') ||
      normalized.endsWith('.avi') ||
      normalized.endsWith('.wmv') ||
      normalized.endsWith('.flv') ||
      normalized.endsWith('.mpeg') ||
      normalized.endsWith('.mpg') ||
      normalized.endsWith('.3gp') ||
      normalized.endsWith('.3g2') ||
      normalized.endsWith('.ts') ||
      normalized.endsWith('.m2ts');
    }

bool isCommonDocumentPath(String path) {
  final normalized = path.toLowerCase();
  return normalized.endsWith('.pdf') ||
      normalized.endsWith('.doc') ||
      normalized.endsWith('.docx') ||
      normalized.endsWith('.xls') ||
      normalized.endsWith('.xlsx') ||
      normalized.endsWith('.ppt') ||
      normalized.endsWith('.pptx') ||
      normalized.endsWith('.txt') ||
      normalized.endsWith('.md') ||
      normalized.endsWith('.csv') ||
      normalized.endsWith('.rtf') ||
      normalized.endsWith('.odt') ||
      normalized.endsWith('.ods') ||
      normalized.endsWith('.odp');
}

String _safeLocalFileName(String value) {
  final sanitized = value.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
  return sanitized.isEmpty ? 'audio.tmp' : sanitized;
}

String _normalizeDirectoryPath(String rawPath) {
  if (rawPath.isEmpty || rawPath == '/') {
    return '/';
  }

  var normalized = rawPath.startsWith('/') ? rawPath : '/$rawPath';
  if (!normalized.endsWith('/')) {
    normalized = '$normalized/';
  }

  return normalized;
}

String _normalizeResourcePath(String rawPath, {required bool isDirectory}) {
  if (rawPath.isEmpty || rawPath == '/') {
    return '/';
  }

  var normalized = rawPath.startsWith('/') ? rawPath : '/$rawPath';
  if (isDirectory && !normalized.endsWith('/')) {
    normalized = '$normalized/';
  }
  if (!isDirectory && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }

  return normalized;
}

String _encodeResourcePath(String resourcePath) {
  final normalized = resourcePath.isEmpty ? '/' : resourcePath;
  if (normalized == '/') {
    return '/';
  }

  final hasTrailingSlash = normalized.endsWith('/');
  final segments = normalized
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .map(Uri.encodeComponent)
      .join('/');

  return '/$segments${hasTrailingSlash ? '/' : ''}';
}

String? _validateEntryName(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '名称不能为空。';
  }
  if (trimmed == '.' || trimmed == '..') {
    return '名称不能为 . 或 ..';
  }
  if (trimmed.contains('/') || trimmed.contains('\\')) {
    return '名称不能包含 / 或 \\';
  }

  return null;
}

String _parentDirectoryPath(String currentDirectory) {
  if (currentDirectory == '/') {
    return '/';
  }

  final trimmed = currentDirectory.endsWith('/')
      ? currentDirectory.substring(0, currentDirectory.length - 1)
      : currentDirectory;
  final lastSlashIndex = trimmed.lastIndexOf('/');
  if (lastSlashIndex <= 0) {
    return '/';
  }

  return '${trimmed.substring(0, lastSlashIndex)}/';
}

String _joinResourcePath(String directoryPath, String fileName) {
  final safeDirectory = directoryPath == '/' ? '/' : _normalizeDirectoryPath(directoryPath);
  return safeDirectory == '/' ? '/$fileName' : '$safeDirectory$fileName';
}

String _joinDirectoryPath(String directoryPath, String folderName) {
  return '${_joinResourcePath(directoryPath, folderName)}/';
}

String _joinLocalPath(String directoryPath, String name) {
  if (directoryPath.endsWith(Platform.pathSeparator)) {
    return '$directoryPath$name';
  }

  return '$directoryPath${Platform.pathSeparator}$name';
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }

  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = -1;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }

  final precision = value >= 10 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unitIndex]}';
}

String _formatMediaDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;

  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

String _compactAudioErrorBody(String body) {
  final singleLine = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (singleLine.isEmpty) {
    return '';
  }

  return singleLine.length <= 120 ? singleLine : '${singleLine.substring(0, 120)}...';
}

String _describeAudioError(Object error, {required String fallback}) {
  if (error is PlayerException) {
    final message = (error.message ?? '').trim();
    if (message.isEmpty) {
      return '$fallback (${error.code})';
    }

    return '$fallback ${error.code}: $message';
  }

  if (error is NasApiException) {
    return error.message;
  }

  return fallback;
}

Future<void> _deleteDirectoryQuietly(Directory directory) async {
  try {
    await directory.delete(recursive: true);
  } catch (_) {
    // Ignore temp cleanup failures.
  }
}
