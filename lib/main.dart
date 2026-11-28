import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart' as crypto;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:just_audio/just_audio.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const NasPhoneApp());
}

const MethodChannel _folderUploadChannel = MethodChannel(
  'nas_phone/folder_upload',
);

const MethodChannel _transferServiceChannel = MethodChannel(
  'nas_phone/transfer_service',
);

class _PickedFolderEntry {
  const _PickedFolderEntry({
    required this.index,
    required this.relativePath,
    required this.size,
    required this.isDir,
  });

  final int index;
  final String relativePath;
  final int size;
  final bool isDir;
}

enum EntryMenuAction { delete, move, rename, compress, download, share }

const String _kPrivateDirName = '.private';

bool _isPrivatePath(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized == '/$_kPrivateDirName' ||
      normalized.startsWith('/$_kPrivateDirName/');
}

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
    this.transferredBytes = 0,
    this.totalBytes = 0,
    this.bytesPerSecond = 0,
  });

  final String id;
  final TransferTaskKind kind;
  final FileBrowserEntry entry;
  final DateTime startedAt;
  final String targetLocation;
  final int processedFiles;
  final int transferredBytes;
  final int totalBytes; // 0 表示总量未知
  final double bytesPerSecond;

  ActiveTransferTask copyWith({
    int? processedFiles,
    int? transferredBytes,
    int? totalBytes,
    double? bytesPerSecond,
  }) {
    return ActiveTransferTask(
      id: id,
      kind: kind,
      entry: entry,
      startedAt: startedAt,
      targetLocation: targetLocation,
      processedFiles: processedFiles ?? this.processedFiles,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
    );
  }
}

/// 活跃传输任务的计量与 UI 节流状态（不进入 immutable model）。
class _TaskMeter {
  int transferred = 0;
  int total = 0;
  DateTime? lastSampleAt;
  int lastSampleBytes = 0;
  double bytesPerSecond = 0;
  DateTime? lastUiUpdateAt;
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

class _NasHomePageState extends State<NasHomePage> with WidgetsBindingObserver {
  final TextEditingController _hostController = TextEditingController();

  /// 二维码下发的局域网/公网入口，用于自动选路。
  String? _lanHost;
  String? _publicHost;

  // CloudSession? _cloudSession; // 云账号功能已停用
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
  final Map<String, _TaskMeter> _taskMeters = {};
  List<LocalNote> _notes = const [];
  bool _showMainShell = false;
  DateTime? _privacyUntil;
  Timer? _privacyTimer;
  int _privacyTapCount = 0;
  DateTime? _privacyFirstTapAt;
  bool _privacyBusy = false;
  bool get _privacyActive =>
      _privacyUntil != null && DateTime.now().isBefore(_privacyUntil!);
  MainTab _selectedTab = MainTab.home;
  SpaceScope _selectedSpace = SpaceScope.personal;

  bool get _hasFileSession => _baseUri != null && _authToken != null;
  bool get _canGoUp => _hasFileSession && _currentDirectory != '/';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadDeviceSecret());
    unawaited(_loadViewMode());
    // 异步恢复上次的登录/连接状态
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreAndAutoConnect());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _privacyTimer?.cancel();
    _hostController.dispose();
    super.dispose();
  }

  /// 从后台回到前台时检查当前地址是否仍可用，不通则自动切换到另一条线路。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_privacyUntil != null && !_privacyActive) {
      unawaited(_exitPrivacyMode());
    }
    if (!_hasFileSession || _isProbing || _isUploading || _busyEntryPath != null) {
      return;
    }
    unawaited(_recheckConnection());
  }

  Future<void> _recheckConnection() async {
    final baseUri = _baseUri;
    if (baseUri == null) return;
    try {
      await _fetchHostStatus(baseUri).timeout(const Duration(seconds: 3));
    } catch (_) {
      if (!mounted) return;
      await _probeHost(preferCandidates: true);
    }
  }

  /// 启动时恢复持久化状态并尝试自动连接。
  /// 策略：
  ///   1. 有有效 session → 走 _onCloudLoginSuccess（从云端取最新地址自动连接）
  ///   2. 无 session 但有保存的 host → 直接 _probeHost
  ///   3. 两者都没有 → 不做任何操作，显示连接页
  Future<void> _restoreAndAutoConnect() async {
    // 无论有没有登录态，都先加载二维码里保存的局域网/公网入口，保证切换网络时能回退。
    await _loadEndpoints();
    await _loadHistory();
    // 旧版本扫码只写了 endpoints 没进历史列表，这里补录一次
    if (_lanHost != null && _lanHost!.isNotEmpty) {
      await _addHistoryEntry(_lanHost!, isLan: true);
    }
    if (_publicHost != null && _publicHost!.isNotEmpty) {
      await _addHistoryEntry(_publicHost!, isLan: false);
    }
    unawaited(_checkHistoryReachability());
    // 云账号登录态已停用，不再从云端取地址
    // final session = await _loadSavedSession();
    // if (session != null) {
    //   await _onCloudLoginSuccess(session);
    //   return;
    // }

    final host = await _loadSavedHost();
    if (!mounted) return;

    if (host != null && host.isNotEmpty) {
      // 无登录态但有上次地址：局域网优先尝试，失败再走公网
      _hostController.text = host;
      await _probeHost(preferCandidates: true);
    }
  }

  /// 依次尝试候选地址（局域网优先），选中第一个可用的。
  Future<void> _probeHost({bool preferCandidates = false}) async {
    final candidates = _hostCandidates(preferCandidates: preferCandidates);
    if (candidates.isEmpty) {
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

    Object? lastError;
    try {
      for (final host in candidates) {
        final timeout = host == _lanHost
            ? const Duration(milliseconds: 2500)
            : const Duration(seconds: 8);
        try {
          final result = await _tryConnectHost(host, timeout);
          if (!mounted) {
            return;
          }

          setState(() {
            _hostController.text = host;
            _hostStatus = result.status;
            _baseUri = result.baseUri;
            _authToken = result.token;
            _currentDirectory = result.directory?.path ?? '/';
            _entries = result.directory?.items ?? const [];
            _fileError = result.fileError;
            _recentFileVisits = const [];
            _activeTransferTasks = const [];
            _showMainShell = result.token != null && result.directory != null;
            _selectedTab = MainTab.home;
            _selectedSpace = SpaceScope.personal;
            _probeState = ProbeState.success(
              endpoint: result.baseUri.origin,
              hostName: result.status.hostName,
              detail: _buildProbeDetail(result.status, fileError: result.fileError),
            );
          });

          // 连接成功时持久化本次地址，供下次启动直接重连
          if (result.token != null && result.directory != null) {
            await _saveLastHost(host);
            await _rememberEndpoint(host);
          }
          return;
        } catch (error) {
          lastError = error;
        }
      }

      if (!mounted) {
        return;
      }

      _resetFileSession();
      setState(() {
        _hostStatus = null;
        _showMainShell = false;
        _probeState = ProbeState.error(
          lastError is NasApiException
              ? lastError.message
              : _publicHost == null || _publicHost!.isEmpty
              ? '无法连接电脑：局域网不可达，且没有保存公网入口。请重新扫二维码或手动输入公网地址（如 101.200.13.82:5034）。'
              : '无法连接电脑：局域网和公网地址都不可达。',
        );
      });
      unawaited(_checkHistoryReachability());
    } finally {
      if (mounted) {
        setState(() {
          _isProbing = false;
        });
      }
    }
  }

  /// 候选地址顺序：preferCandidates 时局域网 → 公网 → 当前输入；否则当前输入优先。
  List<String> _hostCandidates({bool preferCandidates = false}) {
    final current = _hostController.text.trim();
    final ordered = <String>[];
    void add(String? host) {
      final value = host?.trim();
      if (value != null && value.isNotEmpty && !ordered.contains(value)) {
        ordered.add(value);
      }
    }

    if (preferCandidates) {
      add(_lanHost);
      add(_publicHost);
      for (final record in _endpointHistory) {
        add(record.host);
      }
      add(current);
    } else {
      add(current);
      add(_lanHost);
      add(_publicHost);
      for (final record in _endpointHistory) {
        add(record.host);
      }
    }
    return ordered;
  }

  /// 尝试连接单个地址：状态接口 + 文件服务登录 + 根目录列表。
  Future<
      ({
        Uri baseUri,
        NasHostStatus status,
        String? token,
        FileBrowserDirectory? directory,
        String? fileError,
      })> _tryConnectHost(String host, Duration timeout) async {
    final baseUri = _buildBaseUri(host);
    if (baseUri == null) {
      throw const NasApiException('设备地址格式不正确。');
    }

    try {
      return await () async {
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

        return (
          baseUri: baseUri,
          status: status,
          token: token,
          directory: directory,
          fileError: fileError,
        );
      }()
          .timeout(timeout);
    } on TimeoutException {
      throw const NasApiException('连接超时，请确认电脑在线且网络可达。');
    } on SocketException catch (error) {
      throw NasApiException('无法连接电脑：${error.message}');
    }
  }

  // ---- 云账号功能已停用：_showCloudLoginDialog ----
//   Future<void> _showCloudLoginDialog({String? prefillUsername}
// ) async {
//     final usernameController = TextEditingController(
//       text: prefillUsername ?? _cloudSession?.user.username ?? '',
//     );
//     final passwordController = TextEditingController();
//     var obscurePassword = true;
//     var isSubmitting = false;
//     String? inlineError;
//
//     final result = await showDialog<CloudSession>(
//       context: context,
//       builder: (dialogContext) {
//         return StatefulBuilder(
//           builder: (context, setDialogState) {
//             Future<void> submitLogin() async {
//               final username = usernameController.text.trim();
//               final password = passwordController.text;
//
//               if (username.isEmpty || password.isEmpty) {
//                 setDialogState(() {
//                   inlineError = '请输入账号和密码。';
//                 });
//                 return;
//               }
//
//               setDialogState(() {
//                 isSubmitting = true;
//                 inlineError = null;
//               });
//
//               try {
//                 final session = await _loginToCloudAccount(username, password);
//                 if (!dialogContext.mounted) {
//                   return;
//                 }
//
//                 Navigator.of(dialogContext).pop(session);
//               } on NasApiException catch (error) {
//                 if (!dialogContext.mounted) {
//                   return;
//                 }
//
//                 setDialogState(() {
//                   inlineError = error.message;
//                   isSubmitting = false;
//                 });
//               }
//             }
//
//             return AlertDialog(
//               shape: RoundedRectangleBorder(
//                 borderRadius: BorderRadius.circular(28),
//               ),
//               titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
//               contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
//               actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
//               title: Column(
//                 crossAxisAlignment: CrossAxisAlignment.start,
//                 mainAxisSize: MainAxisSize.min,
//                 children: const [
//                   Text('登录云账号'),
//                   SizedBox(height: 8),
//                   Text(
//                     '输入账号和密码进行登录。没有账号时，请使用下方扫码注册卡片。',
//                     style: TextStyle(
//                       fontSize: 13,
//                       color: Color(0xFF64748B),
//                       height: 1.5,
//                     ),
//                   ),
//                 ],
//               ),
//               content: Column(
//                 mainAxisSize: MainAxisSize.min,
//                 children: [
//                   TextField(
//                     controller: usernameController,
//                     autofocus: true,
//                     decoration: const InputDecoration(
//                       labelText: '账号 / 邮箱 / 手机号',
//                       border: OutlineInputBorder(),
//                       prefixIcon: Icon(Icons.person_outline_rounded),
//                     ),
//                     textInputAction: TextInputAction.next,
//                     onSubmitted: (_) =>
//                         FocusScope.of(dialogContext).nextFocus(),
//                   ),
//                   const SizedBox(height: 12),
//                   TextField(
//                     controller: passwordController,
//                     obscureText: obscurePassword,
//                     decoration: InputDecoration(
//                       labelText: '密码',
//                       border: const OutlineInputBorder(),
//                       prefixIcon: const Icon(Icons.lock_outline_rounded),
//                       suffixIcon: IconButton(
//                         onPressed: () {
//                           setDialogState(() {
//                             obscurePassword = !obscurePassword;
//                           });
//                         },
//                         icon: Icon(
//                           obscurePassword
//                               ? Icons.visibility_outlined
//                               : Icons.visibility_off_outlined,
//                         ),
//                       ),
//                     ),
//                     textInputAction: TextInputAction.done,
//                     onSubmitted: (_) {
//                       if (!isSubmitting) {
//                         submitLogin();
//                       }
//                     },
//                   ),
//                   if (inlineError != null) ...[
//                     const SizedBox(height: 12),
//                     Align(
//                       alignment: Alignment.centerLeft,
//                       child: Text(
//                         inlineError!,
//                         style: const TextStyle(
//                           color: Color(0xFFB42318),
//                           height: 1.4,
//                         ),
//                       ),
//                     ),
//                   ],
//                 ],
//               ),
//               actions: [
//                 TextButton(
//                   onPressed: isSubmitting
//                       ? null
//                       : () => Navigator.of(dialogContext).pop(),
//                   child: const Text('取消'),
//                 ),
//                 FilledButton(
//                   onPressed: isSubmitting ? null : submitLogin,
//                   child: isSubmitting
//                       ? const SizedBox(
//                           width: 18,
//                           height: 18,
//                           child: CircularProgressIndicator(strokeWidth: 2),
//                         )
//                       : const Text('登录'),
//                 ),
//               ],
//             );
//           },
//         );
//       },
//     );
//
//     WidgetsBinding.instance.addPostFrameCallback((_) {
//       usernameController.dispose();
//       passwordController.dispose();
//     });
//
//     if (!mounted || result == null) {
//       return;
//     }
//
//     await _onCloudLoginSuccess(result);
//   }

  // ── 登录后自动连接 ─────────────────────────────────────────────────────────

  /// 云账号登录成功后的统一处理：保存 session，并尝试从云端获取 IPv6 地址自动连接设备。
  /// 若首次 ipv6Address 为空，每隔 1 秒轮询 /users/me，最多重试 2 次（共 3 次检查）。
  // ---- 云账号功能已停用：_onCloudLoginSuccess ----
//   Future<void> _onCloudLoginSuccess(CloudSession session) async {
//     if (!mounted) return;
//     await _loadEndpoints(); // 云端地址只作为候选之一，仍需带上二维码保存的公网入口
//     if (!mounted) return;
//     setState(() => _cloudSession = session);
//     await _saveSession(session); // 持久化登录态
//
//     // 最多检查 3 次（首次 + 2 次重试）
//     String? ipv6 = session.user.ipv6Address;
//     for (var attempt = 1; attempt <= 2 && (ipv6 == null || ipv6.isEmpty); attempt++) {
//       await Future<void>.delayed(const Duration(seconds: 1));
//       if (!mounted) return;
//       try {
//         final user = await _fetchCloudUserInfo(session.accessToken);
//         ipv6 = user.ipv6Address;
//       } catch (_) {
//         // 网络失败则直接跳出，稍后提示
//         break;
//       }
//     }
//
//     if (!mounted) return;
//
//     if (ipv6 != null && ipv6.isNotEmpty) {
//       // 填入地址栏并自动发起探测连接
//       _hostController.text = ipv6;
//       ScaffoldMessenger.of(context).showSnackBar(
//         SnackBar(
//           content: Text('已登录 ${session.user.username}，正在自动连接设备…'),
//           duration: const Duration(seconds: 3),
//         ),
//       );
//       await _probeHost(preferCandidates: true);
//     } else {
//       // 3 次均未获取到地址
//       ScaffoldMessenger.of(context).showSnackBar(
//         SnackBar(
//           content: Text(
//             '已登录 ${session.user.username}，但未能获取到电脑端地址。\n'
//             '请确认电脑端网络已就绪，或在局域网内手动输入地址连接。',
//           ),
//           duration: const Duration(seconds: 6),
//         ),
//       );
//     }
//   }

  /// 使用 Bearer Token 查询自己的最新用户信息（主要用于获取 ipv6Address）。
  // ---- 云账号功能已停用：_fetchCloudUserInfo ----
//   Future<CloudUser> _fetchCloudUserInfo(String accessToken) async {
//     final response = await _sendCloudTextRequest(
//       Uri.parse('https://reportzs.me/nas-api/users/me'),
//       headers: {
//         HttpHeaders.acceptHeader: 'application/json',
//         HttpHeaders.authorizationHeader: 'Bearer $accessToken',
//       },
//     );
//     late final Map<String, dynamic> decoded;
//     try {
//       decoded = _decodeJsonObject(response.body, invalidMessage: '用户信息接口返回了无法解析的内容。');
//     } on NasApiException {
//       throw NasApiException('获取用户信息失败：${response.statusCode}。');
//     }
//     if (decoded['success'] != true) {
//       final err = decoded['error']?.toString();
//       throw NasApiException(err?.isNotEmpty == true ? err! : '获取用户信息失败。');
//     }
//     final userRaw = decoded['user'];
//     if (userRaw is! Map) throw const NasApiException('用户信息字段缺失。');
//     return CloudUser.fromJson(Map<String, dynamic>.from(userRaw));
//   }

  // ── 状态持久化 ─────────────────────────────────────────────────────────────

  // static const _kSessionKey = 'cloud_session_v1'; // 云账号功能已停用
  static const _kLastHostKey = 'last_connected_host';
  static const _kEndpointsKey = 'nas_endpoints_v1';

  /// 将 CloudSession 序列化后存入 SharedPreferences。
  // ---- 云账号功能已停用：_saveSession ----
//   Future<void> _saveSession(CloudSession session) async {
//     try {
//       final prefs = await SharedPreferences.getInstance();
//       await prefs.setString(_kSessionKey, jsonEncode(session.toJson()));
//     } catch (_) {}
//   }

  /// 清除持久化的 session（退出登录时调用）。
  // ---- 云账号功能已停用：_clearSession ----
//   Future<void> _clearSession() async {
//     try {
//       final prefs = await SharedPreferences.getInstance();
//       await prefs.remove(_kSessionKey);
//     } catch (_) {}
//   }

  /// 保存最近一次成功连接的设备地址。
  Future<void> _saveLastHost(String host) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastHostKey, host);
    } catch (_) {}
  }

  /// 从本地加载已保存的 CloudSession；若过期或不存在则返回 null。
  // ---- 云账号功能已停用：_loadSavedSession ----
//   Future<CloudSession?> _loadSavedSession() async {
//     try {
//       final prefs = await SharedPreferences.getInstance();
//       final raw = prefs.getString(_kSessionKey);
//       if (raw == null || raw.isEmpty) return null;
//       final json = _decodeJsonObject(raw, invalidMessage: '');
//       final session = CloudSession.fromJson(json);
//       if (session.accessToken.isEmpty) return null;
//       // 已过期则丢弃（提前 30 分钟视为过期）
//       final expires = session.expiresAt;
//       if (expires != null &&
//           expires.isBefore(DateTime.now().add(const Duration(minutes: 30)))) {
//         await _clearSession();
//         return null;
//       }
//       return session;
//     } catch (_) {
//       return null;
//     }
//   }

  /// 从本地加载上次连接的设备地址。
  Future<String?> _loadSavedHost() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kLastHostKey);
    } catch (_) {
      return null;
    }
  }

  // ── 历史地址列表：连接成功过或扫码得到的地址，带可达性探测 ──────────────────
  static const _kHistoryKey = 'nas_endpoint_history_v1';
  List<_EndpointRecord> _endpointHistory = [];
  final Map<String, bool> _endpointReachable = {};
  bool _isCheckingHistory = false;

  String _normalizeEndpointHost(String input) {
    final uri = _buildBaseUri(input);
    return uri?.host ?? input.trim();
  }

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kHistoryKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        _endpointHistory = decoded
            .whereType<Map>()
            .map((e) => _EndpointRecord.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kHistoryKey,
        jsonEncode(_endpointHistory.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> _addHistoryEntry(
    String host, {
    required bool isLan,
    bool success = false,
  }) async {
    final normalized = _normalizeEndpointHost(host);
    if (normalized.isEmpty) return;

    final index = _endpointHistory.indexWhere((e) => e.host == normalized);
    if (index >= 0) {
      final old = _endpointHistory[index];
      _endpointHistory[index] = _EndpointRecord(
        host: normalized,
        isLan: isLan,
        lastSuccess: success ? DateTime.now() : old.lastSuccess,
      );
    } else {
      _endpointHistory.add(_EndpointRecord(
        host: normalized,
        isLan: isLan,
        lastSuccess: success ? DateTime.now() : null,
      ));
    }

    _endpointHistory.sort((a, b) {
      final at = a.lastSuccess?.millisecondsSinceEpoch ?? 0;
      final bt = b.lastSuccess?.millisecondsSinceEpoch ?? 0;
      return bt.compareTo(at);
    });
    if (_endpointHistory.length > 12) {
      _endpointHistory = _endpointHistory.take(12).toList();
    }
    await _saveHistory();
    if (mounted) setState(() {});
  }

  /// Android 无 root 不能发 ICMP ping，这里用 TCP + 状态接口探测，效果等同且更准。
  Future<void> _checkHistoryReachability() async {
    if (_isCheckingHistory || _endpointHistory.isEmpty) return;
    _isCheckingHistory = true;
    try {
      for (final record in List<_EndpointRecord>.from(_endpointHistory)) {
        if (!mounted) return;
        final baseUri = _buildBaseUri(record.host);
        if (baseUri == null) continue;
        var ok = false;
        try {
          await _fetchHostStatus(baseUri).timeout(
            record.isLan
                ? const Duration(milliseconds: 1500)
                : const Duration(seconds: 4),
          );
          ok = true;
        } catch (_) {
          ok = false;
        }
        if (!mounted) return;
        setState(() => _endpointReachable[record.host] = ok);
      }
    } finally {
      _isCheckingHistory = false;
    }
  }

  Widget _buildEndpointHistoryCard(BuildContext context, ThemeData theme) {
    final metrics = _ConnectionPageMetrics.of(context);
    return _buildSectionCard(
      contextOverride: context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '历史地址',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: _isCheckingHistory
                    ? null
                    : () => _checkHistoryReachability(),
                icon: const Icon(Icons.refresh_rounded, size: 20),
                color: const Color(0xFF64748B),
                tooltip: '重新探测',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '点按地址即可填入并连接；绿勾表示当前可通，感叹号表示不通。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF64748B),
              height: 1.5,
            ),
          ),
          SizedBox(height: metrics.sectionSpacing * 0.7),
          if (_endpointHistory.isEmpty)
            Text(
              '还没有记录。扫码或成功连接一次后，地址会自动出现在这里。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF94A3B8),
              ),
            )
          else
            for (final record in _endpointHistory) ...[
              InkWell(
                onTap: _isProbing
                    ? null
                    : () {
                        _hostController.text = record.host;
                        _probeHost();
                      },
                borderRadius: BorderRadius.circular(metrics.inputRadius),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: metrics.badgeVerticalPadding + 2,
                    horizontal: 4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _endpointReachable[record.host] == true
                            ? Icons.check_circle_rounded
                            : _endpointReachable[record.host] == false
                                ? Icons.error_outline_rounded
                                : Icons.hourglass_empty_rounded,
                        size: 20,
                        color: _endpointReachable[record.host] == true
                            ? const Color(0xFF16A34A)
                            : _endpointReachable[record.host] == false
                                ? const Color(0xFFF59E0B)
                                : const Color(0xFF94A3B8),
                      ),
                      SizedBox(width: metrics.inlineSpacing * 0.6),
                      Expanded(
                        child: Text(
                          record.host,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFF0F172A),
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: record.isLan
                              ? const Color(0xFFEFF6FF)
                              : const Color(0xFFECFDF5),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          record.isLan ? '局域网' : '公网',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: record.isLan
                                ? const Color(0xFF2563EB)
                                : const Color(0xFF047857),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.chevron_right_rounded,
                          size: 20, color: Color(0xFF94A3B8)),
                    ],
                  ),
                ),
              ),
              if (record != _endpointHistory.last)
                const Divider(height: 1, color: Color(0xFFF1F5F9)),
            ],
        ],
      ),
    );
  }

  /// 保存二维码下发的局域网/公网入口，供自动选路使用。
  Future<void> _saveEndpoints({String? lan, String? publicHost}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (lan != null) _lanHost = lan;
      if (publicHost != null) _publicHost = publicHost;
      await prefs.setString(
        _kEndpointsKey,
        jsonEncode({'lan': _lanHost, 'public': _publicHost}),
      );
    } catch (_) {}
  }

  /// 连接成功后按地址类型记住入口：内网地址记为局域网，其余记为公网。
  /// 这样即使没有重新扫码，手动填一次地址也能被自动保存下来。
  Future<void> _rememberEndpoint(String host) async {
    final value = host.trim();
    if (value.isEmpty) return;

    final withoutScheme = value.contains('://')
        ? value.substring(value.indexOf('://') + 3)
        : value;
    var hostPart = withoutScheme.split('/').first;
    if (hostPart.startsWith('[')) {
      final end = hostPart.indexOf(']');
      hostPart = end > 0 ? hostPart.substring(1, end) : hostPart;
    } else {
      hostPart = hostPart.split(':').first;
    }

    final lower = hostPart.toLowerCase();
    final isPrivate =
        lower == 'localhost' ||
        lower.startsWith('127.') ||
        lower.startsWith('10.') ||
        lower.startsWith('192.168.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(lower) ||
        lower.startsWith('fe80') ||
        lower.startsWith('fd') ||
        lower.startsWith('::1');

    if (isPrivate) {
      if (_lanHost != value) await _saveEndpoints(lan: value);
    } else {
      if (_publicHost != value) await _saveEndpoints(publicHost: value);
    }
    await _addHistoryEntry(value, isLan: isPrivate, success: true);
  }

  Future<void> _loadEndpoints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kEndpointsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _lanHost = decoded['lan']?.toString();
        _publicHost = decoded['public']?.toString();
      }
    } catch (_) {}
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
      'X-NAS-Timestamp': '$ts',
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
    final ip = result['ip']?.toString();
    final lan = result['lan']?.toString();
    final publicHost = result['public']?.toString();
    // final type = result['type']?.toString(); // 云账号功能已停用
    // final username = result['username']?.toString(); // 云账号功能已停用

    if (deviceId == null || deviceName == null || secret == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('二维码内容不是有效的设备信息，请重新扫描。')),
      );
      return;
    }

    // 扫码后保存二维码里的局域网/公网入口，自动选择可用的那条线路。
    if ((lan != null && lan.isNotEmpty) || (publicHost != null && publicHost.isNotEmpty)) {
      await _saveEndpoints(
        lan: lan?.isNotEmpty == true ? lan : null,
        publicHost: publicHost?.isNotEmpty == true ? publicHost : null,
      );
    }

    final preferredHost = (lan != null && lan.isNotEmpty)
        ? lan
        : (ip != null && ip.isNotEmpty ? ip : publicHost);
    if (preferredHost != null && preferredHost.isNotEmpty) {
      _hostController.text = preferredHost;
    }

    // 持久化保存 secret 和 deviceId，供后续安全通信使用（混淆存储）
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceSecretKey, _encodeDeviceSecret(secret));
    await prefs.setString('bound_device_id', deviceId);
    _deviceSecret = secret;

    if (!mounted) return;

    // 云账号注册/登录已停用：扫码拿到凭证后直接连接设备
    // if (type == 'auth') {
    //   await _showCloudLoginDialog(prefillUsername: username);
    //   return;
    // }
    // await _showRegisterDialog(deviceId: deviceId, deviceName: deviceName);
    if (lan != null && lan.isNotEmpty) {
      await _addHistoryEntry(lan, isLan: true);
    }
    if (publicHost != null && publicHost.isNotEmpty) {
      await _addHistoryEntry(publicHost, isLan: false);
    }
    if (preferredHost != null && preferredHost.isNotEmpty) {
      await _probeHost(preferCandidates: true);
    }
  }

  /// 注册对话框：输入账号和密码，调用注册接口。
  // ---- 云账号功能已停用：_showRegisterDialog ----
//   Future<void> _showRegisterDialog({
//     required String deviceId,
//     required String deviceName,
//   }) async {
//     final usernameCtrl = TextEditingController();
//     final passwordCtrl = TextEditingController();
//     var obscure = true;
//     var submitting = false;
//     String? inlineError;
//
//     final registered = await showDialog<bool>(
//       context: context,
//       barrierDismissible: false,
//       builder: (dialogContext) {
//         return StatefulBuilder(
//           builder: (context, setDialogState) {
//             Future<void> submit() async {
//               final username = usernameCtrl.text.trim();
//               final password = passwordCtrl.text;
//               if (username.isEmpty || password.isEmpty) {
//                 setDialogState(() => inlineError = '请输入账号和密码。');
//                 return;
//               }
//               setDialogState(() {
//                 submitting = true;
//                 inlineError = null;
//               });
//               try {
//                 await _registerToCloud(
//                   username: username,
//                   password: password,
//                   deviceId: deviceId,
//                 );
//                 if (!dialogContext.mounted) return;
//                 Navigator.of(dialogContext).pop(true);
//               } on NasApiException catch (e) {
//                 if (!dialogContext.mounted) return;
//                 setDialogState(() {
//                   inlineError = e.message;
//                   submitting = false;
//                 });
//               }
//             }
//
//             return AlertDialog(
//               shape: RoundedRectangleBorder(
//                   borderRadius: BorderRadius.circular(28)),
//               titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
//               contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
//               actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
//               title: Column(
//                 crossAxisAlignment: CrossAxisAlignment.start,
//                 mainAxisSize: MainAxisSize.min,
//                 children: [
//                   const Text('注册云账号'),
//                   const SizedBox(height: 8),
//                   Text(
//                     '绑定设备：$deviceName\n设备网络地址易变，注册云账号即可实时获取最新连接地址。',
//                     style: const TextStyle(
//                       fontSize: 13,
//                       color: Color(0xFF64748B),
//                       height: 1.5,
//                     ),
//                   ),
//                 ],
//               ),
//               content: Column(
//                 mainAxisSize: MainAxisSize.min,
//                 children: [
//                   TextField(
//                     controller: usernameCtrl,
//                     autofocus: true,
//                     decoration: const InputDecoration(
//                       labelText: '账号（用户名）',
//                       border: OutlineInputBorder(),
//                       prefixIcon: Icon(Icons.person_outline_rounded),
//                     ),
//                     textInputAction: TextInputAction.next,
//                     onSubmitted: (_) =>
//                         FocusScope.of(dialogContext).nextFocus(),
//                   ),
//                   const SizedBox(height: 12),
//                   StatefulBuilder(
//                     builder: (_, setObscure) => TextField(
//                       controller: passwordCtrl,
//                       obscureText: obscure,
//                       decoration: InputDecoration(
//                         labelText: '密码',
//                         border: const OutlineInputBorder(),
//                         prefixIcon: const Icon(Icons.lock_outline_rounded),
//                         suffixIcon: IconButton(
//                           onPressed: () =>
//                               setObscure(() => obscure = !obscure),
//                           icon: Icon(obscure
//                               ? Icons.visibility_outlined
//                               : Icons.visibility_off_outlined),
//                         ),
//                       ),
//                       textInputAction: TextInputAction.done,
//                       onSubmitted: (_) {
//                         if (!submitting) submit();
//                       },
//                     ),
//                   ),
//                   if (inlineError != null) ...[
//                     const SizedBox(height: 12),
//                     Align(
//                       alignment: Alignment.centerLeft,
//                       child: Text(
//                         inlineError!,
//                         style: const TextStyle(
//                             color: Color(0xFFB42318), height: 1.4),
//                       ),
//                     ),
//                   ],
//                 ],
//               ),
//               actions: [
//                 TextButton(
//                   onPressed:
//                       submitting ? null : () => Navigator.of(dialogContext).pop(),
//                   child: const Text('取消'),
//                 ),
//                 FilledButton(
//                   onPressed: submitting ? null : submit,
//                   child: submitting
//                       ? const SizedBox(
//                           width: 18,
//                           height: 18,
//                           child: CircularProgressIndicator(strokeWidth: 2),
//                         )
//                       : const Text('注册'),
//                 ),
//               ],
//             );
//           },
//         );
//       },
//     );
//
//     WidgetsBinding.instance.addPostFrameCallback((_) {
//       usernameCtrl.dispose();
//       passwordCtrl.dispose();
//     });
//
//     if (!mounted || registered != true) return;
//
//     // 注册成功 → 用刚填写的账号密码自动登录
//     final username = usernameCtrl.text.trim();
//     final password = passwordCtrl.text;
//     try {
//       final session = await _loginToCloudAccount(username, password);
//       if (!mounted) return;
//       await _onCloudLoginSuccess(session);
//     } catch (_) {
//       // 自动登录失败时给一个提示，用户可手动登录
//       if (!mounted) return;
//       ScaffoldMessenger.of(context).showSnackBar(
//         const SnackBar(
//           content: Text('注册成功！自动登录失败，请在"我的"页面手动登录云账号。'),
//           duration: Duration(seconds: 5),
//         ),
//       );
//     }
//   }

  /// 调用云服务注册接口。
  // ---- 云账号功能已停用：_registerToCloud ----
//   Future<void> _registerToCloud({
//     required String username,
//     required String password,
//     required String deviceId,
//   }) async {
//     final response = await _sendCloudTextRequest(
//       Uri.parse('https://reportzs.me/nas-api/register'),
//       method: 'POST',
//       headers: const {
//         HttpHeaders.acceptHeader: 'application/json',
//         HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
//       },
//       requestBody: jsonEncode({
//         'username': username,
//         'password': password,
//         'deviceId': deviceId,
//       }),
//     );
//
//     late final Map<String, dynamic> decoded;
//     try {
//       decoded = _decodeJsonObject(
//         response.body,
//         invalidMessage: '注册接口返回了无法解析的内容。',
//       );
//     } on NasApiException {
//       throw NasApiException(
//         '注册失败：${response.statusCode}。${_compactBody(response.body)}',
//       );
//     }
//
//     final success = decoded['success'] == true;
//     if (!success || response.statusCode < 200 || response.statusCode >= 300) {
//       final err = decoded['error']?.toString();
//       if (err != null && err.isNotEmpty) throw NasApiException(err);
//       throw NasApiException('注册失败：${response.statusCode}。');
//     }
//   }

  // ---- 云账号功能已停用：_loginToCloudAccount ----
//   Future<CloudSession> _loginToCloudAccount(
//     String username,
//     String password,
//   ) async {
//     final response = await _sendCloudTextRequest(
//       Uri.parse('https://reportzs.me/nas-api/login'),
//       method: 'POST',
//       headers: const {
//         HttpHeaders.acceptHeader: 'application/json',
//         HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
//       },
//       requestBody: jsonEncode({'username': username, 'password': password}),
//     );
//
//     late final Map<String, dynamic> decoded;
//     try {
//       decoded = _decodeJsonObject(
//         response.body,
//         invalidMessage: '云登录接口返回了无法解析的内容。',
//       );
//     } on NasApiException {
//       if (response.statusCode >= 200 && response.statusCode < 300) {
//         rethrow;
//       }
//
//       throw NasApiException(
//         '云账号登录失败：${response.statusCode}。${_compactBody(response.body)}',
//       );
//     }
//
//     final success = decoded['success'] == true;
//     if (!success || response.statusCode < 200 || response.statusCode >= 300) {
//       final error = decoded['error']?.toString();
//       if (error != null && error.isNotEmpty) {
//         throw NasApiException(error);
//       }
//
//       throw NasApiException('云账号登录失败：${response.statusCode}。');
//     }
//
//     final accessToken = decoded['accessToken']?.toString();
//     if (accessToken == null || accessToken.isEmpty) {
//       throw const NasApiException('云账号登录成功，但 accessToken 为空。');
//     }
//
//     final userRaw = decoded['user'];
//     if (userRaw is! Map) {
//       throw const NasApiException('云账号登录成功，但用户信息缺失。');
//     }
//
//     return CloudSession(
//       accessToken: accessToken,
//       expiresAt: DateTime.tryParse(decoded['expiresAt']?.toString() ?? ''),
//       user: CloudUser.fromJson(Map<String, dynamic>.from(userRaw)),
//     );
//   }

  // ---- 云账号功能已停用：_sendCloudTextRequest ----
//   Future<SimpleHttpResponse> _sendCloudTextRequest(
//     Uri uri, {
//     String method = 'GET',
//     Map<String, String>? headers,
//     String? requestBody,
//   }) async {
//     final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
//
//     try {
//       late HttpClientRequest request;
//       switch (method) {
//         case 'DELETE':
//           request = await client
//               .deleteUrl(uri)
//               .timeout(const Duration(seconds: 8));
//           break;
//         case 'GET':
//           request = await client
//               .getUrl(uri)
//               .timeout(const Duration(seconds: 8));
//           break;
//         default:
//           request = await client
//               .openUrl(method, uri)
//               .timeout(const Duration(seconds: 8));
//       }
//
//       headers?.forEach(request.headers.set);
//       if (requestBody != null) {
//         final bytes = utf8.encode(requestBody);
//         request.contentLength = bytes.length;
//         request.add(bytes);
//       }
//
//       final response = await request.close().timeout(
//         const Duration(seconds: 8),
//       );
//       final responseBody = await utf8
//           .decodeStream(response)
//           .timeout(const Duration(seconds: 8));
//       return SimpleHttpResponse(response.statusCode, responseBody);
//     } on TimeoutException {
//       throw const NasApiException('请求云服务超时，请稍后重试。');
//     } on SocketException catch (error) {
//       throw NasApiException('无法连接云服务：${error.message}');
//     } on HttpException catch (error) {
//       throw NasApiException('云服务请求失败：${error.message}');
//     } finally {
//       client.close(force: true);
//     }
//   }

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
          '1. 扫码即完成授权，直接连接电脑。\n'
          '2. 手动连接只需输入 ipv4 或 ipv6 地址，端口自动补全。\n'
          '3. 历史地址会标注局域网/公网，并自动检测是否可通。\n'
          '4. 连接时优先局域网，不可达会自动尝试公网和历史地址。',
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

    // 刷新/切换目录时给之前失败的封面一次重试机会
    _videoThumbFailed.clear();

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
          size: file.size >= 0 ? file.size : 0,
        );
        final taskId = _startTransferTask(
          kind: TransferTaskKind.upload,
          entry: uploadEntry,
          targetLocation: _currentDirectory,
          totalBytes: file.size >= 0 ? file.size : 0,
        );

        try {
          await _uploadFile(
            baseUri,
            token,
            _currentDirectory,
            file,
            onBytes: (delta) => _updateTransferTaskBytes(taskId, delta),
          );
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

  /// 选择整个文件夹上传，保持原有目录结构（仅 Android）。
  Future<void> _pickAndUploadFolder() async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null || _isUploading) {
      return;
    }

    if (!Platform.isAndroid) {
      const message = '上传文件夹目前只支持 Android 手机端。';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(message)));
      return;
    }

    List<_PickedFolderEntry> picked;
    try {
      final raw = await _folderUploadChannel.invokeMethod<List<dynamic>>(
        'pickFolder',
      );
      if (raw == null) {
        return; // 用户取消
      }

      picked = [
        for (var i = 0; i < raw.length; i++)
          if (raw[i] is Map)
            _PickedFolderEntry(
              index: i,
              relativePath: (raw[i] as Map)['path']?.toString() ?? '',
              size: ((raw[i] as Map)['size'] as num?)?.toInt() ?? 0,
              isDir: (raw[i] as Map)['isDir'] == true,
            ),
      ].where((entry) => entry.relativePath.isNotEmpty).toList();

      if (picked.isEmpty) {
        await _folderUploadChannel.invokeMethod<void>('clearSession');
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这个文件夹是空的。')));
        return;
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      final message = '打开文件夹失败：${error.message ?? error.code}';
      setState(() {
        _fileError = message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    } on MissingPluginException {
      if (!mounted) return;
      const message = '当前安装包不支持选择文件夹，请安装最新版本。';
      setState(() {
        _fileError = message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(message)));
      return;
    }

    final files = picked.where((entry) => !entry.isDir).toList();
    if (files.isEmpty) {
      await _folderUploadChannel.invokeMethod<void>('clearSession');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('文件夹里没有可上传的文件。')));
      return;
    }

    // 汇总需要建立的目录（含空目录），按层级由浅到深创建
    final directories = <String>{};
    for (final entry in picked) {
      final parts = entry.relativePath.split('/');
      final depth = entry.isDir ? parts.length : parts.length - 1;
      for (var i = 1; i <= depth; i++) {
        directories.add(parts.sublist(0, i).join('/'));
      }
    }
    final orderedDirectories = directories.toList()
      ..sort((a, b) => a.split('/').length.compareTo(b.split('/').length));

    setState(() {
      _isUploading = true;
      _fileError = null;
    });

    var uploaded = 0;
    try {
      for (final directory in orderedDirectories) {
        try {
          await _createDirectory(
            baseUri,
            token,
            _joinResourcePath(_currentDirectory, '$directory/'),
          );
        } on NasApiException {
          // 目录已存在时会被拒绝，忽略后继续
        }
      }

      for (final entry in files) {
        final parts = entry.relativePath.split('/');
        final fileName = parts.last;
        final relativeDirectory = parts.length > 1
            ? '${parts.sublist(0, parts.length - 1).join('/')}/'
            : '';
        final targetDirectory = relativeDirectory.isEmpty
            ? _currentDirectory
            : _joinResourcePath(_currentDirectory, relativeDirectory);
        final taskId = _startTransferTask(
          kind: TransferTaskKind.upload,
          entry: FileBrowserEntry(
            name: entry.relativePath,
            path: _joinResourcePath(targetDirectory, fileName),
            isDir: false,
            size: entry.size,
          ),
          targetLocation: targetDirectory,
          totalBytes: entry.size,
        );

        try {
          final localPath = await _folderUploadChannel.invokeMethod<String>(
            'materialize',
            {'index': entry.index},
          );
          if (localPath == null || localPath.isEmpty) {
            throw NasApiException('读取文件失败：${entry.relativePath}');
          }

          await _uploadFile(
            baseUri,
            token,
            targetDirectory,
            PlatformFile(name: fileName, size: entry.size, path: localPath),
            onBytes: (delta) => _updateTransferTaskBytes(taskId, delta),
          );
          uploaded++;
        } finally {
          _finishTransferTask(taskId);
        }
      }

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已上传 $uploaded 个文件，目录结构已保留。')),
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
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      final message = '上传文件夹失败：${error.message ?? error.code}';
      setState(() {
        _fileError = message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) {
        return;
      }
      const fallbackMessage = '上传文件夹失败，请保持应用在前台后重试。';
      setState(() {
        _fileError = fallbackMessage;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(fallbackMessage)));
    } finally {
      try {
        await _folderUploadChannel.invokeMethod<void>('clearSession');
      } catch (_) {
        // 清理失败不影响上传结果
      }
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

    if (entry.path == '/$_kPrivateDirName') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('隐私目录本身不能执行该操作。')),
      );
      return;
    }

    if (_isPrivatePath(entry.path) &&
        !_privacyActive &&
        action != EntryMenuAction.download) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('隐私窗口已结束，请重新解锁后再操作。')),
      );
      return;
    }

    switch (action) {
      case EntryMenuAction.delete:
        await _deleteEntry(entry);
      case EntryMenuAction.move:
        await _moveEntry(entry);
      case EntryMenuAction.rename:
        await _renameEntry(entry);
      case EntryMenuAction.compress:
        await _compressEntry(entry);
      case EntryMenuAction.download:
        await _downloadEntry(entry);
      case EntryMenuAction.share:
        await _shareEntry(entry);
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

  Future<void> _shareEntry(FileBrowserEntry entry) async {
    if (entry.isDir) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('仅支持分享单个文件。')));
      return;
    }

    final baseUri = _baseUri;
    if (baseUri == null) {
      return;
    }

    const expiryPresets = <(int, String)>[
      (3600, '1 小时'),
      (21600, '6 小时'),
      (86400, '24 小时'),
      (259200, '3 天'),
      (604800, '7 天'),
    ];
    var expirySeconds = 86400;
    final passwordController = TextEditingController();
    final limitController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('分享文件'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                const Text('有效期', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final preset in expiryPresets)
                      ChoiceChip(
                        label: Text(preset.$2),
                        selected: expirySeconds == preset.$1,
                        onSelected: (_) => setDialogState(
                          () => expirySeconds = preset.$1,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  maxLength: 64,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '访问密码（可选）',
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: limitController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '下载次数上限（可选）',
                    helperText: '留空表示不限次数',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('生成链接'),
            ),
          ],
        ),
      ),
    );
    final passwordText = passwordController.text;
    final limitText = limitController.text.trim();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      passwordController.dispose();
      limitController.dispose();
    });

    if (!mounted || confirmed != true) {
      return;
    }

    int? maxDownloads;
    if (limitText.isNotEmpty) {
      maxDownloads = int.tryParse(limitText);
      if (maxDownloads == null || maxDownloads < 1 || maxDownloads > 1000) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('下载次数需为 1~1000 的整数。')),
        );
        return;
      }
    }

    setState(() {
      _busyEntryPath = entry.path;
      _fileError = null;
    });

    try {
      final requestBody = <String, dynamic>{
        'path': entry.path,
        'expiresInSeconds': expirySeconds,
        if (passwordText.isNotEmpty) 'password': passwordText,
        'maxDownloads': ?maxDownloads,
      };
      final response = await _sendTextRequest(
        baseUri.replace(path: '/api/shares'),
        method: 'POST',
        headers: const {'Content-Type': 'application/json'},
        requestBody: jsonEncode(requestBody),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NasApiException(_shareErrorText(response));
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const NasApiException('分享失败：服务端返回格式异常。');
      }
      final payload = Map<String, dynamic>.from(decoded);
      final url = payload['url']?.toString() ?? '';
      if (url.isEmpty) {
        throw const NasApiException('分享失败：服务端未返回链接。');
      }

      if (!mounted) {
        return;
      }

      await _showShareResultDialog(
        url: url,
        expiresAt: DateTime.tryParse(payload['expiresAt']?.toString() ?? ''),
        hasPassword: payload['hasPassword'] == true,
        maxDownloads: payload['maxDownloads'] is num
            ? (payload['maxDownloads'] as num).toInt()
            : null,
      );
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

  Future<void> _showShareResultDialog({
    required String url,
    DateTime? expiresAt,
    required bool hasPassword,
    int? maxDownloads,
  }) async {
    final expiryText = expiresAt == null ? null : _formatShareExpiry(expiresAt);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('分享链接已生成'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('把下面的链接发给对方，无需安装客户端即可打开：'),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF6F8FC),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFE6EAF2)),
                ),
                child: SelectableText(
                  url,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
              ),
              if (expiryText != null) ...[
                const SizedBox(height: 10),
                Text('有效期至 $expiryText', style: const TextStyle(fontSize: 13)),
              ],
              if (hasPassword) ...[
                const SizedBox(height: 4),
                const Text('已设置访问密码。', style: TextStyle(fontSize: 13)),
              ],
              if (maxDownloads != null) ...[
                const SizedBox(height: 4),
                Text(
                  '下载次数上限：$maxDownloads 次',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (!dialogContext.mounted) {
                return;
              }
              Navigator.of(dialogContext).pop();
              if (!mounted) {
                return;
              }
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('链接已复制。')),
              );
            },
            icon: const Icon(Icons.copy_outlined),
            label: const Text('复制链接'),
          ),
        ],
      ),
    );
  }

  String _shareErrorText(SimpleHttpResponse response) {
    String? code;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        code = decoded['error']?.toString();
      }
    } catch (_) {
      // 忽略，使用通用提示
    }

    const messages = <String, String>{
      'invalid_path': '文件路径无效。',
      'directory_not_allowed': '仅支持分享单个文件。',
      'file_not_found': '文件不存在或已被移动。',
      'invalid_expiry': '有效期设置无效。',
      'invalid_password': '密码无效，最多 64 个字符。',
      'invalid_max_downloads': '下载次数需为 1~1000 的整数。',
      'too_many_shares': '分享数量已达上限，请先撤销一些旧分享。',
      'invalid_request': '请求无效，请升级手机端后重试。',
    };
    final message = code == null ? null : messages[code];
    return message ??
        '分享失败（HTTP ${response.statusCode}）。${_compactBody(response.body)}';
  }

  String _formatShareExpiry(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _compressEntry(FileBrowserEntry entry) async {
    final baseUri = _baseUri;
    if (baseUri == null) {
      return;
    }

    var level = 'normal';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('压缩为 ZIP'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (entry.isDir) ...[
                  const SizedBox(height: 6),
                  const Text(
                    '将递归压缩文件夹内所有文件。',
                    style: TextStyle(fontSize: 13),
                  ),
                ],
                const SizedBox(height: 14),
                const Text('压缩级别', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final preset in const <(String, String)>[
                      ('fast', '快速'),
                      ('normal', '标准'),
                      ('smaller', '更小'),
                    ])
                      ChoiceChip(
                        label: Text(preset.$2),
                        selected: level == preset.$1,
                        onSelected: (_) => setDialogState(
                          () => level = preset.$1,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  entry.isDir ? 'ZIP 会生成在当前目录。' : 'ZIP 会生成在同级目录。',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('开始压缩'),
            ),
          ],
        ),
      ),
    );

    if (!mounted || confirmed != true) {
      return;
    }

    setState(() {
      _busyEntryPath = entry.path;
      _fileError = null;
    });

    try {
      final response = await _sendTextRequest(
        baseUri.replace(path: '/api/archive/jobs'),
        method: 'POST',
        headers: const {'Content-Type': 'application/json'},
        requestBody: jsonEncode({'path': entry.path, 'level': level}),
        timeout: const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NasApiException(_archiveErrorText(response));
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const NasApiException('压缩失败：服务端返回格式异常。');
      }
      final jobKey = decoded['key']?.toString() ?? '';
      if (jobKey.isEmpty) {
        throw const NasApiException('压缩失败：服务端未返回任务号。');
      }

      if (!mounted) {
        return;
      }

      final result = await showDialog<_ArchiveJobResult>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => _ArchiveProgressDialog(
          request: (method, path) => _sendTextRequest(
            baseUri.replace(path: path),
            method: method,
          ),
          jobKey: jobKey,
        ),
      );

      if (!mounted || result == null) {
        return;
      }

      switch (result.outcome) {
        case _ArchiveOutcome.ready:
          await _refreshFiles(showLoading: false);
          if (!mounted) {
            return;
          }
          var message = '已生成 ${result.outputName ?? 'ZIP 文件'}';
          if (result.skippedCount > 0) {
            message += '，部分文件被跳过';
          }
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        case _ArchiveOutcome.canceled:
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已取消压缩。')));
        case _ArchiveOutcome.background:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('压缩在后台继续，完成后刷新当前目录即可看到 ZIP。')),
          );
        case _ArchiveOutcome.failed:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.message ?? '压缩失败。')),
          );
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
    } finally {
      if (mounted) {
        setState(() {
          _busyEntryPath = null;
        });
      }
    }
  }

  String _archiveErrorText(SimpleHttpResponse response) {
    String? code;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        code = decoded['error']?.toString();
      }
    } catch (_) {
      // 忽略，使用通用提示
    }

    const messages = <String, String>{
      'invalid_path': '无法压缩该位置。',
      'invalid_level': '压缩级别无效。',
      'source_not_found': '源文件不存在或已被移动。',
      'root_not_allowed': '不能压缩共享根目录。',
      'too_many_files': '文件数量过多，无法压缩。',
      'source_too_large': '源文件总大小超过限制。',
      'nothing_to_archive': '源目录为空，没有可压缩的文件。',
      'archive_queue_full': '压缩任务过多，请稍后再试。',
      'insufficient_disk_space': '磁盘剩余空间不足。',
      'invalid_request': '请求无效，请升级手机端后重试。',
    };
    final message = code == null ? null : messages[code];
    return message ??
        '压缩失败（HTTP ${response.statusCode}）。${_compactBody(response.body)}';
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

    if ((_isPrivatePath(entry.path) || _isPrivatePath(destinationPath)) &&
        !_privacyActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('隐私目录已锁定，请重新解锁后再移动。')),
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
      totalBytes: entry.isDir ? 0 : entry.size,
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
        onBytes: (delta) => _updateTransferTaskBytes(taskId, delta),
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
        title: const Text('移入回收站'),
        content: Text('将 ${entry.name} 移入回收站？之后可在「回收站」中恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移入回收站'),
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
      ).showSnackBar(SnackBar(content: Text('${entry.name} 已移入回收站。')));
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
            authHeaders: _buildNasAuthHeaders,
            // 直连失败时（例如 FLAC）自动改走服务端转码；FLAC 直接转码省一次等待
            transcode: AudioTranscodeSource(
              baseUri: baseUri,
              path: entry.path,
              authToken: token,
              authHeaders: _buildNasAuthHeaders,
              transcodeFirst: entry.name.toLowerCase().endsWith('.flac'),
            ),
          ),
        ),
      );
      return;
    }

    if (entry.isPreviewableVideo) {
      await _openVideoExternally(entry);
      return;
    }

    if (entry.isPreviewableMarkdown) {
      if (entry.size > markdownPreviewMaxBytes) {
        if (!mounted) {
          return;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Markdown 文件超过 2 MB，暂不支持预览，请下载后查看。')),
        );
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => MarkdownPreviewPage(
            title: entry.name,
            loadMarkdown: () async {
              final response = await _sendTextRequest(
                _buildRawResourceUri(baseUri, entry.path),
                headers: {
                  'X-Auth': token,
                  HttpHeaders.acceptHeader:
                      'text/markdown, text/plain;q=0.9, */*;q=0.1',
                },
                timeout: const Duration(seconds: 20),
              );
              if (response.statusCode < 200 || response.statusCode >= 300) {
                throw NasApiException(
                  '读取 Markdown 失败：${response.statusCode}。${_compactBody(response.body)}',
                );
              }
              return response.body;
            },
          ),
        ),
      );
      return;
    }

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('当前支持图片、音频、视频和 Markdown。视频会在浏览器中打开播放。'),
      ),
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

  /// 静默刷新 host 状态（用于"我的"页面进入时拉取最新空间占用）。
  /// 失败不清空已有数据、不弹错误，下次成功时再更新。
  Future<void> _refreshHostStatusSilently() async {
    final baseUri = _baseUri;
    if (baseUri == null) return;
    try {
      final status = await _fetchHostStatus(baseUri);
      if (!mounted) return;
      setState(() => _hostStatus = status);
    } catch (_) {
      // 保持现有数据不变
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
    String resourcePath, {
    bool? includePrivate,
  }) async {
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

      return FileBrowserDirectory.fromJson(
        decoded,
        showPrivateDirectory: includePrivate ?? _privacyActive,
      );
    } on FormatException {
      throw const NasApiException('文件列表接口返回了无法解析的内容。');
    }
  }

  Future<void> _uploadFile(
    Uri baseUri,
    String token,
    String directoryPath,
    PlatformFile file, {
    void Function(int deltaBytes)? onBytes,
  }) async {
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
      Stream<List<int>> wrap(Stream<List<int>> source) {
        if (onBytes == null) return source;
        return source.map((chunk) {
          if (chunk.isNotEmpty) onBytes(chunk.length);
          return chunk;
        });
      }

      if (readStream != null) {
        await request.addStream(wrap(readStream)).timeout(uploadTimeout);
      } else if (file.path != null) {
        await request
            .addStream(wrap(File(file.path!).openRead()))
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
    void Function(int deltaBytes)? onBytes,
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
          onBytes: onBytes,
        );
      }

      return downloadedFiles;
    }

    final localFilePath = _joinLocalPath(localParentDirectory, entry.name);
    await _downloadRemoteFileToLocal(
      baseUri,
      token,
      entry.path,
      localFilePath,
      onBytes: onBytes,
    );
    onFileDownloaded?.call();
    return 1;
  }

  Future<void> _downloadRemoteFileToLocal(
    Uri baseUri,
    String token,
    String resourcePath,
    String localFilePath, {
    void Function(int deltaBytes)? onBytes,
  }) async {
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
      final sink = outputFile.openWrite();
      try {
        await response
            .timeout(const Duration(seconds: 2 * 60))
            .forEach((chunk) {
          sink.add(chunk);
          if (onBytes != null && chunk.isNotEmpty) onBytes(chunk.length);
        });
        await sink.flush();
      } finally {
        await sink.close();
      }
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
    Duration timeout = const Duration(seconds: 8),
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

    final client = HttpClient()..connectionTimeout = timeout;

    try {
      late HttpClientRequest request;
      switch (method) {
        case 'DELETE':
          request = await client.deleteUrl(uri).timeout(timeout);
          break;
        case 'GET':
          request = await client.getUrl(uri).timeout(timeout);
          break;
        default:
          request = await client.openUrl(method, uri).timeout(timeout);
      }

      effectiveHeaders.forEach(request.headers.set);
      if (requestBody != null) {
        final bytes = utf8.encode(requestBody);
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(timeout);
      final responseBody =
          await utf8.decodeStream(response).timeout(timeout);
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
    return _buildEntryThumb(entry, size: 44, radius: 12);
  }

  /// 文件缩略图：图片走 FileBrowser 预览接口，视频走后端 ffmpeg 抽帧，其余显示类型图标。
  /// size 为 null 时填满父容器（格子视图使用）。
  Widget _buildEntryThumb(
    FileBrowserEntry entry, {
    double? size,
    double radius = 12,
  }) {
    final iconSize = size == null ? 32.0 : 20.0;

    Widget iconPlaceholder(
      IconData icon,
      Color background,
      Color foreground,
    ) {
      return Container(
        color: background,
        alignment: Alignment.center,
        child: Icon(icon, color: foreground, size: iconSize),
      );
    }

    final Widget content;
    if (entry.isDir) {
      content = iconPlaceholder(
        Icons.folder_outlined,
        const Color(0xFFD1FAE5),
        const Color(0xFF0F766E),
      );
    } else if (entry.isPreviewableImage &&
        _baseUri != null &&
        _authToken != null) {
      content = Image.network(
        _buildThumbPreviewUri(_baseUri!, entry.path).toString(),
        headers: {'X-Auth': _authToken!},
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => iconPlaceholder(
          Icons.image_outlined,
          const Color(0xFFFFEDD5),
          const Color(0xFFEA580C),
        ),
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
      );
    } else if (entry.isPreviewableVideo && _baseUri != null) {
      content = _NasVideoThumb(path: entry.path, loader: _requestVideoThumb);
    } else if (entry.isPreviewableAudio) {
      content = iconPlaceholder(
        Icons.music_note_outlined,
        const Color(0xFFEEE7FF),
        const Color(0xFF6D28D9),
      );
    } else if (entry.isPreviewableVideo) {
      content = iconPlaceholder(
        Icons.movie_outlined,
        const Color(0xFFE0E7FF),
        const Color(0xFF3730A3),
      );
    } else {
      content = iconPlaceholder(
        Icons.description_outlined,
        const Color(0xFFE0F2FE),
        const Color(0xFF0369A1),
      );
    }

    final thumb = Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(borderRadius: BorderRadius.circular(radius), child: content),
        if (entry.isPreviewableVideo)
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Color(0xCC000000),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.play_arrow_rounded,
                size: size == null ? 18 : 14,
                color: Colors.white,
              ),
            ),
          ),
      ],
    );

    if (size == null) {
      return thumb;
    }
    return SizedBox(width: size, height: size, child: thumb);
  }

  // ── 视频封面缓存与视图模式 ───────────────────────────────────────────────

  static const _kViewModeKey = 'file_view_grid_v1';

  bool _isGridView = false;
  final Map<String, Uint8List?> _videoThumbCache = {};
  final Map<String, Completer<Uint8List?>> _videoThumbWaiters = {};
  final List<String> _videoThumbQueue = [];
  final Set<String> _videoThumbFailed = {};
  int _videoThumbActive = 0;
  static const _kMaxVideoThumbConcurrent = 3;

  Future<void> _loadViewMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getBool(_kViewModeKey);
      if (stored != null && stored != _isGridView && mounted) {
        setState(() => _isGridView = stored);
      }
    } catch (_) {}
  }

  Future<void> _setGridView(bool value) async {
    if (_isGridView == value) {
      return;
    }
    setState(() => _isGridView = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kViewModeKey, value);
    } catch (_) {}
  }

  Uri _buildVideoThumbUri(Uri baseUri, String resourcePath) {
    return baseUri.replace(
      path: '/api/video-thumb',
      queryParameters: {'path': resourcePath},
    );
  }

  /// 排队获取视频封面：并发受控（同时 3 个），但每个请求都会被处理，
  /// 不会出现「先加载几个、剩下的永远不加载」的情况。
  Future<Uint8List?> _requestVideoThumb(String resourcePath) {
    final cached = _videoThumbCache[resourcePath];
    if (cached != null) {
      return Future.value(cached);
    }
    if (_videoThumbFailed.contains(resourcePath) || _baseUri == null) {
      return Future.value(null);
    }

    final pending = _videoThumbWaiters[resourcePath];
    if (pending != null) {
      return pending.future;
    }

    final completer = Completer<Uint8List?>();
    _videoThumbWaiters[resourcePath] = completer;
    _videoThumbQueue.add(resourcePath);
    _pumpVideoThumbQueue();
    return completer.future;
  }

  void _pumpVideoThumbQueue() {
    final visiblePaths = {for (final entry in _entries) entry.path};
    while (_videoThumbActive < _kMaxVideoThumbConcurrent &&
        _videoThumbQueue.isNotEmpty) {
      final resourcePath = _videoThumbQueue.removeAt(0);
      // 已切到别的目录或条目消失，直接跳过，别让旧目录的封面继续占着队列
      if (!visiblePaths.contains(resourcePath)) {
        _videoThumbWaiters.remove(resourcePath)?.complete(null);
        continue;
      }
      _videoThumbActive++;
      unawaited(() async {
        try {
          await _fetchVideoThumb(resourcePath);
        } finally {
          _videoThumbActive--;
          _pumpVideoThumbQueue();
        }
      }());
    }
  }

  Future<void> _fetchVideoThumb(String resourcePath) async {
    final completer = _videoThumbWaiters.remove(resourcePath);
    Uint8List? bytes;
    final baseUri = _baseUri;

    if (baseUri != null) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final headers = await _buildNasAuthHeaders();
        final request = await client
            .getUrl(_buildVideoThumbUri(baseUri, resourcePath))
            .timeout(const Duration(seconds: 10));
        headers.forEach(request.headers.set);
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );

        if (response.statusCode == 200) {
          final builder = BytesBuilder(copy: false);
          await response.forEach(builder.add);
          final data = builder.takeBytes();
          if (data.isNotEmpty && data.length <= 512 * 1024) {
            bytes = data;
          }
        } else if (response.statusCode != 429) {
          _videoThumbFailed.add(resourcePath);
        }
      } catch (_) {
        // 超时或网络抖动不记失败，下次进目录会重新排队
      } finally {
        client.close(force: true);
      }
    }

    if (bytes != null) {
      if (_videoThumbCache.length >= 120) {
        _videoThumbCache.clear();
      }
      _videoThumbCache[resourcePath] = bytes;
    }

    completer?.complete(bytes);
    if (mounted) {
      setState(() {});
    }
  }

  Widget _buildFileGridItem(FileBrowserEntry entry) {
    final isBusy = _busyEntryPath == entry.path;
    final theme = Theme.of(context);

    return InkWell(
      onTap: () => _openEntry(entry),
      onLongPress: () => _showEntryActionsSheet(entry),
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildEntryThumb(entry, radius: 14),
                if (isBusy)
                  Container(
                    color: const Color(0x33000000),
                    alignment: Alignment.center,
                    child: const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            entry.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: const Color(0xFF0F172A),
            ),
          ),
          Text(
            entry.isDir ? '目录' : _formatFileSize(entry.size),
            maxLines: 1,
            style: theme.textTheme.labelSmall?.copyWith(
              color: const Color(0xFF94A3B8),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showEntryActionsSheet(FileBrowserEntry entry) async {
    final action = await showModalBottomSheet<EntryMenuAction>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            for (final item in [
              if (!entry.isDir)
                (EntryMenuAction.download, '下载', Icons.download_outlined),
              if (!entry.isDir)
                (EntryMenuAction.share, '分享', Icons.share_outlined),
              (EntryMenuAction.compress, '压缩', Icons.archive_outlined),
              (EntryMenuAction.move, '移动', Icons.drive_file_move_outline),
              (EntryMenuAction.rename, '重命名', Icons.drive_file_rename_outline),
              (EntryMenuAction.delete, '删除', Icons.delete_outline),
            ])
              ListTile(
                leading: Icon(
                  item.$3,
                  color: item.$1 == EntryMenuAction.delete
                      ? const Color(0xFFB42318)
                      : const Color(0xFF334155),
                ),
                title: Text(
                  item.$2,
                  style: TextStyle(
                    color: item.$1 == EntryMenuAction.delete
                        ? const Color(0xFFB42318)
                        : null,
                  ),
                ),
                onTap: () => Navigator.of(sheetContext).pop(item.$1),
              ),
          ],
        ),
      ),
    );

    if (action != null && mounted) {
      await _handleEntryAction(entry, action);
    }
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
    _syncTransferKeepAlive();
    _showMainShell = false;
    _selectedTab = MainTab.home;
    _selectedSpace = SpaceScope.personal;
  }

  void _returnToConnectionPage() {
    setState(() {
      _showMainShell = false;
    });
    unawaited(_checkHistoryReachability());
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

      final directory = await _fetchDirectory(
        baseUri,
        token,
        normalizedPath,
        includePrivate: false,
      );
      for (final entry in directory.items) {
        if (entry.name == _kPrivateDirName) {
          continue;
        }
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
    if (entry.isDir || _isPrivatePath(entry.path)) {
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
    int totalBytes = 0,
  }) {
    final taskId = '${DateTime.now().microsecondsSinceEpoch}:${entry.path}';
    final task = ActiveTransferTask(
      id: taskId,
      kind: kind,
      entry: entry,
      startedAt: DateTime.now(),
      targetLocation: targetLocation,
      totalBytes: totalBytes,
    );

    _taskMeters[taskId] = _TaskMeter()..total = totalBytes;

    setState(() {
      _activeTransferTasks = [task, ..._activeTransferTasks];
    });
    _syncTransferKeepAlive();

    return taskId;
  }

  /// 有传输任务时启动前台服务，避免息屏后系统省电中断网络。
  void _syncTransferKeepAlive() {
    if (!Platform.isAndroid) {
      return;
    }

    final count = _activeTransferTasks.length;
    try {
      if (count == 0) {
        unawaited(
          _transferServiceChannel
              .invokeMethod<void>('stop')
              .catchError((Object _) {}),
        );
        return;
      }

      final text = count == 1
          ? '正在传输 · ${_activeTransferTasks.first.entry.name}'
          : '正在传输 $count 个任务';
      unawaited(
        _transferServiceChannel
            .invokeMethod<void>('start', {'text': text})
            .catchError((Object _) {}),
      );
    } on MissingPluginException {
      // 旧安装包没有该通道，忽略
    }
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

  /// 累加任务已传输字节，并按节流将进度/速度同步到 UI。
  void _updateTransferTaskBytes(String taskId, int deltaBytes) {
    final meter = _taskMeters[taskId];
    if (meter == null) return;

    meter.transferred += deltaBytes;
    final now = DateTime.now();

    // 速度采样：每 800ms 重采样一次，使用指数加权平滑。
    meter.lastSampleAt ??= now;
    final sampleDtMs = now.difference(meter.lastSampleAt!).inMilliseconds;
    if (sampleDtMs >= 800) {
      final dBytes = meter.transferred - meter.lastSampleBytes;
      final instant = dBytes * 1000.0 / sampleDtMs;
      meter.bytesPerSecond = meter.bytesPerSecond == 0
          ? instant
          : meter.bytesPerSecond * 0.6 + instant * 0.4;
      meter.lastSampleAt = now;
      meter.lastSampleBytes = meter.transferred;
    }

    // UI 节流：≥250ms 或首次更新或已完成时才刷新。
    final ui = meter.lastUiUpdateAt;
    final isComplete = meter.total > 0 && meter.transferred >= meter.total;
    if (ui != null &&
        now.difference(ui).inMilliseconds < 250 &&
        !isComplete) {
      return;
    }
    meter.lastUiUpdateAt = now;

    if (!mounted) return;
    setState(() {
      _activeTransferTasks = _activeTransferTasks
          .map(
            (task) => task.id == taskId
                ? task.copyWith(
                    transferredBytes: meter.transferred,
                    bytesPerSecond: meter.bytesPerSecond,
                  )
                : task,
          )
          .toList(growable: false);
    });
  }

  void _finishTransferTask(String taskId) {
    _taskMeters.remove(taskId);
    if (!mounted) {
      return;
    }

    setState(() {
      _activeTransferTasks = _activeTransferTasks
          .where((task) => task.id != taskId)
          .toList(growable: false);
    });
    _syncTransferKeepAlive();
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

  Future<void> _openTerminalCommandPage() async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先连接电脑。')));
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => TerminalCommandPage(
          baseUri: baseUri,
          authToken: token,
          authHeaders: _buildNasAuthHeaders,
        ),
      ),
    );
  }

  Future<void> _openGomokuToolPage() async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先连接电脑。')));
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => GomokuToolPage(
          baseUri: baseUri,
          authToken: token,
          authHeaders: _buildNasAuthHeaders,
        ),
      ),
    );
  }

  Future<void> _openScreenViewPage({bool monitor = false}) async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先连接电脑。')));
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ScreenViewPage(
          baseUri: baseUri,
          authToken: token,
          authHeaders: _buildNasAuthHeaders,
          monitor: monitor,
        ),
      ),
    );
  }

  void _handleCloudTap() {
    if (_privacyBusy) {
      return;
    }
    if (_privacyActive) {
      unawaited(_exitPrivacyMode(manualExit: true));
      return;
    }
    if (!_hasFileSession) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先连接电脑。')));
      return;
    }

    final now = DateTime.now();
    if (_privacyFirstTapAt == null ||
        now.difference(_privacyFirstTapAt!) > const Duration(seconds: 2)) {
      _privacyTapCount = 0;
    }
    _privacyFirstTapAt = now;
    _privacyTapCount++;
    if (_privacyTapCount >= 5) {
      _privacyTapCount = 0;
      _privacyFirstTapAt = null;
      unawaited(_openPrivacyGate());
    }
  }

  String _privacyCountdownLabel() {
    final until = _privacyUntil;
    if (until == null) {
      return '';
    }
    final seconds = max(0, until.difference(DateTime.now()).inSeconds);
    return '隐私 ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _openPrivacyGate() async {
    final baseUri = _baseUri;
    if (baseUri == null || _privacyBusy) {
      return;
    }

    setState(() {
      _privacyBusy = true;
    });
    try {
      final statusResponse = await _sendTextRequest(
        baseUri.replace(path: '/api/privacy/status'),
      );
      if (statusResponse.statusCode < 200 || statusResponse.statusCode >= 300) {
        throw NasApiException(_privacyErrorText(statusResponse));
      }
      final status = jsonDecode(statusResponse.body);
      final configured = status is Map && status['configured'] == true;

      final credentials = await _askPrivacyPassword(setup: !configured);
      if (!mounted || credentials == null || credentials.isEmpty) {
        return;
      }
      final password = credentials.first;

      if (!configured) {
        final setupResponse = await _sendTextRequest(
          baseUri.replace(path: '/api/privacy/setup'),
          method: 'POST',
          headers: const {'Content-Type': 'application/json'},
          requestBody: jsonEncode({
            'password': password,
            'confirmPassword': credentials.length > 1 ? credentials[1] : '',
          }),
        );
        if (setupResponse.statusCode < 200 || setupResponse.statusCode >= 300) {
          throw NasApiException(_privacyErrorText(setupResponse));
        }
      }

      final unlockResponse = await _sendTextRequest(
        baseUri.replace(path: '/api/privacy/unlock'),
        method: 'POST',
        headers: const {'Content-Type': 'application/json'},
        requestBody: jsonEncode({'password': password}),
      );
      if (unlockResponse.statusCode < 200 || unlockResponse.statusCode >= 300) {
        throw NasApiException(_privacyErrorText(unlockResponse));
      }

      final decoded = jsonDecode(unlockResponse.body);
      final expires = decoded is Map && decoded['expiresInSeconds'] is num
          ? (decoded['expiresInSeconds'] as num).toInt()
          : 180;
      if (!mounted) {
        return;
      }
      await _beginPrivacyWindow(expires);
    } on NasApiException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('隐私操作失败：$error')));
    } finally {
      if (mounted) {
        setState(() {
          _privacyBusy = false;
        });
      }
    }
  }

  Future<List<String>?> _askPrivacyPassword({required bool setup}) async {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    String? error;

    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(setup ? '设置隐私密码' : '进入隐私目录'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  autofocus: true,
                  maxLength: 64,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: setup ? '设置密码' : '输入密码',
                    counterText: '',
                  ),
                ),
                if (setup) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: confirmController,
                    obscureText: true,
                    maxLength: 64,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '再次输入密码',
                      counterText: '',
                    ),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    error!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFB42318),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final password = passwordController.text;
                if (password.length < 6) {
                  setDialogState(() {
                    error = '密码至少 6 个字符。';
                  });
                  return;
                }
                if (setup && password != confirmController.text) {
                  setDialogState(() {
                    error = '两次输入的密码不一致。';
                  });
                  return;
                }
                Navigator.of(dialogContext).pop(
                  setup ? [password, confirmController.text] : [password],
                );
              },
              child: Text(setup ? '设置并进入' : '解锁'),
            ),
          ],
        ),
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      passwordController.dispose();
      confirmController.dispose();
    });
    return result;
  }

  Future<void> _beginPrivacyWindow(int seconds) async {
    final until = DateTime.now().add(Duration(seconds: max(1, seconds)));
    _privacyTimer?.cancel();
    setState(() {
      _privacyUntil = until;
    });
    _privacyTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      if (!_privacyActive) {
        unawaited(_exitPrivacyMode());
      } else {
        setState(() {});
      }
    });

    await _refreshFiles(showLoading: false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '隐私目录已解锁 ${max(1, seconds ~/ 60)} 分钟，点云图标可提前退出。',
          ),
        ),
      );
    }
  }

  Future<void> _exitPrivacyMode({bool manualExit = false}) async {
    _privacyTimer?.cancel();
    _privacyTimer = null;
    final wasInside = _isPrivatePath(_currentDirectory);
    if (mounted) {
      setState(() {
        _privacyUntil = null;
      });
    }
    if (!mounted) {
      return;
    }

    if (wasInside && !manualExit) {
      // 倒计时结束时如果人还在隐私目录里，不强制跳回根目录；
      // 只锁定入口/写操作，等用户自己离开后 .private 自然隐藏。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('隐私窗口已结束，离开当前目录后 .private 会隐藏。'),
          ),
        );
      }
      return;
    }

    if (wasInside) {
      await _refreshFiles(path: '/');
    } else {
      await _refreshFiles(showLoading: false);
    }

    if (manualExit && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已退出隐私目录。')),
      );
    }
  }

  String _privacyErrorText(SimpleHttpResponse response) {
    String? code;
    int? retryAfter;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        code = decoded['error']?.toString();
        retryAfter = decoded['retryAfterSeconds'] is num
            ? (decoded['retryAfterSeconds'] as num).toInt()
            : null;
      }
    } catch (_) {
      // ignore
    }

    switch (code) {
      case 'invalid_password':
        return '密码不正确。';
      case 'locked_out':
        return '尝试次数过多，请 ${retryAfter ?? 60} 秒后再试。';
      case 'not_configured':
        return '还没有设置隐私密码。';
      case 'already_configured':
        return '隐私密码已经设置过了。';
      case 'password_too_short':
        return '密码至少 6 个字符。';
      case 'password_mismatch':
        return '两次输入的密码不一致。';
      case 'privacy_unavailable':
        return '隐私目录暂时不可用。';
      default:
        return '隐私操作失败（HTTP ${response.statusCode}）。'
            '${_compactBody(response.body)}';
    }
  }

  Future<void> _openAgentChatPage() async {
    final baseUri = _baseUri;
    if (baseUri == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先连接电脑。')));
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => AgentChatPage(
          request: (method, path, body, timeout) => _sendTextRequest(
            baseUri.replace(path: path),
            method: method,
            headers: body == null
                ? null
                : const {'Content-Type': 'application/json'},
            requestBody: body,
            timeout: timeout,
          ),
        ),
      ),
    );
  }

  Future<void> _openRecycleBinToolPage() async {
    final baseUri = _baseUri;
    final token = _authToken;
    if (baseUri == null || token == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先连接电脑。')));
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => RecycleBinToolPage(
          baseUri: baseUri,
          token: token,
          request:
              (
                Uri uri, {
                String? method,
                Map<String, String>? headers,
                String? requestBody,
              }) => _sendTextRequest(
                uri,
                method: method ?? 'GET',
                headers: headers,
                requestBody: requestBody,
              ),
        ),
      ),
    );

    if (mounted) {
      await _refreshFiles(showLoading: false);
    }
  }

  Future<void> _openScheduledDownloadToolPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => const ScheduledDownloadToolPage(),
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

  // ---- 云账号功能已停用：_buildCloudSummary ----
//   String _buildCloudSummary() {
//     final session = _cloudSession;
//     if (session == null) {
//       return '查看并连接你的设备';
//     }
//
//     final expiresAt = session.expiresAt?.toLocal();
//     if (expiresAt == null) {
//       return '已登录 ${session.user.username}';
//     }
//
//     final month = expiresAt.month.toString().padLeft(2, '0');
//     final day = expiresAt.day.toString().padLeft(2, '0');
//     final hour = expiresAt.hour.toString().padLeft(2, '0');
//     final minute = expiresAt.minute.toString().padLeft(2, '0');
//     return '已登录 ${session.user.username} · 有效至 $month-$day $hour:$minute';
//   }

  // ---- 云账号功能已停用：_buildCloudAccountCard ----
//   Widget _buildCloudAccountCard(BuildContext context, ThemeData theme) {
//     final metrics = _ConnectionPageMetrics.of(context);
//     final session = _cloudSession;
//     final actionLabel = session == null ? '登录 / 注册' : '切换账号';
//
//     return _buildSectionCard(
//       contextOverride: context,
//       child: Column(
//         crossAxisAlignment: CrossAxisAlignment.start,
//         children: [
//           Row(
//             children: [
//               _buildAccentIconBox(
//                 context,
//                 icon: Icons.lock_rounded,
//                 backgroundColor: const Color(0xFF3B82F6),
//                 foregroundColor: Colors.white,
//               ),
//               SizedBox(width: metrics.inlineSpacing),
//               Expanded(
//                 child: Column(
//                   crossAxisAlignment: CrossAxisAlignment.start,
//                   children: [
//                     Text(
//                       '登录云账号',
//                       style: theme.textTheme.titleMedium?.copyWith(
//                         fontWeight: FontWeight.w700,
//                       ),
//                     ),
//                     Text(
//                       _buildCloudSummary(),
//                       style: theme.textTheme.bodySmall?.copyWith(
//                         color: const Color(0xFF64748B),
//                       ),
//                       maxLines: 1,
//                       overflow: TextOverflow.ellipsis,
//                     ),
//                   ],
//                 ),
//               ),
//               SizedBox(width: metrics.inlineSpacing * 0.5),
//               FilledButton(
//                 onPressed: _showCloudLoginDialog,
//                 style: FilledButton.styleFrom(
//                   padding: EdgeInsets.symmetric(
//                     horizontal: metrics.inlineSpacing,
//                     vertical: metrics.badgeVerticalPadding + 2,
//                   ),
//                   backgroundColor: const Color(0xFF2563EB),
//                   foregroundColor: Colors.white,
//                   shape: RoundedRectangleBorder(
//                     borderRadius: BorderRadius.circular(999),
//                   ),
//                 ),
//                 child: Text(
//                   actionLabel,
//                   style: const TextStyle(
//                       fontSize: 13, fontWeight: FontWeight.w600),
//                 ),
//               ),
//             ],
//           ),
//           SizedBox(height: metrics.sectionSpacing),
//           FittedBox(
//             fit: BoxFit.scaleDown,
//             alignment: Alignment.centerLeft,
//             child: Row(
//               mainAxisSize: MainAxisSize.min,
//               children: [
//                 Icon(Icons.shield_outlined,
//                     size: 14, color: const Color(0xFF3B82F6)),
//                 const SizedBox(width: 4),
//                 Text('点对点传输',
//                     style: TextStyle(
//                         color: const Color(0xFF64748B), fontSize: 13)),
//                 Padding(
//                   padding: const EdgeInsets.symmetric(horizontal: 8),
//                   child: Text('|',
//                       style: TextStyle(
//                           color: const Color(0xFFCBD5E1), fontSize: 13)),
//                 ),
//                 Icon(Icons.sync_rounded,
//                     size: 14, color: const Color(0xFF3B82F6)),
//                 const SizedBox(width: 4),
//                 Text('实时同步地址',
//                     style: TextStyle(
//                         color: const Color(0xFF64748B), fontSize: 13)),
//                 Padding(
//                   padding: const EdgeInsets.symmetric(horizontal: 8),
//                   child: Text('|',
//                       style: TextStyle(
//                           color: const Color(0xFFCBD5E1), fontSize: 13)),
//                 ),
//                 Icon(Icons.devices_outlined,
//                     size: 14, color: const Color(0xFF3B82F6)),
//                 const SizedBox(width: 4),
//                 Text('远程访问',
//                     style: TextStyle(
//                         color: const Color(0xFF64748B), fontSize: 13)),
//               ],
//             ),
//           ),
//         ],
//       ),
//     );
//   }

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
            // 云账号入口已停用：扫码后直接连接设备
            // _buildCloudAccountCard(context, theme),
            // SizedBox(height: metrics.sectionSpacing),
            _buildScanRegisterCard(context, theme),
            SizedBox(height: metrics.sectionSpacing),
            // 自动发现功能尚未接入，先隐藏
            // _buildAutoDiscoveryCard(context, theme),
            // SizedBox(height: metrics.sectionSpacing),
            _buildManualAddressCard(context, theme),
            SizedBox(height: metrics.sectionSpacing),
            _buildEndpointHistoryCard(context, theme),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeHeader(ThemeData theme) {
    // 单行卡片：左侧连接状态云图标，右侧空间切换下拉框（不再显示"我的 NAS"标题）
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFFFFF), Color(0xFFF5FBFA)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(
            color: Color(0x120F172A),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _handleCloudTap,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _privacyActive
                    ? const Color(0xFFFEF3C7)
                    : const Color(0xFFDCFCE7),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _privacyActive
                    ? Icons.lock_open_rounded
                    : Icons.cloud_done_outlined,
                color: _privacyActive
                    ? const Color(0xFFB45309)
                    : const Color(0xFF15803D),
                size: 20,
              ),
            ),
          ),
          if (_privacyActive) ...[
            const SizedBox(width: 8),
            Text(
              _privacyCountdownLabel(),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFFB45309),
              ),
            ),
          ],
          const Spacer(),
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
          const SizedBox(height: 10),
          Row(
            children: [
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: IconButton(
                      onPressed: _hasFileSession
                          ? () => _setGridView(!_isGridView)
                          : null,
                      tooltip: _isGridView ? '切换到列表' : '切换到格子',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        _isGridView
                            ? Icons.view_list_rounded
                            : Icons.grid_view_rounded,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
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
                  const Spacer(),
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
            if (_isGridView)
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.78,
                ),
                itemCount: _entries.length,
                itemBuilder: (context, index) =>
                    _buildFileGridItem(_entries[index]),
              )
            else
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
                          itemBuilder: (context) => [
                            const PopupMenuItem<EntryMenuAction>(
                              value: EntryMenuAction.delete,
                              child: Text('删除'),
                            ),
                            const PopupMenuItem<EntryMenuAction>(
                              value: EntryMenuAction.move,
                              child: Text('移动'),
                            ),
                            const PopupMenuItem<EntryMenuAction>(
                              value: EntryMenuAction.rename,
                              child: Text('重命名'),
                            ),
                            const PopupMenuItem<EntryMenuAction>(
                              value: EntryMenuAction.compress,
                              child: Text('压缩'),
                            ),
                            const PopupMenuItem<EntryMenuAction>(
                              value: EntryMenuAction.download,
                              child: Text('下载'),
                            ),
                            if (!entry.isDir)
                              const PopupMenuItem<EntryMenuAction>(
                                value: EntryMenuAction.share,
                                child: Text('分享'),
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
              case 'uploadFolder':
                _pickAndUploadFolder();
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
              value: 'uploadFolder',
              enabled: !_isUploading && Platform.isAndroid,
              child: Row(
                children: [
                  _isUploading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.drive_folder_upload_outlined, size: 20),
                  const SizedBox(width: 10),
                  Text(_isUploading ? '上传中...' : '上传文件夹'),
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
    final recentVisits = _recentFileVisits
        .where((visit) => !_isPrivatePath(visit.entry.path))
        .toList(growable: false);
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

                      final hasTotal = task.totalBytes > 0;
                      final ratio = hasTotal
                          ? (task.transferredBytes / task.totalBytes)
                              .clamp(0.0, 1.0)
                          : null;
                      final speedText = task.bytesPerSecond > 0
                          ? '${_formatFileSize(task.bytesPerSecond.round())}/s'
                          : '—';
                      final progressText = hasTotal
                          ? '${_formatFileSize(task.transferredBytes)} / ${_formatFileSize(task.totalBytes)} · ${(ratio! * 100).toStringAsFixed(ratio >= 0.1 ? 0 : 1)}%'
                          : '已传输 ${_formatFileSize(task.transferredBytes)}';

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
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: ratio,
                                minHeight: 6,
                                backgroundColor: const Color(0xFFE2E8F0),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    progressText,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: const Color(0xFF334155),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  speedText,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFF334155),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
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
                if (recentVisits.isEmpty)
                  const Text('还没有访问记录。先打开一个文件，最近页就会出现内容。')
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: recentVisits.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final visit = recentVisits[index];
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
            icon: Icons.terminal,
            title: '终端指令',
            subtitle: '在电脑上执行命令，需先在电脑端开启远程终端。',
            backgroundColor: const Color(0xFFF1F5F9),
            foregroundColor: const Color(0xFF334155),
            onTap: _openTerminalCommandPage,
          ),
          const SizedBox(height: 14),
          _ToolLauncherButton(
            icon: Icons.grid_on_outlined,
            title: '五子棋',
            subtitle: '创建房间邀请好友对弈；可设置每步限时，关闭最后一个房间即停止进程。',
            backgroundColor: const Color(0xFFFFF7ED),
            foregroundColor: const Color(0xFF9A3412),
            onTap: _openGomokuToolPage,
          ),
          const SizedBox(height: 14),
          _ToolLauncherButton(
            icon: Icons.monitor_outlined,
            title: '看屏幕',
            subtitle: '查看电脑当前的屏幕画面。',
            backgroundColor: const Color(0xFFE0F2FE),
            foregroundColor: const Color(0xFF075985),
            onTap: () => _openScreenViewPage(),
          ),
          const SizedBox(height: 14),
          _ToolLauncherButton(
            icon: Icons.videocam_outlined,
            title: '监控',
            subtitle: '看摄像头画面、移动侦测持续录像、听现场声音。',
            backgroundColor: const Color(0xFFECFCCB),
            foregroundColor: const Color(0xFF3F6212),
            onTap: () => _openScreenViewPage(monitor: true),
          ),
          const SizedBox(height: 14),
          _ToolLauncherButton(
            icon: Icons.auto_awesome,
            title: 'AI 助手',
            subtitle: '多轮对话完成任务；敏感命令需要你在手机上确认。',
            backgroundColor: const Color(0xFFF5F3FF),
            foregroundColor: const Color(0xFF6D28D9),
            onTap: _openAgentChatPage,
          ),
          const SizedBox(height: 14),
          _ToolLauncherButton(
            icon: Icons.delete_outline,
            title: '回收站',
            subtitle: '删除的文件保留 30 天，期间可恢复，到期自动清理。',
            backgroundColor: const Color(0xFFFEF2F2),
            foregroundColor: const Color(0xFFB91C1C),
            onTap: _openRecycleBinToolPage,
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
    // 云账号已停用，这里显示设备名
    final name = _hostStatus?.hostName.trim();
    if (name == null || name.isEmpty) {
      return '未连接设备';
    }
    return name;
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
          // 云账号停用后，"我的"页顶部账号卡片隐藏
          // Container(
          //   padding: const EdgeInsets.all(20),
          //   ... 账号头像 + _mineDisplayName() + 个人空间 ...
          // ),
          // const SizedBox(height: 16),
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
          final next = MainTab.values[index];
          setState(() {
            _selectedTab = next;
          });
          if (next == MainTab.mine) {
            unawaited(_refreshHostStatusSilently());
          }
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

typedef TrashRequest = Future<SimpleHttpResponse> Function(
  Uri uri, {
  String? method,
  Map<String, String>? headers,
  String? requestBody,
});

class RecycleBinToolPage extends StatefulWidget {
  const RecycleBinToolPage({
    super.key,
    required this.baseUri,
    required this.token,
    required this.request,
  });

  final Uri baseUri;
  final String token;
  final TrashRequest request;

  @override
  State<RecycleBinToolPage> createState() => _RecycleBinToolPageState();
}

class _RecycleBinToolPageState extends State<RecycleBinToolPage> {
  final List<_TrashItem> _items = <_TrashItem>[];
  final Set<String> _busy = <String>{};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Uri _trashUri([String suffix = '']) =>
      widget.baseUri.replace(path: '/api/trash$suffix');

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.request(
        _trashUri(),
        headers: {'X-Auth': widget.token},
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NasApiException('读取回收站失败：${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      final rawItems = (decoded is Map && decoded['items'] is List)
          ? decoded['items'] as List
          : const <dynamic>[];
      final items = rawItems
          .whereType<Map>()
          .map((m) => _TrashItem.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(items);
        _loading = false;
      });
    } on NasApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _restore(_TrashItem item) async {
    if (_busy.contains(item.id)) return;
    setState(() => _busy.add(item.id));
    try {
      final response = await widget.request(
        _trashUri('/restore'),
        method: 'POST',
        headers: {
          'X-Auth': widget.token,
          HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        },
        requestBody: jsonEncode({'id': item.id}),
      );
      if (response.statusCode == 409) {
        throw const NasApiException('原位置已有同名文件，无法恢复。');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NasApiException('恢复失败：${response.statusCode}');
      }
      _toast('${item.name} 已恢复。');
      await _load();
    } on NasApiException catch (error) {
      _toast(error.message);
    } finally {
      if (mounted) setState(() => _busy.remove(item.id));
    }
  }

  Future<void> _purge(_TrashItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('彻底删除'),
        content: Text('将永久删除 ${item.name}，不可恢复。确定吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || _busy.contains(item.id)) return;
    setState(() => _busy.add(item.id));
    try {
      final response = await widget.request(
        _trashUri('/${item.id}'),
        method: 'DELETE',
        headers: {'X-Auth': widget.token},
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NasApiException('删除失败：${response.statusCode}');
      }
      _toast('${item.name} 已彻底删除。');
      await _load();
    } on NasApiException catch (error) {
      _toast(error.message);
    } finally {
      if (mounted) setState(() => _busy.remove(item.id));
    }
  }

  Future<void> _emptyAll() async {
    if (_items.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空回收站'),
        content: const Text('将永久删除回收站内所有内容，不可恢复。确定吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final response = await widget.request(
        _trashUri(),
        method: 'DELETE',
        headers: {'X-Auth': widget.token},
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NasApiException('清空失败：${response.statusCode}');
      }
      _toast('回收站已清空。');
      await _load();
    } on NasApiException catch (error) {
      _toast(error.message);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('回收站'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
          IconButton(
            onPressed: _items.isEmpty ? null : _emptyAll,
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 44,
                color: Color(0xFFB91C1C),
              ),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_outline, size: 48, color: Color(0xFF94A3B8)),
              SizedBox(height: 12),
              Text('回收站是空的', style: TextStyle(color: Color(0xFF64748B))),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = _items[index];
          final busy = _busy.contains(item.id);
          return ListTile(
            leading: Icon(
              item.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
            ),
            title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '原位置：${item.originalPath}\n'
              '删除于 ${item.deletedAtText}'
              '${item.sizeText.isEmpty ? '' : ' · ${item.sizeText}'}',
              maxLines: 3,
            ),
            isThreeLine: true,
            trailing: busy
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: () => _restore(item),
                        icon: const Icon(Icons.restore_from_trash_outlined),
                        tooltip: '恢复',
                      ),
                      IconButton(
                        onPressed: () => _purge(item),
                        icon: const Icon(Icons.delete_forever_outlined),
                        tooltip: '彻底删除',
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class _TrashItem {
  const _TrashItem({
    required this.id,
    required this.name,
    required this.originalPath,
    required this.deletedAt,
    required this.isDir,
    required this.size,
  });

  final String id;
  final String name;
  final String originalPath;
  final DateTime? deletedAt;
  final bool isDir;
  final int? size;

  factory _TrashItem.fromJson(Map<String, dynamic> json) {
    final rawSize = json['size'];
    return _TrashItem(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? '(未命名)'}',
      originalPath: '${json['originalPath'] ?? ''}',
      deletedAt: DateTime.tryParse('${json['deletedAt'] ?? ''}'),
      isDir: json['isDir'] == true,
      size: rawSize is int
          ? rawSize
          : (rawSize is num ? rawSize.toInt() : null),
    );
  }

  String get deletedAtText {
    final value = deletedAt?.toLocal();
    if (value == null) return '—';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  String get sizeText {
    final bytes = size;
    if (bytes == null) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double value = bytes.toDouble();
    int unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return unit == 0
        ? '${value.toInt()} ${units[unit]}'
        : '${value.toStringAsFixed(1)} ${units[unit]}';
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
                // '云账号: $cloudAccountName', // 云账号功能已停用
                '当前电脑: $hostName',
                if (sharedRoot != null && sharedRoot!.isNotEmpty)
                  '共享目录: $sharedRoot',
              ],
            ),
            const SizedBox(height: 16),
            _PlainInfoCard(
              title: '安全说明',
              lines: const [
                '登录状态和电脑地址只保存在手机本机，不依赖云账号。',
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
                              itemBuilder: (context) => [
                                const PopupMenuItem<EntryMenuAction>(
                                  value: EntryMenuAction.delete,
                                  child: Text('删除'),
                                ),
                                const PopupMenuItem<EntryMenuAction>(
                                  value: EntryMenuAction.move,
                                  child: Text('移动'),
                                ),
                                const PopupMenuItem<EntryMenuAction>(
                                  value: EntryMenuAction.rename,
                                  child: Text('重命名'),
                                ),
                                const PopupMenuItem<EntryMenuAction>(
                                  value: EntryMenuAction.compress,
                                  child: Text('压缩'),
                                ),
                                const PopupMenuItem<EntryMenuAction>(
                                  value: EntryMenuAction.download,
                                  child: Text('下载'),
                                ),
                                if (!entry.isDir)
                                  const PopupMenuItem<EntryMenuAction>(
                                    value: EntryMenuAction.share,
                                    child: Text('分享'),
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

/// 视频封面：按需加载，加载中显示转圈，失败回落成影片图标。
/// 并发被限流时 loader 返回 null，这里会短暂重试，避免一屏视频互相挤掉。
class _NasVideoThumb extends StatefulWidget {
  const _NasVideoThumb({required this.path, required this.loader});

  final String path;
  final Future<Uint8List?> Function(String path) loader;

  @override
  State<_NasVideoThumb> createState() => _NasVideoThumbState();
}

class _NasVideoThumbState extends State<_NasVideoThumb> {
  Uint8List? _bytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final data = await widget.loader(widget.path);
    if (!mounted) {
      return;
    }
    setState(() {
      _bytes = data;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
    }

    return Container(
      color: const Color(0xFFE0E7FF),
      alignment: Alignment.center,
      child: _loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.movie_outlined, color: Color(0xFF3730A3)),
    );
  }
}

class _EndpointRecord {
  _EndpointRecord({
    required this.host,
    required this.isLan,
    this.lastSuccess,
  });

  factory _EndpointRecord.fromJson(Map<String, dynamic> json) {
    final ts = json['lastSuccess'];
    return _EndpointRecord(
      host: json['host']?.toString() ?? '',
      isLan: json['isLan'] == true,
      lastSuccess: ts is int ? DateTime.fromMillisecondsSinceEpoch(ts) : null,
    );
  }

  final String host;
  final bool isLan;
  final DateTime? lastSuccess;

  Map<String, dynamic> toJson() => {
        'host': host,
        'isLan': isLan,
        'lastSuccess': lastSuccess?.millisecondsSinceEpoch,
      };
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

  factory FileBrowserDirectory.fromJson(
    Map<String, dynamic> json, {
    bool showPrivateDirectory = false,
  }) {
    final rawItems = json['items'];
    final items = rawItems is List
        ? rawItems
              .whereType<Map>()
              .map(
                (item) =>
                    FileBrowserEntry.fromJson(Map<String, dynamic>.from(item)),
              )
              .where((entry) =>
                  !(entry.isDir &&
                      entry.name.startsWith('.') &&
                      !(showPrivateDirectory &&
                          entry.name == _kPrivateDirName)))
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
  bool get isPreviewableMarkdown => !isDir && isPreviewableMarkdownPath(name);
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          final viewportWidth = constraints.maxWidth;
          final viewportHeight = constraints.maxHeight;

          return InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: SizedBox(
              width: viewportWidth,
              height: viewportHeight,
              child: Image.network(
                imageUri.toString(),
                headers: {'X-Auth': authToken},
                width: viewportWidth,
                height: viewportHeight,
                fit: BoxFit.contain,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) {
                    return child;
                  }

                  return SizedBox(
                    width: viewportWidth,
                    height: viewportHeight,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          '正在加载图片...',
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  );
                },
                errorBuilder: (context, error, stackTrace) {
                  return SizedBox(
                    width: viewportWidth,
                    height: viewportHeight,
                    child: Padding(
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
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(color: Colors.white),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class MarkdownPreviewPage extends StatefulWidget {
  const MarkdownPreviewPage({
    required this.title,
    required this.loadMarkdown,
    super.key,
  });

  final String title;
  final Future<String> Function() loadMarkdown;

  @override
  State<MarkdownPreviewPage> createState() => _MarkdownPreviewPageState();
}

class _MarkdownPreviewPageState extends State<MarkdownPreviewPage> {
  static const _tooLargeMessage = 'Markdown 文件超过 2 MB，暂不支持预览，请下载后查看。';

  String? _content;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      var text = await widget.loadMarkdown();
      if (!mounted) {
        return;
      }
      if (text.startsWith('\uFEFF')) {
        text = text.substring(1);
      }
      if (text.length > markdownPreviewMaxBytes) {
        throw const NasApiException(_tooLargeMessage);
      }
      setState(() {
        _content = text;
        _loading = false;
      });
    } on NasApiException catch (error) {
      _showError(error.message);
    } on FormatException {
      _showError('文件不是有效的 UTF-8 文本，可能为 GBK 编码。');
    } catch (error) {
      _showError('读取 Markdown 失败：$error');
    }
  }

  void _showError(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _content = null;
      _error = message;
      _loading = false;
    });
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(
              '正在读取 Markdown...',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF64748B),
              ),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.description_outlined,
                size: 52,
                color: Color(0xFF94A3B8),
              ),
              const SizedBox(height: 14),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFB42318),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final content = _content ?? '';
    if (content.trim().isEmpty) {
      return Center(
        child: Text(
          '文件为空。',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: const Color(0xFF64748B),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: MarkdownBody(
        data: content,
        selectable: true,
        softLineBreak: true,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        styleSheet: buildNasMarkdownStyle(context),
        onTapLink: (text, href, title) async {
          final uri = href == null ? null : Uri.tryParse(href);
          final scheme = uri?.scheme.toLowerCase();
          if (uri != null &&
              (scheme == 'http' || scheme == 'https' || scheme == 'mailto')) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
            return;
          }
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('暂不支持打开该链接。')));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody(theme)),
    );
  }
}

MarkdownStyleSheet buildNasMarkdownStyle(BuildContext context) {
  final base = MarkdownStyleSheet.fromTheme(Theme.of(context));
  return base.copyWith(
    p: const TextStyle(fontSize: 14, height: 1.55),
    h1: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, height: 1.4),
    h2: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, height: 1.4),
    h3: const TextStyle(
      fontSize: 15.5,
      fontWeight: FontWeight.w600,
      height: 1.4,
    ),
    code: const TextStyle(
      fontFamily: 'monospace',
      fontSize: 12.5,
      backgroundColor: Color(0xFFF1F5F9),
    ),
    codeblockDecoration: BoxDecoration(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFE2E8F0)),
    ),
    codeblockPadding: const EdgeInsets.all(10),
    blockquoteDecoration: BoxDecoration(
      color: const Color(0xFFF8FAFC),
      border: const Border(
        left: BorderSide(color: Color(0xFF6D28D9), width: 3),
      ),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
    tableBorder: TableBorder.all(color: const Color(0xFFE2E8F0)),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    tableHead: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
    tableBody: const TextStyle(fontSize: 12.5, height: 1.4),
    horizontalRuleDecoration: const BoxDecoration(
      border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
    ),
  );
}

/// 清晰度档：直接暴露参数，不做"高清/流畅"之类命名。
class _ScreenQuality {
  const _ScreenQuality(this.width, this.quality, this.format);

  final int width;
  final int quality;
  final String format;

  String get label => format == 'png' ? 'PNG $width' : '$width q$quality';
  String get key => '$width-$quality-$format';
}

const List<_ScreenQuality> _screenQualities = [
  _ScreenQuality(1920, 85, 'jpeg'),
  _ScreenQuality(1920, 60, 'jpeg'),
  _ScreenQuality(1280, 85, 'jpeg'),
  _ScreenQuality(1280, 60, 'jpeg'),
  _ScreenQuality(960, 60, 'jpeg'),
  _ScreenQuality(1920, 60, 'png'),
];

/// 摄像头源档位：电脑端摄像头原生就是 1280x720，再往上没有意义；
/// PNG 对摄像头画面（全是噪点细节）体积暴涨，所以不提供。
const List<_ScreenQuality> _cameraQualities = [
  _ScreenQuality(1280, 85, 'jpeg'),
  _ScreenQuality(1280, 60, 'jpeg'),
  _ScreenQuality(640, 85, 'jpeg'),
  _ScreenQuality(640, 60, 'jpeg'),
  _ScreenQuality(320, 60, 'jpeg'),
];

/// 默认档下标：桌面 1280 q60、摄像头 640 q60（公网带宽也扛得住）。
const int _defaultQualityIndex = 3;

/// 侦测灵敏度：值越低越迟钝（只报大动作），越高越灵敏（也更容易被光线变化误报）。
const List<String> _sensitivityOptions = ['low', 'mid', 'high'];

String _sensitivityLabel(String value) => switch (value) {
  'low' => '低',
  'high' => '高',
  _ => '中',
};

const List<double> _screenFpsOptions = [0, 0.2, 0.5, 1, 2, 5, 10, 15];

/// 看屏幕 / 监控：同一个页面，靠入口决定取哪个源、显示哪些按钮。
class ScreenViewPage extends StatefulWidget {
  const ScreenViewPage({
    required this.baseUri,
    required this.authToken,
    required this.authHeaders,
    this.monitor = false,
    super.key,
  });

  final Uri baseUri;
  final String authToken;
  final Future<Map<String, String>> Function() authHeaders;

  /// true = 摄像头源（监控），false = 桌面源（看屏幕）。
  final bool monitor;

  @override
  State<ScreenViewPage> createState() => _ScreenViewPageState();
}

class _ScreenViewPageState extends State<ScreenViewPage> {
  Uint8List? _frame;
  String? _etag;
  bool _fetching = false;
  bool _failed = false;
  Timer? _timer;
  double _autoFps = 0;
  _ScreenQuality _quality = _screenQualities[_defaultQualityIndex];

  /// 画面缩放/平移状态；放大后靠双指或拖动看细节。
  final TransformationController _transform = TransformationController();

  /// 轮询复用同一个连接池，避免高帧率下反复建连接。
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  /// 全屏横屏模式：隐藏标题栏与系统栏，画面占满整屏。
  bool _immersive = false;

  // ── 以下只在监控（摄像头源）模式下使用 ──────────────────────────────
  /// 电脑端上报的监控状态（侦测开关、是否在录、今日片段数等）。
  Map<String, dynamic>? _monitorStatus;
  Timer? _statusTimer;
  bool _statusBusy = false;
  bool _detectEnabled = false;
  String _sensitivity = 'mid';
  bool _recording = false;
  bool _listening = false;
  String? _listenError;
  final AudioPlayer _listenPlayer = AudioPlayer();
  StreamSubscription<PlayerState>? _listenStateSub;

  List<_ScreenQuality> get _qualities =>
      widget.monitor ? _cameraQualities : _screenQualities;

  String get _qualityPrefsKey =>
      widget.monitor ? 'monitor_view_quality' : 'screen_view_quality';

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    if (widget.monitor) {
      _statusTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _refreshMonitorStatus(),
      );
      // 服务端到点会自己断流，播放器进入 idle/completed 后必须把"听现场"按钮复位，
      // 否则图标一直亮着、也点不回监听状态。
      _listenStateSub = _listenPlayer.playerStateStream.listen((state) {
        if (state.processingState != ProcessingState.idle &&
            state.processingState != ProcessingState.completed) {
          return;
        }
        if (!mounted || !_listening) {
          return;
        }
        setState(() => _listening = false);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _statusTimer?.cancel();
    _listenStateSub?.cancel();
    _client.close(force: true);
    _transform.dispose();
    _listenPlayer.dispose();
    if (_immersive) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  Future<void> _setImmersive(bool value) async {
    if (_immersive == value) {
      return;
    }
    setState(() => _immersive = value);
    if (value) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _resetZoom() {
    _transform.value = Matrix4.identity();
  }

  /// 双击：在"适应屏幕"和"放大 2.5 倍（以点击处为中心）"之间切换。
  void _toggleZoomAt(Offset local) {
    if (_transform.value.getMaxScaleOnAxis() > 1.05) {
      _resetZoom();
      return;
    }
    const scale = 2.5;
    _transform.value = Matrix4.identity()
      ..translateByDouble(local.dx, local.dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1)
      ..translateByDouble(-local.dx, -local.dy, 0, 1);
  }

  Future<void> _loadPrefs() async {
    _quality = _qualities[_defaultQualityIndex];
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_qualityPrefsKey);
      if (saved != null) {
        for (final candidate in _qualities) {
          if (candidate.key == saved) {
            _quality = candidate;
            break;
          }
        }
      }
    } catch (_) {
      // 读取失败就用默认档。
    }
    if (!mounted) {
      return;
    }
    if (widget.monitor) {
      _refreshMonitorStatus();
    }
    await _fetch();
  }

  Future<void> _setQuality(_ScreenQuality quality) async {
    if (quality.key == _quality.key) {
      return;
    }
    setState(() {
      _quality = quality;
      _etag = null;
      _frame = null;
    });
    // 分辨率变了，旧的缩放/平移位置没有意义。
    _resetZoom();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_qualityPrefsKey, quality.key);
    } catch (_) {
      // 持久化失败不影响本次使用。
    }
    await _fetch();
  }

  void _setAutoFps(double fps) {
    _timer?.cancel();
    _timer = null;
    setState(() {
      _autoFps = fps;
    });
    if (fps > 0) {
      // 下限 100ms：公网 0.35MB/s 也喂不动更快，顺手防止误设超高帧率把连接打满。
      final interval = Duration(
        milliseconds: (1000 / fps).round().clamp(100, 60000),
      );
      _timer = Timer.periodic(interval, (_) => _fetch());
      _fetch();
    }
  }

  Future<void> _fetch() async {
    if (_fetching) {
      return;
    }
    _fetching = true;
    if (mounted) {
      setState(() {});
    }

    final client = _client;
    try {
      final headers = await widget.authHeaders();
      headers['X-Auth'] = widget.authToken;
      final request = await client
          .getUrl(
            widget.baseUri.replace(
              path: '/api/system/screen',
              queryParameters: {
                'source': widget.monitor ? 'camera' : 'desktop',
                'w': '${_quality.width}',
                'q': '${_quality.quality}',
                'format': _quality.format,
              },
            ),
          )
          .timeout(const Duration(seconds: 10));
      headers.forEach(request.headers.set);
      final etag = _etag;
      if (etag != null) {
        request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      }

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode == HttpStatus.notModified) {
        await response.drain<void>().catchError((Object _) {});
        if (mounted) {
          setState(() {
            _failed = false;
          });
        }
        return;
      }

      final builder = await response.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (buffer, chunk) {
          buffer.add(chunk);
          return buffer;
        },
      );
      if (response.statusCode != HttpStatus.ok) {
        _markFailed();
        return;
      }

      final data = builder.takeBytes();
      if (data.isEmpty) {
        _markFailed();
        return;
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _frame = data;
        _etag = response.headers.value(HttpHeaders.etagHeader);
        _failed = false;
      });
    } catch (_) {
      _markFailed();
    } finally {
      _fetching = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  /// 取图失败统一处理：不保留旧帧，页面上直接显示"无图"。
  void _markFailed() {
    if (!mounted) {
      return;
    }
    setState(() {
      _frame = null;
      _etag = null;
      _failed = true;
    });
  }

  // ── 监控接口 ──────────────────────────────────────────────────────────

  /// 带签名头的 JSON 请求；失败返回 null，由调用方决定怎么提示。
  Future<Map<String, dynamic>?> _jsonRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    try {
      final headers = await widget.authHeaders();
      headers['X-Auth'] = widget.authToken;
      final request = await _client.openUrl(method, widget.baseUri.replace(path: path))
          .timeout(const Duration(seconds: 10));
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshMonitorStatus() async {
    if (_statusBusy) {
      return;
    }
    _statusBusy = true;
    final status = await _jsonRequest('GET', '/api/monitor/status');
    _statusBusy = false;
    if (!mounted || status == null) {
      return;
    }
    final detect = status['detect'];
    final worker = status['worker'];
    setState(() {
      _monitorStatus = status;
      _detectEnabled = detect is Map && detect['enabled'] == true;
      if (detect is Map && detect['sensitivity'] is String) {
        _sensitivity = detect['sensitivity'] as String;
      }
      _recording = worker is Map && worker['recording'] == true;
    });
  }

  Future<void> _applyDetect(bool enabled, String sensitivity) async {
    setState(() {
      _detectEnabled = enabled;
      _sensitivity = sensitivity;
    });
    await _jsonRequest(
      'POST',
      '/api/monitor/detect',
      body: {'enabled': enabled, 'sensitivity': sensitivity},
    );
    await _refreshMonitorStatus();
  }

  Future<void> _recordNow() async {
    await _jsonRequest('POST', '/api/monitor/record', body: const {});
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已开始录 10 秒，稍后在事件片段里查看。')),
    );
    // 录 10 秒 + 合成编码要十几秒，之后再刷新，避免立刻看到旧状态。
    Future<void>.delayed(const Duration(seconds: 15), () {
      if (mounted) {
        _refreshMonitorStatus();
      }
    });
  }

  /// 听现场：申请一次性票据，把电脑麦克风当流式音频播放。
  Future<void> _toggleListen() async {
    if (_listening) {
      setState(() => _listening = false);
      try {
        await _listenPlayer.stop();
      } catch (_) {}
      return;
    }

    setState(() {
      _listening = true;
      _listenError = null;
    });
    final ticket = await _jsonRequest(
      'POST',
      '/api/monitor/listen-ticket',
      body: const {},
    );
    final path = ticket?['path']?.toString();
    if (path == null || path.isEmpty) {
      setState(() {
        _listening = false;
        _listenError = '听现场不可用';
      });
      return;
    }

    try {
      await _listenPlayer.setAudioSource(
        AudioSource.uri(widget.baseUri.resolve(path)),
      );
      await _listenPlayer.play();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _listening = false;
        _listenError = '音频流打开失败';
      });
    }
  }

  /// 事件片段：走视频中转票据，交给系统播放器打开（与文件页里放视频同一套）。
  Future<void> _openClip(String resourcePath) async {
    final ticket = await _jsonRequest(
      'POST',
      '/api/system/media-tickets',
      body: {'path': resourcePath},
    );
    final url = ticket?['url']?.toString();
    if (url == null || url.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('取片段播放链接失败。')),
        );
      }
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return;
    }
    await launchUrl(
      uri.hasScheme ? uri : widget.baseUri.resolveUri(uri),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _showClipsSheet() async {
    final data = await _jsonRequest('GET', '/api/monitor/clips');
    if (!mounted) {
      return;
    }
    final items = (data?['items'] as List?) ?? const [];
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: items.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('今天还没有事件片段。'),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final item = items[index];
                  final map = item is Map<String, dynamic> ? item : const {};
                  final name = map['name']?.toString() ?? '';
                  final bytes = (map['sizeBytes'] as num?)?.toInt() ?? 0;
                  final modified = map['modifiedAt']?.toString() ?? '';
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.play_circle_outline),
                    title: Text(name),
                    subtitle: Text(
                      '${bytes ~/ 1024}KB  ${modified.substring(0, modified.length.clamp(0, 19)).replaceFirst("T", " ")}',
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      _openClip(map['relativePath']?.toString() ?? name);
                    },
                  );
                },
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_immersive) {
      return Scaffold(
        backgroundColor: const Color(0xFF070B14),
        body: Stack(
          fit: StackFit.expand,
          children: [
            _buildViewer(theme),
            _buildImmersiveBar(theme),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.monitor ? '监控' : '看屏幕'),
        actions: [
          if (widget.monitor)
            IconButton(
              tooltip: '今日事件片段',
              onPressed: _showClipsSheet,
              icon: const Icon(Icons.folder_open),
            ),
          IconButton(
            tooltip: '全屏横屏（可双指放大）',
            onPressed: () => _setImmersive(true),
            icon: const Icon(Icons.fullscreen),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildViewer(theme)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton.filledTonal(
                    tooltip: '刷新',
                    onPressed: _fetching ? null : _fetch,
                    icon: const Icon(Icons.refresh),
                  ),
                  _buildDropdown<double>(
                    label: '自动刷新',
                    value: _autoFps,
                    items: _screenFpsOptions,
                    text: (value) => value == 0 ? '关' : '$value fps',
                    onChanged: _setAutoFps,
                  ),
                  _buildDropdown<_ScreenQuality>(
                    label: '清晰度',
                    value: _quality,
                    items: _qualities,
                    text: (value) => value.label,
                    onChanged: _setQuality,
                  ),
                ],
              ),
            ),
            if (widget.monitor) _buildMonitorBar(theme),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                widget.monitor
                    ? '侦测开着时电脑端会一直采集；画面有动就持续录像，静止 5 秒自动结束（单段最长 60 秒），存进共享目录的「监控录像」，跨天的自动移入回收站。'
                    : '自动刷新只在停留本页时生效，退出即停止；电脑端空闲 60 秒后自动结束抓取。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 监控专属控制条：移动侦测开关、灵敏度、手动录一段、听现场。
  Widget _buildMonitorBar(ThemeData theme) {
    final clips = (_monitorStatus?['clipsToday'] as num?)?.toInt() ?? 0;
    final worker = _monitorStatus?['worker'];
    final eventActive = worker is Map && worker['eventActive'] == true;
    final segmentIndex =
        worker is Map ? (worker['segmentIndex'] as num?)?.toInt() ?? 0 : 0;
    final cameraOn = _monitorStatus?['camera'] is Map &&
        (_monitorStatus!['camera'] as Map)['running'] == true;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('移动侦测', style: TextStyle(fontSize: 13)),
              Switch(
                value: _detectEnabled,
                onChanged: (value) => _applyDetect(value, _sensitivity),
              ),
            ],
          ),
          _buildDropdown<String>(
            label: '灵敏度',
            value: _sensitivity,
            items: _sensitivityOptions,
            text: _sensitivityLabel,
            onChanged: (value) => _applyDetect(_detectEnabled, value),
          ),
          IconButton(
            tooltip: _recording
                ? (eventActive && segmentIndex > 1
                    ? '自动录像中（第 $segmentIndex 段）'
                    : '正在录像…')
                : '手动录 10 秒',
            onPressed: _recording ? null : _recordNow,
            icon: Icon(_recording ? Icons.fiber_manual_record : Icons.videocam),
          ),
          if (_recording)
            Text(
              eventActive && segmentIndex > 0
                  ? '自动录像中 · 第 $segmentIndex 段'
                  : '录像中',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          IconButton(
            tooltip: _listening ? '停止听现场' : '听现场',
            onPressed: _toggleListen,
            style: ButtonStyle(
              backgroundColor: WidgetStatePropertyAll(
                _listening ? const Color(0xFFDCFCE7) : Colors.transparent,
              ),
            ),
            icon: Icon(_listening ? Icons.graphic_eq : Icons.hearing),
          ),
          TextButton.icon(
            onPressed: _showClipsSheet,
            icon: const Icon(Icons.folder_open, size: 18),
            label: Text('今日片段 $clips'),
          ),
          if (_listenError != null)
            Text(
              _listenError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          if (!cameraOn && _monitorStatus != null)
            Text(
              '摄像头未采集',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) text,
    required ValueChanged<T> onChanged,
    bool dark = false,
  }) {
    final color = dark ? const Color(0xFFCBD5E1) : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 13, color: color),
        ),
        const SizedBox(width: 6),
        DropdownButton<T>(
          value: value,
          isDense: true,
          dropdownColor: dark ? const Color(0xFF0B1220) : null,
          style: dark
              ? const TextStyle(fontSize: 13, color: Color(0xFFCBD5E1))
              : null,
          underline: const SizedBox.shrink(),
          items: [
            for (final item in items)
              DropdownMenuItem<T>(value: item, child: Text(text(item))),
          ],
          onChanged: (selected) {
            if (selected != null) {
              onChanged(selected);
            }
          },
        ),
      ],
    );
  }

  Widget _buildViewer(ThemeData theme) {
    final status = _fetching
        ? '抓取中'
        : _failed
        ? '失败'
        : widget.monitor && _recording
        ? '录像中'
        : '';

    return Container(
      width: double.infinity,
      color: const Color(0xFF070B14),
      child: LayoutBuilder(
        builder: (context, box) {
          return Stack(
            fit: StackFit.expand,
            children: [
              if (_frame != null)
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onDoubleTap: () => _toggleZoomAt(
                    Offset(box.maxWidth / 2, box.maxHeight / 2),
                  ),
                  child: InteractiveViewer(
                    transformationController: _transform,
                    minScale: 1.0,
                    maxScale: 8.0,
                    boundaryMargin: const EdgeInsets.all(160),
                    child: Image.memory(
                      _frame!,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  ),
                )
              else
                Center(
                  child: Text(
                    _failed ? '取图失败' : '正在取图…',
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 13,
                    ),
                  ),
                ),
              Positioned(
                top: 8,
                right: 10,
                child: status.isEmpty
                    ? const SizedBox.shrink()
                    : Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x990B1220),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          status,
                          style: const TextStyle(
                            color: Color(0xFFCBD5E1),
                            fontSize: 11,
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 全屏模式下的半透明工具条：退出、刷新、复位缩放 + 两个下拉。
  Widget _buildImmersiveBar(ThemeData theme) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        color: const Color(0xB3070B14),
        padding: const EdgeInsets.fromLTRB(6, 2, 10, 4),
        child: Wrap(
          spacing: 4,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              tooltip: '退出全屏',
              onPressed: () => _setImmersive(false),
              icon: const Icon(
                Icons.fullscreen_exit,
                size: 20,
                color: Color(0xFFCBD5E1),
              ),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: _fetching ? null : _fetch,
              icon: const Icon(
                Icons.refresh,
                size: 20,
                color: Color(0xFFCBD5E1),
              ),
            ),
            IconButton(
              tooltip: '缩放复位（也可双击画面）',
              onPressed: _resetZoom,
              icon: const Icon(
                Icons.zoom_out_map,
                size: 20,
                color: Color(0xFFCBD5E1),
              ),
            ),
            _buildDropdown<double>(
              label: '自动刷新',
              value: _autoFps,
              items: _screenFpsOptions,
              text: (value) => value == 0 ? '关' : '$value fps',
              onChanged: _setAutoFps,
              dark: true,
            ),
            _buildDropdown<_ScreenQuality>(
              label: '清晰度',
              value: _quality,
              items: _screenQualities,
              text: (value) => value.label,
              onChanged: _setQuality,
              dark: true,
            ),
          ],
        ),
      ),
    );
  }
}

/// 终端快捷键：用户自存的"名称 + 命令"，只可删除不可编辑。
class _TerminalQuickCommand {
  const _TerminalQuickCommand({required this.name, required this.command});

  final String name;
  final String command;

  Map<String, dynamic> toJson() => {'name': name, 'command': command};

  static _TerminalQuickCommand? fromJson(Object? raw) {
    if (raw is Map) {
      final name = raw['name']?.toString().trim() ?? '';
      final command = raw['command']?.toString().trim() ?? '';
      if (name.isEmpty || command.isEmpty) {
        return null;
      }
      return _TerminalQuickCommand(name: name, command: command);
    }
    return null;
  }
}

/// 终端指令：把命令发到电脑执行（需先在电脑 /admin 面板开启远程终端）。
class TerminalCommandPage extends StatefulWidget {
  const TerminalCommandPage({
    required this.baseUri,
    required this.authToken,
    required this.authHeaders,
    super.key,
  });

  final Uri baseUri;
  final String authToken;
  final Future<Map<String, String>> Function() authHeaders;

  @override
  State<TerminalCommandPage> createState() => _TerminalCommandPageState();
}

class _TerminalCommandPageState extends State<TerminalCommandPage> {
  static const String _historyPrefsKey = 'terminal_command_history';
  static const int _historyLimit = 50;
  static const String _quickPrefsKey = 'terminal_quick_commands';
  static const int _quickLimit = 50;

  final TextEditingController _commandController = TextEditingController();
  final TextEditingController _quickNameController = TextEditingController();
  bool _isRunning = false;
  bool? _enabled;
  DateTime? _expiresAt;
  String? _error;
  String _output = '';
  int? _exitCode;
  int? _durationMs;
  List<String> _history = [];
  List<_TerminalQuickCommand> _quickCommands = [];

  @override
  void initState() {
    super.initState();
    _commandController.addListener(_onCommandTextChanged);
    _loadStatus();
    _loadHistory();
    _loadQuickCommands();
  }

  void _onCommandTextChanged() {
    // 只为刷新"存为快捷键"图标的可用状态。
    setState(() {});
  }

  @override
  void dispose() {
    _commandController.removeListener(_onCommandTextChanged);
    _commandController.dispose();
    _quickNameController.dispose();
    super.dispose();
  }

  Future<Map<String, String>> _headers() async {
    final headers = await widget.authHeaders();
    headers['X-Auth'] = widget.authToken;
    return headers;
  }

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_historyPrefsKey);
      if (raw == null || !mounted) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        setState(() {
          _history = decoded.whereType<String>().take(_historyLimit).toList();
        });
      }
    } catch (_) {
      // 历史损坏时静默忽略，不影响执行功能。
    }
  }

  Future<void> _recordHistory(String command) async {
    setState(() {
      _history.remove(command);
      _history.insert(0, command);
      if (_history.length > _historyLimit) {
        _history = _history.sublist(0, _historyLimit);
      }
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_historyPrefsKey, jsonEncode(_history));
    } catch (_) {
      // 持久化失败不影响本次执行。
    }
  }

  Future<void> _showHistory() async {
    if (_history.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无历史命令。')));
      return;
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('历史命令'),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _history.length,
            itemBuilder: (context, index) {
              final command = _history[index];
              return ListTile(
                dense: true,
                title: Text(
                  command,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                  ),
                ),
                onTap: () => Navigator.of(dialogContext).pop(command),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (selected != null && mounted) {
      _fillCommand(selected);
    }
  }

  void _fillCommand(String command) {
    setState(() {
      _commandController.text = command;
      _commandController.selection = TextSelection.collapsed(
        offset: command.length,
      );
    });
  }

  Future<void> _loadQuickCommands() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_quickPrefsKey);
      if (raw == null || !mounted) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final items = <_TerminalQuickCommand>[];
        for (final entry in decoded) {
          final item = _TerminalQuickCommand.fromJson(entry);
          if (item != null) {
            items.add(item);
          }
        }
        setState(() {
          _quickCommands = items.take(_quickLimit).toList();
        });
      }
    } catch (_) {
      // 快捷键数据损坏时静默忽略。
    }
  }

  Future<void> _persistQuickCommands() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _quickPrefsKey,
        jsonEncode([for (final item in _quickCommands) item.toJson()]),
      );
    } catch (_) {
      // 持久化失败不影响本次使用。
    }
  }

  Future<void> _saveCurrentAsQuickCommand() async {
    final command = _commandController.text.trim();
    if (command.isEmpty) {
      return;
    }
    await _promptAddQuickCommand(command);
  }

  Future<void> _promptAddQuickCommand(String command) async {
    if (_quickCommands.length >= _quickLimit) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('快捷键已满 $_quickLimit 条，请先删除一些。')),
      );
      return;
    }
    if (_quickCommands.any((item) => item.command == command)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条命令已经在快捷键里了。')));
      return;
    }

    _quickNameController.clear();
    String? errorText;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('添加快捷键'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _quickNameController,
                autofocus: true,
                maxLength: 20,
                decoration: InputDecoration(
                  labelText: '名称（必填）',
                  hintText: '例如：拉起 Qoder',
                  errorText: errorText,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '命令',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: double.maxFinite,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(
                    dialogContext,
                  ).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  command,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final name = _quickNameController.text.trim();
                if (name.isEmpty) {
                  setDialogState(() {
                    errorText = '请输入名称。';
                  });
                  return;
                }
                if (_quickCommands.any((item) => item.name == name)) {
                  setDialogState(() {
                    errorText = '名称已存在，换一个。';
                  });
                  return;
                }
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    final name = _quickNameController.text.trim();
    if (saved != true || name.isEmpty || !mounted) {
      return;
    }
    setState(() {
      _quickCommands.insert(
        0,
        _TerminalQuickCommand(name: name, command: command),
      );
    });
    await _persistQuickCommands();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已添加快捷键「$name」。')));
  }

  Future<void> _showQuickCommands() async {
    if (_quickCommands.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有快捷键：在命令框右侧点书签图标添加。')),
      );
      return;
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('快捷键'),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _quickCommands.length,
              itemBuilder: (context, index) {
                final item = _quickCommands[index];
                return ListTile(
                  dense: true,
                  title: Text(
                    item.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  subtitle: Text(
                    item.command,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  onTap: () => Navigator.of(dialogContext).pop(item.command),
                  trailing: IconButton(
                    tooltip: '删除',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () async {
                      setState(() {
                        _quickCommands.removeAt(index);
                      });
                      await _persistQuickCommands();
                      if (!dialogContext.mounted) {
                        return;
                      }
                      if (_quickCommands.isEmpty) {
                        Navigator.of(dialogContext).pop();
                      } else {
                        setDialogState(() {});
                      }
                    },
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) {
      _fillCommand(selected);
    }
  }

  Future<void> _loadStatus() async {
    try {
      final headers = await _headers();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      try {
        final request = await client
            .getUrl(
              widget.baseUri.replace(path: '/api/system/terminal/status'),
            )
            .timeout(const Duration(seconds: 10));
        headers.forEach(request.headers.set);
        final response = await request.close().timeout(
          const Duration(seconds: 12),
        );
        final body = await utf8.decoder.bind(response).join();
        if (response.statusCode >= 300) {
          throw NasApiException('读取终端状态失败：${response.statusCode}。');
        }

        final data = jsonDecode(body);
        final expiresText = data is Map ? data['expiresAt']?.toString() : null;
        if (!mounted) {
          return;
        }
        setState(() {
          _enabled = data is Map && data['enabled'] == true;
          _expiresAt = expiresText == null
              ? null
              : DateTime.tryParse(expiresText)?.toLocal();
        });
      } finally {
        client.close(force: true);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _enabled = false;
        _error = error is NasApiException
            ? error.message
            : '无法读取终端状态，请确认已连接电脑。';
      });
    }
  }

  Future<void> _runCommand() async {
    if (_isRunning) {
      return;
    }

    final command = _commandController.text.trim();
    if (command.isEmpty) {
      return;
    }

    await _recordHistory(command);
    if (!mounted) {
      return;
    }

    setState(() {
      _isRunning = true;
      _error = null;
      _output = '';
      _exitCode = null;
      _durationMs = null;
    });

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final headers = await _headers();
      final request = await client
          .postUrl(widget.baseUri.replace(path: '/api/system/terminal/exec'))
          .timeout(const Duration(seconds: 10));
      headers.forEach(request.headers.set);
      request.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      final payload = utf8.encode(jsonEncode({'command': command}));
      request.contentLength = payload.length;
      request.add(payload);

      final response = await request.close().timeout(
        const Duration(seconds: 90),
      );
      final body = await utf8.decoder.bind(response).join();

      if (response.statusCode == 404) {
        throw const NasApiException(
          '远程终端没有开启：请在电脑上打开 http://127.0.0.1:5034/admin 开启后重试。',
        );
      }
      if (response.statusCode >= 300) {
        throw NasApiException('执行失败：${response.statusCode}。${body.trim()}');
      }

      final data = jsonDecode(body);
      final stdoutText = data is Map ? (data['stdout']?.toString() ?? '') : '';
      final stderrText = data is Map ? (data['stderr']?.toString() ?? '') : '';
      final timedOut = data is Map && data['timedOut'] == true;
      final exitCode = data is Map ? (data['exitCode'] as num?)?.toInt() : null;
      final durationMs = data is Map
          ? (data['durationMs'] as num?)?.toInt()
          : null;

      final buffer = StringBuffer();
      if (stdoutText.isNotEmpty) {
        buffer.write(stdoutText);
      }
      if (stderrText.isNotEmpty) {
        if (buffer.isNotEmpty) {
          buffer.write('\n');
        }
        buffer.write(stderrText);
      }
      if (buffer.isEmpty) {
        buffer.write('（无输出）');
      }
      if (timedOut) {
        buffer.write('\n…执行超过 30 秒，已被终止。');
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _output = buffer.toString();
        _exitCode = exitCode;
        _durationMs = durationMs;
        _enabled = true;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error is NasApiException ? error.message : '执行失败，请稍后重试。';
      });
    } finally {
      client.close(force: true);
      if (mounted) {
        setState(() {
          _isRunning = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('终端指令')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          children: [
            _buildStatusCard(theme),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _commandController,
                    minLines: 3,
                    maxLines: 6,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13.5,
                    ),
                    decoration: const InputDecoration(
                      labelText: '命令',
                      hintText: '例如：ls -al ~/项目',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '存为快捷键',
                      visualDensity: VisualDensity.compact,
                      onPressed:
                          (_isRunning ||
                              _commandController.text.trim().isEmpty)
                          ? null
                          : _saveCurrentAsQuickCommand,
                      icon: const Icon(Icons.bookmark_add_outlined, size: 22),
                    ),
                    IconButton(
                      tooltip: '清空',
                      visualDensity: VisualDensity.compact,
                      onPressed: _isRunning
                          ? null
                          : () {
                              setState(() {
                                _commandController.clear();
                                _output = '';
                                _exitCode = null;
                                _durationMs = null;
                                _error = null;
                              });
                            },
                      icon: const Icon(Icons.clear_all_outlined, size: 22),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _isRunning ? null : _runCommand,
                  icon: _isRunning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(_isRunning ? '执行中...' : '执行'),
                ),
                OutlinedButton.icon(
                  onPressed: _isRunning ? null : _showHistory,
                  icon: const Icon(Icons.history, size: 18),
                  label: const Text('历史'),
                ),
                OutlinedButton.icon(
                  onPressed: _isRunning ? null : _showQuickCommands,
                  icon: const Icon(Icons.bookmarks_outlined, size: 18),
                  label: const Text('快捷键'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
              ),
            ],
            if (_output.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildOutputCard(theme),
            ],
            const SizedBox(height: 16),
            Text(
              '命令以 kali 身份在电脑上执行，最长 30 秒；可执行程序请自行加 nohup 放后台。'
              '开启状态由电脑 /admin 面板控制，到期自动关闭。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard(ThemeData theme) {
    final enabled = _enabled;
    final text = enabled == null
        ? '正在读取远程终端状态…'
        : enabled
        ? (_expiresAt == null
              ? '远程终端已开启（永久）。'
              : '远程终端已开启，到期时间：${_formatDateTime(_expiresAt!)}。')
        : '远程终端未开启。请在电脑上打开 http://127.0.0.1:5034/admin 开启（可设 30 分钟）。';

    final color = enabled == true
        ? const Color(0xFF047857)
        : enabled == false
        ? const Color(0xFFB45309)
        : theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: enabled == true
            ? const Color(0xFFECFDF5)
            : const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            enabled == true ? Icons.verified_user_outlined : Icons.lock_clock,
            size: 20,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 13, height: 1.5),
            ),
          ),
          IconButton(
            tooltip: '刷新状态',
            onPressed: _isRunning ? null : _loadStatus,
            icon: const Icon(Icons.refresh, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildOutputCard(ThemeData theme) {
    final meta = [
      if (_exitCode != null) '退出码 $_exitCode',
      if (_durationMs != null) '耗时 ${(_durationMs! / 1000).toStringAsFixed(1)} 秒',
    ].join(' · ');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0B1220),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  meta.isEmpty ? '输出' : '输出 · $meta',
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: '复制输出',
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _output));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制输出。')),
                  );
                },
                icon: const Icon(
                  Icons.copy_rounded,
                  size: 16,
                  color: Color(0xFF94A3B8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            _output,
            style: const TextStyle(
              color: Color(0xFFE2E8F0),
              fontFamily: 'monospace',
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDateTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.month)}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
}

/// 音频转码兜底配置：直连播放失败时，请求电脑上的 ffmpeg 转成 MP3 再播。
/// 五子棋房间管理页：创建房间、设置落子超时与有效期、复制链接/二维码、关闭房间。
class GomokuToolPage extends StatefulWidget {
  const GomokuToolPage({
    required this.baseUri,
    required this.authToken,
    required this.authHeaders,
    super.key,
  });

  final Uri baseUri;
  final String authToken;
  final Future<Map<String, String>> Function() authHeaders;

  @override
  State<GomokuToolPage> createState() => _GomokuToolPageState();
}

class _GomokuToolPageState extends State<GomokuToolPage> {
  static const String _appId = 'gomoku';

  final TextEditingController _timeoutController = TextEditingController(
    text: '60',
  );
  final Set<String> _closingTokens = <String>{};

  bool _loading = true;
  bool _creating = false;
  bool _running = false;
  String? _error;
  int _maxRooms = 8;
  int _lifetimeHours = 6;
  int _defaultLifetimeHours = 6;
  int _maxLifetimeHours = 24;
  List<_GomokuRoomInfo> _rooms = const <_GomokuRoomInfo>[];
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _timeoutController.dispose();
    super.dispose();
  }

  Future<Map<String, String>> _authHeaders() async {
    final headers = await widget.authHeaders();
    headers['X-Auth'] = widget.authToken;
    return headers;
  }

  Uri _uri(String path) => widget.baseUri.replace(path: path);

  Future<SimpleHttpResponse> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      late HttpClientRequest request;
      if (method == 'GET') {
        request = await client.getUrl(_uri(path)).timeout(timeout);
      } else if (method == 'DELETE') {
        request = await client.deleteUrl(_uri(path)).timeout(timeout);
      } else {
        request = await client.postUrl(_uri(path)).timeout(timeout);
      }

      final headers = await _authHeaders();
      headers.forEach(request.headers.set);

      if (body != null) {
        request.headers.contentType = ContentType(
          'application',
          'json',
          charset: 'utf-8',
        );
        final payload = utf8.encode(jsonEncode(body));
        request.contentLength = payload.length;
        request.add(payload);
      }

      final response = await request.close().timeout(timeout);
      final responseBody = await utf8
          .decoder
          .bind(response)
          .join()
          .timeout(timeout);
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

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final response = await _request(
        'GET',
        '/api/apps/$_appId/rooms',
        timeout: const Duration(seconds: 12),
      );
      if (response.statusCode >= 300) {
        throw NasApiException(
          response.statusCode == 404
              ? '电脑端还没有启用五子棋应用，请先更新电脑端。'
              : _errorMessage(response.body, '读取房间列表失败。'),
        );
      }

      final decoded = jsonDecode(response.body);
      final data = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
      final rawRooms = data['rooms'];
      final rooms = <_GomokuRoomInfo>[];
      if (rawRooms is List) {
        for (final item in rawRooms) {
          if (item is Map) {
            rooms.add(
              _GomokuRoomInfo.fromJson(Map<String, dynamic>.from(item)),
            );
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
        _running = data['running'] == true;
        _maxRooms = (data['maxRooms'] as num?)?.toInt() ?? 8;
        _defaultLifetimeHours =
            (data['defaultRoomLifetimeHours'] as num?)?.toInt() ?? 6;
        _maxLifetimeHours =
            (data['maxRoomLifetimeHours'] as num?)?.toInt() ?? 24;
        if (_maxLifetimeHours < 1) _maxLifetimeHours = 1;
        if (_lifetimeHours > _maxLifetimeHours) {
          _lifetimeHours = _maxLifetimeHours;
        }
        _rooms = rooms;
      });
    } catch (error) {
      if (!mounted) return;
      if (silent && _rooms.isNotEmpty) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error is NasApiException
            ? error.message
            : '无法读取五子棋房间，请确认已连接电脑。';
      });
    }
  }

  List<int> get _lifetimeChoices {
    final values = <int>{
      1,
      2,
      4,
      6,
      12,
      24,
      _defaultLifetimeHours,
      _maxLifetimeHours,
    }.where((hours) => hours >= 1 && hours <= _maxLifetimeHours).toList()
      ..sort();
    if (values.isEmpty) {
      values.add(1);
    }
    return values;
  }

  Future<void> _createRoom() async {
    if (_creating) return;

    final timeout = int.tryParse(_timeoutController.text.trim());
    if (timeout == null || timeout < 15 || timeout > 600) {
      _showSnack('落子超时时间需在 15–600 秒之间。');
      return;
    }

    setState(() {
      _creating = true;
      _error = null;
    });

    try {
      final response = await _request(
        'POST',
        '/api/apps/$_appId/rooms',
        body: {
          'expiresInSeconds': _lifetimeHours * 3600,
          'options': {'moveTimeoutSeconds': timeout},
        },
        // 首次创建需要启动应用进程，给足启动时间。
        timeout: const Duration(seconds: 50),
      );

      if (response.statusCode >= 300) {
        throw NasApiException(
          _errorMessage(response.body, '创建房间失败（${response.statusCode}）。'),
        );
      }

      final decoded = jsonDecode(response.body);
      final room = _GomokuRoomInfo.fromJson(
        decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : <String, dynamic>{},
      );

      if (!mounted) return;
      await _load(silent: true);
      if (!mounted) return;
      await _showCreatedDialog(room);
    } catch (error) {
      if (!mounted) return;
      _showSnack(
        error is NasApiException ? error.message : '创建房间失败，请稍后重试。',
      );
    } finally {
      if (mounted) {
        setState(() => _creating = false);
      }
    }
  }

  Future<void> _showCreatedDialog(_GomokuRoomInfo room) async {
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('房间已创建'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '先以房主身份进入房间（你执黑），进入后到列表里复制分享链接发给好友。',
              style: TextStyle(height: 1.6),
            ),
            const SizedBox(height: 12),
            SelectableText(
              room.ownerUrl,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 10),
            Text(
              '每步限时 ${_timeoutController.text.trim()} 秒 · 有效期 $_lifetimeHours 小时',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('copy'),
            child: const Text('复制房主链接'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop('open'),
            child: const Text('打开房主链接'),
          ),
        ],
      ),
    );

    if (!mounted || action == null) return;
    if (action == 'copy') {
      await _copyText(room.ownerUrl, '房主链接已复制');
    } else if (action == 'open') {
      await _openUrl(room.ownerUrl);
    }
  }

  Future<void> _closeRoom(_GomokuRoomInfo room) async {
    if (_closingTokens.contains(room.token)) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('关闭房间'),
        content: const Text(
          '关闭后链接立即失效。如果这是最后一个房间，五子棋应用进程也会停止。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('关闭房间'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _closingTokens.add(room.token));
    try {
      final response = await _request(
        'DELETE',
        '/api/apps/$_appId/rooms/${room.token}',
        timeout: const Duration(seconds: 15),
      );
      if (response.statusCode >= 300 && response.statusCode != 404) {
        throw NasApiException(
          _errorMessage(response.body, '关闭房间失败（${response.statusCode}）。'),
        );
      }
      if (!mounted) return;
      _showSnack('房间已关闭');
      await _load(silent: true);
    } catch (error) {
      if (!mounted) return;
      _showSnack(
        error is NasApiException ? error.message : '关闭房间失败，请稍后重试。',
      );
    } finally {
      if (mounted) {
        setState(() => _closingTokens.remove(room.token));
      }
    }
  }

  Future<void> _openRoom(_GomokuRoomInfo room) => _openUrl(room.ownerUrl);

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _showSnack('房间链接无效。');
      return;
    }

    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      _showSnack('无法打开浏览器，请复制链接后手动打开。');
    }
  }

  Future<void> _copyText(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      _showSnack(message);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<Uint8List> _loadQr(String token) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .getUrl(_uri('/api/apps/$_appId/rooms/$token/qr.png'))
          .timeout(const Duration(seconds: 10));
      final headers = await _authHeaders();
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode >= 300) {
        throw NasApiException('二维码加载失败：${response.statusCode}');
      }

      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  void _showQrDialog(_GomokuRoomInfo room) {
    final future = _loadQr(room.token);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('房间二维码'),
        content: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FutureBuilder<Uint8List>(
                future: future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const SizedBox(
                      height: 240,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snapshot.hasError) {
                    return SizedBox(
                      height: 240,
                      child: Center(
                        child: Text(
                          '${snapshot.error}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      snapshot.data!,
                      width: 240,
                      height: 240,
                      filterQuality: FilterQuality.medium,
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              SelectableText(
                room.url,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, height: 1.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  String _errorMessage(String body, String fallback) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final detail = decoded['detail']?.toString().trim();
        if (detail != null && detail.isNotEmpty) {
          return detail;
        }
        final code = decoded['error']?.toString();
        if (code != null && code.isNotEmpty) {
          return switch (code) {
            'too_many_rooms' => '房间数量已达上限，请先关闭一个房间。',
            'invalid_expiry' => '房间有效期不合法。',
            'app_start_failed' => '应用启动失败，请查看电脑端日志。',
            'app_room_create_failed' => '应用拒绝创建房间。',
            'app_not_found' => '电脑端还没有安装五子棋应用。',
            'room_not_found' => '房间不存在或已关闭。',
            _ => '操作失败：$code',
          };
        }
      }
    } catch (_) {
      // 忽略非 JSON 响应
    }
    return fallback;
  }

  String _remainingText(DateTime? expiresAt) {
    if (expiresAt == null) return '有效期未知';
    final remaining = expiresAt.difference(DateTime.now().toUtc());
    if (remaining.isNegative) return '已过期';
    if (remaining.inHours >= 1) {
      return '剩余 ${remaining.inHours} 小时 ${remaining.inMinutes % 60} 分';
    }
    return '剩余 ${remaining.inMinutes} 分';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('五子棋'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : () => _load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 32),
          children: [
            _buildStatusCard(theme, colorScheme),
            const SizedBox(height: 14),
            _buildCreateCard(theme, colorScheme),
            const SizedBox(height: 22),
            Row(
              children: [
                Text(
                  '我的房间',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_rooms.length} / $_maxRooms',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_loading && _rooms.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 36),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null && _rooms.isEmpty)
              _buildErrorCard(theme, colorScheme)
            else if (_rooms.isEmpty)
              _buildEmptyRooms(theme, colorScheme)
            else
              ..._rooms.map((room) => _buildRoomCard(room, theme, colorScheme)),
            const SizedBox(height: 18),
            Text(
              '说明：只有手机端能创建房间；公开链接只用于加入已存在的房间。'
              '关闭最后一个房间会停止五子棋进程，对局结束不会自动停止。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.7,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard(ThemeData theme, ColorScheme colorScheme) {
    final statusColor = _running ? const Color(0xFF1AA268) : colorScheme.outline;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _running ? '五子棋进程运行中' : '五子棋进程未运行',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            _running ? '运行中' : '空闲',
            style: theme.textTheme.bodySmall?.copyWith(
              color: statusColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCreateCard(ThemeData theme, ColorScheme colorScheme) {
    final timeoutText = _timeoutController.text.trim();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '创建房间',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  '每步落子限时',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              SizedBox(
                width: 86,
                child: TextField(
                  controller: _timeoutController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              const Text('秒'),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final seconds in const [30, 60, 120, 300])
                ChoiceChip(
                  label: Text('$seconds 秒'),
                  selected: timeoutText == '$seconds',
                  onSelected: (_) {
                    _timeoutController.text = '$seconds';
                    setState(() {});
                  },
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text('房间有效期', style: theme.textTheme.bodyMedium),
              ),
              DropdownButton<int>(
                value: _lifetimeChoices.contains(_lifetimeHours)
                    ? _lifetimeHours
                    : _lifetimeChoices.first,
                underline: const SizedBox.shrink(),
                items: [
                  for (final hours in _lifetimeChoices)
                    DropdownMenuItem(value: hours, child: Text('$hours 小时')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _lifetimeHours = value);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _creating ? null : _createRoom,
              icon: _creating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_circle_outline),
              label: Text(_creating ? '正在启动应用…' : '创建房间'),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '首次创建会启动五子棋进程，可能需要几秒。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard(ThemeData theme, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _error!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => _load(),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyRooms(ThemeData theme, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 28),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(
            Icons.grid_on_outlined,
            size: 34,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 10),
          Text(
            '还没有房间',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '创建后把链接发给好友，对方打开即可加入。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoomCard(
    _GomokuRoomInfo room,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final closing = _closingTokens.contains(room.token);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.meeting_room_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '房间 ${room.shortToken}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                closing ? '正在关闭…' : _remainingText(room.expiresAt),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            room.url,
            maxLines: 1,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 2,
            children: [
              TextButton.icon(
                onPressed: closing
                    ? null
                    : () => _copyText(room.url, '房间链接已复制'),
                icon: const Icon(Icons.copy, size: 17),
                label: const Text('复制链接'),
              ),
              TextButton.icon(
                onPressed: closing ? null : () => _openRoom(room),
                icon: const Icon(Icons.open_in_new, size: 17),
                label: const Text('打开'),
              ),
              TextButton.icon(
                onPressed: closing ? null : () => _showQrDialog(room),
                icon: const Icon(Icons.qr_code_2, size: 18),
                label: const Text('二维码'),
              ),
              TextButton.icon(
                onPressed: closing ? null : () => _closeRoom(room),
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.error,
                ),
                icon: const Icon(Icons.delete_outline, size: 17),
                label: Text(closing ? '关闭中…' : '关闭房间'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GomokuRoomInfo {
  const _GomokuRoomInfo({
    required this.token,
    required this.url,
    required this.ownerUrl,
    required this.expiresAt,
  });

  factory _GomokuRoomInfo.fromJson(Map<String, dynamic> json) {
    final token = json['token']?.toString() ?? '';
    final url = json['url']?.toString() ?? '';
    final ownerUrl = json['ownerUrl']?.toString() ?? url;
    final expiresText = json['expiresAt']?.toString();
    return _GomokuRoomInfo(
      token: token,
      url: url,
      ownerUrl: ownerUrl,
      expiresAt: expiresText == null ? null : DateTime.tryParse(expiresText),
    );
  }

  final String token;
  final String url;
  final String ownerUrl;
  final DateTime? expiresAt;

  String get shortToken => token.length <= 6
      ? token.toUpperCase()
      : token.substring(0, 6).toUpperCase();
}

String lyricsKeyFromFileName(String fileName) {
  var key = fileName;
  final dot = key.lastIndexOf('.');
  if (dot > 0) {
    key = key.substring(0, dot);
  }
  key = key.replaceFirst(RegExp(r'^\s*\d{1,3}\s*[-._]\s+'), '');
  key = key.replaceFirst(RegExp(r'^\s*\d{2,3}\s+'), '');
  key = key.replaceAll(RegExp(r'[/\\\x00]'), '_').trim();
  return key.isEmpty ? '未命名' : key;
}

String lyricsResourcePath(String fileName) =>
    '/音乐播放器/lyrics/${lyricsKeyFromFileName(fileName)}.lrc';

class LyricLine {
  const LyricLine(this.time, this.text);

  final Duration time;
  final String text;
}

final RegExp _lrcTimePattern = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');

List<LyricLine> parseLyrics(String text) {
  final offsetMatch = RegExp(
    r'\[offset:([+-]?\d+)\]',
    caseSensitive: false,
  ).firstMatch(text);
  final offsetMs = int.tryParse(offsetMatch?.group(1) ?? '') ?? 0;
  final timed = <LyricLine>[];
  var hasTimedLines = false;

  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final matches = _lrcTimePattern.allMatches(raw).toList();
    final clean = raw.replaceAll(_lrcTimePattern, '').trim();
    if (clean.isEmpty ||
        RegExp(r'^\[[a-zA-Z]+:[^\]]*\]$').hasMatch(clean)) {
      continue;
    }
    if (matches.isEmpty) {
      continue;
    }

    hasTimedLines = true;
    for (final match in matches) {
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final fraction = (match.group(3) ?? '0').padRight(3, '0').substring(0, 3);
      final millis =
          minutes * 60000 + seconds * 1000 + int.parse(fraction) + offsetMs;
      timed.add(LyricLine(Duration(milliseconds: millis), clean));
    }
  }

  if (!hasTimedLines) {
    final plain = stripLrcForDisplay(text);
    return plain.isEmpty ? const [] : [LyricLine(Duration.zero, plain)];
  }

  timed.sort((left, right) => left.time.compareTo(right.time));
  return timed;
}

String stripLrcForDisplay(String text) {
  final output = <String>[];
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final trimmed = raw.trim();
    if (RegExp(r'^\[[a-zA-Z]+:[^\]]*\]$').hasMatch(trimmed)) {
      continue;
    }
    if (trimmed.isEmpty) {
      if (output.isNotEmpty && output.last.isNotEmpty) {
        output.add('');
      }
      continue;
    }
    final line = trimmed.replaceFirst(
      RegExp(r'^(?:\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\])+'),
      '',
    );
    if (line.trim().isNotEmpty) {
      output.add(line.trimRight());
    }
  }
  while (output.isNotEmpty && output.last.isEmpty) {
    output.removeLast();
  }
  return output.join('\n');
}

class AudioTranscodeSource {
  const AudioTranscodeSource({
    required this.baseUri,
    required this.path,
    required this.authToken,
    required this.authHeaders,
    this.transcodeFirst = false,
  });

  final Uri baseUri;
  final String path;
  final String authToken;
  final Future<Map<String, String>> Function() authHeaders;
  final bool transcodeFirst;
}

class AudioPreviewPage extends StatefulWidget {
  const AudioPreviewPage({
    required this.title,
    required this.audioUri,
    required this.authToken,
    required this.authHeaders,
    this.transcode,
    super.key,
  });

  final String title;
  final Uri audioUri;
  final String authToken;
  final Future<Map<String, String>> Function() authHeaders;
  final AudioTranscodeSource? transcode;

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
  String? _preparingLabel;
  bool _triedTranscode = false;
  String? _lyricsText;
  String? _lyricsError;
  bool _lyricsLoading = true;
  bool _positionRestored = false;

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

    unawaited(
      _initializeAudio().then((_) => _restorePositionFromNas()),
    );
    unawaited(_loadLocalLyrics());
  }

  String get _songKey => lyricsKeyFromFileName(widget.title);

  Future<Map<String, String>> _nasHeaders() async {
    final headers = Map<String, String>.from(await widget.authHeaders());
    headers['X-Auth'] = widget.authToken;
    return headers;
  }

  Uri _nasRawUri(String resourcePath) => widget.audioUri.replace(
    path: '/api/filebrowser/raw${_encodeResourcePath(resourcePath)}',
  );

  Uri _nasResourceUri(String resourcePath) => widget.audioUri.replace(
    path: '/api/filebrowser/resources${_encodeResourcePath(resourcePath)}',
    queryParameters: const {'override': 'true'},
  );

  Future<String?> _readNasText(String resourcePath) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .getUrl(_nasRawUri(resourcePath))
          .timeout(const Duration(seconds: 15));
      (await _nasHeaders()).forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final text = await utf8.decodeStream(response).timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode == 404) {
        return null;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NasApiException('读取共享文件失败：${response.statusCode}。');
      }
      return text;
    } on TimeoutException {
      throw const NasApiException('读取共享文件超时。');
    } on SocketException catch (error) {
      throw NasApiException('无法连接电脑：${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _writeNasText(String resourcePath, String text) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .postUrl(_nasResourceUri(resourcePath))
          .timeout(const Duration(seconds: 15));
      (await _nasHeaders()).forEach(request.headers.set);
      request.headers.contentType = ContentType(
        'text',
        'plain',
        charset: 'utf-8',
      );
      final bytes = utf8.encode(text);
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await utf8.decodeStream(response).timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NasApiException(
          '保存共享文件失败：${response.statusCode}。${_compactAudioErrorBody(body)}',
        );
      }
    } on TimeoutException {
      throw const NasApiException('保存共享文件超时。');
    } on SocketException catch (error) {
      throw NasApiException('无法连接电脑：${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _loadLocalLyrics() async {
    try {
      final existing = await _readNasText(lyricsResourcePath(widget.title));
      if (!mounted) {
        return;
      }
      if (existing != null && existing.trim().isNotEmpty) {
        setState(() {
          _lyricsText = existing;
        });
      }
    } catch (_) {
      // 本地无歌词或读取失败时保留“获取歌词”入口
    } finally {
      if (mounted) {
        setState(() {
          _lyricsLoading = false;
        });
      }
    }
  }

  Future<void> _fetchLyrics() async {
    if (_lyricsLoading) {
      return;
    }
    setState(() {
      _lyricsLoading = true;
      _lyricsError = null;
    });
    try {
      final lyrics = await _fetchLyricsFromLrclib();
      if (!mounted) {
        return;
      }
      setState(() {
        _lyricsText = lyrics;
      });
      try {
        await _writeNasText(lyricsResourcePath(widget.title), lyrics);
      } catch (_) {
        // 歌词可以先展示，写入失败不阻塞
      }
    } on NasApiException catch (error) {
      if (mounted) {
        setState(() {
          _lyricsError = error.message;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _lyricsError = '歌词获取失败：$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _lyricsLoading = false;
        });
      }
    }
  }

  Future<String> _fetchLyricsFromLrclib() async {
    final query = Uri.encodeQueryComponent(_songKey);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .getUrl(Uri.parse('https://lrclib.net/api/search?track_name=$query'))
          .timeout(const Duration(seconds: 15));
      request.headers.set('User-Agent', 'nas-phone/1.0');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final text = await utf8.decodeStream(response).timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NasApiException('歌词服务返回 ${response.statusCode}。');
      }

      final decoded = jsonDecode(text);
      if (decoded is! List) {
        throw const NasApiException('歌词服务返回了无法识别的数据。');
      }

      String? bestLyrics;
      var bestScore = 1 << 30;
      final targetSeconds = _duration.inSeconds;
      for (final item in decoded.whereType<Map>()) {
        final synced = item['syncedLyrics']?.toString().trim() ?? '';
        final plain = item['plainLyrics']?.toString().trim() ?? '';
        final lyrics = synced.isNotEmpty ? synced : plain;
        if (lyrics.isEmpty) {
          continue;
        }

        final track = item['trackName']?.toString() ?? '';
        final duration = (item['duration'] as num?)?.toDouble();
        var score = 0;
        if (track.toLowerCase() != _songKey.toLowerCase()) {
          score += 1000;
        }
        if (synced.isEmpty) {
          score += 100;
        }
        if (duration != null && targetSeconds > 0) {
          score += (duration - targetSeconds).abs().round();
        }
        if (score < bestScore) {
          bestScore = score;
          bestLyrics = lyrics;
        }
      }

      if (bestLyrics == null) {
        throw const NasApiException('没有找到歌词。');
      }
      return bestLyrics;
    } on TimeoutException {
      throw const NasApiException('歌词获取超时，请稍后重试。');
    } on SocketException catch (error) {
      throw NasApiException('歌词获取失败：${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _restorePositionFromNas() async {
    if (_positionRestored || _duration <= Duration.zero) {
      return;
    }
    _positionRestored = true;
    try {
      final text = await _readNasText('/音乐播放器/player.json');
      if (text == null || text.trim().isEmpty) {
        return;
      }
      final data = jsonDecode(text);
      if (data is! Map || data['title']?.toString() != widget.title) {
        return;
      }
      final seconds = (data['position'] as num?)?.toDouble() ?? 0;
      if (seconds <= 1) {
        return;
      }
      final target = Duration(milliseconds: (seconds * 1000).round());
      if (target >= _duration - const Duration(seconds: 2)) {
        return;
      }
      await _player.seek(target);
      if (mounted) {
        setState(() {
          _position = target;
        });
      }
    } catch (_) {
      // 播放数据损坏或不可用时从 0 开始
    }
  }

  Future<void> _savePlayerState() async {
    if (_duration <= Duration.zero) {
      return;
    }
    var position = _position;
    if (position >= _duration - const Duration(seconds: 2)) {
      position = Duration.zero;
    }
    final payload = jsonEncode({
      'title': widget.title,
      'position': position.inMilliseconds / 1000.0,
    });
    try {
      await _writeNasText('/音乐播放器/player.json', payload);
    } catch (_) {
      // 进度保存失败不影响播放
    }
  }

  Future<void> _initializeAudio() async {
    final transcode = widget.transcode;
    if (transcode != null && transcode.transcodeFirst && !_triedTranscode) {
      _triedTranscode = true;
      await _initializeTranscoded();
      return;
    }

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
        _preparingLabel = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      // 直连失败（解码器不认、内容类型被拒等）：改走服务端转码
      if (transcode != null && !_triedTranscode) {
        _triedTranscode = true;
        await _initializeTranscoded();
        return;
      }

      setState(() {
        _isPreparing = false;
        _preparingLabel = null;
        _error = _describeAudioError(error, fallback: '音频加载失败，请稍后重试。');
      });
    }
  }

  /// 请求电脑把当前音频转成 MP3（缓存复用），再播放转码结果。
  Future<void> _initializeTranscoded() async {
    final source = widget.transcode;
    if (source == null) {
      return;
    }

    try {
      if (mounted) {
        setState(() {
          _isPreparing = true;
          _error = null;
          _preparingLabel = '正在转码音频...';
        });
      }

      var data = await _sendTranscodeRequest(
        source,
        '/api/system/audio-transcode',
        body: {'path': source.path},
      );
      var status = data['status']?.toString() ?? 'processing';
      var progress = (data['progress'] as num?)?.toDouble() ?? 0;
      final key = data['key']?.toString();

      var guard = 0;
      while (status == 'processing' && guard < 600) {
        if (!mounted) {
          return;
        }
        setState(() {
          _preparingLabel = progress > 0
              ? '正在转码音频 ${(progress * 100).round()}%'
              : '正在转码音频...';
        });
        await Future.delayed(const Duration(milliseconds: 600));
        final polled = await _sendTranscodeRequest(
          source,
          '/api/system/audio-transcode/status/$key',
        );
        status = polled['status']?.toString() ?? status;
        progress = (polled['progress'] as num?)?.toDouble() ?? progress;
        if (status == 'failed') {
          data = polled;
        }
        guard++;
      }

      if (status != 'ready' || key == null) {
        throw NasApiException('音频转码失败：${data['error'] ?? '未知错误'}');
      }

      final playUri = source.baseUri.replace(
        path:
            '/api/system/audio-cache/$key/${Uri.encodeComponent(widget.title)}',
      );
      final duration = await _player.setUrl(playUri.toString());
      if (!mounted) {
        return;
      }

      setState(() {
        _duration = duration ?? Duration.zero;
        _isPreparing = false;
        _preparingLabel = null;
        _error = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isPreparing = false;
        _preparingLabel = null;
        _error = _describeAudioError(
          error,
          fallback: '音频转码播放失败，请稍后重试。',
        );
      });
    }
  }

  Future<Map<String, dynamic>> _sendTranscodeRequest(
    AudioTranscodeSource source,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);

    try {
      final request = await client
          .openUrl(
            body == null ? 'GET' : 'POST',
            source.baseUri.replace(path: path),
          )
          .timeout(const Duration(seconds: 10));
      final headers = await source.authHeaders();
      headers.forEach(request.headers.set);
      request.headers.set('X-Auth', source.authToken);

      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType(
          'application',
          'json',
          charset: 'utf-8',
        );
        request.contentLength = bytes.length;
        request.add(bytes);
      }

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final text = await utf8.decoder.bind(response).join();
      if (response.statusCode >= 300) {
        throw NasApiException('转码服务返回 ${response.statusCode}。${text.trim()}');
      }

      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      throw const NasApiException('转码服务返回了无法识别的数据。');
    } finally {
      client.close(force: true);
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
        unawaited(_savePlayerState());
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
    unawaited(_savePlayerState());
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
    final statusText =
        _error ??
        (_isPlaying
            ? '正在播放'
            : (_isPreparing
                  ? (_preparingLabel ?? '正在加载音频...')
                  : '已暂停'));
    final statusColor = _error == null
        ? Colors.white.withValues(alpha: 0.82)
        : const Color(0xFFFECACA);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const SizedBox.shrink(),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/images/music_player_background_alt.png',
            fit: BoxFit.cover,
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x66040A07),
                  Color(0x33040A07),
                  Color(0x8C040A07),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
              child: Align(
                alignment: const Alignment(0, -0.1),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0x2A111827),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.2),
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x22000000),
                              blurRadius: 24,
                              offset: Offset(0, 12),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                widget.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                statusText,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: statusColor,
                                ),
                              ),
                              const SizedBox(height: 10),
                              _LyricsPanel(
                                lyrics: _lyricsText,
                                loading: _lyricsLoading,
                                error: _lyricsError,
                                onFetch: _fetchLyrics,
                                position: _position,
                              ),
                              const SizedBox(height: 10),
                              SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor: Colors.white.withValues(
                                    alpha: 0.24,
                                  ),
                                  thumbColor: Colors.white,
                                  overlayColor: Colors.white.withValues(
                                    alpha: 0.16,
                                  ),
                                ),
                                child: Slider(
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
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _formatMediaDuration(effectivePosition),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: 0.88,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    hasKnownDuration
                                        ? _formatMediaDuration(_duration)
                                        : '--:--',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: 0.88,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: IconButton(
                                      tooltip: '播放模式',
                                      onPressed: () {},
                                      icon: const Icon(
                                        Icons.repeat_rounded,
                                        size: 24,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: IconButton(
                                      tooltip: '上一曲',
                                      onPressed: () {},
                                      icon: const Icon(
                                        Icons.skip_previous_rounded,
                                        size: 30,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  SizedBox(
                                    width: 52,
                                    height: 52,
                                    child: IconButton(
                                      tooltip: _isPlaying ? '暂停' : '播放',
                                      onPressed: _error == null && !_isPreparing
                                          ? _togglePlayback
                                          : null,
                                      icon: Icon(
                                        _isPlaying
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        size: 40,
                                        color: _error == null && !_isPreparing
                                            ? Colors.white
                                            : Colors.white54,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: IconButton(
                                      tooltip: '下一曲',
                                      onPressed: () {},
                                      icon: const Icon(
                                        Icons.skip_next_rounded,
                                        size: 30,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  const SizedBox(width: 48, height: 48),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LyricsPanel extends StatefulWidget {
  const _LyricsPanel({
    required this.lyrics,
    required this.loading,
    required this.error,
    required this.onFetch,
    required this.position,
  });

  final String? lyrics;
  final bool loading;
  final String? error;
  final Future<void> Function() onFetch;
  final Duration position;

  @override
  State<_LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<_LyricsPanel> {
  static const double _height = 180;
  static const double _lineExtent = 44;
  final ScrollController _scrollController = ScrollController();
  List<LyricLine> _lines = const [];
  bool _synced = false;
  int _activeIndex = -1;

  @override
  void initState() {
    super.initState();
    _refreshLyrics();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToActive(animate: false);
    });
  }

  @override
  void didUpdateWidget(covariant _LyricsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyrics != widget.lyrics) {
      _refreshLyrics();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToActive(animate: false);
      });
    } else if (oldWidget.position != widget.position) {
      final index = _indexFor(widget.position);
      if (index != _activeIndex) {
        _activeIndex = index;
        _scrollToActive(animate: true);
      }
    }
  }

  void _refreshLyrics() {
    final text = widget.lyrics;
    _lines = text == null ? const [] : parseLyrics(text);
    _synced = _lines.length > 1 ||
        (_lines.isNotEmpty && _lines.first.time > Duration.zero);
    _activeIndex = _indexFor(widget.position);
  }

  int _indexFor(Duration position) {
    if (!_synced || _lines.isEmpty) {
      return -1;
    }
    if (position < _lines.first.time) {
      return -1;
    }
    var index = 0;
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].time <= position) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  void _scrollToActive({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_synced || !_scrollController.hasClients) {
        return;
      }
      final target = (_activeIndex < 0 ? 0.0 : _activeIndex * _lineExtent)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      if (animate) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasLyrics = _lines.isNotEmpty &&
        widget.lyrics != null &&
        widget.lyrics!.trim().isNotEmpty;
    if (!hasLyrics) {
      return _buildPlaceholder();
    }
    if (!_synced) {
      return _buildPlainLyrics();
    }
    return _buildSyncedLyrics();
  }

  Widget _buildPlaceholder() {
    if (widget.loading) {
      return Container(
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text(
              '正在加载歌词...',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
      );
    }

    final error = widget.error;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            error ?? '暂无歌词',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: error == null
                  ? Colors.white54
                  : const Color(0xFFFCA5A5),
            ),
          ),
          SizedBox(
            height: 30,
            child: TextButton(
              onPressed: widget.onFetch,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white.withValues(alpha: 0.88),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: Text(error == null ? '获取歌词' : '重试'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlainLyrics() {
    return Container(
      height: _height,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          _lines.first.text,
          style: TextStyle(
            fontSize: 13.5,
            height: 1.7,
            color: Colors.white.withValues(alpha: 0.82),
          ),
        ),
      ),
    );
  }

  Widget _buildSyncedLyrics() {
    return Container(
      height: _height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView.builder(
        controller: _scrollController,
        itemExtent: _lineExtent,
        padding: const EdgeInsets.symmetric(
          vertical: (_height - _lineExtent) / 2,
        ),
        itemCount: _lines.length,
        itemBuilder: (context, index) {
          final active = index == _activeIndex;
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                _lines[index].text,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: active ? 15 : 13,
                  height: 1.35,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.45),
                ),
              ),
            ),
          );
        },
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
  Key _scannerKey = UniqueKey();

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
          'ip': decoded['ip']?.toString(),
          'lan': decoded['lan']?.toString(),
          'public': decoded['public']?.toString(),
          // 'type': decoded['type']?.toString(), // 云账号功能已停用
          // 'username': decoded['username']?.toString(), // 云账号功能已停用
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
          MobileScanner(
            key: _scannerKey,
            onDetect: _onDetect,
            errorBuilder: (context, error) {
              final detail = error.errorDetails?.message;
              final denied =
                  error.errorCode == MobileScannerErrorCode.permissionDenied;
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline,
                          color: Colors.white70, size: 40),
                      const SizedBox(height: 12),
                      Text(
                        denied ? '相机权限被拒绝' : '相机启动失败',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        denied
                            ? '请到 设置 → 应用 → 千私云 → 权限 → 相机，选择“允许”，然后点重试。'
                            : '错误码：${error.errorCode.name}${detail == null ? '' : '\n$detail'}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () =>
                            setState(() => _scannerKey = UniqueKey()),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
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

const markdownPreviewMaxBytes = 2 * 1024 * 1024;

bool isPreviewableMarkdownPath(String path) {
  final normalized = path.toLowerCase();
  return normalized.endsWith('.md') || normalized.endsWith('.markdown');
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
      normalized.endsWith('.markdown') ||
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

enum _ArchiveOutcome { ready, failed, canceled, background }

class _ArchiveJobResult {
  const _ArchiveJobResult(
    this.outcome, {
    this.outputName,
    this.skippedCount = 0,
    this.message,
  });

  final _ArchiveOutcome outcome;
  final String? outputName;
  final int skippedCount;
  final String? message;
}

String _archiveJobErrorText(String? error) {
  const messages = <String, String>{
    'io_error': '写入 ZIP 时出错，请确认磁盘空间和文件权限。',
    'source_missing': '源文件不存在或已被移动。',
    'archive_failed': '压缩失败，请稍后再试。',
  };
  return messages[error] ?? '压缩失败：${error ?? '未知错误'}';
}

/// 压缩任务进度弹窗：轮询服务端任务状态，可取消或转入后台。
class _ArchiveProgressDialog extends StatefulWidget {
  const _ArchiveProgressDialog({required this.request, required this.jobKey});

  final Future<SimpleHttpResponse> Function(String method, String path) request;
  final String jobKey;

  @override
  State<_ArchiveProgressDialog> createState() => _ArchiveProgressDialogState();
}

class _ArchiveProgressDialogState extends State<_ArchiveProgressDialog> {
  Timer? _timer;
  bool _polling = false;
  bool _finished = false;
  String _status = 'queued';
  double _progress = 0;
  String? _statusText;
  int _failures = 0;

  @override
  void initState() {
    super.initState();
    _poll();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(milliseconds: 600),
      (_) => _poll(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling || _finished || !mounted) {
      return;
    }

    _polling = true;
    try {
      final response = await widget.request(
        'GET',
        '/api/archive/jobs/${widget.jobKey}',
      );
      if (!mounted || _finished) {
        return;
      }

      if (response.statusCode == 404) {
        _finish(
          const _ArchiveJobResult(
            _ArchiveOutcome.failed,
            message: '压缩任务不存在，服务可能已重启。',
          ),
        );
        return;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NasApiException('压缩状态查询失败（HTTP ${response.statusCode}）。');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const NasApiException('压缩状态返回格式异常。');
      }

      final data = Map<String, dynamic>.from(decoded);
      final status = data['status']?.toString() ?? '';
      final progress = data['progress'] is num
          ? (data['progress'] as num).toDouble()
          : 0.0;
      _failures = 0;

      switch (status) {
        case 'queued':
          setState(() {
            _status = status;
            _progress = 0;
            _statusText = '排队中…';
          });
        case 'processing':
          setState(() {
            _status = status;
            _progress = progress.clamp(0.0, 1.0);
            _statusText =
                '正在压缩 ${(progress * 100).clamp(0, 99).round()}%';
          });
        case 'ready':
          _finish(
            _ArchiveJobResult(
              _ArchiveOutcome.ready,
              outputName: data['outputName']?.toString(),
              skippedCount: data['skippedCount'] is num
                  ? (data['skippedCount'] as num).toInt()
                  : 0,
            ),
          );
        case 'canceled':
          _finish(const _ArchiveJobResult(_ArchiveOutcome.canceled));
        case 'failed':
          _finish(
            _ArchiveJobResult(
              _ArchiveOutcome.failed,
              message: _archiveJobErrorText(data['error']?.toString()),
            ),
          );
        default:
          setState(() {
            _statusText = '处理中…';
          });
      }
    } catch (error) {
      _failures++;
      if (!mounted || _finished) {
        return;
      }

      if (_failures >= 5) {
        _finish(
          _ArchiveJobResult(
            _ArchiveOutcome.failed,
            message: error is NasApiException ? error.message : '压缩状态查询失败。',
          ),
        );
      } else {
        setState(() {
          _statusText = '连接中断，重试中…';
        });
      }
    } finally {
      _polling = false;
    }
  }

  void _finish(_ArchiveJobResult result) {
    if (_finished) {
      return;
    }

    _finished = true;
    _timer?.cancel();
    Navigator.of(context).pop(result);
  }

  Future<void> _cancelJob() async {
    if (_finished) {
      return;
    }

    _timer?.cancel();
    try {
      await widget.request(
        'POST',
        '/api/archive/jobs/${widget.jobKey}/cancel',
      );
    } catch (_) {
      if (!mounted || _finished) {
        return;
      }

      // 网络失败时无法确认取消结果，按后台继续处理。
      _finish(const _ArchiveJobResult(_ArchiveOutcome.background));
      return;
    }

    if (!mounted || _finished) {
      return;
    }

    // 取消请求与任务完成可能同时发生：查一次真实状态，
    // 已完成就按 ready 返回，避免误报“已取消”。
    await _poll();
    if (!mounted || _finished) {
      return;
    }

    // 取消还没生效，继续轮询直到状态落定。
    _startTimer();
  }

  @override
  Widget build(BuildContext context) {
    final queued = _status == 'queued';
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('正在压缩'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: queued ? null : _progress),
            const SizedBox(height: 12),
            Text(_statusText ?? (queued ? '排队中…' : '正在压缩…')),
            const SizedBox(height: 6),
            const Text(
              '关闭弹窗不会中断任务，可稍后刷新目录查看。',
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (_finished) {
                return;
              }
              _finished = true;
              _timer?.cancel();
              Navigator.of(context).pop(
                const _ArchiveJobResult(_ArchiveOutcome.background),
              );
            },
            child: const Text('后台继续'),
          ),
          TextButton(
            onPressed: _cancelJob,
            child: const Text(
              '取消压缩',
              style: TextStyle(color: Color(0xFFB42318)),
            ),
          ),
        ],
      ),
    );
  }
}

String _agentCompactBody(String body) {
  final singleLine = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (singleLine.isEmpty) {
    return '';
  }
  return singleLine.length <= 160
      ? singleLine
      : '${singleLine.substring(0, 160)}...';
}

typedef AgentHttpRequest = Future<SimpleHttpResponse> Function(
  String method,
  String path,
  String? jsonBody,
  Duration timeout,
);

class AgentApi {
  AgentApi(this._request);

  final AgentHttpRequest _request;

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Object? body,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final response = await _request(
      method,
      path,
      body == null ? null : jsonEncode(body),
      timeout,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NasApiException(_errorText(response));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw const NasApiException('AI 服务返回格式异常。');
  }

  String _errorText(SimpleHttpResponse response) {
    String? code;
    String? detail;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        code = decoded['error']?.toString();
        detail = decoded['detail']?.toString();
      }
    } catch (_) {
      // ignore
    }

    const messages = <String, String>{
      'model_not_configured': '请先在设置里配置模型与 API Key。',
      'agent_unavailable': 'AI 服务未就绪，请稍后重试或查看电脑端日志。',
      'session_busy': '当前会话正在运行，请先中断或等待完成。',
      'invalid_session': '会话不存在或已失效。',
      'session_not_found': '会话不存在或已失效。',
      'prompt_too_long': '消息太长。',
      'invalid_base_url': 'Base URL 无效。',
      'invalid_model': '模型名称无效。',
      'provider_error': '模型服务连接失败。',
      'approval_expired': '审批已超时。',
      'approval_not_found': '审批请求已失效。',
      'question_not_found': '该问题已失效，请刷新后重试。',
      'question_expired': '问题已超时，请重新提问。',
      'invalid_answer': '回答内容无效。',
      'invalid_form': '问题标识无效。',
    };
    final mapped = code == null ? null : messages[code];
    if (mapped != null) {
      return detail == null || detail.isEmpty ? mapped : '$mapped $detail';
    }

    return 'AI 请求失败（HTTP ${response.statusCode}）。'
        '${_agentCompactBody(response.body)}';
  }

  Future<List<AgentSessionSummary>> listSessions() async {
    final data = await _send('GET', '/api/agent/sessions');
    final raw = data['sessions'];
    if (raw is! List) {
      return [];
    }

    return raw
        .whereType<Map>()
        .map((item) => AgentSessionSummary.fromJson(
              Map<String, dynamic>.from(item),
            ))
        .toList();
  }

  Future<AgentSessionSummary> createSession() async {
    final data = await _send(
      'POST',
      '/api/agent/sessions',
      body: const <String, dynamic>{},
      timeout: const Duration(seconds: 30),
    );
    return AgentSessionSummary(
      id: data['id']?.toString() ?? '',
      title: data['title']?.toString() ?? '新对话',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      active: false,
    );
  }

  Future<AgentSessionDetail> getSession(String id) async {
    final data = await _send(
      'GET',
      '/api/agent/sessions/${Uri.encodeComponent(id)}',
    );
    final sessionRaw = data['session'];
    final session = sessionRaw is Map
        ? AgentSessionSummary.fromJson(
            Map<String, dynamic>.from(sessionRaw),
          )
        : AgentSessionSummary(
            id: id,
            title: '新对话',
            updatedAt: 0,
            active: false,
          );
    final messages = <AgentMessage>[];
    final rawMessages = data['messages'];
    if (rawMessages is List) {
      for (final item in rawMessages.whereType<Map>()) {
        messages.add(AgentMessage.fromJson(
          Map<String, dynamic>.from(item),
        ));
      }
    }

    final pendingRaw = data['pendingApproval'];
    final pending = pendingRaw is Map
        ? AgentPendingApproval.fromJson(
            Map<String, dynamic>.from(pendingRaw),
          )
        : null;
    final questionRaw = data['pendingQuestion'];
    final pendingQuestion = questionRaw is Map
        ? AgentPendingQuestion.fromJson(
            Map<String, dynamic>.from(questionRaw),
          )
        : null;
    return AgentSessionDetail(
      session: session.copyWith(active: session.active),
      messages: messages,
      pendingApproval: pending,
      pendingQuestion: pendingQuestion,
    );
  }

  Future<void> replyQuestion(
    String sessionId,
    String formId,
    Map<String, dynamic> answer,
  ) async {
    await _send(
      'POST',
      '/api/agent/sessions/${Uri.encodeComponent(sessionId)}'
          '/questions/${Uri.encodeComponent(formId)}',
      body: {'answer': answer},
      timeout: const Duration(seconds: 15),
    );
  }

  Future<void> cancelQuestion(String sessionId, String formId) async {
    await _send(
      'DELETE',
      '/api/agent/sessions/${Uri.encodeComponent(sessionId)}'
          '/questions/${Uri.encodeComponent(formId)}',
      timeout: const Duration(seconds: 15),
    );
  }

  Future<void> sendMessage(String id, String text) async {
    await _send(
      'POST',
      '/api/agent/sessions/${Uri.encodeComponent(id)}/messages',
      body: {'text': text},
      timeout: const Duration(seconds: 30),
    );
  }

  Future<void> interrupt(String id) async {
    await _send(
      'POST',
      '/api/agent/sessions/${Uri.encodeComponent(id)}/interrupt',
      body: const <String, dynamic>{},
      timeout: const Duration(seconds: 15),
    );
  }

  Future<void> decideApproval(
    String sessionId,
    String approvalId,
    bool allow,
  ) async {
    await _send(
      'POST',
      '/api/agent/sessions/${Uri.encodeComponent(sessionId)}'
          '/approvals/${Uri.encodeComponent(approvalId)}',
      body: {'decision': allow ? 'allow' : 'deny'},
      timeout: const Duration(seconds: 15),
    );
  }

  Future<bool> getAutonomous() async {
    final data = await _send('GET', '/api/agent/mode');
    return data['autonomous'] == true;
  }

  Future<bool> setAutonomous(bool autonomous) async {
    final data = await _send(
      'PUT',
      '/api/agent/mode',
      body: {'autonomous': autonomous},
      timeout: const Duration(seconds: 15),
    );
    return data['autonomous'] == true;
  }

  Future<AgentModelSettings> getModel() async {
    final data = await _send('GET', '/api/agent/model');
    return AgentModelSettings.fromJson(data);
  }

  Future<AgentModelSettings> saveModel({
    required String providerId,
    required String baseUrl,
    required String model,
    String? apiKey,
    bool clearKey = false,
  }) async {
    final data = await _send(
      'PUT',
      '/api/agent/model',
      body: {
        'providerId': providerId,
        'baseUrl': baseUrl,
        'model': model,
        if (apiKey != null && apiKey.isNotEmpty) 'apiKey': apiKey,
        'clearKey': clearKey,
      },
      timeout: const Duration(seconds: 60),
    );
    return AgentModelSettings.fromJson(data);
  }

  Future<String> testModel() async {
    final data = await _send(
      'POST',
      '/api/agent/model/test',
      body: const <String, dynamic>{},
      timeout: const Duration(seconds: 20),
    );
    final latency = data['latencyMs'];
    return latency is num ? '连接正常（${latency.toInt()} ms）' : '连接正常。';
  }
}

class AgentSessionSummary {
  const AgentSessionSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.active,
  });

  factory AgentSessionSummary.fromJson(Map<String, dynamic> json) {
    return AgentSessionSummary(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '新对话',
      updatedAt: json['updatedAt'] is num
          ? (json['updatedAt'] as num).toInt()
          : 0,
      active: json['active'] == true,
    );
  }

  final String id;
  final String title;
  final int updatedAt;
  final bool active;

  AgentSessionSummary copyWith({String? title, bool? active}) {
    return AgentSessionSummary(
      id: id,
      title: title ?? this.title,
      updatedAt: updatedAt,
      active: active ?? this.active,
    );
  }
}

class AgentToolCall {
  const AgentToolCall({
    required this.name,
    required this.status,
    required this.command,
    required this.output,
  });

  factory AgentToolCall.fromJson(Map<String, dynamic> json) {
    return AgentToolCall(
      name: json['name']?.toString() ?? 'tool',
      status: json['status']?.toString() ?? '',
      command: json['command']?.toString() ?? '',
      output: json['output']?.toString() ?? '',
    );
  }

  final String name;
  final String status;
  final String command;
  final String output;
}

class AgentMessage {
  const AgentMessage({
    required this.id,
    required this.kind,
    required this.text,
    required this.createdAt,
    required this.tools,
  });

  factory AgentMessage.fromJson(Map<String, dynamic> json) {
    final tools = <AgentToolCall>[];
    final rawTools = json['tools'];
    if (rawTools is List) {
      for (final item in rawTools.whereType<Map>()) {
        tools.add(AgentToolCall.fromJson(
          Map<String, dynamic>.from(item),
        ));
      }
    }

    return AgentMessage(
      id: json['id']?.toString() ?? '',
      kind: json['kind']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      createdAt: json['createdAt'] is num
          ? (json['createdAt'] as num).toInt()
          : 0,
      tools: tools,
    );
  }

  final String id;
  final String kind;
  final String text;
  final int createdAt;
  final List<AgentToolCall> tools;

  bool get isUser => kind == 'user';
  bool get isCompaction => kind == 'compaction';
}

class AgentPendingApproval {
  const AgentPendingApproval({
    required this.id,
    required this.command,
    required this.cwd,
    required this.matched,
    required this.expiresAt,
  });

  factory AgentPendingApproval.fromJson(Map<String, dynamic> json) {
    return AgentPendingApproval(
      id: json['id']?.toString() ?? '',
      command: json['command']?.toString() ?? '',
      cwd: json['cwd']?.toString() ?? '',
      matched: json['matched']?.toString(),
      expiresAt: json['expiresAt']?.toString() ?? '',
    );
  }

  final String id;
  final String command;
  final String cwd;
  final String? matched;
  final String expiresAt;
}

class AgentQuestionOption {
  const AgentQuestionOption({
    required this.value,
    required this.label,
    required this.description,
  });

  factory AgentQuestionOption.fromJson(Map<String, dynamic> json) {
    return AgentQuestionOption(
      value: json['value']?.toString() ?? '',
      label: json['label']?.toString() ?? json['value']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
    );
  }

  final String value;
  final String label;
  final String description;
}

class AgentQuestion {
  const AgentQuestion({
    required this.key,
    required this.header,
    required this.question,
    required this.multiple,
    required this.custom,
    required this.required,
    required this.options,
  });

  factory AgentQuestion.fromJson(Map<String, dynamic> json) {
    final options = <AgentQuestionOption>[];
    final rawOptions = json['options'];
    if (rawOptions is List) {
      for (final item in rawOptions.whereType<Map>()) {
        options.add(AgentQuestionOption.fromJson(
          Map<String, dynamic>.from(item),
        ));
      }
    }

    return AgentQuestion(
      key: json['key']?.toString() ?? '',
      header: json['header']?.toString() ?? '',
      question: json['question']?.toString() ?? '',
      multiple: json['multiple'] == true,
      custom: json['custom'] == true,
      required: json['required'] == true,
      options: options,
    );
  }

  final String key;
  final String header;
  final String question;
  final bool multiple;
  final bool custom;
  final bool required;
  final List<AgentQuestionOption> options;
}

class AgentPendingQuestion {
  const AgentPendingQuestion({
    required this.formId,
    required this.title,
    required this.questions,
  });

  factory AgentPendingQuestion.fromJson(Map<String, dynamic> json) {
    final questions = <AgentQuestion>[];
    final rawQuestions = json['questions'];
    if (rawQuestions is List) {
      for (final item in rawQuestions.whereType<Map>()) {
        questions.add(AgentQuestion.fromJson(
          Map<String, dynamic>.from(item),
        ));
      }
    }

    return AgentPendingQuestion(
      formId: json['formId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      questions: questions,
    );
  }

  final String formId;
  final String title;
  final List<AgentQuestion> questions;
}

class AgentSessionDetail {
  const AgentSessionDetail({
    required this.session,
    required this.messages,
    required this.pendingApproval,
    required this.pendingQuestion,
  });

  final AgentSessionSummary session;
  final List<AgentMessage> messages;
  final AgentPendingApproval? pendingApproval;
  final AgentPendingQuestion? pendingQuestion;
}

class AgentModelPreset {
  const AgentModelPreset({
    required this.id,
    required this.display,
    required this.baseUrl,
    required this.models,
  });

  factory AgentModelPreset.fromJson(Map<String, dynamic> json) {
    final models = <String>[];
    final rawModels = json['models'];
    if (rawModels is List) {
      for (final item in rawModels) {
        models.add(item.toString());
      }
    }

    return AgentModelPreset(
      id: json['id']?.toString() ?? '',
      display: json['display']?.toString() ?? '',
      baseUrl: json['baseUrl']?.toString() ?? '',
      models: models,
    );
  }

  final String id;
  final String display;
  final String baseUrl;
  final List<String> models;
}

class AgentModelSettings {
  const AgentModelSettings({
    required this.providerId,
    required this.baseUrl,
    required this.model,
    required this.hasKey,
    required this.keyMasked,
    required this.presets,
  });

  factory AgentModelSettings.fromJson(Map<String, dynamic> json) {
    final presets = <AgentModelPreset>[];
    final rawPresets = json['presets'];
    if (rawPresets is List) {
      for (final item in rawPresets.whereType<Map>()) {
        presets.add(AgentModelPreset.fromJson(
          Map<String, dynamic>.from(item),
        ));
      }
    }

    return AgentModelSettings(
      providerId: json['providerId']?.toString() ?? '',
      baseUrl: json['baseUrl']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      hasKey: json['hasKey'] == true,
      keyMasked: json['keyMasked']?.toString(),
      presets: presets,
    );
  }

  final String providerId;
  final String baseUrl;
  final String model;
  final bool hasKey;
  final String? keyMasked;
  final List<AgentModelPreset> presets;
}

class AgentChatPage extends StatefulWidget {
  const AgentChatPage({required this.request, super.key});

  final AgentHttpRequest request;

  @override
  State<AgentChatPage> createState() => _AgentChatPageState();
}

class _AgentChatPageState extends State<AgentChatPage>
    with WidgetsBindingObserver {
  late final AgentApi _api;
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Timer? _timer;
  List<AgentSessionSummary> _sessions = [];
  List<AgentMessage> _messages = [];
  AgentSessionSummary? _current;
  AgentPendingApproval? _pending;
  AgentPendingQuestion? _pendingQuestion;
  String? _error;
  bool _loading = true;
  bool _polling = false;
  bool _sending = false;
  DateTime? _pollStartedAt;
  DateTime? _sendStartedAt;
  int _pollToken = 0;
  int _sendToken = 0;
  bool _deciding = false;
  bool _answeringQuestion = false;
  bool _modelConfigured = true;
  bool _autonomous = false;
  int _failures = 0;
  int _lastMessageCount = 0;
  final Set<String> _expandedToolBlocks = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = AgentApi(widget.request);
    _bootstrap();
    _startPollingTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _startPollingTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => _poll(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) {
      return;
    }

    final now = DateTime.now();
    if (_sending &&
        (_sendStartedAt == null ||
            now.difference(_sendStartedAt!) > const Duration(seconds: 10))) {
      _sendToken++;
      _sendStartedAt = null;
      setState(() {
        _sending = false;
      });
    }

    _startPollingTimer();
    if (_current == null) {
      _bootstrap();
    } else {
      _poll(force: true);
    }
  }

  Future<void> _bootstrap() async {
    try {
      final model = await _api.getModel();
      _modelConfigured = model.hasKey;
    } catch (_) {
      _modelConfigured = false;
    }

    try {
      _autonomous = await _api.getAutonomous();
    } catch (_) {
      // 保持默认关闭
    }

    try {
      final sessions = await _api.listSessions();
      _sessions = sessions;
      if (sessions.isNotEmpty && mounted) {
        await _selectSession(sessions.first.id);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is NasApiException ? error.message : '$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _poll({bool force = false}) async {
    final current = _current;
    if (current == null) {
      return;
    }

    final now = DateTime.now();
    if (_polling) {
      final startedAt = _pollStartedAt;
      final stale = startedAt != null &&
          now.difference(startedAt) > const Duration(seconds: 12);
      if (!force && !stale) {
        return;
      }
    }

    final token = ++_pollToken;
    _polling = true;
    _pollStartedAt = now;
    try {
      final detail = await _api.getSession(current.id);
      if (!mounted || token != _pollToken) {
        return;
      }

      final messageChanged = detail.messages.length != _lastMessageCount;
      setState(() {
        _current = detail.session;
        _messages = detail.messages;
        _pending = detail.pendingApproval;
        _pendingQuestion = detail.pendingQuestion;
        _lastMessageCount = detail.messages.length;
        _failures = 0;
        _error = null;
      });
      final index = _sessions.indexWhere((item) => item.id == current.id);
      if (index >= 0) {
        _sessions[index] = detail.session;
      }
      if (messageChanged) {
        _scrollToBottom();
      }
    } catch (error) {
      if (token != _pollToken) {
        return;
      }
      _failures++;
      if (mounted && _failures >= 3) {
        setState(() {
          _error = error is NasApiException ? error.message : '$error';
        });
      }
    } finally {
      if (token == _pollToken) {
        _polling = false;
        _pollStartedAt = null;
      }
    }
  }

  Future<void> _refreshChat() async {
    if (_current == null) {
      await _bootstrap();
      return;
    }
    await _poll(force: true);
  }

  Future<void> _selectSession(String id) async {
    setState(() {
      _loading = true;
      _error = null;
      _messages = [];
      _pending = null;
      _pendingQuestion = null;
      _lastMessageCount = 0;
      _expandedToolBlocks.clear();
    });

    try {
      final detail = await _api.getSession(id);
      if (!mounted) {
        return;
      }
      setState(() {
        _current = detail.session;
        _messages = detail.messages;
        _pending = detail.pendingApproval;
        _pendingQuestion = detail.pendingQuestion;
        _lastMessageCount = detail.messages.length;
        _loading = false;
      });
      final index = _sessions.indexWhere((item) => item.id == id);
      if (index >= 0) {
        _sessions[index] = detail.session;
      }
      _jumpToLatest();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error is NasApiException ? error.message : '$error';
      });
    }
  }

  Future<void> _newSession() async {
    if (!_modelConfigured) {
      await _openModelSettings();
      if (!_modelConfigured) {
        return;
      }
    }

    try {
      final session = await _api.createSession();
      if (!mounted || session.id.isEmpty) {
        return;
      }
      setState(() {
        _sessions = [session, ..._sessions];
      });
      await _selectSession(session.id);
    } catch (error) {
      _toast(error is NasApiException ? error.message : '$error');
    }
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) {
      return;
    }

    final now = DateTime.now();
    if (_sending) {
      final startedAt = _sendStartedAt;
      if (startedAt == null ||
          now.difference(startedAt) < const Duration(seconds: 20)) {
        return;
      }
    }

    if (!_modelConfigured) {
      await _openModelSettings();
      if (!_modelConfigured) {
        return;
      }
    }

    if (_current == null) {
      await _newSession();
      if (_current == null) {
        return;
      }
    }

    final token = ++_sendToken;
    _sendStartedAt = now;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _api.sendMessage(_current!.id, text);
      if (!mounted || token != _sendToken) {
        return;
      }
      _inputController.clear();
      await _poll(force: true);
    } catch (error) {
      if (token == _sendToken) {
        _toast(error is NasApiException ? error.message : '$error');
      }
    } finally {
      if (token == _sendToken) {
        _sendStartedAt = null;
        if (mounted) {
          setState(() {
            _sending = false;
          });
        }
      }
    }
  }

  Future<void> _interrupt() async {
    final current = _current;
    if (current == null) {
      return;
    }

    try {
      await _api.interrupt(current.id);
      await _poll();
    } catch (error) {
      _toast(error is NasApiException ? error.message : '$error');
    }
  }

  Future<void> _decideApproval(bool allow) async {
    final current = _current;
    final pending = _pending;
    if (current == null || pending == null || _deciding) {
      return;
    }

    setState(() {
      _deciding = true;
    });
    try {
      await _api.decideApproval(current.id, pending.id, allow);
      if (!mounted) {
        return;
      }
      setState(() {
        _pending = null;
      });
      await _poll();
    } catch (error) {
      _toast(error is NasApiException ? error.message : '$error');
    } finally {
      if (mounted) {
        setState(() {
          _deciding = false;
        });
      }
    }
  }

  Future<void> _answerQuestion(Map<String, dynamic> answer) async {
    final current = _current;
    final question = _pendingQuestion;
    if (current == null || question == null || _answeringQuestion) {
      return;
    }
    if (answer.isEmpty) {
      _toast('请先选择或填写回答。');
      return;
    }

    setState(() {
      _answeringQuestion = true;
    });
    try {
      await _api.replyQuestion(current.id, question.formId, answer);
      if (!mounted) {
        return;
      }
      setState(() {
        _pendingQuestion = null;
      });
      await _poll();
    } catch (error) {
      _toast(error is NasApiException ? error.message : '$error');
    } finally {
      if (mounted) {
        setState(() {
          _answeringQuestion = false;
        });
      }
    }
  }

  Future<void> _skipQuestion() async {
    final current = _current;
    final question = _pendingQuestion;
    if (current == null || question == null || _answeringQuestion) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('跳过本次提问？'),
        content: const Text('AI 将按自己的判断继续，或转而向你追问。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('继续回答'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('跳过'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _answeringQuestion = true;
    });
    try {
      await _api.cancelQuestion(current.id, question.formId);
      if (!mounted) {
        return;
      }
      setState(() {
        _pendingQuestion = null;
      });
      await _poll();
    } catch (error) {
      _toast(error is NasApiException ? error.message : '$error');
    } finally {
      if (mounted) {
        setState(() {
          _answeringQuestion = false;
        });
      }
    }
  }

  Future<void> _openSessions() async {
    try {
      final sessions = await _api.listSessions();
      if (!mounted) {
        return;
      }
      setState(() {
        _sessions = sessions;
      });

      final selected = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.add_comment_outlined),
                title: const Text('新建对话'),
                onTap: () => Navigator.of(sheetContext).pop('__new__'),
              ),
              const Divider(height: 1),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    final selected = session.id == _current?.id;
                    return ListTile(
                      leading: Icon(
                        selected ? Icons.chat_bubble : Icons.chat_bubble_outline,
                        color: selected
                            ? const Color(0xFF6D28D9)
                            : const Color(0xFF64748B),
                      ),
                      title: Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        session.active ? '运行中' : '空闲',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: selected
                          ? const Icon(Icons.check, color: Color(0xFF6D28D9))
                          : null,
                      onTap: () => Navigator.of(sheetContext).pop(session.id),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );

      if (!mounted || selected == null) {
        return;
      }
      if (selected == '__new__') {
        await _newSession();
      } else if (selected != _current?.id) {
        await _selectSession(selected);
      }
    } catch (error) {
      _toast(error is NasApiException ? error.message : '$error');
    }
  }

  Future<void> _openAutonomousSettings() async {
    var next = _autonomous;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 64),
          title: const Text('审批模式'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('完全自主模式'),
                subtitle: const Text(
                  '开启后，rm -rf、sudo、网络类等敏感命令也不再弹窗确认，全部直接执行。',
                ),
                value: next,
                onChanged: (value) => setDialogState(() => next = value),
              ),
              if (next)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    '请确认你信任当前模型与供应商；该模式会关闭所有命令拦截。',
                    style: TextStyle(fontSize: 12, color: Color(0xFFB42318)),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(next),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (!mounted || result == null || result == _autonomous) {
      return;
    }

    try {
      final updated = await _api.setAutonomous(result);
      if (!mounted) {
        return;
      }
      setState(() {
        _autonomous = updated;
        if (updated) {
          _pending = null;
        }
      });
      _toast(updated ? '已开启完全自主模式。' : '已恢复敏感命令确认。');
    } catch (error) {
      _toast(error is NasApiException ? error.message : '$error');
    }
  }

  Future<void> _openModelSettings() async {
    try {
      final settings = await _api.getModel();
      if (!mounted) {
        return;
      }
      final updated = await showDialog<AgentModelSettings>(
        context: context,
        builder: (dialogContext) => _AgentModelConfigDialog(
          api: _api,
          settings: settings,
        ),
      );
      if (!mounted || updated == null) {
        return;
      }
      setState(() {
        _modelConfigured = updated.hasKey;
        _error = null;
      });
      _toast('模型配置已保存。');
    } catch (error) {
      _toast(error is NasApiException ? error.message : '$error');
    }
  }

  void _toast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _copyMessageText(String text) async {
    if (text.trim().isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      _toast('已复制回复。');
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  /// 刚进入会话时 ListView 还没测量完，maxScrollExtent 会偏小；
  /// 连续几帧跳到底部，等 Markdown / 工具块完成布局后再落位。
  Future<void> _jumpToLatest() async {
    for (var attempt = 0; attempt < 8; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      final target = _scrollController.position.maxScrollExtent;
      if ((_scrollController.offset - target).abs() > 0.5) {
        _scrollController.jumpTo(target);
      }
      if (attempt < 7) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
  }

  String _formatTime(int millis) {
    if (millis <= 0) {
      return '';
    }
    final time = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final title = _current?.title ?? 'AI 助手';
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '刷新对话',
            onPressed: _refreshChat,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '会话列表',
            onPressed: _openSessions,
            icon: const Icon(Icons.forum_outlined),
          ),
          IconButton(
            tooltip: '新建对话',
            onPressed: _newSession,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          IconButton(
            tooltip: _autonomous ? '完全自主模式已开启' : '审批模式',
            onPressed: _openAutonomousSettings,
            icon: Icon(
              _autonomous ? Icons.shield : Icons.shield_outlined,
            ),
            color: _autonomous ? const Color(0xFFB42318) : null,
          ),
          IconButton(
            tooltip: '模型设置',
            onPressed: _openModelSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!_modelConfigured)
              Material(
                color: const Color(0xFFFFFBEB),
                child: InkWell(
                  onTap: _openModelSettings,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Icon(Icons.key_outlined, color: Color(0xFFB45309)),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '还没有配置模型，点这里选择供应商并填写 API Key。',
                            style: TextStyle(
                              fontSize: 13,
                              color: Color(0xFF8A5A00),
                            ),
                          ),
                        ),
                        Icon(Icons.chevron_right, color: Color(0xFFB45309)),
                      ],
                    ),
                  ),
                ),
              ),
            if (_error != null)
              Material(
                color: const Color(0xFFFEF2F2),
                child: InkWell(
                  onTap: _refreshChat,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.refresh,
                          size: 14,
                          color: Color(0xFFB42318),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFB42318),
                            ),
                          ),
                        ),
                        const Text(
                          '点此重试',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFFB42318),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_autonomous)
              Material(
                color: const Color(0xFFFEF2F2),
                child: InkWell(
                  onTap: _openAutonomousSettings,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(
                      children: [
                        Icon(Icons.shield, size: 16, color: Color(0xFFB42318)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '完全自主模式：敏感命令不再弹确认',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFFB42318),
                            ),
                          ),
                        ),
                        Icon(Icons.chevron_right, color: Color(0xFFB42318)),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(child: _buildMessages()),
            if (_pending != null) _buildApprovalCard(_pending!),
            if (_pendingQuestion != null)
              _AgentQuestionCard(
                key: ValueKey(_pendingQuestion!.formId),
                question: _pendingQuestion!,
                submitting: _answeringQuestion,
                onSubmit: _answerQuestion,
                onSkip: _skipQuestion,
              ),
            _buildComposer(),
          ],
        ),
      ),
    );
  }

  Widget _buildMessages() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_current == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_awesome, size: 48, color: Color(0xFF6D28D9)),
              const SizedBox(height: 14),
              const Text(
                '让 AI 帮你处理电脑上的文件',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '可以提问、总结文件、生成内容；敏感命令会先请你确认。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _newSession,
                icon: const Icon(Icons.add_comment_outlined),
                label: const Text('开始新对话'),
              ),
            ],
          ),
        ),
      );
    }

    final children = <Widget>[];
    for (final message in _messages) {
      children.add(_buildMessage(message));
    }
    if (_current?.active == true) {
      children.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text(
                '正在思考或执行命令…',
                style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
              ),
            ],
          ),
        ),
      );
    }

    if (children.isEmpty) {
      return const Center(
        child: Text(
          '发一条消息开始对话。',
          style: TextStyle(color: Color(0xFF64748B)),
        ),
      );
    }

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
      children: children,
    );
  }

  Widget _buildMessage(AgentMessage message) {
    if (message.isCompaction) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFE2E8F0),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text(
            '上下文已自动压缩',
            style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
          ),
        ),
      );
    }

    if (message.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10, left: 42),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF6D28D9),
            borderRadius: BorderRadius.circular(16),
          ),
          child: SelectableText(
            message.text,
            style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.45),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12, right: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE6EAF2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.text.isNotEmpty) _buildMarkdown(message.text),
                for (var index = 0; index < message.tools.length; index++)
                  _buildTool(message, message.tools[index], index),
                if (message.createdAt > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _formatTime(message.createdAt),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (message.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Tooltip(
                message: '复制回复',
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _copyMessageText(message.text),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.copy_rounded,
                          size: 13,
                          color: Color(0xFF94A3B8),
                        ),
                        SizedBox(width: 4),
                        Text(
                          '复制',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMarkdown(String data) {
    return MarkdownBody(
      data: data,
      selectable: true,
      softLineBreak: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      onTapLink: (text, href, title) async {
        final uri = href == null ? null : Uri.tryParse(href);
        if (uri != null) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      styleSheet: buildNasMarkdownStyle(context),
    );
  }

  Widget _buildTool(AgentMessage message, AgentToolCall tool, int index) {
    final command = tool.command.trim();
    final output = tool.output.trim();
    final key = '${message.id}:$index';
    final expanded = _expandedToolBlocks.contains(key);
    final statusColor = switch (tool.status) {
      'completed' => const Color(0xFF34D399),
      'error' => const Color(0xFFF87171),
      'running' => const Color(0xFFFBBF24),
      _ => const Color(0xFF94A3B8),
    };

    return Container(
      margin: const EdgeInsets.only(top: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF0B1220),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                if (expanded) {
                  _expandedToolBlocks.remove(key);
                } else {
                  _expandedToolBlocks.add(key);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.terminal,
                    size: 15,
                    color: Color(0xFF93C5FD),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                tool.name,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF93C5FD),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Text(
                              tool.status,
                              style: TextStyle(
                                fontSize: 11,
                                color: statusColor,
                              ),
                            ),
                          ],
                        ),
                        if (!expanded && command.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              command,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF94A3B8),
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: const Color(0xFF94A3B8),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (command.isNotEmpty)
                    SelectableText(
                      command,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFE2E8F0),
                        fontFamily: 'monospace',
                        height: 1.4,
                      ),
                    ),
                  if (output.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(
                        top: command.isNotEmpty ? 8 : 0,
                      ),
                      child: Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxHeight: 260),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            output.length > 4000
                                ? '${output.substring(0, 4000)}…'
                                : output,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFFCBD5E1),
                              fontFamily: 'monospace',
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHighlightedCommand(String command, String? matched) {
    final needle = matched?.trim() ?? '';
    if (needle.isEmpty) {
      return SelectableText(
        command,
        style: const TextStyle(
          fontSize: 12,
          color: Color(0xFFE2E8F0),
          fontFamily: 'monospace',
          height: 1.4,
        ),
      );
    }

    final spans = <TextSpan>[];
    final lowerCommand = command.toLowerCase();
    final lowerNeedle = needle.toLowerCase();
    var start = 0;
    while (start < command.length) {
      final index = lowerCommand.indexOf(lowerNeedle, start);
      if (index < 0) {
        spans.add(TextSpan(text: command.substring(start)));
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: command.substring(start, index)));
      }
      spans.add(
        TextSpan(
          text: command.substring(index, index + needle.length),
          style: const TextStyle(
            backgroundColor: Color(0xFFB45309),
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      start = index + needle.length;
    }

    return SelectableText.rich(
      TextSpan(
        children: spans,
        style: const TextStyle(
          fontSize: 12,
          color: Color(0xFFE2E8F0),
          fontFamily: 'monospace',
          height: 1.4,
        ),
      ),
    );
  }

  Widget _buildApprovalCard(AgentPendingApproval pending) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final baseCommandHeight = (screenHeight * 0.22).clamp(120.0, 220.0);
    // 问答卡也在同屏时再压缩命令区，避免两张卡叠加把按钮顶出屏幕。
    final maxCommandHeight = _pendingQuestion == null
        ? baseCommandHeight.toDouble()
        : min(baseCommandHeight.toDouble(), 130.0);
    final commandIsLong =
        pending.command.length > 600 ||
        '\n'.allMatches(pending.command).length > 10;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.shield_outlined, size: 18, color: Color(0xFFB45309)),
              SizedBox(width: 8),
              Text(
                '需要确认的命令',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF8A5A00),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF0B1220),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxCommandHeight),
              child: SingleChildScrollView(
                child: _buildHighlightedCommand(
                  pending.command,
                  pending.matched,
                ),
              ),
            ),
          ),
          if (commandIsLong)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '命令较长，可在黑色框内上下滑动查看完整内容',
                style: TextStyle(fontSize: 11, color: Color(0xFF8A5A00)),
              ),
            ),
          if ((pending.matched ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '命中：${pending.matched}',
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFFFBBF24),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (pending.cwd.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '目录：${pending.cwd}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFF8A5A00)),
              ),
            ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _deciding ? null : () => _decideApproval(false),
                child: const Text('拒绝'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _deciding ? null : () => _decideApproval(true),
                child: const Text('允许一次'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildComposer() {
    final active = _current?.active == true;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE6EAF2))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.newline,
              enabled: !_sending,
              decoration: InputDecoration(
                hintText: '输入消息…',
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          active
              ? IconButton.filledTonal(
                  tooltip: '中断',
                  onPressed: _interrupt,
                  icon: const Icon(Icons.stop_circle_outlined),
                )
              : IconButton.filled(
                  tooltip: '发送',
                  onPressed: _sending ? null : _send,
                  icon: const Icon(Icons.send),
                ),
        ],
      ),
    );
  }
}

class _AgentQuestionCard extends StatefulWidget {
  const _AgentQuestionCard({
    required this.question,
    required this.submitting,
    required this.onSubmit,
    required this.onSkip,
    super.key,
  });

  final AgentPendingQuestion question;
  final bool submitting;
  final Future<void> Function(Map<String, dynamic> answer) onSubmit;
  final Future<void> Function() onSkip;

  @override
  State<_AgentQuestionCard> createState() => _AgentQuestionCardState();
}

class _AgentQuestionCardState extends State<_AgentQuestionCard> {
  final Map<String, Set<String>> _selected = {};
  final Map<String, TextEditingController> _custom = {};

  @override
  void initState() {
    super.initState();
    for (final question in widget.question.questions) {
      _selected[question.key] = <String>{};
      _custom[question.key] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final controller in _custom.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _buildAnswer() {
    final answer = <String, dynamic>{};
    for (final question in widget.question.questions) {
      final selected = _selected[question.key] ?? const <String>{};
      final custom = _custom[question.key]?.text.trim() ?? '';
      if (question.multiple) {
        final values = <String>[...selected];
        if (custom.isNotEmpty && !values.contains(custom)) {
          values.add(custom);
        }
        if (values.isNotEmpty) {
          answer[question.key] = values;
        }
      } else {
        final value = custom.isNotEmpty
            ? custom
            : (selected.isEmpty ? '' : selected.first);
        if (value.isNotEmpty) {
          answer[question.key] = value;
        }
      }
    }
    return answer;
  }

  Future<void> _submit() async {
    final answer = _buildAnswer();
    final missing = widget.question.questions
        .where((question) => question.required && !answer.containsKey(question.key))
        .toList();
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '请回答：${missing.first.header.isEmpty ? missing.first.question : missing.first.header}',
          ),
        ),
      );
      return;
    }
    if (answer.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择或填写回答。')),
      );
      return;
    }
    await widget.onSubmit(answer);
  }

  Widget _buildField(AgentQuestion question) {
    final selected = _selected[question.key] ?? <String>{};
    final controller = _custom[question.key]!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (question.header.isNotEmpty)
            Text(
              question.required ? '${question.header} *' : question.header,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF3B276B),
              ),
            ),
          if (question.question.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: question.header.isEmpty ? 0 : 3),
              child: Text(
                question.question,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: Color(0xFF64748B),
                ),
              ),
            ),
          if (question.options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final option in question.options)
                    Tooltip(
                      message: option.description,
                      child: question.multiple
                          ? FilterChip(
                              label: Text(option.label),
                              selected: selected.contains(option.value),
                              onSelected: widget.submitting
                                  ? null
                                  : (checked) {
                                      setState(() {
                                        final values = _selected.putIfAbsent(
                                          question.key,
                                          () => <String>{},
                                        );
                                        if (checked) {
                                          values.add(option.value);
                                        } else {
                                          values.remove(option.value);
                                        }
                                      });
                                    },
                            )
                          : ChoiceChip(
                              label: Text(option.label),
                              selected: selected.contains(option.value),
                              onSelected: widget.submitting
                                  ? null
                                  : (checked) {
                                      setState(() {
                                        _selected[question.key] = checked
                                            ? <String>{option.value}
                                            : <String>{};
                                        controller.clear();
                                      });
                                    },
                            ),
                    ),
                ],
              ),
            ),
          if (question.custom || question.options.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: controller,
                enabled: !widget.submitting,
                textInputAction: TextInputAction.done,
                onChanged: (value) {
                  setState(() {
                    if (value.trim().isNotEmpty && !question.multiple) {
                      _selected[question.key] = <String>{};
                    }
                  });
                },
                decoration: InputDecoration(
                  isDense: true,
                  hintText: question.options.isEmpty ? '输入回答' : '自定义回答（可选）',
                  hintStyle: const TextStyle(fontSize: 12.5),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.75),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFDDD6FE)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFDDD6FE)),
                  ),
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = !widget.submitting && _buildAnswer().isNotEmpty;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F3FF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDDD6FE)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Row(
              children: [
                Icon(
                  Icons.question_answer_outlined,
                  size: 18,
                  color: Color(0xFF6D28D9),
                ),
                SizedBox(width: 8),
                Text(
                  'AI 需要你的回答',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF3B276B),
                  ),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 250),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final question in widget.question.questions)
                    _buildField(question),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: widget.submitting ? null : widget.onSkip,
                  child: const Text('跳过'),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: canSubmit ? _submit : null,
                  child: widget.submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('提交回答'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentModelConfigDialog extends StatefulWidget {
  const _AgentModelConfigDialog({required this.api, required this.settings});

  final AgentApi api;
  final AgentModelSettings settings;

  @override
  State<_AgentModelConfigDialog> createState() => _AgentModelConfigDialogState();
}

class _AgentModelConfigDialogState extends State<_AgentModelConfigDialog> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _modelController;
  final TextEditingController _keyController = TextEditingController();
  late String _providerId;
  bool _clearKey = false;
  bool _saving = false;
  bool _testing = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _providerId = widget.settings.providerId;
    _baseUrlController = TextEditingController(text: widget.settings.baseUrl);
    _modelController = TextEditingController(text: widget.settings.model);
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  void _selectPreset(AgentModelPreset preset) {
    setState(() {
      _providerId = preset.id;
      if (preset.baseUrl.isNotEmpty) {
        _baseUrlController.text = preset.baseUrl;
      }
      if (preset.models.isNotEmpty) {
        _modelController.text = preset.models.first;
      }
    });
  }

  Future<void> _save() async {
    final baseUrl = _baseUrlController.text.trim();
    final model = _modelController.text.trim();
    final key = _keyController.text.trim();
    if (baseUrl.isEmpty || model.isEmpty) {
      setState(() {
        _status = '请填写 Base URL 和模型名称。';
      });
      return;
    }
    if (!widget.settings.hasKey && !_clearKey && key.isEmpty) {
      setState(() {
        _status = '请填写 API Key。';
      });
      return;
    }

    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      final updated = await widget.api.saveModel(
        providerId: _providerId,
        baseUrl: baseUrl,
        model: model,
        apiKey: key.isEmpty ? null : key,
        clearKey: _clearKey,
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(updated);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = error is NasApiException ? error.message : '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _status = null;
    });
    try {
      final message = await widget.api.testModel();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = error is NasApiException ? error.message : '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final presets = widget.settings.presets;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 32),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      title: const Text('模型设置'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('供应商', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in presets)
                    ChoiceChip(
                      label: Text(preset.display),
                      selected: _providerId == preset.id,
                      onSelected: (_) => _selectPreset(preset),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _baseUrlController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                        labelText: 'Base URL',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _modelController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                        labelText: '模型名称',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                '预设会自动填充 Base URL 和模型名；自定义时手动填写。',
                style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _keyController,
                obscureText: true,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  isDense: true,
                  labelText: 'API Key',
                  hintText: widget.settings.hasKey
                      ? '已保存 ${widget.settings.keyMasked ?? ''}，留空保持不变'
                      : '输入 API Key',
                ),
              ),
              if (widget.settings.hasKey)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () {
                      setState(() {
                        _clearKey = !_clearKey;
                      });
                    },
                    child: Text(_clearKey ? '取消清除 Key' : '清除已保存的 Key'),
                  ),
                ),
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _status!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _status!.contains('正常') ||
                              _status!.contains('已保存')
                          ? const Color(0xFF047857)
                          : const Color(0xFFB42318),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: (_saving || _testing) ? null : _test,
          child: _testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('测试连接'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ],
    );
  }
}
