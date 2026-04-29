import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  Future<void> _probeHost() async {
    final uri = _buildProbeUri(_hostController.text);
    if (uri == null) {
      setState(() {
        _probeState = const ProbeState.error('请输入可访问的宿主地址，例如 http://192.168.1.10:5034。');
      });
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _isProbing = true;
      _probeState = const ProbeState.loading();
    });

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);

    try {
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 8));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response = await request.close().timeout(const Duration(seconds: 8));
      final responseBody = await utf8.decodeStream(response).timeout(const Duration(seconds: 8));

      if (!mounted) {
        return;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        setState(() {
          _probeState = ProbeState.error(
            '宿主返回了 ${response.statusCode}。${_compactBody(responseBody)}',
          );
        });
        return;
      }

      setState(() {
        _probeState = _parseProbeState(uri, responseBody);
      });
    } on TimeoutException {
      if (!mounted) {
        return;
      }

      setState(() {
        _probeState = const ProbeState.error('连接超时，请确认手机和宿主在同一网络，且 5034 端口可访问。');
      });
    } on SocketException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _probeState = ProbeState.error('无法连接宿主：${error.message}');
      });
    } on HttpException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _probeState = ProbeState.error('请求失败：${error.message}');
      });
    } on FormatException {
      if (!mounted) {
        return;
      }

      setState(() {
        _probeState = ProbeState.success(
          endpoint: uri.origin,
          hostName: '宿主已响应',
          detail: '接口返回了非 JSON 内容，请确认目标是 loal_NAS 宿主的 /api/system/status。',
        );
      });
    } finally {
      client.close(force: true);
      if (mounted) {
        setState(() {
          _isProbing = false;
        });
      }
    }
  }

  Uri? _buildProbeUri(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final normalized = trimmed.contains('://') ? trimmed : 'http://$trimmed';
    final baseUri = Uri.tryParse(normalized);
    if (baseUri == null || baseUri.host.isEmpty) {
      return null;
    }

    return baseUri.replace(path: '/api/system/status', query: '');
  }

  ProbeState _parseProbeState(Uri uri, String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      return ProbeState.success(
        endpoint: uri.origin,
        hostName: '宿主已响应',
        detail: _compactBody(body),
      );
    }

    final hostName = decoded['name']?.toString() ?? 'loal_NAS 宿主';
    final fileBrowser = decoded['fileBrowser'];
    final running = fileBrowser is Map ? fileBrowser['running'] as bool? : null;
    final baseUrl = fileBrowser is Map ? fileBrowser['baseUrl']?.toString() : null;
    final sharedRoot = fileBrowser is Map ? fileBrowser['sharedRoot']?.toString() : null;

    final details = <String>[
      '状态接口可达。',
      if (running != null) 'FileBrowser: ${running ? '运行中' : '未运行'}',
      if (baseUrl != null && baseUrl.isNotEmpty) '内部地址: $baseUrl',
      if (sharedRoot != null && sharedRoot.isNotEmpty) '共享目录: $sharedRoot',
    ].join('\n');

    return ProbeState.success(
      endpoint: uri.origin,
      hostName: hostName,
      detail: details,
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
                    '先验证手机能否访问宿主的 /api/system/status，后续再接登录、文件浏览和上传。',
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
                    Text(
                      '宿主地址',
                      style: theme.textTheme.titleMedium,
                    ),
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
                        label: Text(_isProbing ? '探测中...' : '探测宿主'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '提示：IPv6 地址必须带中括号，例如 http://[fc00::55:ca]:5034。',
                    ),
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
                    Text(
                      '探测结果',
                      style: theme.textTheme.titleMedium,
                    ),
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
          detail: '输入宿主地址后点击“探测宿主”，先确认手机和 NAS 宿主之间的基础联通。',
          color: const Color(0xFF475569),
        );

  const ProbeState.loading()
      : this._(
          headline: '正在连接',
          detail: '正在请求 /api/system/status ...',
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
