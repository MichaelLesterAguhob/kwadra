import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kwadra_management/data/api_client.dart';
import 'package:kwadra_management/data/models.dart';
import 'package:kwadra_management/features/session.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    final font = FontLoader('Manrope')
      ..addFont(rootBundle.load('assets/fonts/Manrope.ttf'));
    await font.load();
  });
  const listingId = '2972c125-13e3-44a1-8d6d-c10a1444cc37';
  Json rental([String id = listingId]) => {
    'id': id,
    'title': 'Sunny Cebu studio',
    'rent': 650000,
    'moveInCost': 1300000,
    'description': 'A bright rental near the city center.',
    'locationLabel': 'Cebu City',
    'locationPrecision': 'area',
    'latitude': null,
    'longitude': null,
    'type': 'Studio',
    'capacity': 2,
    'photos': [],
    'amenities': [
      {'id': 'wifi', 'name': 'Wi-Fi'},
    ],
    'houseRules': 'Keep shared spaces clean.',
    'contactPolicy': 'inquiry_only',
    'publicPhone': '',
    'publicEmail': '',
  };
  http.Response json(Object value, [int status = 200]) => http.Response(
    jsonEncode(value),
    status,
    headers: {'content-type': 'application/json'},
  );
  Future<void> mount(
    WidgetTester tester,
    ApiClient api, {
    double width = 390,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(BackendApp(api: api));
    await tester.pumpAndSettle();
  }

  Future<void> nav(WidgetTester tester, String text) async {
    await tester.tap(
      find
          .descendant(of: find.byType(NavigationBar), matching: find.text(text))
          .first,
    );
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 390.0, 1440.0]) {
    testWidgets(
      'cold launch lands on public marketplace without login at $width',
      (tester) async {
        final requests = <String>[];
        final api = ApiClient(
          baseUrl: 'http://server/api/v1',
          client: MockClient((r) async {
            requests.add('${r.method} ${r.url.path}');
            expect(r.headers['Authorization'], isNull);
            return json(
              r.url.path.endsWith('/amenities')
                  ? {'data': []}
                  : {
                      'data': [rental()],
                      'total': 1,
                      'page': 1,
                      'pageSize': 12,
                    },
            );
          }),
        );
        await mount(tester, api, width: width);
        expect(find.text('Find your next home.'), findsOneWidget);
        expect(find.text('Sunny Cebu studio'), findsOneWidget);
        expect(find.text('Welcome back'), findsNothing);
        expect(find.byType(NavigationDestination), findsNWidgets(4));
        await nav(tester, 'Saved');
        expect(find.text('Keep your favorites together'), findsOneWidget);
        await nav(tester, 'Messages');
        expect(find.text('Talk to your next landlord'), findsOneWidget);
        expect(
          requests.every((r) => r.startsWith('GET /api/v1/public/')),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'guest detail browsing is open and cancelling sign-in sends no inquiry',
    (tester) async {
      final writes = <String>[];
      final api = ApiClient(
        baseUrl: 'http://server/api/v1',
        client: MockClient((r) async {
          if (r.method != 'GET') writes.add(r.url.path);
          if (r.url.path.endsWith('/amenities')) return json({'data': []});
          if (r.url.path.endsWith(listingId)) return json({'data': rental()});
          return json({
            'data': [rental()],
            'total': 1,
            'page': 1,
            'pageSize': 12,
          });
        }),
      );
      await mount(tester, api);
      await tester.ensureVisible(find.text('Sunny Cebu studio'));
      await tester.tap(find.text('Sunny Cebu studio'));
      await tester.pumpAndSettle();
      expect(find.text('Rental details'), findsOneWidget);
      expect(find.text('About this place'), findsOneWidget);
      await tester.tap(find.text('Message landlord'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Rental details'), findsOneWidget);
      expect(writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'sign-in resumes the requested inquiry and opens an account-owned conversation',
    (tester) async {
      Json? inquiry;
      var signed = false;
      final api = ApiClient(
        baseUrl: 'http://server/api/v1',
        client: MockClient((r) async {
          if (r.url.path.endsWith('/auth/login')) {
            signed = true;
            return json({
              'user': {
                'id': 'renter-one',
                'name': 'Renter One',
                'email': 'renter@example.com',
              },
              'organizations': [],
              'token': 'test-native-token',
              'csrfToken': 'csrf',
            });
          }
          if (r.url.path.endsWith('/marketplace/saved')) {
            return json({
              'data': [rental()],
              'unavailableCount': 0,
            });
          }
          if (r.url.path == '/api/v1/marketplace/inquiries') {
            return json({'data': []});
          }
          if (r.url.path ==
              '/api/v1/marketplace/listings/$listingId/inquiries') {
            expect(signed, isTrue);
            expect(r.headers['Authorization'], 'Bearer test-native-token');
            expect(r.headers['Idempotency-Key'], isNotEmpty);
            inquiry = Json.from(jsonDecode(r.body));
            return json({
              'data': {'id': 'inquiry-one'},
            });
          }
          if (r.url.path.endsWith('/marketplace/inquiries/inquiry-one')) {
            return json({
              'id': 'inquiry-one',
              'title': 'Sunny Cebu studio',
              'status': 'new',
              'messages': [
                {
                  'id': 'one',
                  'sender': 'seeker',
                  'body': inquiry!['message'],
                  'created': '2026-10-18T00:00:00Z',
                },
              ],
              'viewings': [],
            });
          }
          if (r.url.path.endsWith('/amenities')) return json({'data': []});
          if (r.url.path.endsWith(listingId)) return json({'data': rental()});
          return json({
            'data': [rental()],
            'total': 1,
            'page': 1,
            'pageSize': 12,
          });
        }),
      );
      await mount(tester, api);
      await tester.ensureVisible(find.text('Sunny Cebu studio'));
      await tester.tap(find.text('Sunny Cebu studio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Message landlord'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email address'),
        'renter@example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'KwadraDemo!2026',
      );
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Send inquiry'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Your message'),
        'Is this studio still available for a viewing?',
      );
      await tester.ensureVisible(find.text('Send inquiry'));
      await tester.tap(find.text('Send inquiry'));
      await tester.pumpAndSettle();
      expect(
        inquiry?['message'],
        'Is this studio still available for a viewing?',
      );
      expect(inquiry?.containsKey('email'), isFalse);
      expect(find.text('Conversation'), findsOneWidget);
      expect(
        find.text('Is this studio still available for a viewing?'),
        findsOneWidget,
      );
      expect(api.accountKind, 'seeker');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove saved rental'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'search and filters use public API parameters and pagination appends results',
    (tester) async {
      final queries = <Map<String, String>>[];
      final api = ApiClient(
        baseUrl: 'http://server/api/v1',
        client: MockClient((r) async {
          if (r.url.path.endsWith('/amenities')) return json({'data': []});
          queries.add(r.url.queryParameters);
          final second = r.url.queryParameters['page'] == '2';
          return json({
            'data': [
              rental(second ? 'rental-two' : listingId)
                ..['title'] = second ? 'Second rental' : 'Sunny Cebu studio',
            ],
            'total': 2,
            'page': second ? 2 : 1,
            'pageSize': 1,
          });
        }),
      );
      await mount(tester, api);
      await tester.enterText(find.byType(TextField).first, 'Cebu');
      await tester.tap(find.byTooltip('Search rentals'));
      await tester.pumpAndSettle();
      expect(queries.last['q'], 'Cebu');
      await tester.tap(find.byTooltip('Filter rentals'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Max rent (PHP)'),
        '7000',
      );
      await tester.ensureVisible(find.text('Show rentals'));
      await tester.tap(find.text('Show rentals'));
      await tester.pumpAndSettle();
      expect(queries.last['maxRent'], '700000');
      await tester.ensureVisible(find.text('Load more rentals'));
      await tester.tap(find.text('Load more rentals'));
      await tester.pumpAndSettle();
      expect(queries.last['page'], '2');
      expect(find.text('Second rental'), findsOneWidget);
      expect(find.text('Sunny Cebu studio'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed browsing stays on marketplace and exposes retry and server connection',
    (tester) async {
      final api = ApiClient(
        baseUrl: 'http://server/api/v1',
        client: MockClient(
          (r) async => r.url.path.endsWith('/amenities')
              ? json({'data': []})
              : json({
                  'error': {'message': 'Server is temporarily unavailable.'},
                }, 503),
        ),
      );
      await mount(tester, api);
      expect(find.text('Find your next home.'), findsOneWidget);
      expect(find.text('Server is temporarily unavailable.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Server connection'), findsOneWidget);
      expect(find.text('Welcome back'), findsNothing);
    },
  );
}
