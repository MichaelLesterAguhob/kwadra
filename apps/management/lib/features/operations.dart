import 'package:flutter/material.dart';

import '../core/export_file.dart';
import '../core/formatters.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/workspace_store.dart';
import '../ui/components.dart';
import 'forms.dart';
import 'operation_details.dart';
export 'operation_details.dart';

class LeasesPage extends StatefulWidget {
  const LeasesPage({super.key, required this.store});
  final WorkspaceStore store;
  @override
  State<LeasesPage> createState() => _LeasesPageState();
}

class _LeasesPageState extends State<LeasesPage> {
  String query = '', filter = 'All leases';
  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final leases =
        store.leases
            .where(
              (l) =>
                  (filter == 'All leases' ||
                      leaseStatus(l, store.today) == filter) &&
                  '${store.leaseNames(l)} ${store.unitLabel(l.unitId)}'
                      .toLowerCase()
                      .contains(query.toLowerCase()),
            )
            .toList()
          ..sort((a, b) => b.start.compareTo(a.start));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeading(
          title: 'Leases',
          subtitle: 'Rental agreements, tenants and dates.',
          action: store.canWrite
              ? FilledButton.icon(
                  onPressed: () => createLease(context, store),
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('Create lease'),
                )
              : null,
        ),
        const SizedBox(height: 24),
        SearchFilter(
          hint: 'Find a tenant or unit',
          onChanged: (v) => setState(() => query = v),
          values: const [
            'All leases',
            'Draft',
            'Active',
            'Upcoming',
            'Ended',
            'Expired',
          ],
          selected: filter,
          onSelected: (v) => setState(() => filter = v),
        ),
        const SizedBox(height: 18),
        if (leases.isEmpty)
          const Surface(
            child: EmptyState(
              title: 'No leases found',
              message: 'Create a lease or try a different search.',
            ),
          )
        else
          LayoutBuilder(
            builder: (ctx, box) => box.maxWidth < 720
                ? RecordList(
                    children: leases
                        .map(
                          (l) => RecordTile(
                            title: store.leaseNames(l),
                            subtitle:
                                '${store.unitLabel(l.unitId)}\n${shortDate(l.start)} – ${shortDate(l.end)}',
                            trailing: StatusPill(leaseStatus(l, store.today)),
                            onTap: () => showLeaseDetails(context, store, l.id),
                          ),
                        )
                        .toList(),
                  )
                : Surface(
                    padding: EdgeInsets.zero,
                    child: RecordTable(
                      minWidth: 800,
                      columns: const [
                        'Tenant & unit',
                        'Lease dates',
                        'Monthly rent',
                        'Status',
                      ],
                      rows: leases
                          .map(
                            (l) => DataRow(
                              onSelectChanged: (_) =>
                                  showLeaseDetails(context, store, l.id),
                              cells: [
                                DataCell(
                                  cellText(
                                    store.leaseNames(l),
                                    secondary: store.unitLabel(l.unitId),
                                    bold: true,
                                  ),
                                ),
                                DataCell(
                                  cellText(
                                    shortDate(l.start),
                                    secondary: 'to ${shortDate(l.end)}',
                                  ),
                                ),
                                DataCell(cellText(money(l.rent), bold: true)),
                                DataCell(
                                  StatusPill(leaseStatus(l, store.today)),
                                ),
                              ],
                            ),
                          )
                          .toList(),
                    ),
                  ),
          ),
      ],
    );
  }
}

class BillingPage extends StatefulWidget {
  const BillingPage({super.key, required this.store});
  final WorkspaceStore store;
  @override
  State<BillingPage> createState() => _BillingPageState();
}

class _BillingPageState extends State<BillingPage> {
  late DateTime period = DateTime(
    widget.store.today.year,
    widget.store.today.month,
  );
  String query = '', filter = 'All invoices';
  bool generating = false;
  Future<void> generate() async {
    if (!await confirmAction(
      context,
      title: 'Generate ${monthLabel(period)} rent?',
      message: 'Creates one full monthly charge for each eligible lease. Existing invoices are skipped. No proration or late fees are applied.',
      confirm: 'Generate invoices',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => generating = true);
    try {
      final count = await widget.store.generateInvoices(period);
      if (mounted) {
        toast(
          context,
          count == 0
              ? 'Already up to date. No duplicate invoices created.'
              : '$count invoices created.',
        );
      }
    } catch (error) {
      if (mounted) toast(context, friendlyError(error));
    } finally {
      if (mounted) setState(() => generating = false);
    }
  }

  Future<void> export(List<RentInvoice> invoices) async {
    String safe(String value) {
      final clean = RegExp(r'^[=+\-@\t\r]').hasMatch(value) ? "'$value" : value;
      return '"${clean.replaceAll('"', '""')}"';
    }

    final csv = [
      'Invoice,Tenant,Property and unit,Period,Due date,Amount PHP',
      ...invoices.map((i) {
        final l = widget.store.lease(i.leaseId);
        return [
          safe(i.number),
          safe(widget.store.leaseNames(l)),
          safe(widget.store.unitLabel(l.unitId)),
          i.period,
          i.due.toIso8601String().substring(0, 10),
          (i.amount / 100).toStringAsFixed(2),
        ].join(',');
      }),
    ].join('\r\n');
    try {
      final result = await exportText(
        'kwadra-invoices-${periodKey(period)}.csv',
        csv,
        'text/csv;charset=utf-8',
      );
      if (mounted) toast(context, result);
    } catch (error) {
      if (mounted) toast(context, friendlyError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store,
        all = widget.store.invoices
            .where((i) => i.period == periodKey(period))
            .toList();
    final invoices =
        all
            .where(
              (i) =>
                  (filter != 'Past due date' || i.due.isBefore(store.today)) &&
                  (filter != 'Upcoming' || !i.due.isBefore(store.today)) &&
                  '${i.number} ${store.leaseNames(store.lease(i.leaseId))} ${store.unitLabel(store.lease(i.leaseId).unitId)}'
                      .toLowerCase()
                      .contains(query.toLowerCase()),
            )
            .toList()
          ..sort((a, b) => a.due.compareTo(b.due));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeading(
          title: 'Rent invoices',
          subtitle: 'Monthly rent charges for your leases.',
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (store.canWrite)
                FilledButton.icon(
                  onPressed: generating ? null : generate,
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: Text(generating ? 'Generating…' : 'Generate rent'),
                ),
              if (invoices.isNotEmpty)
                ActionsMenu(
                  tooltip: 'Invoice actions',
                  actions: [
                    (
                      'Export CSV',
                      Icons.file_download_outlined,
                      () => export(invoices),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: periodKey(period),
            style: const TextStyle(
              fontFamily: 'Manrope',
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: KColors.ink,
            ),
            items: List.generate(12, (i) {
              final d = DateTime(store.today.year, store.today.month - i);
              return DropdownMenuItem(
                value: periodKey(d),
                child: Text(monthLabel(d)),
              );
            }),
            onChanged: (v) => setState(() => period = DateTime.parse('$v-01')),
          ),
        ),
        const SizedBox(height: 12),
        Surface(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      money(all.fold(0, (sum, i) => sum + i.amount)),
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${all.length} rent invoices',
                      style: const TextStyle(
                        fontSize: 13,
                        color: KColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.receipt_long_outlined,
                size: 28,
                color: KColors.green,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Rent charges only. Payments are not tracked yet.',
          style: TextStyle(fontSize: 13, color: KColors.muted),
        ),
        const SizedBox(height: 22),
        SearchFilter(
          hint: 'Find an invoice or tenant',
          onChanged: (v) => setState(() => query = v),
          values: const ['All invoices', 'Past due date', 'Upcoming'],
          selected: filter,
          onSelected: (v) => setState(() => filter = v),
        ),
        const SizedBox(height: 18),
        if (invoices.isEmpty)
          const Surface(
            child: EmptyState(
              title: 'No invoices here',
              message: 'Generate rent for this month or change your search.',
            ),
          )
        else
          LayoutBuilder(
            builder: (ctx, box) => box.maxWidth < 720
                ? RecordList(
                    children: invoices.map((i) {
                      final l = store.lease(i.leaseId);
                      return RecordTile(
                        title: store.leaseNames(l),
                        subtitle:
                            '${i.number} · ${store.unit(l.unitId).code}\nDue ${shortDate(i.due)}',
                        trailing: Text(
                          money(i.amount),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: KColors.green,
                          ),
                        ),
                        onTap: () => showInvoiceDetails(context, store, i),
                      );
                    }).toList(),
                  )
                : Surface(
                    padding: EdgeInsets.zero,
                    child: RecordTable(
                      minWidth: 800,
                      columns: const [
                        'Invoice',
                        'Tenant & unit',
                        'Due date',
                        'Rent charge',
                      ],
                      rows: invoices.map((i) {
                        final l = store.lease(i.leaseId);
                        return DataRow(
                          onSelectChanged: (_) =>
                              showInvoiceDetails(context, store, i),
                          cells: [
                            DataCell(cellText(i.number, bold: true)),
                            DataCell(
                              cellText(
                                store.leaseNames(l),
                                secondary: store.unitLabel(l.unitId),
                              ),
                            ),
                            DataCell(cellText(shortDate(i.due))),
                            DataCell(cellText(money(i.amount), bold: true)),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
          ),
      ],
    );
  }
}

class MaintenancePage extends StatefulWidget {
  const MaintenancePage({super.key, required this.store});
  final WorkspaceStore store;
  @override
  State<MaintenancePage> createState() => _MaintenancePageState();
}

class _MaintenancePageState extends State<MaintenancePage> {
  String query = '', filter = 'All requests';
  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final tickets =
        store.tickets
            .where(
              (t) =>
                  (filter == 'All requests' || t.status == filter) &&
                  '${t.title} ${t.category} ${store.unitLabel(t.unitId)}'
                      .toLowerCase()
                      .contains(query.toLowerCase()),
            )
            .toList()
          ..sort((a, b) => b.created.compareTo(a.created));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeading(
          title: 'Repairs',
          subtitle: 'Keep track of what needs fixing.',
          action: store.canWrite
              ? FilledButton.icon(
                  onPressed: () => editTicket(context, store),
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('Add request'),
                )
              : null,
        ),
        const SizedBox(height: 24),
        SearchFilter(
          hint: 'Find a request or unit',
          onChanged: (v) => setState(() => query = v),
          values: const ['All requests', 'Open', 'In progress', 'Resolved'],
          selected: filter,
          onSelected: (v) => setState(() => filter = v),
        ),
        const SizedBox(height: 18),
        if (tickets.isEmpty)
          const Surface(
            child: EmptyState(
              title: 'No requests found',
              message: 'Try another search or add a repair request.',
              icon: Icons.handyman_outlined,
            ),
          )
        else
          RecordList(
            children: tickets
                .map(
                  (t) => RecordTile(
                    title: t.title,
                    subtitle:
                        '${store.unitLabel(t.unitId)}\n${t.category} · ${shortDate(t.created)}',
                    leading: tileIcon(
                      Icons.handyman_outlined,
                      color: t.priority == 'Urgent'
                          ? KColors.red
                          : KColors.green,
                    ),
                    trailing: StatusPill(
                      t.priority == 'Urgent' && t.status != 'Resolved'
                          ? 'Urgent'
                          : t.status,
                    ),
                    onTap: () => showTicketDetails(context, store, t.id),
                  ),
                )
                .toList(),
          ),
      ],
    );
  }
}
