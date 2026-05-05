import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const NasPhoneApp());
}

enum EntryMenuAction { delete, move, rename, download }

enum MainTab { home, recent, tools, mine }

enum SpaceScope { personal, family }

enum FileCategoryFilter { image, video, audio, document }

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

class RecentFileVisit {
  const RecentFileVisit({required this.entry, required this.visitedAt});

  final FileBrowserEntry entry;
  final DateTime visitedAt;
}

enum TransferTaskKind { download, upload }

class ActiveTransferTask {
  const ActiveTransferTask({
    required this.id,
    required this.kind,
    required this.entry,
    required this.startedAt,
    required this.targetLocation,
    this.processedFiles = 0,
  });

  final String id;
  final TransferTaskKind kind;
  final FileBrowserEntry entry;
  final DateTime startedAt;
  final String targetLocation;
  final int processedFiles;

  ActiveTransferTask copyWith({int? processedFiles}) {
    return ActiveTransferTask(
      id: id,
      kind: kind,
      entry: entry,
      startedAt: startedAt,
      targetLocation: targetLocation,
      processedFiles: processedFiles ?? this.processedFiles,
    );
  }
}

class LocalNote {
  const LocalNote({
    required this.id,
    required this.title,
    required this.content,
    required this.updatedAt,
  });

  factory LocalNote.fromJson(Map<String, dynamic> json) {
    final parsedUpdatedAt = DateTime.tryParse(
      json['updatedAt']?.toString() ?? '',
    );
    return LocalNote(
      id:
          json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      title: json['title']?.toString() ?? '未命名笔记',
      content: json['content']?.toString() ?? '',
      updatedAt: parsedUpdatedAt ?? DateTime.now(),
    );
  }

  final String id;
  final String title;
  final String content;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  String get preview {
    final normalized = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) {
      return '空白笔记';
    }

    return normalized.length <= 56
        ? normalized
        : '${normalized.substring(0, 56)}...';
  }
}

String _deriveLocalNoteTitle(String rawTitle, String rawContent) {
  if (rawTitle.isNotEmpty) {
    return rawTitle;
  }

  final normalized = rawContent.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) {
    return '未命名笔记';
  }

  return normalized.length <= 18 ? normalized : normalized.substring(0, 18);
}

const String _notesDirectoryPath = '/.note/';
const String _notesFilePath = '/.note/notes.json';

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
  final TextEditingController _hostController = TextEditingController();

  CloudSession? _cloudSession;
  ProbeState _probeState = const ProbeState.idle();
  bool _isProbing = false;
  bool _isLoadingFiles = false;
  bool _isUploading = false;
  bool _isCreatingFolder = false;

  NasHostStatus? _hostStatus;
  Uri? _baseUri;
  String? _authToken;
  String? _deviceSecret;
  String _currentDirectory = '/';
  List<FileBrowserEntry> _entries = const [];
  String? _fileError;
  String? _busyEntryPath;
  List<RecentFileVisit> _recentFileVisits = const [];
  List<ActiveTransferTask> _activeTransferTasks = const [];
  List<LocalNote> _notes = const [];
  bool _showMainShell = false;
  MainTab _selectedTab = MainTab.home;
  SpaceScope _selectedSpace = SpaceScope.personal;

  bool get _hasFileSession => _baseUri != null && _authToken != null;
  bool get _canGoUp => _hasFileSession && _currentDirectory != '/';

  @override
  void initState() {
    super.initState();
    unawaited(_loadDeviceSecret());
    // 异步恢复上次的登录/连接状态
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreAndAutoConnect());
  }

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  /// 启动时恢复持久化状态并尝试自动连接。
  /// 策略：
  ///   1. 有有效 session → 走 _onCloudLoginSuccess（从云端取最新地址自动连接）
  ///   2. 无 session 但有保存的 host → 直接 _probeHost
  ///   3. 两者都没有 → 不做任何操作，显示连接页
  Future<void> _restoreAndAutoConnect() async {
    final session = await _loadSavedSession();
    if (!mounted) return;

    if (session != null) {
      // 有登录态：云端取最新地址自动连接（含重试逻辑）
      await _onCloudLoginSuccess(session);
      return;
    }

    final host = await _loadSavedHost();
    if (!mounted) return;

    if (host != null && host.isNotEmpty) {
      // 无登录态但有上次地址：直接尝试局域网连接
      _hostController.text = host;
      await _probeHost();
    }
  }

  Future<void> _probeHost() async {
    final baseUri = _buildBaseUri(_hostController.text);
    if (baseUri == null) {
      _resetFileSession();
      setState(() {
        _probeState = const ProbeState.error(
          '请输入设备地址，例如 192.168.1.10 或 mynas.example.com。',
        );
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
        _hostStatus = status;
        _baseUri = baseUri;
        _authToken = token;
        _currentDirectory = directory?.path ?? '/';
        _entries = directory?.items ?? const [];
        _fileError = fileError;
        _recentFileVisits = const [];
        _activeTransferTasks = const [];
        _showMainShell = token != null && directory != null;
        _selectedTab = MainTab.home;
        _selectedSpace = SpaceScope.personal;
        _probeState = ProbeState.success(
          endpoint: baseUri.origin,
          hostName: status.hostName,
          detail: _buildProbeDetail(status, fileError: fileError),
        );
      });

      // 连接成功时持久化本次地址，供下次启动直接重连
      if (token != null && directory != null) {
        await _saveLastHost(_hostController.text);
      }
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      _resetFileSession();
      setState(() {
        _hostStatus = null;
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

  Future<void> _showCloudLoginDialog() async {
    final usernameController = TextEditingController(
      text: _cloudSession?.user.username ?? '',
    );
    final passwordController = TextEditingController();
    var obscurePassword = true;
    var isSubmitting = false;
    String? inlineError;

    final result = await showDialog<CloudSession>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submitLogin() async {
              final username = usernameController.text.trim();
              final password = passwordController.text;

              if (username.isEmpty || password.isEmpty) {
                setDialogState(() {
                  inlineError = '请输入账号和密码。';
                });
                return;
              }

              setDialogState(() {
                isSubmitting = true;
                inlineError = null;
              });

              try {
                final session = await _loginToCloudAccount(username, password);
                if (!dialogContext.mounted) {
                  return;
                }

                Navigator.of(dialogContext).pop(session);
              } on NasApiException catch (error) {
                if (!dialogContext.mounted) {
                  return;
                }

                setDialogState(() {
                  inlineError = error.message;
                  isSubmitting = false;
                });
              }
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
              actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Text('登录云账号'),
                  SizedBox(height: 8),
                  Text(
                    '输入账号和密码进行登录。没有账号时，请使用下方扫码注册卡片。',
                    style: TextStyle(
                      fontSize: 13,
                      color: Color(0xFF64748B),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: usernameController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '账号 / 邮箱 / 手机号',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person_outline_rounded),
                    ),
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) =>
                        FocusScope.of(dialogContext).nextFocus(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    decoration: InputDecoration(
                      labelText: '密码',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      suffixIcon: IconButton(
                        onPressed: () {
                          setDialogState(() {
                            obscurePassword = !obscurePassword;
                          });
                        },
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (!isSubmitting) {
                        submitLogin();
                      }
                    },
                  ),
                  if (inlineError != null) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        inlineError!,
                        style: const TextStyle(
                          color: Color(0xFFB42318),
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isSubmitting
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: isSubmitting ? null : submitLogin,
                  child: isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('登录'),
                ),
              ],
            );
          },
        );
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      usernameController.dispose();
      passwordController.dispose();
    });

    if (!mounted || result == null) {
      return;
    }

    await _onCloudLoginSuccess(result);
  }

  // ── 登录后自动连接 ─────────────────────────────────────────────────────────

  /// 云账号登录成功后的统一处理：保存 session，并尝试从云端获取 IPv6 地址自动连接设备。
  /// 若首次 ipv6Address 为空，每隔 1 秒轮询 /users/me，最多重试 2 次（共 3 次检查）。
  Future<void> _onCloudLoginSuccess(CloudSession session) async {
    if (!mounted) return;
    setState(() => _cloudSession = session);
    await _saveSession(session); // 持久化登录态

    // 最多检查 3 次（首次 + 2 次重试）
    String? ipv6 = session.user.ipv6Address;
    for (var attempt = 1; attempt <= 2 && (ipv6 == null || ipv6.isEmpty); attempt++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      try {
        final user = await _fetchCloudUserInfo(session.accessToken);
        ipv6 = user.ipv6Address;
      } catch (_) {
        // 网络失败则直接跳出，稍后提示
        break;
      }
    }

    if (!mounted) return;

    if (ipv6 != null && ipv6.isNotEmpty) {
      // 填入地址栏并自动发起探测连接
      _hostController.text = ipv6;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已登录 ${session.user.username}，正在自动连接设备…'),
          duration: const Duration(seconds: 3),
        ),
      );
      await _probeHost();
    } else {
      // 3 次均未获取到地址
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已登录 ${session.user.username}，但未能获取到电脑端地址。\n'
            '请确认电脑端网络已就绪，或在局域网内手动输入地址连接。',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  /// 使用 Bearer Token 查询自己的最新用户信息（主要用于获取 ipv6Address）。
  Future<CloudUser> _fetchCloudUserInfo(String accessToken) async {
    final response = await _sendCloudTextRequest(
      Uri.parse('https://reportzs.me/nas-api/users/me'),
      headers: {
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.authorizationHeader: 'Bearer $accessToken',
      },
    );
    late final Map<String, dynamic> decoded;
    try {
      decoded = _decodeJsonObject(response.body, invalidMessage: '用户信息接口返回了无法解析的内容。');
    } on NasApiException {
      throw NasApiException('获取用户信息失败：${response.statusCode}。');
    }
    if (decoded['success'] != true) {
      final err = decoded['error']?.toString();
      throw NasApiException(err?.isNotEmpty == true ? err! : '获取用户信息失败。');
    }
    final userRaw = decoded['user'];
    if (userRaw is! Map) throw const NasApiException('用户信息字段缺失。');
    return CloudUser.fromJson(Map<String, dynamic>.from(userRaw));
  }

  // ── 状态持久化 ─────────────────────────────────────────────────────────────

  static const _kSessionKey = 'cloud_session_v1';
  static const _kLastHostKey = 'last_connected_host';

  /// 将 CloudSession 序列化后存入 SharedPreferences。
  Future<void> _saveSession(CloudSession session) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSessionKey, jsonEncode(session.toJson()));
    } catch (_) {}
  }

  /// 清除持久化的 session（退出登录时调用）。
  Future<void> _clearSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kSessionKey);
    } catch (_) {}
  }

  /// 保存最近一次成功连接的设备地址。
  Future<void> _saveLastHost(String host) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastHostKey, host);
    } catch (_) {}
  }

  /// 从本地加载已保存的 CloudSession；若过期或不存在则返回 null。
  Future<CloudSession?> _loadSavedSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kSessionKey);
      if (raw == null || raw.isEmpty) return null;
      final json = _decodeJsonObject(raw, invalidMessage: '');
      final session = CloudSession.fromJson(json);
      if (session.accessToken.isEmpty) return null;
      // 已过期则丢弃（提前 30 分钟视为过期）
      final expires = session.expiresAt;
      if (expires != null &&
          expires.isBefore(DateTime.now().add(const Duration(minutes: 30)))) {
        await _clearSession();
        return null;
      }
      return session;
    } catch (_) {
      return null;
    }
  }

  /// 从本地加载上次连接的设备地址。
  Future<String?> _loadSavedHost() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kLastHostKey);
    } catch (_) {
      return null;
    }
  }

  // ── NAS 访问鉴权 ──────────────────────────────────────────────────────────

  static const _kDeviceSecretKey = 'bound_device_secret';
  static const _kAlphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final Random _random = Random.secure();

  /// 手机端 secret 混淆存储规则（与 PC 端不同）：
  ///   交换 index 1 与 index 5，在 index 15 与 16 之间插入 '3'（存储 65 字符）。
  static String _encodeDeviceSecret(String secret) {
    final chars = secret.split('');
    final tmp = chars[1];
    chars[1] = chars[5];
    chars[5] = tmp;
    chars.insert(15, '3');
    return chars.join();
  }

  static String _decodeDeviceSecret(String encoded) {
    final chars = encoded.split('')..removeAt(15);
    final tmp = chars[1];
    chars[1] = chars[5];
    chars[5] = tmp;
    return chars.join();
  }

  /// 读取本地 secret，若不存在、损坏或解码失败则返回 null。
  Future<String?> _loadDeviceSecret() async {
    final cachedSecret = _deviceSecret;
    if (cachedSecret != null) {
      return cachedSecret;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_kDeviceSecretKey);
      if (stored == null || stored.length != 65) {
        return null;
      }
      final secret = _decodeDeviceSecret(stored);
      _deviceSecret = secret;
      return secret;
    } catch (_) {
      return null;
    }
  }

  /// 生成 8 位随机 nonce（字母+数字）。
  String _generateNonce() {
    return List.generate(8, (_) => _kAlphabet[_random.nextInt(_kAlphabet.length)]).join();
  }

  /// 计算鉴权哈希：SHA-256(secret:timestamp_seconds:nonce)，返回小写 hex。
  static String _computeNasHash(String secret, int timestampSeconds, String nonce) {
    final input = '$secret:$timestampSeconds:$nonce';
    final bytes = utf8.encode(input);
    return crypto.sha256.convert(bytes).toString();
  }

  /// 构建 NAS 请求鉴权头（需要 await 因为要读 SharedPreferences）。
  /// 若本地无 secret 则返回空 Map（此时请求会被 PC 端拒绝，是预期行为）。
  Future<Map<String, String>> _buildNasAuthHeaders() async {
    final secret = await _loadDeviceSecret();
    if (secret == null) {
      return const {};
    }
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nonce = _generateNonce();
    final hash = _computeNasHash(secret, ts, nonce);
    return {
      'X-NAS-Nonce': nonce,
      'X-NAS-Hash': hash,
    };
  }

  // ── 扫码注册流程 ──────────────────────────────────────────────────────────

  /// 打开二维码扫描页。扫到合法设备 QR 后保存 secret，进入注册对话框。
  Future<void> _openQrScanner() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>?>(
      MaterialPageRoute<Map<String, dynamic>?>(
        builder: (_) => const _QrScanPage(),
      ),
    );
    if (!mounted || result == null) return;

    final deviceId = result['deviceId']?.toString();
    final deviceName = result['deviceName']?.toString();
    final secret = result['secret']?.toString();

    if (deviceId == null || deviceName == null || secret == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('二维码内容不是有效的设备信息，请重新扫描。')),
      );
      return;
    }

    // 持久化保存 secret 和 deviceId，供后续安全通信使用（混淆存储）
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceSecretKey, _encodeDeviceSecret(secret));
    await prefs.setString('bound_device_id', deviceId);
    _deviceSecret = secret;

    if (!mounted) return;
    await _showRegisterDialog(deviceId: deviceId, deviceName: deviceName);
  }

  /// 注册对话框：输入账号和密码，调用注册接口。
  Future<void> _showRegisterDialog({
    required String deviceId,
    required String deviceName,
  }) async {
    final usernameCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    var obscure = true;
    var submitting = false;
    String? inlineError;

    final registered = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submit() async {
              final username = usernameCtrl.text.trim();
              final password = passwordCtrl.text;
              if (username.isEmpty || password.isEmpty) {
                setDialogState(() => inlineError = '请输入账号和密码。');
                return;
              }
              setDialogState(() {
                submitting = true;
                inlineError = null;
              });
              try {
                await _registerToCloud(
                  username: username,
                  password: password,
                  deviceId: deviceId,
                );
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop(true);
              } on NasApiException catch (e) {
                if (!dialogContext.mounted) return;
                setDialogState(() {
                  inlineError = e.message;
                  submitting = false;
                });
              }
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28)),
              titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
              actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('注册云账号'),
                  const SizedBox(height: 8),
                  Text(
                    '绑定设备：$deviceName\n设备网络地址易变，注册云账号即可实时获取最新连接地址。',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF64748B),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: usernameCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '账号（用户名）',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person_outline_rounded),
                    ),
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) =>
                        FocusScope.of(dialogContext).nextFocus(),
                  ),
                  const SizedBox(height: 12),
                  StatefulBuilder(
                    builder: (_, setObscure) => TextField(
                      controller: passwordCtrl,
                      obscureText: obscure,
                      decoration: InputDecoration(
                        labelText: '密码',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        suffixIcon: IconButton(
                          onPressed: () =>
                              setObscure(() => obscure = !obscure),
                          icon: Icon(obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                        ),
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) {
                        if (!submitting) submit();
                      },
                    ),
                  ),
                  if (inlineError != null) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        inlineError!,
                        style: const TextStyle(
                            color: Color(0xFFB42318), height: 1.4),
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed:
                      submitting ? null : () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: submitting ? null : submit,
                  child: submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('注册'),
                ),
              ],
            );
          },
        );
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      usernameCtrl.dispose();
      passwordCtrl.dispose();
    });

    if (!mounted || registered != true) return;

    // 注册成功 → 用刚填写的账号密码自动登录
    final username = usernameCtrl.text.trim();
    final password = passwordCtrl.text;
    try {
      final session = await _loginToCloudAccount(username, password);
      if (!mounted) return;
      await _onCloudLoginSuccess(session);
    } catch (_) {
      // 自动登录失败时给一个提示，用户可手动登录
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('注册成功！自动登录失败，请在"我的"页面手动登录云账号。'),
          duration: Duration(seconds: 5),
        ),
      );
    }
  }

  /// 调用云服务注册接口。
  Future<void> _registerToCloud({
    required String username,
    required String password,
    required String deviceId,
  }) async {
    final response = await _sendCloudTextRequest(
      Uri.parse('https://reportzs.me/nas-api/register'),
      method: 'POST',
      headers: const {
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
      },
      requestBody: jsonEncode({
        'username': username,
        'password': password,
        'deviceId': deviceId,
      }),
    );

    late final Map<String, dynamic> decoded;
    try {
      decoded = _decodeJsonObject(
        response.body,
        invalidMessage: '注册接口返回了无法解析的内容。',
      );
    } on NasApiException {
      throw NasApiException(
        '注册失败：${response.statusCode}。${_compactBody(response.body)}',
      );
    }

    final success = decoded['success'] == true;
    if (!success || response.statusCode < 200 || response.statusCode >= 300) {
      final err = decoded['error']?.toString();
      if (err != null && err.isNotEmpty) throw NasApiException(err);
      throw NasApiException('注册失败：${response.statusCode}。');
    }
  }

  Future<CloudSession> _loginToCloudAccount(
    String username,
    String password,
  ) async {
    final response = await _sendCloudTextRequest(
      Uri.parse('https://reportzs.me/nas-api/login'),
      method: 'POST',
      headers: const {
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
      },
      requestBody: jsonEncode({'username': username, 'password': password}),
    );

    late final Map<String, dynamic> decoded;
    try {
      decoded = _decodeJsonObject(
        response.body,
        invalidMessage: '云登录接口返回了无法解析的内容。',
      );
    } on NasApiException {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        rethrow;
      }

      throw NasApiException(
        '云账号登录失败：${response.statusCode}。${_compactBody(response.body)}',
      );
    }

    final success = decoded['success'] == true;
    if (!success || response.statusCode < 200 || response.statusCode >= 300) {
      final error = decoded['error']?.toString();
      if (error != null && error.isNotEmpty) {
        throw NasApiException(error);
      }

      throw NasApiException('云账号登录失败：${response.statusCode}。');
    }

    final accessToken = decoded['accessToken']?.toString();
    if (accessToken == null || accessToken.isEmpty) {
      throw const NasApiException('云账号登录成功，但 accessToken 为空。');
    }

    final userRaw = decoded['user'];
    if (userRaw is! Map) {
      throw const NasApiException('云账号登录成功，但用户信息缺失。');
    }

    return CloudSession(
      accessToken: accessToken,
      expiresAt: DateTime.tryParse(decoded['expiresAt']?.toString() ?? ''),
      user: CloudUser.fromJson(Map<String, dynamic>.from(userRaw)),
    );
  }

  Future<SimpleHttpResponse> _sendCloudTextRequest(
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
          request = await client
              .deleteUrl(uri)
              .timeout(const Duration(seconds: 8));
          break;
        case 'GET':
          request = await client
              .getUrl(uri)
              .timeout(const Duration(seconds: 8));
          break;
        default:
          request = await client
              .openUrl(method, uri)
              .timeout(const Duration(seconds: 8));
      }

      headers?.forEach(request.headers.set);
      if (requestBody != null) {
        final bytes = utf8.encode(requestBody);
        request.contentLength = bytes.length;
        request.add(bytes);
      }

      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final responseBody = await utf8
          .decodeStream(response)
          .timeout(const Duration(seconds: 8));
      return SimpleHttpResponse(response.statusCode, responseBody);
    } on TimeoutException {
      throw const NasApiException('请求云服务超时，请稍后重试。');
    } on SocketException catch (error) {
      throw NasApiException('无法连接云服务：${error.message}');
    } on HttpException catch (error) {
      throw NasApiException('云服务请求失败：${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic> _decodeJsonObject(
    String body, {
    required String invalidMessage,
  }) {
    late final Object decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw NasApiException(invalidMessage);
    }

    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }

    throw NasApiException(invalidMessage);
  }

  void _showPendingFeatureMessage(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showConnectionHelp() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('连接说明'),
        content: const Text(
          '1. 云账号登录只用于账号体系。\n'
          '2. 扫码获取授权和注册云账号。\n'
          '3. 自动发现当前用于展示最近设备，后续会实现局域网自动扫描设备。\n'
          '4. 手动连接只需输入ipv4或ipv6地址。',
          style: TextStyle(height: 1.6),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
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
      final directory = await _fetchDirectory(
        baseUri,
        token,
        path ?? _currentDirectory,
      );
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

    FilePickerResult? pickerResult;
    try {
      pickerResult = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
        withReadStream: true,
      );
    } catch (error) {
      if (!mounted) return;
      const msg = '无法打开文件选择器，请检查应用权限。';
      setState(() {
        _fileError = msg;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(msg)));
      return;
    }

    if (pickerResult == null || pickerResult.files.isEmpty) {
      return;
    }

    setState(() {
      _isUploading = true;
      _fileError = null;
    });

    try {
      for (final file in pickerResult.files) {
        final uploadEntry = FileBrowserEntry(
          name: file.name,
          path: _joinResourcePath(_currentDirectory, file.name),
          isDir: false,
          size: 0,
        );
        final taskId = _startTransferTask(
          kind: TransferTaskKind.upload,
          entry: uploadEntry,
          targetLocation: _currentDirectory,
        );

        try {
          await _uploadFile(baseUri, token, _currentDirectory, file);
        } finally {
          _finishTransferTask(taskId);
        }
      }

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已上传 ${pickerResult.files.length} 个文件。')),
      );
      await _refreshFiles(showLoading: false);
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fileError = error.message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (!mounted) {
        return;
      }

      const fallbackMessage = '读取所选文件失败，请先重试；如果仍然闪退，请使用 adb 抓取崩溃日志。';
      setState(() {
        _fileError = fallbackMessage;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(fallbackMessage)));
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
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    // dialog 关闭动画仍在播放时 TextField 还持有 controller 引用，
    // 延迟到下一帧再 dispose，避免 _dependents.isEmpty 断言失败。
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());

    if (!mounted) {
      return;
    }

    if (folderName == null || folderName.isEmpty) {
      return;
    }

    final validationError = _validateEntryName(folderName);
    if (validationError != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(validationError)));
      return;
    }

    setState(() {
      _isCreatingFolder = true;
      _fileError = null;
    });

    try {
      await _createDirectory(
        baseUri,
        token,
        _joinDirectoryPath(_currentDirectory, folderName),
      );
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('文件夹“$folderName”已创建。')));
      await _refreshFiles(showLoading: false);
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fileError = error.message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) {
        setState(() {
          _isCreatingFolder = false;
        });
      }
    }
  }

  Future<void> _handleEntryAction(
    FileBrowserEntry entry,
    EntryMenuAction action,
  ) async {
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
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());

    if (!mounted || nextName == null) {
      return;
    }

    final validationError = _validateEntryName(nextName);
    if (validationError != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(validationError)));
      return;
    }

    final parentDirectory = _parentDirectoryPath(entry.path);
    final destinationPath = entry.isDir
        ? _joinDirectoryPath(parentDirectory, nextName)
        : _joinResourcePath(parentDirectory, nextName);
    if (destinationPath == entry.path) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('名称未变化。')));
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

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${entry.name} 已重命名为 $nextName。')));
      await _refreshFiles(showLoading: false);
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fileError = error.message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('目标目录未变化。')));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
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
    if (baseUri == null || token == null) return;
    await _downloadEntryViaMediaStore(entry, baseUri, token);
  }

  /// 默认路径：下载到临时目录，逐文件通过 MediaStore API 写入系统下载目录。
  /// 这样文件可以在文件管理器"下载"和"最近"中找到，适用于所有 Android 版本。
  Future<void> _downloadEntryViaMediaStore(
      FileBrowserEntry entry, Uri baseUri, String token) async {
    setState(() {
      _busyEntryPath = entry.path;
      _fileError = null;
    });
    final taskId = _startTransferTask(
      kind: TransferTaskKind.download,
      entry: entry,
      targetLocation: '下载/NAS_Downloads',
    );
    var count = 0;

    // 临时目录用于中转
    final tempDir = await getTemporaryDirectory();
    final tempBase =
        '${tempDir.path}/nas_dl_${DateTime.now().millisecondsSinceEpoch}';
    try {
      await _downloadEntryToLocal(
        baseUri,
        token,
        entry,
        tempBase,
        onFileDownloaded: () {
          count++;
          _updateTransferTaskProgress(taskId, count);
        },
      );

      // 将 tempBase 下所有文件复制到 MediaStore Downloads
      await _copyTempDirToMediaStore(
          Directory(tempBase), Directory(tempBase), 'NAS_Downloads');

      if (!mounted) return;
      final msg = entry.isDir
          ? '${entry.name} 已下载，共 $count 个文件。\n可在文件管理器"下载/NAS_Downloads"中找到。'
          : '${entry.name} 已下载。\n可在文件管理器"下载/NAS_Downloads"中找到。';
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 6)));
    } catch (e) {
      if (!mounted) return;
      final msg = e is NasApiException ? e.message : '下载失败：$e';
      setState(() => _fileError = msg);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      try {
        await Directory(tempBase).delete(recursive: true);
      } catch (_) {}
      if (mounted) setState(() => _busyEntryPath = null);
      _finishTransferTask(taskId);
    }
  }

  /// 递归遍历 [dir]，将每个文件通过 MediaStore 平台通道写入 Downloads。
  /// [root] 为临时根目录，用于计算相对路径以还原子目录结构。
  static Future<void> _copyTempDirToMediaStore(
      Directory dir, Directory root, String mediaStoreBase) async {
    await for (final entity in dir.list()) {
      if (entity is File) {
        // 计算相对于 root 的子目录路径，例如 "Photos" 或 ""
        final rel = entity.path.substring(root.path.length + 1);
        final segments = rel.split('/');
        final fileName = segments.last;
        final subFolder = segments.length > 1
            ? '$mediaStoreBase/${segments.sublist(0, segments.length - 1).join('/')}'
            : mediaStoreBase;
        final mimeType = _guessMimeType(fileName);
        await _NasMediaChannel.copyToMediaStoreDownloads(
          sourcePath: entity.path,
          fileName: fileName,
          mimeType: mimeType,
          subFolder: subFolder,
        );
      } else if (entity is Directory) {
        await _copyTempDirToMediaStore(entity, root, mediaStoreBase);
      }
    }
  }

  /// 根据文件扩展名猜测 MIME 类型（供 MediaStore 使用）。
  static String _guessMimeType(String fileName) {
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    const map = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
      'gif': 'image/gif',  'webp': 'image/webp', 'bmp': 'image/bmp',
      'mp4': 'video/mp4',  'mkv': 'video/x-matroska', 'mov': 'video/quicktime',
      'avi': 'video/x-msvideo', 'flv': 'video/x-flv', 'wmv': 'video/x-ms-wmv',
      'mp3': 'audio/mpeg', 'aac': 'audio/aac',   'flac': 'audio/flac',
      'ogg': 'audio/ogg',  'wav': 'audio/wav',   'm4a': 'audio/mp4',
      'pdf': 'application/pdf',
      'zip': 'application/zip', 'rar': 'application/x-rar-compressed',
      '7z':  'application/x-7z-compressed',
      'txt': 'text/plain', 'md': 'text/markdown',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    };
    return map[ext] ?? 'application/octet-stream';
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

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${entry.name} 已删除。')));
      await _refreshFiles(showLoading: false);
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fileError = error.message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
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

    _recordRecentFileVisit(entry);

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

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('当前支持图片、音频和视频。视频会在浏览器中打开播放。')));
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
      if (!mounted) {
        return;
      }

      final launched = await launchUrl(
        relayUri,
        mode: LaunchMode.externalApplication,
      );
      if (!mounted) {
        return;
      }

      if (!launched) {
        throw const NasApiException('无法打开浏览器，请检查设备是否安装了浏览器。');
      }
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fileError = error.message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      final msg = error.message?.trim();
      final detail = (msg == null || msg.isEmpty) ? '打开浏览器失败。' : msg;
      setState(() {
        _fileError = detail;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(detail)));
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

    final needsIpv6Brackets =
        !trimmed.contains('://') &&
        trimmed.contains(':') &&
        !trimmed.startsWith('[') &&
        !trimmed.endsWith(']');
    final normalizedHost = needsIpv6Brackets ? '[$trimmed]' : trimmed;
    final normalized = trimmed.contains('://')
        ? trimmed
        : 'http://$normalizedHost';
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }

    final fixedPortUri = uri.replace(
      scheme: uri.scheme.isEmpty ? 'http' : uri.scheme,
      port: 5034,
      path: '',
      query: null,
      fragment: null,
      userInfo: '',
    );

    return Uri.parse(fixedPortUri.origin);
  }

  Future<NasHostStatus> _fetchHostStatus(Uri baseUri) async {
    final response = await _sendTextRequest(
      baseUri.replace(path: '/api/system/status'),
      headers: const {HttpHeaders.acceptHeader: 'application/json'},
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NasApiException(
        '电脑返回了 ${response.statusCode}。${_compactBody(response.body)}',
      );
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Unexpected response');
      }

      return NasHostStatus.fromJson(decoded);
    } on FormatException {
      throw const NasApiException('电脑状态接口返回了非 JSON 内容。');
    }
  }

  Future<String> _loginToFileBrowser(Uri baseUri) async {
    final response = await _sendTextRequest(
      baseUri.replace(path: '/api/filebrowser/login'),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NasApiException(
        '文件服务登录失败：${response.statusCode}。${_compactBody(response.body)}',
      );
    }

    final token = response.body.trim();
    if (token.isEmpty) {
      throw const NasApiException('文件服务登录失败：登录信息为空。');
    }

    return token;
  }

  Future<FileBrowserDirectory> _fetchDirectory(
    Uri baseUri,
    String token,
    String resourcePath,
  ) async {
    final response = await _sendTextRequest(
      _buildResourceUri(baseUri, resourcePath),
      headers: {'X-Auth': token, HttpHeaders.acceptHeader: 'application/json'},
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NasApiException(
        '读取文件列表失败：${response.statusCode}。${_compactBody(response.body)}',
      );
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

  Future<void> _uploadFile(
    Uri baseUri,
    String token,
    String directoryPath,
    PlatformFile file,
  ) async {
    final targetPath = _joinResourcePath(directoryPath, file.name);
    final uri = _buildResourceUri(
      baseUri,
      targetPath,
      queryParameters: const {'override': 'true'},
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    final uploadTimeout = const Duration(minutes: 10);
    final responseTimeout = const Duration(minutes: 2);

    try {
      final request = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.bufferOutput = false;
      request.headers.set('X-Auth', token);
      // NAS 鉴权头
      final uploadAuthHeaders = await _buildNasAuthHeaders();
      uploadAuthHeaders.forEach(request.headers.set);
      request.headers.contentType = ContentType.binary;
      // file.size is metadata-only (no file read), safe for any file size
      if (file.size >= 0) {
        request.contentLength = file.size;
      }
      // readStream is a lazy stream backed by ContentResolver — no file copy, no OOM
      final readStream = file.readStream;
      if (readStream != null) {
        await request.addStream(readStream).timeout(uploadTimeout);
      } else if (file.path != null) {
        await request
            .addStream(File(file.path!).openRead())
            .timeout(uploadTimeout);
      } else {
        throw const NasApiException('无法读取文件内容，请重试。');
      }

      final response = await request.close().timeout(responseTimeout);
      final body = await utf8.decodeStream(response).timeout(responseTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NasApiException(
          '上传 ${file.name} 失败：${response.statusCode}。${_compactBody(body)}',
        );
      }
    } on TimeoutException {
      throw NasApiException('上传 ${file.name} 超时，请保持应用停留在前台后重试。');
    } on SocketException catch (error) {
      throw NasApiException('上传 ${file.name} 失败：${error.message}');
    } on HttpException catch (error) {
      throw NasApiException('上传 ${file.name} 失败：${error.message}');
    } catch (error) {
      throw NasApiException('上传 ${file.name} 失败：$error');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _uploadTextFile(
    Uri baseUri,
    String token,
    String resourcePath,
    String content, {
    String contentType = 'text/plain; charset=utf-8',
  }) async {
    final uri = _buildResourceUri(
      baseUri,
      resourcePath,
      queryParameters: const {'override': 'true'},
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);

    try {
      final request = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 15));
      final bytes = utf8.encode(content);
      request.headers.set('X-Auth', token);
      // NAS 鉴权头
      final textUploadAuthHeaders = await _buildNasAuthHeaders();
      textUploadAuthHeaders.forEach(request.headers.set);
      request.headers.set(HttpHeaders.contentTypeHeader, contentType);
      request.contentLength = bytes.length;
      request.add(bytes);

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await utf8
          .decodeStream(response)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NasApiException(
          '保存笔记失败：${response.statusCode}。${_compactBody(body)}',
        );
      }
    } on TimeoutException {
      throw const NasApiException('保存笔记超时。');
    } on SocketException catch (error) {
      throw NasApiException('保存笔记失败：${error.message}');
    } on HttpException catch (error) {
      throw NasApiException('保存笔记失败：${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _createDirectory(
    Uri baseUri,
    String token,
    String directoryPath,
  ) async {
    final response = await _sendTextRequest(
      _buildResourceUri(baseUri, directoryPath),
      method: 'POST',
      headers: {'X-Auth': token},
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NasApiException(
        '创建文件夹失败：${response.statusCode}。${_compactBody(response.body)}',
      );
    }
  }

  Future<void> _deleteResource(
    Uri baseUri,
    String token,
    String resourcePath,
  ) async {
    final response = await _sendTextRequest(
      _buildResourceUri(baseUri, resourcePath),
      method: 'DELETE',
      headers: {'X-Auth': token},
    );

    if (response.statusCode != 204 && response.statusCode != 200) {
      throw NasApiException(
        '删除失败：${response.statusCode}。${_compactBody(response.body)}',
      );
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
        queryParameters: {'action': 'rename', 'destination': destinationPath},
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

    throw NasApiException(
      '移动或重命名失败：${response.statusCode}。${_compactBody(response.body)}',
    );
  }

  Future<int> _downloadEntryToLocal(
    Uri baseUri,
    String token,
    FileBrowserEntry entry,
    String localParentDirectory, {
    void Function()? onFileDownloaded,
  }) async {
    if (entry.isDir) {
      final localDirectoryPath = _joinLocalPath(
        localParentDirectory,
        entry.name,
      );
      await Directory(localDirectoryPath).create(recursive: true);

      final directory = await _fetchDirectory(baseUri, token, entry.path);
      var downloadedFiles = 0;
      for (final child in directory.items) {
        downloadedFiles += await _downloadEntryToLocal(
          baseUri,
          token,
          child,
          localDirectoryPath,
          onFileDownloaded: onFileDownloaded,
        );
      }

      return downloadedFiles;
    }

    final localFilePath = _joinLocalPath(localParentDirectory, entry.name);
    await _downloadRemoteFileToLocal(baseUri, token, entry.path, localFilePath);
    onFileDownloaded?.call();
    return 1;
  }

  Future<void> _downloadRemoteFileToLocal(
    Uri baseUri,
    String token,
    String resourcePath,
    String localFilePath,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);

    try {
      final request = await client
          .getUrl(_buildRawDownloadUri(baseUri, resourcePath))
          .timeout(const Duration(seconds: 15));
      request.headers.set('X-Auth', token);
      // NAS 鉴权头
      final downloadAuthHeaders = await _buildNasAuthHeaders();
      downloadAuthHeaders.forEach(request.headers.set);

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await utf8
            .decodeStream(response)
            .timeout(const Duration(seconds: 30));
        throw NasApiException(
          '下载失败：${response.statusCode}。${_compactBody(body)}',
        );
      }

      final outputFile = File(localFilePath);
      await outputFile.parent.create(recursive: true);
      await response
          .pipe(outputFile.openWrite())
          .timeout(const Duration(seconds: 2 * 60));
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
    // 非云端请求自动注入 NAS 访问鉴权头（secret + 时间戳 + nonce）
    final isCloudApi = uri.host.contains('reportzs.me');
    Map<String, String> effectiveHeaders = headers ?? const {};
    if (!isCloudApi) {
      final authHeaders = await _buildNasAuthHeaders();
      if (authHeaders.isNotEmpty) {
        effectiveHeaders = {...effectiveHeaders, ...authHeaders};
      }
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);

    try {
      late HttpClientRequest request;
      switch (method) {
        case 'DELETE':
          request = await client
              .deleteUrl(uri)
              .timeout(const Duration(seconds: 8));
          break;
        case 'GET':
          request = await client
              .getUrl(uri)
              .timeout(const Duration(seconds: 8));
          break;
        default:
          request = await client
              .openUrl(method, uri)
              .timeout(const Duration(seconds: 8));
      }

      effectiveHeaders.forEach(request.headers.set);
      if (requestBody != null) {
        final bytes = utf8.encode(requestBody);
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final responseBody = await utf8
          .decodeStream(response)
          .timeout(const Duration(seconds: 8));
      return SimpleHttpResponse(response.statusCode, responseBody);
    } on TimeoutException {
      throw const NasApiException('请求超时，请确认电脑仍然在线。');
    } on SocketException catch (error) {
      throw NasApiException('无法连接电脑：${error.message}');
    } on HttpException catch (error) {
      throw NasApiException('请求失败：${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Uri _buildResourceUri(
    Uri baseUri,
    String resourcePath, {
    Map<String, String>? queryParameters,
  }) {
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

  Future<Uri> _createMediaRelayUri(
    Uri baseUri,
    String token,
    String resourcePath,
  ) async {
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
      throw NasApiException(
        '创建视频播放链接失败：${response.statusCode}。${_compactBody(response.body)}',
      );
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
      if (fileError == null)
        '已连接，可浏览、上传、下载和管理文件。'
      else
        '电脑在线，但文件访问连接失败：$fileError',
    ];

    return lines.join('\n');
  }

  String _formatConnectionAddress(String endpoint) {
    final uri = Uri.tryParse(endpoint);
    if (uri != null && uri.host.isNotEmpty) {
      return uri.host;
    }

    var value = endpoint.trim().replaceFirst(RegExp(r'^https?://'), '');
    final slashIndex = value.indexOf('/');
    if (slashIndex >= 0) {
      value = value.substring(0, slashIndex);
    }

    if (value.startsWith('[')) {
      final closingIndex = value.indexOf(']');
      if (closingIndex > 0) {
        return value.substring(1, closingIndex);
      }
    }

    if (':'.allMatches(value).length == 1) {
      return value.split(':').first;
    }

    return value;
  }

  void _resetFileSession() {
    _hostStatus = null;
    _baseUri = null;
    _authToken = null;
    _currentDirectory = '/';
    _entries = const [];
    _fileError = null;
    _busyEntryPath = null;
    _recentFileVisits = const [];
    _activeTransferTasks = const [];
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('家庭空间还没接入，当前先保留占位。')));
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

  Future<List<FileBrowserEntry>> _loadCategoryEntries(
    FileCategoryFilter filter,
  ) async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      throw const NasApiException('当前还没有有效的文件会话，请先重新连接电脑。');
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

  void _recordRecentFileVisit(FileBrowserEntry entry) {
    if (entry.isDir) {
      return;
    }

    final visit = RecentFileVisit(entry: entry, visitedAt: DateTime.now());
    setState(() {
      _recentFileVisits = [
        visit,
        ..._recentFileVisits.where((item) => item.entry.path != entry.path),
      ].take(20).toList(growable: false);
    });
  }

  String _startTransferTask({
    required TransferTaskKind kind,
    required FileBrowserEntry entry,
    required String targetLocation,
  }) {
    final taskId = '${DateTime.now().microsecondsSinceEpoch}:${entry.path}';
    final task = ActiveTransferTask(
      id: taskId,
      kind: kind,
      entry: entry,
      startedAt: DateTime.now(),
      targetLocation: targetLocation,
    );

    setState(() {
      _activeTransferTasks = [task, ..._activeTransferTasks];
    });

    return taskId;
  }

  void _updateTransferTaskProgress(String taskId, int processedFiles) {
    if (!mounted) {
      return;
    }

    setState(() {
      _activeTransferTasks = _activeTransferTasks
          .map(
            (task) => task.id == taskId
                ? task.copyWith(processedFiles: processedFiles)
                : task,
          )
          .toList(growable: false);
    });
  }

  void _finishTransferTask(String taskId) {
    if (!mounted) {
      return;
    }

    setState(() {
      _activeTransferTasks = _activeTransferTasks
          .where((task) => task.id != taskId)
          .toList(growable: false);
    });
  }

  void _updateNotes(List<LocalNote> notes) {
    setState(() {
      _notes = List<LocalNote>.from(notes);
    });
  }

  Future<void> _ensureNotesDirectoryExists() async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      throw const NasApiException('当前还没有有效的文件会话，请先重新连接电脑。');
    }

    final response = await _sendTextRequest(
      _buildResourceUri(baseUri, _notesDirectoryPath),
      headers: {'X-Auth': token, HttpHeaders.acceptHeader: 'application/json'},
    );
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    if (response.statusCode == 404) {
      await _createDirectory(baseUri, token, _notesDirectoryPath);
      return;
    }

    throw NasApiException(
      '读取笔记目录失败：${response.statusCode}。${_compactBody(response.body)}',
    );
  }

  Future<List<LocalNote>> _loadNotesFromCloud() async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      throw const NasApiException('当前还没有有效的文件会话，请先重新连接电脑。');
    }

    await _ensureNotesDirectoryExists();
    final response = await _sendTextRequest(
      _buildRawDownloadUri(baseUri, _notesFilePath),
      headers: {'X-Auth': token, HttpHeaders.acceptHeader: 'application/json'},
    );
    if (response.statusCode == 404) {
      return const [];
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NasApiException(
        '读取云端笔记失败：${response.statusCode}。${_compactBody(response.body)}',
      );
    }

    final trimmedBody = response.body.trim();
    if (trimmedBody.isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(trimmedBody);
      if (decoded is! List) {
        throw const FormatException('Unexpected note payload');
      }

      return decoded
          .whereType<Map>()
          .map((item) => LocalNote.fromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false)
        ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    } on FormatException {
      throw const NasApiException('云端笔记文件内容无法解析，请检查 /.note/notes.json。');
    }
  }

  Future<void> _saveNotesToCloud(List<LocalNote> notes) async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      throw const NasApiException('当前还没有有效的文件会话，请先重新连接电脑。');
    }

    await _ensureNotesDirectoryExists();
    final requestBody = jsonEncode(
      notes.map((note) => note.toJson()).toList(growable: false),
    );
    await _uploadTextFile(
      baseUri,
      token,
      _notesFilePath,
      requestBody,
      contentType: 'application/json; charset=utf-8',
    );
  }

  Future<void> _openNotesToolPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => NotesToolPage(
          initialNotes: _notes,
          loadNotes: _loadNotesFromCloud,
          saveNotes: _saveNotesToCloud,
          onNotesChanged: _updateNotes,
        ),
      ),
    );
  }

  Future<void> _openChatToolPage() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (context) => const ChatToolPage()));
  }

  Future<void> _openRecycleBinToolPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => const RecycleBinToolPage()),
    );
  }

  Future<void> _openBookkeepingToolPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => const BookkeepingToolPage()),
    );
  }

  Future<void> _openScheduledDownloadToolPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => const ScheduledDownloadToolPage(),
      ),
    );
  }

  Future<void> _openRemoteDesktopToolPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => const RemoteDesktopToolPage(),
      ),
    );
  }

  Future<void> _openCameraCenterToolPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => const CameraCenterToolPage(),
      ),
    );
  }

  Widget _buildSectionCard({
    BuildContext? contextOverride,
    EdgeInsetsGeometry? paddingOverride,
    required Widget child,
  }) {
    final metrics = _ConnectionPageMetrics.of(contextOverride ?? context);
    return Container(
      padding: paddingOverride ?? EdgeInsets.all(metrics.cardPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(metrics.cardRadius),
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

  Widget _buildAccentIconBox(
    BuildContext context, {
    required IconData icon,
    required Color backgroundColor,
    required Color foregroundColor,
  }) {
    final metrics = _ConnectionPageMetrics.of(context);
    return Container(
      width: metrics.iconBoxSize,
      height: metrics.iconBoxSize,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(metrics.iconBoxRadius),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: foregroundColor, size: metrics.iconSize),
    );
  }

  String _buildCloudSummary() {
    final session = _cloudSession;
    if (session == null) {
      return '查看并连接你的设备';
    }

    final expiresAt = session.expiresAt?.toLocal();
    if (expiresAt == null) {
      return '已登录 ${session.user.username}';
    }

    final month = expiresAt.month.toString().padLeft(2, '0');
    final day = expiresAt.day.toString().padLeft(2, '0');
    final hour = expiresAt.hour.toString().padLeft(2, '0');
    final minute = expiresAt.minute.toString().padLeft(2, '0');
    return '已登录 ${session.user.username} · 有效至 $month-$day $hour:$minute';
  }

  Widget _buildCloudAccountCard(BuildContext context, ThemeData theme) {
    final metrics = _ConnectionPageMetrics.of(context);
    final session = _cloudSession;
    final actionLabel = session == null ? '登录 / 注册' : '切换账号';

    return _buildSectionCard(
      contextOverride: context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildAccentIconBox(
                context,
                icon: Icons.lock_rounded,
                backgroundColor: const Color(0xFF3B82F6),
                foregroundColor: Colors.white,
              ),
              SizedBox(width: metrics.inlineSpacing),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '登录云账号',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      _buildCloudSummary(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF64748B),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              SizedBox(width: metrics.inlineSpacing * 0.5),
              FilledButton(
                onPressed: _showCloudLoginDialog,
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.symmetric(
                    horizontal: metrics.inlineSpacing,
                    vertical: metrics.badgeVerticalPadding + 2,
                  ),
                  backgroundColor: const Color(0xFF2563EB),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                child: Text(
                  actionLabel,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          SizedBox(height: metrics.sectionSpacing),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.shield_outlined,
                    size: 14, color: const Color(0xFF3B82F6)),
                const SizedBox(width: 4),
                Text('点对点传输',
                    style: TextStyle(
                        color: const Color(0xFF64748B), fontSize: 13)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('|',
                      style: TextStyle(
                          color: const Color(0xFFCBD5E1), fontSize: 13)),
                ),
                Icon(Icons.sync_rounded,
                    size: 14, color: const Color(0xFF3B82F6)),
                const SizedBox(width: 4),
                Text('实时同步地址',
                    style: TextStyle(
                        color: const Color(0xFF64748B), fontSize: 13)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('|',
                      style: TextStyle(
                          color: const Color(0xFFCBD5E1), fontSize: 13)),
                ),
                Icon(Icons.devices_outlined,
                    size: 14, color: const Color(0xFF3B82F6)),
                const SizedBox(width: 4),
                Text('远程访问',
                    style: TextStyle(
                        color: const Color(0xFF64748B), fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceScanIllustration(
    BuildContext context, {
    double? maxWidth,
    double scale = 1,
  }) {
    final metrics = _ConnectionPageMetrics.of(context);
    final availableWidth = maxWidth ?? metrics.screenWidth;
    final layoutWidth = metrics.illustrationWidthFor(availableWidth) * scale;
    final layoutHeight = metrics.illustrationHeightFor(availableWidth) * scale;
    final monitorHeight = layoutHeight * 0.68;
    final phoneWidth = layoutWidth * 0.31;
    final phoneHeight = layoutHeight * 0.8;
    final qrBoxSize = monitorHeight * 0.5;
    return SizedBox(
      width: layoutWidth,
      height: layoutHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: layoutWidth * 0.07,
            right: layoutWidth * 0.19,
            top: layoutHeight * 0.15,
            child: Container(
              height: monitorHeight,
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(layoutWidth * 0.1),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x140F172A),
                    blurRadius: 18,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Center(
                child: Container(
                  width: qrBoxSize,
                  height: qrBoxSize,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(layoutWidth * 0.06),
                  ),
                  child: Icon(
                    Icons.qr_code_2_rounded,
                    color: Color(0xFF111827),
                    size: qrBoxSize * 0.6,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: layoutWidth * 0.24,
            right: layoutWidth * 0.36,
            bottom: layoutHeight * 0.04,
            child: Container(
              height: layoutHeight * 0.08,
              decoration: BoxDecoration(
                color: const Color(0xFFD6DAE1),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: phoneWidth,
              height: phoneHeight,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1E293B), Color(0xFF334155)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(layoutWidth * 0.11),
                border: Border.all(color: const Color(0xFF475569)),
              ),
              child: Center(
                child: Icon(
                  Icons.qr_code_scanner_rounded,
                  color: Color(0xFF60A5FA),
                  size: phoneWidth * 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanRegisterCard(BuildContext context, ThemeData theme) {
    final metrics = _ConnectionPageMetrics.of(context);
    return _buildSectionCard(
      contextOverride: context,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '扫码获取授权和注册',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '扫描电脑端二维码获取鉴权凭证',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF64748B),
                    height: 1.5,
                  ),
                ),
                SizedBox(height: metrics.sectionSpacing),
                OutlinedButton.icon(
                  onPressed: () => _openQrScanner(),
                  icon: const Icon(Icons.crop_free_rounded, size: 17),
                  label: const Text('扫一扫'),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(
                      horizontal: metrics.inlineSpacing,
                      vertical: metrics.badgeVerticalPadding + 2,
                    ),
                    side: const BorderSide(color: Color(0xFFCBD5E1)),
                    foregroundColor: const Color(0xFF334155),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: metrics.inlineSpacing),
          _buildDeviceScanIllustration(
            context,
            maxWidth: metrics.screenWidth * 0.36,
            scale: 0.88,
          ),
        ],
      ),
    );
  }

  Widget _buildDiscoveryHostTile(BuildContext context, ThemeData theme) {
    final metrics = _ConnectionPageMetrics.of(context);
    final hostStatus = _hostStatus;
    final baseUri = _baseUri;
    if (hostStatus == null || baseUri == null) {
      return Container(
        width: double.infinity,
        padding: EdgeInsets.all(metrics.cardPadding * 0.85),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(metrics.inputRadius),
        ),
        child: Row(
          children: [
            _buildAccentIconBox(
              context,
              icon: Icons.radar_rounded,
              backgroundColor: const Color(0xFFEFF6FF),
              foregroundColor: const Color(0xFF2563EB),
            ),
            SizedBox(width: metrics.inlineSpacing),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '正在准备自动发现',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '当前先保留界面，后续会接入同一局域网扫描。你也可以先使用下方手动输入地址。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF64748B),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final host = _formatConnectionAddress(baseUri.origin);

    return Material(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(metrics.inputRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(metrics.inputRadius),
        onTap: _isProbing
            ? null
            : () {
                setState(() {
                  _hostController.text = host;
                });
                _probeHost();
              },
        child: Padding(
          padding: EdgeInsets.all(metrics.cardPadding * 0.85),
          child: Row(
            children: [
              _buildAccentIconBox(
                context,
                icon: Icons.desktop_windows_outlined,
                backgroundColor: const Color(0xFFEFF6FF),
                foregroundColor: const Color(0xFF2563EB),
              ),
              SizedBox(width: metrics.inlineSpacing),
              Expanded(
                child: Text(
                  host,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              SizedBox(width: metrics.inlineSpacing * 0.85),
              const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '在线',
                    style: TextStyle(
                      color: Color(0xFF16A34A),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 4),
                  Icon(Icons.wifi_rounded, color: Color(0xFF22C55E), size: 18),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAutoDiscoveryCard(BuildContext context, ThemeData theme) {
    final metrics = _ConnectionPageMetrics.of(context);
    return _buildSectionCard(
      contextOverride: context,
      paddingOverride: EdgeInsets.fromLTRB(
        metrics.cardPadding,
        metrics.cardPadding * 0.62,
        metrics.cardPadding,
        metrics.cardPadding * 0.44,
      ),
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
                    Text(
                      '自动发现设备',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _hostStatus == null ? '正在搜索同一局域网内的设备...' : '最近一次成功连接的设备会显示在这里。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF64748B),
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: metrics.inlineSpacing * 0.6),
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: () =>
                    _showPendingFeatureMessage('自动发现功能还在接入，当前先使用手动输入地址。'),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('刷新'),
              ),
            ],
          ),
          SizedBox(height: metrics.sectionSpacing * 0.56),
          _buildDiscoveryHostTile(context, theme),
          SizedBox(height: metrics.inlineSpacing * 0.38),
          Align(
            alignment: Alignment.center,
            child: TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: () =>
                  _showPendingFeatureMessage('未发现设备时，请先使用手动输入地址连接。'),
              child: const Text('未发现设备？'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProbeStatePanel(BuildContext context, ThemeData theme) {
    final metrics = _ConnectionPageMetrics.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(metrics.cardPadding * 0.78),
      decoration: BoxDecoration(
        color: _probeState.backgroundColor,
        borderRadius: BorderRadius.circular(metrics.inputRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _probeState.icon,
                color: _probeState.color,
                size: (metrics.iconSize * 0.72).clamp(18.0, 22.0).toDouble(),
              ),
              SizedBox(width: metrics.inlineSpacing * 0.55),
              Text(
                _probeState.headline,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: _probeState.color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SizedBox(height: metrics.inlineSpacing * 0.55),
          Text(
            _probeState.detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF475569),
              height: 1.5,
            ),
          ),
          if (_probeState.endpoint != null) ...[
            SizedBox(height: metrics.inlineSpacing * 0.65),
            Text(
              '连接地址: ${_formatConnectionAddress(_probeState.endpoint!)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF0F172A),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildManualAddressCard(BuildContext context, ThemeData theme) {
    final metrics = _ConnectionPageMetrics.of(context);
    return _buildSectionCard(
      contextOverride: context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '手动输入地址',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '输入设备的 IP 地址或域名进行连接',
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF64748B),
              height: 1.5,
            ),
          ),
          SizedBox(height: metrics.sectionSpacing),
          TextField(
            controller: _hostController,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            decoration: InputDecoration(
              hintText: '例如：192.168.1.10 或 mynas.example.com',
              prefixIcon: const Icon(Icons.link_rounded),
              filled: true,
              fillColor: const Color(0xFFF8FAFC),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(metrics.inputRadius),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(metrics.inputRadius),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
            ),
            onSubmitted: (_) {
              if (!_isProbing) {
                _probeHost();
              }
            },
          ),
          SizedBox(height: metrics.sectionSpacing),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _isProbing ? null : _probeHost,
              style: FilledButton.styleFrom(
                padding: EdgeInsets.symmetric(
                  vertical: metrics.primaryButtonVerticalPadding,
                ),
                backgroundColor: const Color(0xFF93C5FD),
                foregroundColor: const Color(0xFF0F172A),
              ),
              child: _isProbing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('连接'),
            ),
          ),
          SizedBox(height: metrics.inlineSpacing * 0.6),
          InkWell(
            onTap: _showConnectionHelp,
            borderRadius: BorderRadius.circular(metrics.inputRadius),
            child: Padding(
              padding:
                  EdgeInsets.symmetric(vertical: metrics.badgeVerticalPadding),
              child: Row(
                children: [
                  const Icon(Icons.lightbulb_outline_rounded,
                      size: 17, color: Color(0xFF64748B)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '如何获取设备地址？',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF64748B),
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded,
                      size: 18, color: Color(0xFF94A3B8)),
                ],
              ),
            ),
          ),
          SizedBox(height: metrics.sectionSpacing),
          _buildProbeStatePanel(context, theme),
        ],
      ),
    );
  }

  Widget _buildConnectionPage(ThemeData theme) {
    final metrics = _ConnectionPageMetrics.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            metrics.horizontalPadding,
            metrics.horizontalPadding,
            metrics.horizontalPadding,
            metrics.listBottomPadding,
          ),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    '连接到你的设备',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontSize: metrics.titleFontSize,
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF0F172A),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _showConnectionHelp,
                  style: IconButton.styleFrom(
                    fixedSize: Size.square(metrics.helpButtonSize),
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF64748B),
                    shape: const CircleBorder(),
                  ),
                  icon: const Icon(Icons.help_outline_rounded),
                ),
              ],
            ),
            SizedBox(height: metrics.sectionSpacing),
            _buildCloudAccountCard(context, theme),
            SizedBox(height: metrics.sectionSpacing),
            _buildScanRegisterCard(context, theme),
            SizedBox(height: metrics.sectionSpacing),
            _buildAutoDiscoveryCard(context, theme),
            SizedBox(height: metrics.sectionSpacing),
            _buildManualAddressCard(context, theme),
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
            child: const Icon(
              Icons.cloud_done_outlined,
              color: Color(0xFF15803D),
            ),
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
              for (
                var index = 0;
                index < _fileCategoryShortcuts.length;
                index++
              ) ...[
                if (index > 0) const SizedBox(width: 10),
                Expanded(
                  child: _CategoryShortcutButton(
                    shortcut: _fileCategoryShortcuts[index],
                    onTap: () =>
                        _openCategoryPage(_fileCategoryShortcuts[index]),
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
    final canOpenQuickActions = _hasFileSession;
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF475569),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: IconButton(
                      onPressed: _hasFileSession && !_isLoadingFiles
                          ? () => _refreshFiles()
                          : null,
                      tooltip: '刷新',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildDirectoryQuickActionButton(canOpenQuickActions),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _canGoUp && !_isLoadingFiles
                        ? () => _refreshFiles(
                            path: _parentDirectoryPath(_currentDirectory),
                          )
                        : null,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.arrow_upward_rounded),
                    label: const Text('上级目录'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_isLoadingFiles) ...[
            const LinearProgressIndicator(minHeight: 3),
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
                          onSelected: (action) =>
                              _handleEntryAction(entry, action),
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

  Widget _buildDirectoryQuickActionButton(bool canOpenQuickActions) {
    return Container(
      decoration: BoxDecoration(
        color: canOpenQuickActions
            ? const Color(0xFFCFF4EA)
            : const Color(0xFFE2E8F0),
        borderRadius: BorderRadius.circular(14),
      ),
      child: SizedBox(
        width: 40,
        height: 40,
        child: PopupMenuButton<String>(
          enabled: canOpenQuickActions,
          tooltip: '更多操作',
          padding: EdgeInsets.zero,
          splashRadius: 20,
          iconColor: canOpenQuickActions
              ? const Color(0xFF0F766E)
              : const Color(0xFF94A3B8),
          icon: const Icon(Icons.add_rounded),
          color: Colors.white,
          onSelected: (value) {
            switch (value) {
              case 'upload':
                _pickAndUploadFiles();
                break;
              case 'folder':
                _createFolder();
                break;
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem<String>(
              value: 'upload',
              enabled: !_isUploading,
              child: Row(
                children: [
                  _isUploading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_file_outlined, size: 20),
                  const SizedBox(width: 10),
                  Text(_isUploading ? '上传中...' : '上传文件'),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'folder',
              enabled: !_isCreatingFolder,
              child: Row(
                children: [
                  _isCreatingFolder
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.create_new_folder_outlined, size: 20),
                  const SizedBox(width: 10),
                  Text(_isCreatingFolder ? '创建中...' : '新建文件夹'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFamilyPlaceholder(ThemeData theme) {
    return _buildSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '家庭空间',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
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

  Widget _buildRecentTab(ThemeData theme) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          _buildSectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '进行中的任务',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      _activeTransferTasks.isEmpty
                          ? '空闲中'
                          : '${_activeTransferTasks.length} 个进行中',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (_activeTransferTasks.isEmpty)
                  const Text('当前没有进行中的上传或下载任务。')
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _activeTransferTasks.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final task = _activeTransferTasks[index];
                      final actionText = task.kind == TransferTaskKind.download
                          ? '下载中'
                          : '上传中';
                      final subtitle = task.entry.isDir
                          ? '目录$actionText · 已处理 ${task.processedFiles} 个文件'
                          : '文件$actionText · 正在传输';

                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                _buildEntryLeading(task.entry),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        task.entry.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        subtitle,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '目标位置: ${task.targetLocation}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: const Color(0xFF64748B),
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            const LinearProgressIndicator(),
                            const SizedBox(height: 8),
                            Text(
                              '开始于 ${_formatRelativeTime(task.startedAt)}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: const Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildSectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '最近',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                if (_recentFileVisits.isEmpty)
                  const Text('还没有访问记录。先打开一个文件，最近页就会出现内容。')
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _recentFileVisits.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final visit = _recentFileVisits[index];
                      final entry = visit.entry;

                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: _buildEntryLeading(entry),
                        title: Text(entry.name),
                        subtitle: Text(
                          '${_buildEntrySubtitle(entry)}\n位置: ${_parentDirectoryPath(entry.path)} · ${_formatRelativeTime(visit.visitedAt)}',
                        ),
                        isThreeLine: true,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openEntry(entry),
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolsTab(ThemeData theme) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Text(
            '工具',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          _ToolLauncherButton(
            icon: Icons.edit_note_outlined,
            title: '笔记',
            subtitle: '记录临时想法、待办和说明。',
            backgroundColor: const Color(0xFFF8FAFC),
            foregroundColor: const Color(0xFF0F172A),
            onTap: _openNotesToolPage,
          ),
          const SizedBox(height: 14),
          _ToolLauncherButton(
            icon: Icons.forum_outlined,
            title: '聊天',
            subtitle: '以个人电脑为服务器，完全自主的聊天平台。',
            backgroundColor: const Color(0xFFEEF2FF),
            foregroundColor: const Color(0xFF3730A3),
            onTap: _openChatToolPage,
          ),
          const SizedBox(height: 14),
          _ToolLauncherButton(
            icon: Icons.delete_outline,
            title: '回收站',
            subtitle: '功能暂未接入，谨慎删除文件。',
            backgroundColor: const Color(0xFFFEF2F2),
            foregroundColor: const Color(0xFFB91C1C),
            onTap: _openRecycleBinToolPage,
          ),
          const SizedBox(height: 14),
          _ToolLauncherButton(
            icon: Icons.receipt_long_outlined,
            title: '记账',
            subtitle: '功能接入中，后续可在这里管理日常收支。',
            backgroundColor: const Color(0xFFFFFBEB),
            foregroundColor: const Color(0xFFB45309),
            onTap: _openBookkeepingToolPage,
          ),
          const SizedBox(height: 14),
          _ToolLauncherButton(
            icon: Icons.download_outlined,
            title: '定时下载',
            subtitle: '功能接入中，后续可让电脑按计划下载内容。',
            backgroundColor: const Color(0xFFECFDF5),
            foregroundColor: const Color(0xFF047857),
            onTap: _openScheduledDownloadToolPage,
          ),
          const SizedBox(height: 14),
          _ToolLauncherButton(
            icon: Icons.desktop_windows_outlined,
            title: '远程桌面',
            subtitle: '功能接入中，后续可远程打开并操作你的电脑。',
            backgroundColor: const Color(0xFFEFF6FF),
            foregroundColor: const Color(0xFF1D4ED8),
            onTap: _openRemoteDesktopToolPage,
          ),
          const SizedBox(height: 14),
          _ToolLauncherButton(
            icon: Icons.videocam_outlined,
            title: '摄像头中心',
            subtitle: '功能接入中，后续可统一接入摄像头并在手机端观看。',
            backgroundColor: const Color(0xFFF5F3FF),
            foregroundColor: const Color(0xFF6D28D9),
            onTap: _openCameraCenterToolPage,
          ),
        ],
      ),
    );
  }

  String _mineDisplayName() {
    final username = _cloudSession?.user.username.trim();
    if (username == null || username.isEmpty) {
      return '未登录云账号';
    }

    return username;
  }

  Future<void> _openAccountSecurityPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => AccountSecurityPage(
          cloudAccountName: _mineDisplayName(),
          hostName: _hostStatus?.hostName ?? '未连接',
          sharedRoot: _hostStatus?.sharedRoot,
          onReturnToConnectionPage: _returnToConnectionPage,
        ),
      ),
    );
  }

  Future<void> _openContactDeveloperPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => const ContactDeveloperPage(),
      ),
    );
  }

  Widget _buildMineTab(ThemeData theme) {
    final storage = _hostStatus?.storage;
    final usedRatio = storage?.usedRatio ?? 0;
    final usedPercent = '${(usedRatio * 100).toStringAsFixed(0)}%';

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
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
                const CircleAvatar(
                  radius: 30,
                  backgroundColor: Color(0xFFE0F2FE),
                  child: Icon(
                    Icons.person_outline,
                    color: Color(0xFF0369A1),
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _mineDisplayName(),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '个人空间',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildSectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '存储空间',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                if (storage == null)
                  Text(
                    '暂时看不到当前硬盘的空间信息。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF64748B),
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      Expanded(
                        child: _StorageMetric(
                          label: '全部',
                          value: _formatFileSize(storage.totalBytes),
                        ),
                      ),
                      Expanded(
                        child: _StorageMetric(
                          label: '已使用',
                          value: _formatFileSize(storage.usedBytes),
                        ),
                      ),
                      Expanded(
                        child: _StorageMetric(
                          label: '占用',
                          value: usedPercent,
                          alignment: CrossAxisAlignment.end,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: usedRatio,
                      minHeight: 8,
                      backgroundColor: const Color(0xFFE2E8F0),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFF3B82F6),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '当前硬盘: ${storage.driveName.isEmpty ? '共享目录所在硬盘' : storage.driveName}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF64748B),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(
                          Icons.info_outline,
                          size: 18,
                          color: Color(0xFFB45309),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '这里只显示当前硬盘总量，不单独统计云空间占用。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF92400E),
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildSectionCard(
            child: Column(
              children: [
                _MineOptionTile(
                  icon: Icons.shield_outlined,
                  title: '账号与安全',
                  onTap: _openAccountSecurityPage,
                ),
                const Divider(height: 1),
                _MineOptionTile(
                  icon: Icons.mail_outline,
                  title: '联系开发者',
                  trailingText: 'xfdlxyw@163.com',
                  onTap: _openContactDeveloperPage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainShell(ThemeData theme) {
    Widget body;
    switch (_selectedTab) {
      case MainTab.home:
        body = _buildHomeTab(theme);
        break;
      case MainTab.recent:
        body = _buildRecentTab(theme);
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
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.access_time_outlined),
            selectedIcon: Icon(Icons.access_time_filled),
            label: '最近',
          ),
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view_rounded),
            label: '工具',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }

  String _compactBody(String body) {
    final singleLine = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (singleLine.isEmpty) {
      return '';
    }

    return singleLine.length <= 120
        ? singleLine
        : '${singleLine.substring(0, 120)}...';
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
  const _CategoryShortcutButton({required this.shortcut, required this.onTap});

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

class _ToolLauncherButton extends StatelessWidget {
  const _ToolLauncherButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(icon, color: foregroundColor),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: foregroundColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: foregroundColor.withValues(alpha: 0.82),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: foregroundColor),
            ],
          ),
        ),
      ),
    );
  }
}

class _StorageMetric extends StatelessWidget {
  const _StorageMetric({
    required this.label,
    required this.value,
    this.alignment = CrossAxisAlignment.start,
  });

  final String label;
  final String value;
  final CrossAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignment,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: const Color(0xFF64748B)),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _MineOptionTile extends StatelessWidget {
  const _MineOptionTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.trailingText,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final String? trailingText;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: const Color(0xFFF8FAFC),
        child: Icon(icon, color: const Color(0xFF334155)),
      ),
      title: Text(title),
      subtitle: trailingText == null
          ? null
          : Text(trailingText!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class NotesToolPage extends StatefulWidget {
  const NotesToolPage({
    required this.initialNotes,
    required this.loadNotes,
    required this.saveNotes,
    required this.onNotesChanged,
    super.key,
  });

  final List<LocalNote> initialNotes;
  final Future<List<LocalNote>> Function() loadNotes;
  final Future<void> Function(List<LocalNote> notes) saveNotes;
  final ValueChanged<List<LocalNote>> onNotesChanged;

  @override
  State<NotesToolPage> createState() => _NotesToolPageState();
}

class _NotesToolPageState extends State<NotesToolPage> {
  late List<LocalNote> _notes;
  bool _isLoading = true;
  bool _isSaving = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _notes = List<LocalNote>.from(widget.initialNotes)..sort(_compareNotes);
    unawaited(_loadNotes());
  }

  int _compareNotes(LocalNote left, LocalNote right) {
    return right.updatedAt.compareTo(left.updatedAt);
  }

  Future<void> _loadNotes() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final notes = await widget.loadNotes();
      if (!mounted) {
        return;
      }

      setState(() {
        _notes = List<LocalNote>.from(notes)..sort(_compareNotes);
      });
      widget.onNotesChanged(_notes);
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loadError = error.message;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _persistNotes(
    List<LocalNote> nextNotes, {
    required List<LocalNote> previousNotes,
  }) async {
    setState(() {
      _isSaving = true;
      _loadError = null;
    });

    try {
      await widget.saveNotes(nextNotes);
      widget.onNotesChanged(nextNotes);
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _notes = previousNotes;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _editNote([LocalNote? existing]) async {
    final result = await Navigator.of(context).push<LocalNote>(
      MaterialPageRoute<LocalNote>(
        builder: (context) => _NoteEditorPage(existing: existing),
      ),
    );

    if (!mounted || result == null) {
      return;
    }

    final previousNotes = List<LocalNote>.from(_notes);
    final nextNotes = [result, ..._notes.where((note) => note.id != result.id)]
      ..sort(_compareNotes);

    setState(() {
      _notes = nextNotes;
    });
    await _persistNotes(
      List<LocalNote>.from(nextNotes),
      previousNotes: previousNotes,
    );
  }

  Future<void> _deleteNote(LocalNote note) async {
    final previousNotes = List<LocalNote>.from(_notes);
    final nextNotes = _notes
        .where((item) => item.id != note.id)
        .toList(growable: false);

    setState(() {
      _notes = nextNotes;
    });
    await _persistNotes(nextNotes, previousNotes: previousNotes);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('笔记')),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.cloud_off_outlined,
                        size: 48,
                        color: Color(0xFF94A3B8),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        _loadError!,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 14),
                      FilledButton.tonal(
                        onPressed: _loadNotes,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              )
            : _notes.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.note_alt_outlined,
                      size: 48,
                      color: Color(0xFF94A3B8),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '还没有笔记',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '云端笔记保存在根目录的 /.note 文件夹下，点右下角加号先记下一条。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF64748B),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                itemCount: _notes.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final note = _notes[index];
                  return Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: _isSaving ? null : () => _editNote(note),
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.sticky_note_2_outlined,
                              color: Color(0xFF0F766E),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    note.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    note.preview,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: const Color(0xFF475569),
                                          height: 1.4,
                                        ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    _formatRelativeTime(note.updatedAt),
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: const Color(0xFF94A3B8),
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: _isSaving
                                  ? null
                                  : () => _deleteNote(note),
                              icon: const Icon(Icons.delete_outline),
                              tooltip: '删除笔记',
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isLoading || _isSaving ? null : _editNote,
        child: _isSaving
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
      ),
    );
  }
}

class _NoteEditorPage extends StatefulWidget {
  const _NoteEditorPage({this.existing});

  final LocalNote? existing;

  @override
  State<_NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<_NoteEditorPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.existing?.title ?? '');
    _contentController = TextEditingController(
      text: widget.existing?.content ?? '',
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  LocalNote? _buildNoteResult() {
    final rawTitle = _titleController.text.trim();
    final rawContent = _contentController.text.trim();
    final existing = widget.existing;

    if (existing == null && rawTitle.isEmpty && rawContent.isEmpty) {
      return null;
    }

    final resolvedTitle = _deriveLocalNoteTitle(rawTitle, rawContent);
    if (existing != null &&
        existing.title == resolvedTitle &&
        existing.content == rawContent) {
      return null;
    }

    return LocalNote(
      id: existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      title: resolvedTitle,
      content: rawContent,
      updatedAt: DateTime.now(),
    );
  }

  void _closeEditor() {
    if (_isClosing) {
      return;
    }

    _isClosing = true;
    Navigator.of(context).pop(_buildNoteResult());
  }

  @override
  Widget build(BuildContext context) {
    final isNewNote = widget.existing == null;
    return PopScope<LocalNote?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _closeEditor();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: _closeEditor,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: Text(isNewNote ? '新建笔记' : '编辑笔记'),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              children: [
                TextField(
                  controller: _titleController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '标题',
                    hintText: '不填标题时，会自动取内容前几个字',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: TextField(
                    controller: _contentController,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      labelText: '内容',
                      hintText: '在这里记录想法、待办和说明',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ChatToolPage extends StatelessWidget {
  const ChatToolPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('聊天')),
      body: const _PendingToolPageBody(
        icon: Icons.forum_outlined,
        title: '功能接入中',
        detail: '聊天功能正在接入中，后续会在这里提供完整的聊天体验。',
        iconColor: Color(0xFF3730A3),
      ),
    );
  }
}

class RecycleBinToolPage extends StatelessWidget {
  const RecycleBinToolPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('回收站')),
      body: const _PendingToolPageBody(
        icon: Icons.delete_outline,
        title: '功能接入中',
        detail: '回收站功能正在接入中，当前删除文件时请务必谨慎。',
        iconColor: Color(0xFFB91C1C),
      ),
    );
  }
}

class BookkeepingToolPage extends StatelessWidget {
  const BookkeepingToolPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('记账')),
      body: const _PendingToolPageBody(
        icon: Icons.receipt_long_outlined,
        title: '功能接入中',
        detail: '记账功能正在接入中，后续会在这里提供个人收支记录与整理。',
        iconColor: Color(0xFFB45309),
      ),
    );
  }
}

class ScheduledDownloadToolPage extends StatelessWidget {
  const ScheduledDownloadToolPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('定时下载')),
      body: const _PendingToolPageBody(
        icon: Icons.download_outlined,
        title: '功能接入中',
        detail: '定时下载功能正在接入中，后续可以让电脑按计划自动下载文件。',
        iconColor: Color(0xFF047857),
      ),
    );
  }
}

class RemoteDesktopToolPage extends StatelessWidget {
  const RemoteDesktopToolPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('远程桌面')),
      body: const _PendingToolPageBody(
        icon: Icons.desktop_windows_outlined,
        title: '功能接入中',
        detail: '远程桌面功能正在接入中，后续会支持远程查看和操作你的电脑。',
        iconColor: Color(0xFF1D4ED8),
      ),
    );
  }
}

class CameraCenterToolPage extends StatelessWidget {
  const CameraCenterToolPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('摄像头中心')),
      body: const _PendingToolPageBody(
        icon: Icons.videocam_outlined,
        title: '功能接入中',
        detail: '摄像头中心正在接入中，后续可统一接入摄像头，把视频流存到电脑并在手机端观看。',
        iconColor: Color(0xFF6D28D9),
      ),
    );
  }
}

class _PendingToolPageBody extends StatelessWidget {
  const _PendingToolPageBody({
    required this.icon,
    required this.title,
    required this.detail,
    required this.iconColor,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 52, color: iconColor),
              const SizedBox(height: 16),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                detail,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: const Color(0xFF475569),
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AccountSecurityPage extends StatelessWidget {
  const AccountSecurityPage({
    required this.cloudAccountName,
    required this.hostName,
    required this.sharedRoot,
    required this.onReturnToConnectionPage,
    super.key,
  });

  final String cloudAccountName;
  final String hostName;
  final String? sharedRoot;
  final VoidCallback onReturnToConnectionPage;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('账号与安全')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            _PlainInfoCard(
              title: '当前状态',
              lines: [
                '云账号: $cloudAccountName',
                '当前电脑: $hostName',
                if (sharedRoot != null && sharedRoot!.isNotEmpty)
                  '共享目录: $sharedRoot',
              ],
            ),
            const SizedBox(height: 16),
            _PlainInfoCard(
              title: '安全说明',
              lines: const [
                '云账号当前主要用于登录状态和同步电脑地址。',
                '手机访问电脑前，需要先扫码授权，请求会自动完成安全校验。',
                '如果需要更换电脑或重新授权，可以返回连接页重新扫码或连接。',
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () {
                Navigator.of(context).pop();
                onReturnToConnectionPage();
              },
              icon: const Icon(Icons.settings_ethernet),
              label: const Text('返回连接页'),
            ),
          ],
        ),
      ),
    );
  }
}

class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  bool _taskNotifications = true;
  bool _connectionNotifications = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('通知设置')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              child: Column(
                children: [
                  SwitchListTile(
                    value: _taskNotifications,
                    onChanged: (value) =>
                        setState(() => _taskNotifications = value),
                    title: const Text('任务完成提醒'),
                    subtitle: const Text('上传、下载结束后在应用内提醒。'),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    value: _connectionNotifications,
                    onChanged: (value) =>
                        setState(() => _connectionNotifications = value),
                    title: const Text('连接异常提醒'),
                    subtitle: const Text('电脑无法访问时给出明显提示。'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '这些设置当前只在本次运行中生效，后续再接持久化。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF64748B)),
            ),
          ],
        ),
      ),
    );
  }
}

class ContactDeveloperPage extends StatelessWidget {
  const ContactDeveloperPage({super.key});

  static const String _email = 'xfdlxyw@163.com';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('联系开发者')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '邮箱地址',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      SelectableText(
                        _email,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          Clipboard.setData(const ClipboardData(text: _email));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('邮箱地址已复制。')),
                          );
                        },
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('复制邮箱地址'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlainInfoCard extends StatelessWidget {
  const _PlainInfoCard({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            for (var index = 0; index < lines.length; index++) ...[
              if (index > 0) const SizedBox(height: 8),
              Text(
                lines[index],
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF475569),
                  height: 1.5,
                ),
              ),
            ],
          ],
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
  final Future<void> Function(FileBrowserEntry entry, EntryMenuAction action)
  onHandleEntryAction;

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

  Future<void> _runEntryAction(
    FileBrowserEntry entry,
    EntryMenuAction action,
  ) async {
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
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF475569),
                    ),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
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
                      subtitle: Text(
                        '${widget.buildSubtitle(entry)}\n位置: ${_parentDirectoryPath(entry.path)}',
                      ),
                      onTap: () => _runOpenEntry(entry),
                      trailing: isBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : PopupMenuButton<EntryMenuAction>(
                              tooltip: '更多操作',
                              onSelected: (action) =>
                                  _runEntryAction(entry, action),
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
    required this.backgroundColor,
    required this.icon,
    this.endpoint,
    this.hostName,
  });

  const ProbeState.idle()
    : this._(
        headline: '尚未探测',
        detail: '输入电脑地址后点击“连接”，应用会通过 5034 端口连接这台电脑。',
        color: const Color(0xFF475569),
        backgroundColor: const Color(0xFFF8FAFC),
        icon: Icons.info_outline_rounded,
      );

  const ProbeState.loading()
    : this._(
        headline: '正在连接',
        detail: '正在检查这台电脑，并登录文件服务...',
        color: const Color(0xFF0F766E),
        backgroundColor: const Color(0xFFECFEFF),
        icon: Icons.sync_rounded,
      );

  const ProbeState.error(String message)
    : this._(
        headline: '连接失败',
        detail: message,
        color: const Color(0xFFB42318),
        backgroundColor: const Color(0xFFFEF2F2),
        icon: Icons.error_outline_rounded,
      );

  const ProbeState.success({
    required String endpoint,
    required String hostName,
    required String detail,
  }) : this._(
         headline: '电脑在线',
         detail: detail,
         color: const Color(0xFF0F766E),
         backgroundColor: const Color(0xFFECFDF5),
         icon: Icons.check_circle_outline_rounded,
         endpoint: endpoint,
         hostName: hostName,
       );

  final String headline;
  final String detail;
  final Color color;
  final Color backgroundColor;
  final IconData icon;
  final String? endpoint;
  final String? hostName;
}

class _ConnectionPageMetrics {
  const _ConnectionPageMetrics({
    required this.screenWidth,
    required this.horizontalPadding,
    required this.listBottomPadding,
    required this.cardPadding,
    required this.cardRadius,
    required this.sectionSpacing,
    required this.titleFontSize,
    required this.iconBoxSize,
    required this.iconBoxRadius,
    required this.iconSize,
    required this.inlineSpacing,
    required this.badgeHorizontalPadding,
    required this.badgeVerticalPadding,
    required this.badgeRadius,
    required this.inputRadius,
    required this.primaryButtonVerticalPadding,
    required this.helpButtonSize,
  });

  factory _ConnectionPageMetrics.of(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isNarrow = screenWidth < 400;
    final horizontalPadding = isNarrow ? 14.0
        : (screenWidth * 0.053).clamp(16.0, 24.0).toDouble();
    final sectionWidth = screenWidth - (horizontalPadding * 2);
    final cardPadding = isNarrow
        ? (sectionWidth * 0.042).clamp(13.0, 16.0).toDouble()
        : (sectionWidth * 0.055).clamp(16.0, 22.0).toDouble();
    final iconBoxSize = isNarrow
        ? (sectionWidth * 0.13).clamp(42.0, 50.0).toDouble()
        : (sectionWidth * 0.17).clamp(50.0, 60.0).toDouble();
    final badgeHorizontalPadding = isNarrow
        ? (sectionWidth * 0.026).clamp(7.0, 10.0).toDouble()
        : (sectionWidth * 0.034).clamp(10.0, 14.0).toDouble();
    final badgeVerticalPadding = isNarrow
        ? (sectionWidth * 0.018).clamp(5.0, 8.0).toDouble()
        : (sectionWidth * 0.028).clamp(8.0, 10.0).toDouble();

    return _ConnectionPageMetrics(
      screenWidth: screenWidth,
      horizontalPadding: horizontalPadding,
      listBottomPadding: (screenWidth * 0.06).clamp(20.0, 32.0).toDouble(),
      cardPadding: cardPadding,
      cardRadius: isNarrow
          ? (sectionWidth * 0.065).clamp(18.0, 24.0).toDouble()
          : (sectionWidth * 0.08).clamp(24.0, 30.0).toDouble(),
      sectionSpacing: isNarrow
          ? (cardPadding * 0.8).clamp(10.0, 14.0).toDouble()
          : (cardPadding * 0.9).clamp(14.0, 20.0).toDouble(),
      titleFontSize: isNarrow
          ? (screenWidth * 0.065).clamp(20.0, 26.0).toDouble()
          : (screenWidth * 0.078).clamp(26.0, 34.0).toDouble(),
      iconBoxSize: iconBoxSize,
      iconBoxRadius: (iconBoxSize * 0.32).clamp(13.0, 20.0).toDouble(),
      iconSize: (iconBoxSize * 0.48).clamp(20.0, 30.0).toDouble(),
      inlineSpacing: isNarrow
          ? (sectionWidth * 0.032).clamp(10.0, 13.0).toDouble()
          : (sectionWidth * 0.04).clamp(12.0, 16.0).toDouble(),
      badgeHorizontalPadding: badgeHorizontalPadding,
      badgeVerticalPadding: badgeVerticalPadding,
      badgeRadius: isNarrow
          ? (sectionWidth * 0.04).clamp(10.0, 14.0).toDouble()
          : (sectionWidth * 0.05).clamp(14.0, 18.0).toDouble(),
      inputRadius: isNarrow
          ? (sectionWidth * 0.044).clamp(12.0, 16.0).toDouble()
          : (sectionWidth * 0.055).clamp(16.0, 20.0).toDouble(),
      primaryButtonVerticalPadding: isNarrow
          ? (sectionWidth * 0.038).clamp(10.0, 14.0).toDouble()
          : (sectionWidth * 0.05).clamp(14.0, 18.0).toDouble(),
      helpButtonSize: (screenWidth * 0.11).clamp(40.0, 52.0).toDouble(),
    );
  }

  final double screenWidth;
  final double horizontalPadding;
  final double listBottomPadding;
  final double cardPadding;
  final double cardRadius;
  final double sectionSpacing;
  final double titleFontSize;
  final double iconBoxSize;
  final double iconBoxRadius;
  final double iconSize;
  final double inlineSpacing;
  final double badgeHorizontalPadding;
  final double badgeVerticalPadding;
  final double badgeRadius;
  final double inputRadius;
  final double primaryButtonVerticalPadding;
  final double helpButtonSize;

  double illustrationWidthFor(double maxWidth) {
    final ratio = maxWidth < 430 ? 0.48 : 0.34;
    return (maxWidth * ratio).clamp(132.0, 176.0).toDouble();
  }

  double illustrationHeightFor(double maxWidth) {
    return illustrationWidthFor(maxWidth) * 0.72;
  }
}

class CloudSession {
  const CloudSession({
    required this.accessToken,
    required this.user,
    this.expiresAt,
  });

  final String accessToken;
  final CloudUser user;
  final DateTime? expiresAt;

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'expiresAt': expiresAt?.toIso8601String(),
        'user': user.toJson(),
      };

  factory CloudSession.fromJson(Map<String, dynamic> json) {
    return CloudSession(
      accessToken: json['accessToken']?.toString() ?? '',
      expiresAt: DateTime.tryParse(json['expiresAt']?.toString() ?? ''),
      user: CloudUser.fromJson(
          Map<String, dynamic>.from(json['user'] as Map? ?? {})),
    );
  }
}

class CloudUser {
  const CloudUser({
    required this.username,
    this.deviceId,
    this.deviceName,
    this.ipv6Address,
    this.isActive = true,
    this.updatedAt,
  });

  factory CloudUser.fromJson(Map<String, dynamic> json) {
    return CloudUser(
      username: json['username']?.toString() ?? '未命名账号',
      deviceId: json['deviceId']?.toString(),
      deviceName: json['deviceName']?.toString(),
      ipv6Address: json['ipv6Address']?.toString(),
      isActive: json['isActive'] is bool ? json['isActive'] as bool : true,
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
    );
  }

  Map<String, dynamic> toJson() => {
        'username': username,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'ipv6Address': ipv6Address,
        'isActive': isActive,
        'updatedAt': updatedAt?.toIso8601String(),
      };

  final String username;
  final String? deviceId;
  final String? deviceName;
  final String? ipv6Address;
  final bool isActive;
  final DateTime? updatedAt;
}

class NasHostStatus {
  const NasHostStatus({
    required this.hostName,
    this.fileBrowserRunning,
    this.fileBrowserBaseUrl,
    this.sharedRoot,
    this.storage,
  });

  factory NasHostStatus.fromJson(Map<String, dynamic> json) {
    final fileBrowser = json['fileBrowser'];
    final fileBrowserMap = fileBrowser is Map<String, dynamic>
        ? fileBrowser
        : fileBrowser is Map
        ? Map<String, dynamic>.from(fileBrowser)
        : const <String, dynamic>{};
    final running = fileBrowserMap['running'] ?? json['fileBrowserRunning'];
    final storageJson = json['storage'];
    final storageMap = storageJson is Map<String, dynamic>
        ? storageJson
        : storageJson is Map
        ? Map<String, dynamic>.from(storageJson)
        : null;

    return NasHostStatus(
      hostName: json['name']?.toString() ?? '我的电脑',
      fileBrowserRunning: running is bool ? running : null,
      fileBrowserBaseUrl:
          (fileBrowserMap['baseUrl'] ?? json['fileBrowserBaseUrl'])?.toString(),
      sharedRoot: (fileBrowserMap['sharedRoot'] ?? json['sharedRootPath'])
          ?.toString(),
      storage: storageMap == null
          ? null
          : HostStorageSummary.fromJson(storageMap),
    );
  }

  final String hostName;
  final bool? fileBrowserRunning;
  final String? fileBrowserBaseUrl;
  final String? sharedRoot;
  final HostStorageSummary? storage;
}

class HostStorageSummary {
  const HostStorageSummary({
    required this.driveName,
    required this.totalBytes,
    required this.usedBytes,
    required this.freeBytes,
  });

  factory HostStorageSummary.fromJson(Map<String, dynamic> json) {
    int toInt(dynamic value) {
      return value is num ? value.toInt() : 0;
    }

    return HostStorageSummary(
      driveName: json['driveName']?.toString() ?? '',
      totalBytes: toInt(json['totalBytes']),
      usedBytes: toInt(json['usedBytes']),
      freeBytes: toInt(json['freeBytes']),
    );
  }

  final String driveName;
  final int totalBytes;
  final int usedBytes;
  final int freeBytes;

  double get usedRatio {
    if (totalBytes <= 0) {
      return 0;
    }

    return (usedBytes / totalBytes).clamp(0, 1);
  }
}

class FileBrowserDirectory {
  const FileBrowserDirectory({required this.path, required this.items});

  factory FileBrowserDirectory.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = rawItems is List
        ? rawItems
              .whereType<Map>()
              .map(
                (item) =>
                    FileBrowserEntry.fromJson(Map<String, dynamic>.from(item)),
              )
              .where((entry) => !(entry.isDir && entry.name.startsWith('.')))
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
      path: _normalizeResourcePath(
        json['path']?.toString() ?? '',
        isDirectory: isDir,
      ),
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
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.white),
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
                    const Icon(
                      Icons.broken_image_outlined,
                      size: 64,
                      color: Colors.white70,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '图片预览失败，请稍后重试。',
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(color: Colors.white),
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
    final tempDirectory = await Directory.systemTemp.createTemp(
      'nas_phone_audio_',
    );
    final localFilePath = _joinLocalPath(
      tempDirectory.path,
      _safeLocalFileName(widget.title),
    );
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
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);

    try {
      final request = await client
          .getUrl(widget.audioUri)
          .timeout(const Duration(seconds: 15));
      request.headers.set('X-Auth', widget.authToken);

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await utf8
            .decodeStream(response)
            .timeout(const Duration(seconds: 30));
        throw NasApiException(
          '音频下载失败：${response.statusCode}。${_compactAudioErrorBody(body)}',
        );
      }

      await localFile.parent.create(recursive: true);
      await response
          .pipe(localFile.openWrite())
          .timeout(const Duration(seconds: 2 * 60));
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
    final displayedPositionMs =
        _dragValueMs ?? _position.inMilliseconds.toDouble();
    final sliderValue = hasKnownDuration
        ? displayedPositionMs.clamp(0.0, sliderMax)
        : 0.0;
    final canSeek = !_isPreparing && _error == null && hasKnownDuration;
    final effectivePosition = Duration(
      milliseconds: displayedPositionMs.round(),
    );

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
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _error ??
                            (_isPlaying
                                ? '正在播放'
                                : (_isPreparing ? '正在加载音频...' : '已暂停')),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _error == null
                              ? const Color(0xFF475569)
                              : const Color(0xFFB42318),
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
                          Text(
                            hasKnownDuration
                                ? _formatMediaDuration(_duration)
                                : '--:--',
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Center(
                        child: IconButton.filledTonal(
                          onPressed: _error == null && !_isPreparing
                              ? _togglePlayback
                              : null,
                          iconSize: 34,
                          icon: Icon(
                            _isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
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
  State<RemoteDirectoryPickerDialog> createState() =>
      _RemoteDirectoryPickerDialogState();
}

class _RemoteDirectoryPickerDialogState
    extends State<RemoteDirectoryPickerDialog> {
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
                      : () => _loadDirectory(
                          _parentDirectoryPath(_currentDirectory),
                        ),
                  icon: const Icon(Icons.arrow_upward),
                  label: const Text('上级目录'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _isLoading
                      ? null
                      : () => _loadDirectory(_currentDirectory),
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
          onPressed: _isLoading
              ? null
              : () => Navigator.of(context).pop(_currentDirectory),
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

/// 二维码扫描页。仅处理包含 deviceId / deviceName / secret 三个字段的 JSON 格式 QR。
class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final deviceId = decoded['deviceId']?.toString();
        final deviceName = decoded['deviceName']?.toString();
        final secret = decoded['secret']?.toString();
        if (deviceId == null || deviceName == null || secret == null) continue;
        _handled = true;
        Navigator.of(context).pop(<String, dynamic>{
          'deviceId': deviceId,
          'deviceName': deviceName,
          'secret': secret,
        });
        return;
      } catch (_) {
        // 不是有效 JSON，继续扫
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫描设备二维码'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Stack(
        children: [
          MobileScanner(onDetect: _onDetect),
          Center(
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2.5),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          const Positioned(
            bottom: 48,
            left: 24,
            right: 24,
            child: Text(
              '将电脑端显示的二维码对准方框',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

/// 平台通道工具类：负责调用 Android 原生 MediaStore Downloads API。
class _NasMediaChannel {
  static const _channel = MethodChannel('nas_phone/system_open');

  /// 将临时文件 [sourcePath] 写入系统下载目录（MediaStore.Downloads）。
  ///
  /// [fileName]   最终显示的文件名（如 "photo.jpg"）。
  /// [mimeType]   MIME 类型（如 "image/jpeg"）。
  /// [subFolder]  在 Download/ 下的子目录路径（如 "NAS_Downloads" 或 "NAS_Downloads/Photos"）。
  ///
  /// 成功返回相对路径字符串，如 "Download/NAS_Downloads/photo.jpg"。
  /// 失败抛出 [PlatformException]。
  static Future<String> copyToMediaStoreDownloads({
    required String sourcePath,
    required String fileName,
    required String mimeType,
    required String subFolder,
  }) async {
    final result = await _channel.invokeMethod<String>(
      'copyToMediaStoreDownloads',
      {
        'sourcePath': sourcePath,
        'fileName': fileName,
        'mimeType': mimeType,
        'subFolder': subFolder,
      },
    );
    return result ?? 'Download/$subFolder/$fileName';
  }
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
  final sanitized = value
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .trim();
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
  final safeDirectory = directoryPath == '/'
      ? '/'
      : _normalizeDirectoryPath(directoryPath);
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

String _formatRelativeTime(DateTime timestamp) {
  final delta = DateTime.now().difference(timestamp);
  if (delta.inSeconds < 60) {
    return '刚刚';
  }
  if (delta.inMinutes < 60) {
    return '${delta.inMinutes} 分钟前';
  }
  if (delta.inHours < 24) {
    return '${delta.inHours} 小时前';
  }
  if (delta.inDays < 7) {
    return '${delta.inDays} 天前';
  }

  final month = timestamp.month.toString().padLeft(2, '0');
  final day = timestamp.day.toString().padLeft(2, '0');
  final hour = timestamp.hour.toString().padLeft(2, '0');
  final minute = timestamp.minute.toString().padLeft(2, '0');
  return '$month-$day $hour:$minute';
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

  return singleLine.length <= 120
      ? singleLine
      : '${singleLine.substring(0, 120)}...';
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
