import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'http_client_native.dart'
    if (dart.library.js_interop) 'http_client_web.dart';
import 'models.dart';
import 'session_storage.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.status = 0, this.code = ''});
  final String message, code;
  final int status;
  @override
  String toString() => message;
}

String uuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String defaultApiUrl() {
  const configured = String.fromEnvironment('API_BASE_URL');
  if (configured.isNotEmpty) return configured;
  if (kIsWeb) {
    final base = Uri.base;
    if (['localhost', '127.0.0.1'].contains(base.host) &&
        (kDebugMode || base.port == 8080)) {
      return '${base.scheme}://${base.host}:3000/api/v1';
    }
    return '${base.origin}/api/v1';
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    return 'http://10.0.2.2:3000/api/v1';
  }
  return 'http://localhost:3000/api/v1';
}

class ApiClient {
  ApiClient({
    required String baseUrl,
    http.Client? client,
    SessionStorage? sessionStorage,
  }) : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
       _client = client ?? createHttpClient(),
       _storage =
           sessionStorage ??
           SecureSessionStorage(baseUrl.replaceAll(RegExp(r'/+$'), ''));
  final String baseUrl;
  final http.Client _client;
  final SessionStorage _storage;
  String? organizationId, _token, _csrf, _refreshToken;
  Future<void>? _refreshing;
  bool liveNotifications = false;
  bool get hasCredentials => _token != null || _refreshToken != null;
  VoidCallback? onSessionExpired;
  List<Json> organizations = [];
  Json user = {};
  ValueChanged<String>? onOrganizationChanged;
  String get accountKind => user['platformAdmin'] == true
      ? 'platform'
      : organizations
                .where((o) => o['id'] == organizationId)
                .firstOrNull?['role'] ==
            'tenant'
      ? 'tenant'
      : organizations.isEmpty
      ? 'seeker'
      : 'management';
  final Map<String, String> _pendingKeys = {};

  Future<Json> request(
    String method,
    String path, {
    Json? body,
    bool authenticated = true,
    bool retrySession = true,
  }) async {
    if (kReleaseMode && !kIsWeb && Uri.parse(baseUrl).scheme != 'https') {
      throw const ApiException(
        'Set an HTTPS server address to use this release build.',
      );
    }
    final mutation = method != 'GET';
    final encoded = body == null ? null : jsonEncode(body);
    final signature = '$method:$path:$encoded';
    final sentToken = _token;
    final headers = <String, String>{
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
      if (authenticated && organizationId != null)
        'X-Organization-Id': organizationId!,
      if (authenticated && _token != null) 'Authorization': 'Bearer $_token',
      if (authenticated && _csrf != null) 'X-CSRF-Token': _csrf!,
      if (authenticated && mutation)
        'Idempotency-Key': _pendingKeys.putIfAbsent(signature, uuid),
    };
    try {
      final request = http.Request(method, Uri.parse('$baseUrl$path'))
        ..headers.addAll(headers);
      if (encoded != null) request.body = encoded;
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 25));
      Json result;
      try {
        result = jsonDecode(response.body) as Json;
      } catch (_) {
        throw const ApiException(
          'The server returned an unexpected response. Check the API address.',
        );
      }
      if (response.statusCode >= 400) {
        if (authenticated &&
            response.statusCode == 401 &&
            retrySession &&
            _refreshToken != null) {
          if (_token == sentToken) await _refresh();
          return await this.request(
            method,
            path,
            body: body,
            authenticated: authenticated,
            retrySession: false,
          );
        }
        // A definitive validation/conflict response ends this attempt. Transport
        // failures keep the key so the same operation can be retried safely.
        if (response.statusCode < 500) _pendingKeys.remove(signature);
        if (authenticated &&
            (response.statusCode == 401 ||
                response.statusCode == 403 &&
                    ['/workspace', '/auth/me'].contains(path))) {
          await _forgetSession();
        }
        throw ApiException(
          (result['error']?['message'] ?? 'The request failed.').toString(),
          status: response.statusCode,
          code: (result['error']?['code'] ?? '').toString(),
        );
      }
      _pendingKeys.remove(signature);
      return result;
    } on TimeoutException {
      throw const ApiException(
        'The server took too long to respond. Check your connection and retry.',
      );
    } on http.ClientException {
      throw const ApiException(
        'Cannot reach the server. Check the API address, Wi-Fi and that the backend is running.',
      );
    }
  }

  void _session(Json result) {
    liveNotifications = result['capabilities']?['liveNotifications'] == true;
    user = Json.from(result['user'] ?? {});
    _token = result['token'] as String? ?? _token;
    _refreshToken = result['refreshToken'] as String? ?? _refreshToken;
    _csrf = result['csrfToken'] as String;
    organizations = (result['organizations'] as List)
        .map((v) => Json.from(v))
        .toList();
    if (!organizations.any((o) => o['id'] == organizationId)) {
      organizationId = organizations.firstOrNull?['id'] as String?;
    }
  }

  Future<void> login(String email, String password, {String? mfaCode}) async {
    _newSession(
      await request(
        'POST',
        '/auth/login',
        authenticated: false,
        body: {
          'email': email.trim(),
          'password': password,
          'client': kIsWeb ? 'web' : 'native',
          if (mfaCode != null && mfaCode.isNotEmpty) 'mfaCode': mfaCode,
        },
      ),
    );
    await _persist();
  }

  Future<void> loginGoogle(String idToken, {String? mfaCode}) async {
    _newSession(
      await request(
        'POST',
        '/auth/google',
        authenticated: false,
        body: {
          'idToken': idToken,
          'client': kIsWeb ? 'web' : 'native',
          if (mfaCode != null && mfaCode.isNotEmpty) 'mfaCode': mfaCode,
        },
      ),
    );
    await _persist();
  }

  Future<void> _persist() async {
    if (!kIsWeb && _token != null) {
      await _storage.write({'token': _token, 'refreshToken': _refreshToken});
    }
  }

  void _newSession(Json result) {
    _token = null;
    _refreshToken = null;
    _csrf = null;
    _session(result);
  }

  Future<void> _forgetSession() async {
    liveNotifications = false;
    _token = null;
    _refreshToken = null;
    _csrf = null;
    user = {};
    organizations = [];
    organizationId = null;
    _pendingKeys.clear();
    try {
      await _storage.clear();
    } finally {
      onSessionExpired?.call();
    }
  }

  Future<void> _refresh() async {
    if (_refreshing != null) return _refreshing!;
    final pending = () async {
      try {
        final next = await request(
          'POST',
          '/auth/refresh',
          authenticated: false,
          body: {'refreshToken': _refreshToken},
        );
        _session(next);
        await _persist();
      } on ApiException catch (e) {
        if (e.status == 401) await _forgetSession();
        rethrow;
      }
    }();
    _refreshing = pending;
    try {
      await pending;
    } finally {
      _refreshing = null;
    }
  }

  Future<bool> restoreSaved() async {
    if (!kIsWeb) {
      final saved = await _storage.read();
      _token = saved?['token'] as String?;
      _refreshToken = saved?['refreshToken'] as String?;
      if (!hasCredentials) return false;
    }
    await restore();
    return true;
  }

  Future<void> restore() async => _session(await request('GET', '/auth/me'));
  Stream<void> notificationEvents() async* {
    final abort = Completer<void>();
    try {
      final request = http.AbortableRequest(
        'GET',
        Uri.parse('$baseUrl/account/notifications/events'),
        abortTrigger: abort.future,
      );
      request.headers['Accept'] = 'text/event-stream';
      if (_token != null) request.headers['Authorization'] = 'Bearer $_token';
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        await restore();
        return;
      }
      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.startsWith('data:')) yield null;
      }
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<void> logout() async {
    // Do not report a successful logout unless the server revokes the session.
    await request('POST', '/auth/logout', body: {});
    await _forgetSession();
  }

  void close() => _client.close();
}
