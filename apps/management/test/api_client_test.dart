import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kwadra_management/app.dart';
import 'package:kwadra_management/data/api_client.dart';
import 'package:kwadra_management/data/models.dart';
import 'package:kwadra_management/data/workspace_store.dart';
import 'package:kwadra_management/features/payment_preview.dart';
import 'package:kwadra_management/features/portfolio.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    final font = FontLoader('Manrope')
      ..addFont(rootBundle.load('assets/fonts/Manrope.ttf'));
    await font.load();
  });
  Json snapshot({List<Json> properties = const [], bool viewer = false}) => {
    'version': 1,
    'revision': 1,
    'today': '2026-10-17',
    'ownerName': 'API Owner',
    'ownerEmail': 'owner@example.com',
    'organizationName': 'API Workspace',
    'permissions': {
      'role': viewer ? 'viewer' : 'owner',
      'canWrite': !viewer,
      'canManage': !viewer,
      'allProperties': true,
    },
    'properties': properties,
    'units': [],
    'tenants': [],
    'leases': [],
    'invoices': [],
    'tickets': [],
    'activities': [],
  };
  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );
  const id = 'c34a139d-74a1-40c4-82dc-39076d575304';
  const property = RentalProperty(
    id: id,
    name: 'API property',
    address: 'Cebu',
    type: 'Apartment',
    image: 'residence',
  );

  test(
    'API failures preserve pending retry keys and send authentication headers',
    () async {
      final keys = <String>[];
      var calls = 0;
      final api = ApiClient(
        baseUrl: 'http://server/api/v1',
        client: MockClient((r) async {
          keys.add(r.headers['Idempotency-Key']!);
          expect(r.headers['X-Organization-Id'], id);
          if (calls++ == 0) throw http.ClientException('offline');
          return json({
            'data': {'id': id},
            'revision': 2,
          });
        }),
      )..organizationId = id;
      addTearDown(api.close);
      await expectLater(
        api.request('POST', '/properties', body: property.toJson()),
        throwsA(isA<ApiException>()),
      );
      await api.request('POST', '/properties', body: property.toJson());
      expect(keys[0], keys[1]);
    },
  );
  test('remote saves reload server data and never overwrite local demonstration storage', () async {
    final local = await WorkspaceStore.open();
    final prefs = await SharedPreferences.getInstance();
    final savedLocal = prefs.getString(WorkspaceStore.storageKey);
    addTearDown(local.dispose);
    var created = false;
    final api = ApiClient(
      baseUrl: 'http://server/api/v1',
      client: MockClient((r) async {
        if (r.method == 'POST') {
          expect(r.url.path, '/api/v1/properties');
          expect(jsonDecode(r.body)['name'], 'API property');
          created = true;
          return json({
            'data': {'id': id},
            'revision': 2,
          });
        }
        return json(
          snapshot(
            properties: created
                ? [
                    {...property.toJson(), 'revision': 1},
                  ]
                : [],
          ),
        );
      }),
    );
    addTearDown(api.close);
    final store = await WorkspaceStore.connect(api);
    addTearDown(store.dispose);
    expect(store.properties, isEmpty);
    await store.saveProperty(property);
    expect(store.properties.single.name, 'API property');
    expect(store.properties.single.revision, 1);
    expect(prefs.getString(WorkspaceStore.storageKey), savedLocal);
  });
  test(
    'failed server writes do not optimistically change visible records',
    () async {
      final api = ApiClient(
        baseUrl: 'http://server/api/v1',
        client: MockClient(
          (r) async => r.method == 'GET'
              ? json(snapshot())
              : json({
                  'error': {
                    'message': 'A record conflicts.',
                    'code': 'CONFLICT',
                  },
                }, 409),
        ),
      );
      addTearDown(api.close);
      final store = await WorkspaceStore.connect(api);
      addTearDown(store.dispose);
      await expectLater(
        store.saveProperty(property),
        throwsA(isA<ApiException>()),
      );
      expect(store.properties, isEmpty);
    },
  );
  test(
    'committed writes with a failed refresh report saved state separately',
    () async {
      var reads = 0;
      final api = ApiClient(
        baseUrl: 'http://server/api/v1',
        client: MockClient((r) async {
          if (r.method != 'GET') {
            return json({
              'data': {'id': id},
              'revision': 2,
            });
          }
          if (reads++ == 0) return json(snapshot());
          throw http.ClientException('offline after commit');
        }),
      );
      addTearDown(api.close);
      final store = await WorkspaceStore.connect(api);
      addTearDown(store.dispose);
      await store.saveProperty(property);
      expect(store.refreshError, contains('was saved'));
      expect(store.properties, isEmpty);
    },
  );
  test(
    'expired sessions notify the sign-in gate and cannot silently load samples',
    () async {
      var expired = false;
      final api = ApiClient(
        baseUrl: 'http://server/api/v1',
        client: MockClient(
          (r) async => json({
            'error': {'message': 'Sign in again.', 'code': 'UNAUTHENTICATED'},
          }, 401),
        ),
      )..onSessionExpired = () => expired = true;
      addTearDown(api.close);
      await expectLater(
        WorkspaceStore.connect(api),
        throwsA(isA<ApiException>()),
      );
      expect(expired, isTrue);
    },
  );
  testWidgets('viewer has no property creation control', (tester) async {
    final api = ApiClient(
      baseUrl: 'http://server/api/v1',
      client: MockClient((r) async => json(snapshot(viewer: true))),
    );
    addTearDown(api.close);
    final store = await WorkspaceStore.connect(api);
    addTearDown(store.dispose);
    await tester.pumpWidget(KwadraApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Properties').last);
    await tester.pumpAndSettle();
    expect(find.byType(PropertiesPage), findsOneWidget);
    expect(find.text('Add property'), findsNothing);
  });
  testWidgets(
    'sample payment completes without changing workspace or calling API',
    (tester) async {
      final store = await WorkspaceStore.open();
      addTearDown(store.dispose);
      final before = store.exportJson();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PaymentPreviewPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue sample'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, '2000.00');
      await tester.ensureVisible(find.text('Review sample'));
      await tester.tap(find.text('Review sample'));
      await tester.pumpAndSettle();
      expect(find.text('Illustrative remaining amount'), findsOneWidget);
      await tester.ensureVisible(find.text('Finish preview'));
      await tester.tap(find.text('Finish preview'));
      await tester.pumpAndSettle();
      expect(find.text('Preview complete'), findsOneWidget);
      expect(store.exportJson(), before);
      expect(tester.takeException(), isNull);
    },
  );
}
