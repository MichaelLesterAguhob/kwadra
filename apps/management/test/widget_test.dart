import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kwadra_management/app.dart';
import 'package:kwadra_management/data/workspace_store.dart';
import 'package:kwadra_management/ui/components.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    final font = FontLoader('Manrope')
      ..addFont(rootBundle.load('assets/fonts/Manrope.ttf'));
    await font.load();
  });
  Future<WorkspaceStore> load(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final store = await WorkspaceStore.open(
      clock: () => DateTime.utc(2026, 10, 17, 4),
    );
    addTearDown(store.dispose);
    await tester.pumpWidget(KwadraApp(store: store));
    await tester.pumpAndSettle();
    return store;
  }

  Future<void> navTap(WidgetTester tester, String label) async {
    final Finder target;
    if (tester.view.physicalSize.width < 1080) {
      target = find
          .descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          )
          .first;
    } else {
      target = find.widgetWithText(ListTile, label).first;
    }
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> goTo(WidgetTester tester, String label) async {
    if (['Home', 'Properties', 'Tenants', 'More'].contains(label)) {
      await navTap(tester, label);
    } else {
      await navTap(tester, 'More');
      await tester.ensureVisible(find.text(label).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).first);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(PageHeading, label), findsOneWidget);
    }
  }

  testWidgets(
    'desktop property creation validates and persists a new rental unit',
    (tester) async {
      final store = await load(tester, const Size(1440, 1050));
      expect(find.text('Hi, Alex.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await goTo(tester, 'Properties');
      await tester.tap(find.text('The Palm Residences'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Add unit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'A-09');
      await tester.enterText(find.byType(TextFormField).at(1), '6500.50');
      await tester.tap(find.widgetWithText(FilledButton, 'Add unit').last);
      await tester.pumpAndSettle();
      expect(store.unitsFor('p-1').length, 9);
      expect(store.units.firstWhere((u) => u.code == 'A-09').rent, 650050);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tenant form creates a searchable profile', (tester) async {
    final store = await load(tester, const Size(1440, 1050));
    await goTo(tester, 'Tenants');
    await tester.tap(find.widgetWithText(FilledButton, 'Add tenant'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Mika Rivera');
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'mika@example.com',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add tenant').last);
    await tester.pumpAndSettle();
    expect(store.tenants.any((t) => t.name == 'Mika Rivera'), isTrue);
    await tester.enterText(find.byType(TextField).first, 'Mika');
    await tester.pumpAndSettle();
    expect(find.text('Mika Rivera'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 720),
    const Size(390, 844),
    const Size(768, 1024),
    const Size(1440, 1050),
  ]) {
    testWidgets(
      'all destinations render without overflow at ${size.width.toInt()}px',
      (tester) async {
        await load(tester, size);
        expect(tester.takeException(), isNull);
        for (final label in [
          'Properties',
          'Tenants',
          'Leases',
          'Rent invoices',
          'Repairs',
          'Portfolio summary',
          'Activity log',
          'Settings',
        ]) {
          await goTo(tester, label);
          expect(
            tester.takeException(),
            isNull,
            reason: '$label at ${size.width}px',
          );
        }
      },
    );
  }

  testWidgets('global search opens a tenant profile', (tester) async {
    await load(tester, const Size(1440, 1050));
    await tester.tap(find.byTooltip('Search workspace'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Isabel');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Isabel Reyes'));
    await tester.pumpAndSettle();
    expect(find.text('Tenant profile'), findsOneWidget);
    expect(find.text('isabel.reyes@example.com'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a new lease generates one invoice and can be ended without losing it',
    (tester) async {
      final store = await load(tester, const Size(1440, 1100));
      await goTo(tester, 'Leases');
      await tester.tap(find.widgetWithText(FilledButton, 'Create lease'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Isabel Reyes').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create lease').last);
      await tester.pumpAndSettle();
      expect(store.occupiedCount, 19);
      expect(tester.takeException(), isNull);
      await goTo(tester, 'Rent invoices');
      await tester.tap(find.widgetWithText(FilledButton, 'Generate rent'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Generate invoices'));
      await tester.pumpAndSettle();
      expect(store.invoices.length, 19);
      await tester.tap(find.widgetWithText(FilledButton, 'Generate rent'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Generate invoices'));
      await tester.pumpAndSettle();
      expect(store.invoices.length, 19);
      await goTo(tester, 'Leases');
      await tester.tap(find.text('Isabel Reyes').first);
      await tester.pumpAndSettle();
      final endButton = find.widgetWithText(OutlinedButton, 'End lease');
      await tester.ensureVisible(endButton);
      await tester.tap(endButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'End lease'));
      await tester.pumpAndSettle();
      expect(store.occupiedCount, 18);
      expect(store.invoices.length, 19);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone shows four destinations and keeps optional controls tucked away',
    (tester) async {
      await load(tester, const Size(390, 844));
      final navigation = tester.widget<NavigationBar>(
        find.byType(NavigationBar),
      );
      expect(navigation.destinations.length, 4);
      expect(find.byType(FilledButton), findsNothing);
      await goTo(tester, 'Properties');
      await tester.tap(find.widgetWithText(FilledButton, 'Add property'));
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsNWidgets(2));
      expect(find.text('Choose a cover'), findsNothing);
      await tester.tap(find.text('More details (optional)'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a cover'), findsOneWidget);
      await tester.tap(find.byTooltip('Close').last);
      await tester.pumpAndSettle();
      await goTo(tester, 'Settings');
      expect(find.text('Clear workspace'), findsNothing);
      await tester.ensureVisible(find.text('Backup & data'));
      await tester.tap(find.text('Backup & data'));
      await tester.pumpAndSettle();
      expect(find.text('Clear workspace'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
