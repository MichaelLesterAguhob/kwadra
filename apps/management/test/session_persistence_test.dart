import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kwadra_management/data/api_client.dart';
import 'package:kwadra_management/data/session_storage.dart';

Map<String, dynamic> session(String token, String refresh) => {
  'token': token,
  'refreshToken': refresh,
  'csrfToken': 'csrf',
  'user': {'id': 'renter', 'name': 'Renter', 'email': 'renter@example.com'},
  'organizations': [],
};
http.Response json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

class MemorySessions implements SessionStorage {
  Map<String, dynamic>? value;
  @override
  Future<Map<String, dynamic>?> read() async => value;
  @override
  Future<void> write(Map<String, dynamic> data) async {
    value = Map.from(data);
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test('foreground stream uses authenticated headers and ignores heartbeat comments', () async {
    final api = ApiClient(
      baseUrl: 'https://server/api/v1',
      sessionStorage: MemorySessions(),
      client: MockClient.streaming((r, body) async {
        if (r.url.path.endsWith('/auth/login')) {
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(session('access', 'refresh')))),
            200,
          );
        }
        expect(r.headers['Authorization'], 'Bearer access');
        expect(r.headers['Accept'], 'text/event-stream');
        expect(r.url.query, isEmpty);
        return http.StreamedResponse(
          Stream.fromIterable(
            [
              ': heartbeat\n\n',
              'data: {"changed":true}\n\n',
              'data: {"expired":true}\n\n',
            ].map(utf8.encode),
          ),
          200,
        );
      }),
    );
    await api.login('renter@example.com', 'TestPassword!2026');
    expect(await api.notificationEvents().length, 2);
    api.close();
  });
  test('secure native credentials restore in a new client and remain bound to their API', () async {
    final first = ApiClient(
      baseUrl: 'https://one.example/api/v1',
      client: MockClient((r) async => json(session('access', 'refresh'))),
    );
    await first.login('renter@example.com', 'TestPassword!2026');
    first.close();
    final next = ApiClient(
      baseUrl: 'https://one.example/api/v1',
      client: MockClient((r) async {
        expect(r.headers['Authorization'], 'Bearer access');
        return json(session('access', 'refresh'));
      }),
    );
    expect(await next.restoreSaved(), true);
    expect(next.user['id'], 'renter');
    final another = ApiClient(
      baseUrl: 'https://two.example/api/v1',
      client: MockClient(
        (_) async =>
            throw StateError('Must not send another server’s credentials'),
      ),
    );
    expect(await another.restoreSaved(), false);
    next.close();
    another.close();
  });
  test(
    'concurrent expired requests share refresh and retain write retry keys',
    () async {
      final store = MemorySessions();
      var refreshes = 0;
      final keys = <String>[];
      final wait = Completer<void>();
      final api = ApiClient(
        baseUrl: 'https://server/api/v1',
        sessionStorage: store,
        client: MockClient((r) async {
          if (r.url.path.endsWith('/auth/login')) {
            return json(session('old', 'old-refresh'));
          }
          if (r.url.path.endsWith('/auth/refresh')) {
            refreshes++;
            await wait.future;
            return json(session('new', 'new-refresh'));
          }
          if (r.method == 'PUT') keys.add(r.headers['Idempotency-Key']!);
          if (r.headers['Authorization'] == 'Bearer old') {
            return json({
              'error': {'message': 'Expired', 'code': 'UNAUTHENTICATED'},
            }, 401);
          }
          expect(r.headers['Authorization'], 'Bearer new');
          return json({'data': []});
        }),
      );
      await api.login('renter@example.com', 'TestPassword!2026');
      final one = api.request('PUT', '/properties/one', body: {'name': 'One'}),
          two = api.request('GET', '/workspace');
      await Future<void>.delayed(Duration.zero);
      wait.complete();
      await Future.wait([one, two]);
      expect(refreshes, 1);
      expect(keys.length, 2);
      expect(keys.first, keys.last);
      expect(store.value?['refreshToken'], 'new-refresh');
      api.close();
    },
  );
  test(
    'refresh rejection clears stored credentials and reports session expiry',
    () async {
      final store = MemorySessions()
        ..value = {'token': 'expired', 'refreshToken': 'revoked'};
      var expired = false;
      final api = ApiClient(
        baseUrl: 'https://server/api/v1',
        sessionStorage: store,
        client: MockClient(
          (_) async => json({
            'error': {'message': 'Revoked', 'code': 'UNAUTHENTICATED'},
          }, 401),
        ),
      )..onSessionExpired = () => expired = true;
      await expectLater(api.restoreSaved(), throwsA(isA<ApiException>()));
      expect(store.value, null);
      expect(api.hasCredentials, false);
      expect(expired, true);
      api.close();
    },
  );
  test(
    'network outages preserve remembered credentials for a later retry',
    () async {
      final store = MemorySessions()
        ..value = {'token': 'access', 'refreshToken': 'refresh'};
      final api = ApiClient(
        baseUrl: 'https://server/api/v1',
        sessionStorage: store,
        client: MockClient((_) async => throw http.ClientException('Offline')),
      );
      await expectLater(api.restoreSaved(), throwsA(isA<ApiException>()));
      expect(store.value?['refreshToken'], 'refresh');
      expect(api.user, isEmpty);
      api.close();
    },
  );
  test('successful logout clears secure storage; failed logout retains credentials', () async {
    final store = MemorySessions();
    var fail = true;
    final api = ApiClient(
      baseUrl: 'https://server/api/v1',
      sessionStorage: store,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/auth/login')) {
          return json(session('access', 'refresh'));
        }
        return fail
            ? json({
                'error': {'message': 'Unavailable'},
              }, 503)
            : json({'message': 'Signed out'});
      }),
    );
    await api.login('renter@example.com', 'TestPassword!2026');
    await expectLater(api.logout(), throwsA(isA<ApiException>()));
    expect(store.value, isNotNull);
    fail = false;
    await api.logout();
    expect(store.value, null);
    expect(api.user, isEmpty);
    api.close();
  });
}
