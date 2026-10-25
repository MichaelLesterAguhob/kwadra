import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SessionStorage {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
  Future<void> clear();
}

/// Native credentials use Keychain/Keystore and are bound to one API address.
/// Browsers continue to use HttpOnly cookies, never plugin/local storage tokens.
class SecureSessionStorage implements SessionStorage {
  SecureSessionStorage(String apiUrl)
    : key = 'kwadra.session.${base64Url.encode(utf8.encode(apiUrl))}';
  final String key;
  static const storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  @override
  Future<Map<String, dynamic>?> read() async {
    if (kIsWeb) return null;
    final raw = await storage.read(key: key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      await clear();
      return null;
    } on TypeError {
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (!kIsWeb) await storage.write(key: key, value: jsonEncode(value));
  }

  @override
  Future<void> clear() async {
    if (!kIsWeb) await storage.delete(key: key);
  }
}
