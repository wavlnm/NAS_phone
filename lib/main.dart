import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const NasPhoneApp());
}

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

    final validationError = _validateFolderName(folderName);
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

    if (!entry.isPreviewableImage) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前先支持图片在线预览。')),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ImagePreviewPage(
          title: entry.name,
          imageUri: _buildRawResourceUri(baseUri, entry.path),
          authToken: token,
        ),
      ),
    );
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

  Future<SimpleHttpResponse> _sendTextRequest(
    Uri uri, {
    String method = 'GET',
    Map<String, String>? headers,
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
      final response = await request.close().timeout(const Duration(seconds: 8));
      final body = await utf8.decodeStream(response).timeout(const Duration(seconds: 8));
      return SimpleHttpResponse(response.statusCode, body);
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

  Uri _buildThumbPreviewUri(Uri baseUri, String resourcePath) {
    final encodedPath = _encodeResourcePath(resourcePath);
    return baseUri.replace(path: '/api/filebrowser/preview/thumb$encodedPath');
  }

  Widget _buildEntryLeading(FileBrowserEntry entry) {
    if (!entry.isPreviewableImage || _baseUri == null || _authToken == null) {
      return CircleAvatar(
        backgroundColor: entry.isDir
            ? const Color(0xFFD1FAE5)
            : entry.isPreviewableImage
                ? const Color(0xFFFFEDD5)
                : const Color(0xFFE0F2FE),
        child: Icon(
          entry.isDir
              ? Icons.folder_outlined
              : entry.isPreviewableImage
                  ? Icons.image_outlined
                  : Icons.description_outlined,
          color: entry.isDir
              ? const Color(0xFF0F766E)
              : entry.isPreviewableImage
                  ? const Color(0xFFEA580C)
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
        '已连接 FileBrowser，可浏览、上传、删除文件。'
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

    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        title: const Text('NAS Phone'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF134E4A), Color(0xFF0F766E)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '连接你的 loal_NAS 宿主',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(
                    '连接成功后直接复用 FileBrowser 原生接口，展示文件列表，并支持上传和删除。',
                    style: TextStyle(
                      color: Color(0xFFD1FAE5),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
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
                    const Text('提示：IPv6 地址必须带中括号，例如 http://[fc00::55:ca]:5034。'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
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
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('文件列表', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    Text('当前目录: $_currentDirectory'),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: _hasFileSession && !_isLoadingFiles ? () => _refreshFiles() : null,
                          icon: const Icon(Icons.refresh),
                          label: const Text('刷新'),
                        ),
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
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _fileError!,
                          style: const TextStyle(color: Color(0xFFB42318)),
                        ),
                      ),
                    ] else if (!_hasFileSession) ...[
                      const Text('先连接宿主后加载文件列表。'),
                    ] else if (_entries.isEmpty) ...[
                      const Text('当前目录为空。'),
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
                            subtitle: Text(
                              entry.isDir
                                  ? '目录'
                                  : entry.isPreviewableImage
                                      ? '图片 · ${_formatFileSize(entry.size)}'
                                      : _formatFileSize(entry.size),
                            ),
                            onTap: () => _openEntry(entry),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (entry.isDir || entry.isPreviewableImage)
                                  Icon(
                                    entry.isDir ? Icons.chevron_right : Icons.open_in_new,
                                  ),
                                if (isBusy)
                                  const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                else
                                  IconButton(
                                    onPressed: () => _deleteEntry(entry),
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: '删除',
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
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

String? _validateFolderName(String folderName) {
  final trimmed = folderName.trim();
  if (trimmed.isEmpty) {
    return '文件夹名称不能为空。';
  }
  if (trimmed == '.' || trimmed == '..') {
    return '文件夹名称不能为 . 或 ..';
  }
  if (trimmed.contains('/') || trimmed.contains('\\')) {
    return '文件夹名称不能包含 / 或 \\';
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
