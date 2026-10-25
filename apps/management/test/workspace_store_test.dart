import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kwadra_management/core/formatters.dart';
import 'package:kwadra_management/data/models.dart';
import 'package:kwadra_management/data/workspace_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final today = DateTime(2026, 10, 17);
  late WorkspaceStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await WorkspaceStore.open(
      clock: () => DateTime.utc(2026, 10, 17, 4),
    );
  });
  tearDown(() => store.dispose());

  test('billing uses the Manila calendar even before midnight UTC', () async {
    final eveningUtc = await WorkspaceStore.open(
      clock: () => DateTime.utc(2026, 10, 16, 18),
    );
    expect(eveningUtc.today, DateTime(2026, 10, 17));
    eveningUtc.dispose();
  });

  test(
    'seed reconciles properties, occupancy, availability and scheduled rent',
    () {
      expect(store.visibleProperties.length, 3);
      expect(store.visibleUnits.length, 24);
      expect(store.occupiedCount, 18);
      expect(store.availableCount, 5);
      expect(store.monthlyRent, 14400000);
      expect(store.openTickets.length, 4);
      expect(
        store.invoices.fold<int>(0, (n, i) => n + i.amount),
        store.monthlyRent,
      );
    },
  );

  test(
    'money parses centavos exactly and due dates clamp including leap years',
    () {
      expect(parseMoney('₱1,234.56'), 123456);
      expect(parseMoney('0.10'), 10);
      expect(parseMoney('12.345'), isNull);
      expect(parseMoney('-10'), isNull);
      expect(money(123456), '₱1,234.56');
      expect(billingDueDate(DateTime(2028, 2), 31), DateTime(2028, 2, 29));
      expect(billingDueDate(DateTime(2027, 2), 31), DateTime(2027, 2, 28));
    },
  );

  test(
    'concurrent generation is idempotent per lease and billing month',
    () async {
      expect(await store.generateInvoices(today), 0);
      final counts = await Future.wait([
        store.generateInvoices(DateTime(2026, 9)),
        store.generateInvoices(DateTime(2026, 9)),
      ]);
      expect(counts.reduce((a, b) => a + b), 18);
      expect(store.invoices.length, 36);
      expect(
        store.invoices.map((i) => '${i.leaseId}/${i.period}').toSet().length,
        36,
      );
      expect(store.invoices.map((i) => i.number).toSet().length, 36);
    },
  );

  test(
    'future invoice generation is rejected and leaves records unchanged',
    () async {
      final before = store.exportJson();
      await expectLater(
        store.generateInvoices(DateTime(2026, 11)),
        throwsFormatException,
      );
      expect(store.exportJson(), before);
    },
  );

  Lease candidate(
    String id, {
    String unitId = 'u-1-7',
    List<String> tenants = const ['t-0'],
    DateTime? start,
    DateTime? end,
  }) => Lease(
    id: id,
    unitId: unitId,
    tenantIds: tenants,
    start: start ?? today,
    end: end ?? DateTime(2027, 10, 16),
    rent: 950000,
    dueDay: 31,
  );

  test('competing overlapping leases cannot overbook a unit', () async {
    final results = await Future.wait([
      for (final id in ['new-1', 'new-2'])
        store
            .addLease(candidate(id))
            .then((_) => true)
            .catchError((Object _) => false),
    ]);
    expect(results.where((success) => success).length, 1);
    expect(store.leases.where((l) => l.unitId == 'u-1-7').length, 1);
    expect(store.occupiedCount, 19);
  });

  test('capacity permits co-tenants while preventing overflow and duplicate participants', () async {
    await expectLater(
      store.addLease(candidate('too-many', tenants: ['t-0', 't-1', 't-2'])),
      throwsFormatException,
    );
    await expectLater(
      store.addLease(candidate('duplicates', tenants: ['t-0', 't-0'])),
      throwsFormatException,
    );
    await store.addLease(candidate('shared', tenants: ['t-0', 't-1']));
    expect(store.currentLease('u-1-7')!.tenantIds.length, 2);
  });

  test(
    'duplicate unit codes are case insensitive within their property',
    () async {
      final count = store.units.length;
      await expectLater(
        store.saveUnit(
          const RentalUnit(
            id: 'new-unit',
            propertyId: 'p-1',
            code: 'a-01',
            type: 'Studio',
            rent: 500000,
          ),
        ),
        throwsFormatException,
      );
      expect(store.units.length, count);
      await store.saveUnit(
        const RentalUnit(
          id: 'new-unit',
          propertyId: 'p-2',
          code: 'A-01',
          type: 'Studio',
          rent: 500000,
        ),
      );
      expect(store.units.length, count + 1);
    },
  );

  test(
    'maintenance units and archived records cannot get new leases',
    () async {
      await expectLater(
        store.addLease(candidate('maintenance', unitId: 'u-2-8')),
        throwsFormatException,
      );
      await store.saveTenant(
        const Tenant(
          id: 'archived',
          name: 'Archived tenant',
          email: '',
          phone: '',
          archived: true,
        ),
      );
      await expectLater(
        store.addLease(candidate('archived-lease', tenants: ['archived'])),
        throwsFormatException,
      );
    },
  );

  test('active tenancies block property and tenant archival', () async {
    final p = store.property('p-1'), t = store.tenant('t-0');
    await expectLater(
      store.saveProperty(
        RentalProperty(
          id: p.id,
          name: p.name,
          address: p.address,
          type: p.type,
          image: p.image,
          archived: true,
        ),
      ),
      throwsFormatException,
    );
    await expectLater(
      store.saveTenant(
        Tenant(
          id: t.id,
          name: t.name,
          email: t.email,
          phone: t.phone,
          archived: true,
        ),
      ),
      throwsFormatException,
    );
    expect(store.property(p.id).archived, isFalse);
    expect(store.tenant(t.id).archived, isFalse);
  });

  test(
    'ending a lease releases occupancy, keeps history and stops billing',
    () async {
      final invoiceCount = store.invoices.length;
      await store.endLease('l-0');
      expect(store.currentLease('u-1-1'), isNull);
      expect(store.occupiedCount, 17);
      expect(store.invoices.length, invoiceCount);
      expect(store.lease('l-0').occupiedAt(DateTime(2026, 9, 30)), isTrue);
      expect(store.lease('l-0').occupiedAt(today), isFalse);
      await store.generateInvoices(DateTime(2026, 9));
      expect(store.invoices.where((i) => i.leaseId == 'l-0').length, 1);
      expect(store.activities.first.title, 'Rent invoices generated');
    },
  );

  test(
    'cancelled upcoming leases never appear as historical occupancy',
    () async {
      await store.addLease(
        candidate(
          'upcoming',
          start: DateTime(2026, 12),
          end: DateTime(2027, 12),
        ),
      );
      await store.endLease('upcoming');
      expect(store.lease('upcoming').cancelled, isTrue);
      expect(store.lease('upcoming').occupiedAt(DateTime(2027, 1)), isFalse);
    },
  );

  test('invalid restore rolls back partially parsed changes', () async {
    final original = store.exportJson();
    final invalid = jsonDecode(original) as Map<String, dynamic>;
    invalid['ownerName'] = 'Must not persist';
    invalid['units'][0]['propertyId'] = 'missing-property';
    await expectLater(
      store.importJson(jsonEncode(invalid)),
      throwsA(isA<StateError>()),
    );
    expect(store.exportJson(), original);
  });

  test(
    'local changes survive reopening and workspace exports round-trip',
    () async {
      await store.saveTenant(
        const Tenant(
          id: 'new-tenant',
          name: 'New Neighbor',
          email: 'neighbor@example.com',
          phone: '0917 000 0000',
        ),
      );
      final reopened = await WorkspaceStore.open(clock: () => today);
      expect(reopened.tenant('new-tenant').name, 'New Neighbor');
      final backup = store.exportJson();
      await store.clearWorkspace();
      expect(store.properties, isEmpty);
      await store.importJson(backup);
      expect(store.tenant('new-tenant').email, 'neighbor@example.com');
      expect(store.visibleUnits.length, 24);
      reopened.dispose();
    },
  );

  test(
    'maintenance transitions preserve event history and audit activity',
    () async {
      final before = store.tickets
          .firstWhere((t) => t.id == 'm-1')
          .history
          .length;
      await store.updateTicketStatus('m-1', 'In progress');
      await store.updateTicketStatus('m-1', 'Resolved');
      final updated = store.tickets.firstWhere((t) => t.id == 'm-1');
      expect(updated.history.length, before + 2);
      expect(updated.status, 'Resolved');
      expect(store.openTickets.length, 3);
      expect(store.activities.first.kind, 'maintenance');
    },
  );
}
