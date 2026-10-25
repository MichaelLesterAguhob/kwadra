import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kwadra_management/core/theme.dart';
import 'package:kwadra_management/data/api_client.dart';
import 'package:kwadra_management/data/models.dart';
import 'package:kwadra_management/features/platform_console.dart';
import 'package:kwadra_management/features/tenant_portal.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('Manrope')
      ..addFont(rootBundle.load('assets/fonts/Manrope.ttf'));
    await font.load();
  });
  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );
  const lease = {
    'id': 'lease-one',
    'property': 'Test home',
    'unit': 'A1',
    'address': 'Cebu',
    'start': '2026-01-01',
    'end': '2026-12-31',
    'status': 'active',
    'rent': 500000,
    'dueDay': 5,
    'contact': 'Office',
  };
  Json portal({List<Json> tickets = const []}) => {
    'today': '2026-10-18',
    'user': {'name': 'Linked Tenant'},
    'leases': [lease],
    'invoices': [
      {
        'id': 'invoice-one',
        'number': 'RENT-ONE',
        'period': '2026-10',
        'due': '2026-10-05',
        'kind': 'rent',
        'amount': 500000,
        'items': [
          {'description': 'October rent', 'amount': 500000},
        ],
      },
    ],
    'tickets': tickets,
    'documents': [],
    'announcements': [],
    'moveOuts': [],
    'history': [],
    'comments': [],
  };
  Future<void> mount(WidgetTester tester, Widget page, double width) async {
    tester.view.physicalSize = Size(width, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme: kwadraTheme(), home: page));
    await tester.pumpAndSettle();
  }

  Future<void> nav(WidgetTester tester, String label) async {
    await tester.tap(
      find
          .descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 1440.0]) {
    testWidgets(
      'tenant portal shows own itemized charges and four simple tabs at $width',
      (tester) async {
        final requests = <String>[];
        final api = ApiClient(
          baseUrl: 'http://server/api/v1',
          client: MockClient((r) async {
            requests.add(r.url.path);
            return json(portal());
          }),
        );
        addTearDown(api.close);
        await mount(tester, TenantPortal(api: api), width);
        expect(find.text('Test home · A1'), findsOneWidget);
        expect(find.byType(NavigationDestination), findsNWidgets(4));
        await nav(tester, 'Charges');
        await tester.tap(find.text('RENT-ONE'));
        await tester.pumpAndSettle();
        expect(find.text('October rent'), findsOneWidget);
        expect(find.text('This is not a payment receipt.'), findsOneWidget);
        await tester.tap(find.byTooltip('Close').first);
        await tester.pumpAndSettle();
        await nav(tester, 'Repairs');
        expect(find.text('Add request'), findsOneWidget);
        await nav(tester, 'More');
        expect(find.text('Your documents'), findsOneWidget);
        expect(requests.every((p) => p == '/api/v1/tenant/portal'), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'tenant repair submission persists through API and reloads server data',
    (tester) async {
      Json? saved;
      final api = ApiClient(
        baseUrl: 'http://server/api/v1',
        client: MockClient((r) async {
          if (r.method == 'POST') {
            expect(r.url.path, '/api/v1/tenant/tickets');
            expect(r.headers['Idempotency-Key'], isNotEmpty);
            saved = Json.from(jsonDecode(r.body));
            return json({
              'data': {'id': 'repair-one'},
              'revision': 2,
            });
          }
          return json(
            portal(
              tickets: saved == null
                  ? []
                  : [
                      {
                        'id': 'repair-one',
                        'title': saved!['title'],
                        'status': 'Open',
                        'closedAt': null,
                      },
                    ],
            ),
          );
        }),
      );
      addTearDown(api.close);
      await mount(tester, TenantPortal(api: api), 390);
      await nav(tester, 'Repairs');
      await tester.tap(find.text('Add request'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'Leaking tap');
      await tester.enterText(
        fields.at(1),
        'The kitchen tap leaks continuously.',
      );
      await tester.ensureVisible(find.text('Send request').last);
      await tester.tap(find.text('Send request').last);
      await tester.pumpAndSettle();
      expect(saved?['leaseId'], 'lease-one');
      expect(saved?['title'], 'Leaking tap');
      expect(find.text('Leaking tap'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'moderation keeps failed review open and submits a reason with the record revision',
    (tester) async {
      var attempts = 0;
      final api = ApiClient(
        baseUrl: 'http://server/api/v1',
        client: MockClient((r) async {
          if (r.method == 'PUT') {
            expect(r.url.path, '/api/v1/platform/listings/listing-one');
            expect(jsonDecode(r.body), {
              'revision': 7,
              'status': 'approved',
              'reason': 'Evidence and listing reviewed.',
            });
            attempts++;
            if (attempts == 1) {
              return json({
                'error': {
                  'message': 'Temporary review failure.',
                  'code': 'TEMPORARY',
                },
              }, 503);
            }
            return json({
              'data': {'id': 'listing-one'},
              'revision': 8,
            });
          }
          if (r.url.path.endsWith('/preview')) {
            return json({
              'listing': {
                'id': 'listing-one',
                'title': 'Reviewed home',
                'description': 'A detailed description.',
                'location': 'Cebu',
                'status': 'pending',
                'revision': 7,
                'publisherName': 'Owner',
                'publisherEmail': 'owner@example.com',
                'publisherId': 'owner-one',
                'publisherDisabled': false,
              },
              'photos': [],
            });
          }
          return json({
            'verifications': [],
            'listings': [
              {
                'id': 'listing-one',
                'title': 'Reviewed home',
                'status': 'pending',
                'duplicateFlags': 0,
              },
            ],
            'reports': [],
            'cases': [],
            'events': [],
            'caseEvents': [],
          });
        }),
      );
      addTearDown(api.close);
      await mount(tester, PlatformConsole(api: api), 390);
      await nav(tester, 'Listings');
      await tester.tap(find.text('Reviewed home'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField),
        'Evidence and listing reviewed.',
      );
      await tester.ensureVisible(find.text('Save').last);
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(find.text('Temporary review failure.'), findsOneWidget);
      expect(find.text('Review listing'), findsOneWidget);
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('Review listing'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
