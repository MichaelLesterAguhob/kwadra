import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/workspace_store.dart';
import '../ui/components.dart';
import 'forms.dart';
import 'operations.dart';

Future<void> showUnitDetails(
  BuildContext context,
  WorkspaceStore store,
  String id,
) => showDetails(
  context,
  title: 'Unit ${store.unit(id).code}',
  child: ListenableBuilder(
    listenable: store,
    builder: (ctx, _) {
      final u = store.unit(id),
          lease = store.currentLease(id),
          history = store.leasesForUnit(id);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusPill(store.unitStatus(u)),
          const SizedBox(height: 16),
          detailRow('Property', store.property(u.propertyId).name),
          detailRow('Unit type', u.type),
          detailRow('Floor', u.floor),
          detailRow('Capacity', '${u.capacity} people'),
          detailRow('Monthly rent', money(u.rent)),
          const SizedBox(height: 20),
          const SectionHeading('Lease history'),
          const SizedBox(height: 8),
          if (history.isEmpty)
            const Text(
              'No leases yet.',
              style: TextStyle(fontSize: 14, color: KColors.muted),
            )
          else
            ...history.map(
              (l) => RecordTile(
                title: store.leaseNames(l),
                subtitle: '${shortDate(l.start)} – ${shortDate(l.end)}',
                trailing: StatusPill(leaseStatus(l, store.today)),
                onTap: () => showLeaseDetails(context, store, l.id),
              ),
            ),
          const SizedBox(height: 22),
          if (store.canWrite)
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      if (lease == null &&
                          !u.maintenance &&
                          !store.property(u.propertyId).archived) {
                        createLease(context, store, unitId: id);
                      } else {
                        editUnit(context, store, u.propertyId, u);
                      }
                    },
                    child: Text(
                      lease == null &&
                              !u.maintenance &&
                              !store.property(u.propertyId).archived
                          ? 'Create lease'
                          : 'Edit unit',
                    ),
                  ),
                ),
                if (lease == null &&
                    !u.maintenance &&
                    !store.property(u.propertyId).archived) ...[
                  const SizedBox(width: 8),
                  ActionsMenu(
                    actions: [
                      (
                        'Edit unit',
                        Icons.edit_outlined,
                        () => editUnit(context, store, u.propertyId, u),
                      ),
                    ],
                  ),
                ],
              ],
            ),
        ],
      );
    },
  ),
);

Future<void> showTenantDetails(
  BuildContext context,
  WorkspaceStore store,
  String id,
) => showDetails(
  context,
  title: 'Tenant profile',
  child: ListenableBuilder(
    listenable: store,
    builder: (ctx, _) {
      final t = store.tenant(id),
          leases = store.leases.where((l) => l.tenantIds.contains(id)).toList();
      final active = leases.any((l) => l.activeAt(store.today));
      Future<void> archive() async {
        final approved = await confirmAction(
          context,
          title: t.archived ? 'Restore tenant?' : 'Archive tenant?',
          message: 'Rental history will be kept. Any current or upcoming leases must be ended before archiving.',
          confirm: t.archived ? 'Restore' : 'Archive',
        );
        if (approved && context.mounted) {
          await runAction(
            context,
            () => store.saveTenant(
              Tenant(
                id: t.id,
                revision: t.revision,
                name: t.name,
                email: t.email,
                phone: t.phone,
                emergency: t.emergency,
                archived: !t.archived,
              ),
            ),
            'Tenant updated.',
          );
        }
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PersonAvatar(t.name, size: 52),
              const SizedBox(width: 15),
              Expanded(
                child: Text(
                  t.name,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          detailRow('Phone', t.phone.isEmpty ? 'Not provided' : t.phone),
          detailRow('Email', t.email.isEmpty ? 'Not provided' : t.email),
          if (t.emergency.isNotEmpty) detailRow('Emergency', t.emergency),
          const SizedBox(height: 20),
          const SectionHeading('Rental history'),
          const SizedBox(height: 8),
          if (leases.isEmpty)
            const Text(
              'No leases yet.',
              style: TextStyle(fontSize: 14, color: KColors.muted),
            )
          else
            ...leases.map(
              (l) => RecordTile(
                title: store.unitLabel(l.unitId),
                subtitle:
                    '${shortDate(l.start)} – ${shortDate(l.end)}\n${money(l.rent)} / month',
                trailing: StatusPill(leaseStatus(l, store.today)),
                onTap: () => showLeaseDetails(context, store, l.id),
              ),
            ),
          const SizedBox(height: 22),
          if (store.canManageTenants)
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      if (!active && !t.archived) {
                        createLease(context, store, tenantId: id);
                      } else {
                        editTenant(context, store, t);
                      }
                    },
                    child: Text(
                      !active && !t.archived ? 'Create lease' : 'Edit tenant',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ActionsMenu(
                  tooltip: 'Tenant actions',
                  actions: [
                    if (!active && !t.archived)
                      (
                        'Edit tenant',
                        Icons.edit_outlined,
                        () => editTenant(context, store, t),
                      ),
                    if (!t.archived && active)
                      (
                        'Create lease',
                        Icons.description_outlined,
                        () => createLease(context, store, tenantId: id),
                      ),
                    (
                      t.archived ? 'Restore tenant' : 'Archive tenant',
                      t.archived
                          ? Icons.unarchive_outlined
                          : Icons.archive_outlined,
                      archive,
                    ),
                  ],
                ),
              ],
            ),
        ],
      );
    },
  ),
);
