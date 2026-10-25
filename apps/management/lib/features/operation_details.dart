import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/workspace_store.dart';
import '../ui/components.dart';
import 'forms.dart';
import 'repair_conversation.dart';

String leaseStatus(Lease l, DateTime today) => l.draft
    ? 'Draft'
    : l.ended
    ? 'Ended'
    : l.activeAt(today)
    ? 'Active'
    : l.start.isAfter(today)
    ? 'Upcoming'
    : 'Expired';

Future<void> showLeaseDetails(
  BuildContext context,
  WorkspaceStore store,
  String id,
) => showDetails(
  context,
  title: 'Lease details',
  child: ListenableBuilder(
    listenable: store,
    builder: (ctx, _) {
      final l = store.lease(id),
          invoices = store.invoices.where((i) => i.leaseId == id).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusPill(leaseStatus(l, store.today)),
          const SizedBox(height: 16),
          detailRow('Home', store.unitLabel(l.unitId)),
          detailRow('Tenant(s)', store.leaseNames(l)),
          detailRow('Starts', shortDate(l.start)),
          detailRow('Ends', shortDate(l.end)),
          detailRow('Monthly rent', money(l.rent)),
          detailRow('Rent due', 'Day ${l.dueDay} of each month'),
          detailRow('Deposit agreed', money(l.deposit)),
          if (store.isRemote && store.canWrite) ...[
            if (l.draft)
              FilledButton(
                onPressed: () => runAction(context, () async {
                  await store.backendCommand('/leases/$id/activate', {
                    'revision': l.revision,
                  });
                }, 'Lease activated.'),
                child: const Text('Activate lease'),
              ),
            if (!l.draft && !l.cancelled)
              TextButton(
                onPressed: () => createLease(context, store, renewalOf: l),
                child: const Text('Renew lease'),
              ),
          ],
          const SizedBox(height: 10),
          const Notice(
            'The deposit shown is a lease term, not a record of funds received. Payment features are outside this build.',
          ),
          const SizedBox(height: 20),
          Text(
            '${invoices.length} rent invoices',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          ...invoices.map(
            (i) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${i.number} · ${i.period}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: KColors.muted,
                      ),
                    ),
                  ),
                  Text(
                    money(i.amount),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (store.canWrite &&
              !l.draft &&
              !l.ended &&
              !l.end.isBefore(store.today)) ...[
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () async {
                if (await confirmAction(
                      context,
                      title: l.start.isAfter(store.today)
                          ? 'Cancel this upcoming lease?'
                          : 'End this lease?',
                      message: 'This will release the unit and stop new recurring charges for this lease. Existing invoices are preserved. This action cannot be undone.',
                      confirm: 'End lease',
                    ) &&
                    context.mounted) {
                  await runAction(
                    context,
                    () => store.endLease(id),
                    'Lease ended. History preserved.',
                  );
                }
              },
              icon: const Icon(Icons.event_busy_outlined, size: 16),
              label: const Text('End lease'),
            ),
          ],
        ],
      );
    },
  ),
);

Future<void> showInvoiceDetails(
  BuildContext context,
  WorkspaceStore store,
  RentInvoice invoice,
) {
  final lease = store.lease(invoice.leaseId);
  return showDetails(
    context,
    title: invoice.number,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Brand(small: true),
        const SizedBox(height: 20),
        Text(
          store.organizationName,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 18),
        detailRow('Billed to', store.leaseNames(lease)),
        detailRow('Home', store.unitLabel(lease.unitId)),
        detailRow('Billing period', invoice.period),
        detailRow('Due date', shortDate(invoice.due)),
        const SizedBox(height: 18),
        const Divider(),
        const SizedBox(height: 18),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Monthly rent',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              money(invoice.amount),
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: KColors.green,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Notice(
          'Local rent invoice preview. This is not a payment receipt or a tax invoice. No payment status or late fees are applied.',
        ),
      ],
    ),
  );
}

Future<void> showTicketDetails(
  BuildContext context,
  WorkspaceStore store,
  String id,
) => showDetails(
  context,
  title: 'Maintenance request',
  child: ListenableBuilder(
    listenable: store,
    builder: (ctx, _) {
      final t = store.tickets.firstWhere((t) => t.id == id);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (store.canWrite)
            Wrap(
              spacing: 8,
              children: [StatusPill(t.status), StatusPill(t.priority)],
            ),
          const SizedBox(height: 18),
          Text(
            t.title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -.5,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            t.description,
            style: const TextStyle(
              fontSize: 13,
              height: 1.8,
              color: KColors.muted,
            ),
          ),
          const SizedBox(height: 20),
          detailRow('Home', store.unitLabel(t.unitId)),
          detailRow('Category', t.category),
          detailRow('Created', shortDate(t.created)),
          const SizedBox(height: 18),
          const Text(
            'Request history',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          ...t.history.map(
            (event) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 5),
                    child: Icon(Icons.circle, size: 5, color: KColors.green),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      event,
                      style: const TextStyle(
                        fontSize: 13,
                        color: KColors.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 22),
          if (store.canWrite)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionsMenu(
                  tooltip: 'Repair actions',
                  actions: [
                    (
                      'Edit request',
                      Icons.edit_outlined,
                      () => editTicket(context, store, t),
                    ),
                    if (store.isRemote)
                      (
                        'Comments & photos',
                        Icons.forum_outlined,
                        () => repairConversation(context, store, id),
                      ),
                  ],
                ),
                FilledButton(
                  onPressed: () => runAction(
                    context,
                    () => store.updateTicketStatus(
                      t.id,
                      t.status == 'Open'
                          ? 'In progress'
                          : t.status == 'In progress'
                          ? 'Resolved'
                          : 'Open',
                    ),
                    'Request status updated.',
                  ),
                  child: Text(
                    t.status == 'Open'
                        ? 'Start work'
                        : t.status == 'In progress'
                        ? 'Mark resolved'
                        : 'Reopen request',
                  ),
                ),
              ],
            ),
        ],
      );
    },
  ),
);
