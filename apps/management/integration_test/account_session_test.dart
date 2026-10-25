import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kwadra_management/data/api_client.dart';
import 'package:kwadra_management/features/session.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('KWADRA_TEST_API_URL');
  const email = String.fromEnvironment(
    'KWADRA_TEST_EMAIL',
    defaultValue: 'renter@example.com',
  );
  const password = String.fromEnvironment(
    'KWADRA_TEST_PASSWORD',
    defaultValue: 'KwadraDemo!2026',
  );
  testWidgets(
    'native secure storage restores account and logout revokes saved credentials',
    (tester) async {
      final first = ApiClient(baseUrl: url);
      await first.login(email, password);
      final expected = first.user['id'];
      first.close();
      final restored = ApiClient(baseUrl: url);
      expect(await restored.restoreSaved(), true);
      expect(restored.user['id'], expected);
      await tester.pumpWidget(BackendApp(api: restored));
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(find.text('Find your next home.'), findsOneWidget);
      await tester.tap(find.text('Account').last);
      await tester.pumpAndSettle();
      expect(find.text(email), findsOneWidget);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      final afterLogout = ApiClient(baseUrl: url);
      expect(await afterLogout.restoreSaved(), false);
      afterLogout.close();
    },
    skip: url.isEmpty,
  );
}
