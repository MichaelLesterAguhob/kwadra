import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kwadra_management/data/api_client.dart';
import 'package:kwadra_management/features/account_notifications.dart';
import 'package:kwadra_management/features/sign_in.dart';

http.Response json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);
void main() {
  testWidgets(
    'notification preferences and read actions use the personal backend endpoints',
    (tester) async {
      var inApp = true, read = false;
      final api = ApiClient(
        baseUrl: 'http://server/api/v1',
        client: MockClient((r) async {
          if (r.url.path.endsWith('/auth/providers')) {
            return json({
              'google': {'enabled': false},
            });
          }
          if (r.method == 'PUT') {
            expect(r.url.path, '/api/v1/account/notification-preferences');
            final body = jsonDecode(r.body);
            inApp = body['inApp'];
            expect(body.keys.toList(), ['inApp']);
            return json({'data': body});
          }
          if (r.method == 'POST') {
            expect(r.url.path, '/api/v1/account/notifications/read');
            expect(jsonDecode(r.body)['ids'], ['notice-one']);
            read = true;
            return json({});
          }
          return json({
            'notifications': [
              {
                'id': 'notice-one',
                'title': 'Viewing update',
                'body': 'Your viewing is confirmed.',
                'readAt': read ? '2026-10-25' : null,
                'inquiryId': null,
              },
            ],
            'unread': read ? 0 : 1,
            'preferences': {'inApp': inApp},
          });
        }),
      );
      await tester.pumpWidget(
        MaterialApp(home: AccountNotificationsPage(api: api)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your viewing is confirmed.'), findsOneWidget);
      await tester.tap(find.text('In-app updates'));
      await tester.pumpAndSettle();
      expect(inApp, false);
      await tester.tap(find.text('Mark all read'));
      await tester.pumpAndSettle();
      expect(read, true);
      expect(find.text('Mark all read'), findsNothing);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
      api.close();
    },
  );
  testWidgets('verification resend is available without signing in', (
    tester,
  ) async {
    var queued = false;
    final api = ApiClient(
      baseUrl: 'http://server/api/v1',
      client: MockClient((r) async {
        if (r.method == 'GET') {
          return json({
            'google': {'enabled': false},
          });
        }
        expect(r.url.path, '/api/v1/identity/resend-verification');
        expect(r.headers['Authorization'], null);
        expect(jsonDecode(r.body)['email'], 'renter@example.com');
        queued = true;
        return json({'message': 'If needed, verification was queued.'});
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SignInPage(client: () => api, configureServer: () async {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Account options'));
    await tester.tap(find.text('Account options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resend verification email'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email address').last,
      'renter@example.com',
    );
    await tester.tap(find.text('Send verification email'));
    await tester.pumpAndSettle();
    expect(queued, true);
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox.shrink());
    api.close();
  });
}
