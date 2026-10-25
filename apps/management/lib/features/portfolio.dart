import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/workspace_store.dart';
import '../ui/components.dart';
import 'forms.dart';
import 'property_card.dart';
import 'record_details.dart';
export 'record_details.dart';

class PropertiesPage extends StatefulWidget {
  const PropertiesPage({
    super.key,
    required this.store,
    required this.openProperty,
    this.selectedId,
    required this.back,
  });
  final WorkspaceStore store;
  final ValueChanged<String> openProperty;
  final String? selectedId;
  final VoidCallback back;
  @override
  State<PropertiesPage> createState() => _PropertiesPageState();
}

class _PropertiesPageState extends State<PropertiesPage> {
  String query = '', filter = 'All properties';
  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    if (widget.selectedId != null) {
      return _PropertyDetails(
        store: store,
        property: store.property(widget.selectedId!),
      );
    }
    final properties = store.properties
        .where(
          (p) =>
              (filter == 'Archived' ? p.archived : !p.archived) &&
              (filter == 'All properties' ||
                  filter == 'Archived' ||
                  p.type == filter) &&
              '${p.name} ${p.address}'.toLowerCase().contains(
                query.toLowerCase(),
              ),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeading(
          title: 'Properties',
          subtitle: 'Your properties and rental units.',
          action: store.canManage
              ? FilledButton.icon(
                  onPressed: () => editProperty(context, store),
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('Add property'),
                )
              : null,
        ),
        const SizedBox(height: 24),
        SearchFilter(
          hint: 'Find a property',
          onChanged: (v) => setState(() => query = v),
          values: const [
            'All properties',
            'Apartment',
            'Boarding house',
            'Condominium',
            'House',
            'Archived',
          ],
          selected: filter,
          onSelected: (v) => setState(() => filter = v),
        ),
        const SizedBox(height: 22),
        if (properties.isEmpty)
          const Surface(
            child: EmptyState(
              title: 'No properties found',
              message: 'Try a different search or add a property.',
              icon: Icons.home_outlined,
            ),
          )
        else
          ResponsiveGrid(
            minWidth: 255,
            maxColumns: 3,
            children: properties
                .map(
                  (p) => PropertyCard(
                    property: p,
                    store: store,
                    onTap: () => widget.openProperty(p.id),
                  ),
                )
                .toList(),
          ),
      ],
    );
  }
}

class _PropertyDetails extends StatefulWidget {
  const _PropertyDetails({required this.store, required this.property});
  final WorkspaceStore store;
  final RentalProperty property;
  @override
  State<_PropertyDetails> createState() => _PropertyDetailsState();
}

class _PropertyDetailsState extends State<_PropertyDetails> {
  String query = '', filter = 'All units';
  Future<void> archive() async {
    final p = widget.property;
    final approved = await confirmAction(
      context,
      title: p.archived ? 'Restore property?' : 'Archive property?',
      message: p.archived ? 'This property will return to your active list.' : 'First end any current or upcoming leases. The property and its rental history will be kept.',
      confirm: p.archived ? 'Restore' : 'Archive',
    );
    if (approved && mounted) {
      await runAction(
        context,
        () => widget.store.saveProperty(
          RentalProperty(
            id: p.id,
            revision: p.revision,
            name: p.name,
            address: p.address,
            type: p.type,
            image: p.image,
            notes: p.notes,
            archived: !p.archived,
          ),
        ),
        'Property updated.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.property,
        store = widget.store,
        units = widget.store.unitsFor(widget.property.id);
    final occupied = units
        .where((u) => store.currentLease(u.id) != null)
        .length;
    final visible = units
        .where(
          (u) =>
              (filter == 'All units' || store.unitStatus(u) == filter) &&
              '${u.code} ${u.type}'.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeading(
          title: p.name,
          subtitle: '${p.address}${p.archived ? ' · Archived' : ''}',
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!p.archived && store.canWrite)
                FilledButton.icon(
                  onPressed: () => editUnit(context, store, p.id),
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('Add unit'),
                ),
              const SizedBox(width: 6),
              if (store.canManage)
                ActionsMenu(
                  tooltip: 'Property actions',
                  actions: [
                    (
                      'Edit property',
                      Icons.edit_outlined,
                      () => editProperty(context, store, p),
                    ),
                    (
                      p.archived ? 'Restore property' : 'Archive property',
                      p.archived
                          ? Icons.unarchive_outlined
                          : Icons.archive_outlined,
                      archive,
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Surface(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(
                  'assets/images/${p.image}.jpg',
                  width: 72,
                  height: 72,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$occupied of ${units.length} units occupied',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${units.where((u) => store.unitStatus(u) == 'Available').length} available · ${p.type}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: KColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (p.notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text(
                'About this property',
                style: TextStyle(fontSize: 14),
              ),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Text(
                      p.notes,
                      style: const TextStyle(
                        fontSize: 14,
                        color: KColors.muted,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 24),
        const SectionHeading('Rental units'),
        const SizedBox(height: 14),
        SearchFilter(
          hint: 'Find a unit',
          onChanged: (v) => setState(() => query = v),
          values: const ['All units', 'Occupied', 'Available', 'Maintenance'],
          selected: filter,
          onSelected: (v) => setState(() => filter = v),
        ),
        const SizedBox(height: 18),
        if (visible.isEmpty)
          const Surface(
            child: EmptyState(
              title: 'No units found',
              message: 'Add a unit or try a different filter.',
            ),
          )
        else
          LayoutBuilder(
            builder: (ctx, box) => box.maxWidth < 720
                ? RecordList(
                    children: visible.map((u) {
                      final lease = store.currentLease(u.id);
                      return RecordTile(
                        title: '${u.code} · ${u.type}',
                        subtitle:
                            '${money(u.rent)} / month${lease == null ? '' : '\n${store.leaseNames(lease)}'}',
                        trailing: StatusPill(store.unitStatus(u)),
                        onTap: () => showUnitDetails(context, store, u.id),
                      );
                    }).toList(),
                  )
                : Surface(
                    padding: EdgeInsets.zero,
                    child: RecordTable(
                      minWidth: 700,
                      columns: const [
                        'Unit',
                        'Tenant',
                        'Monthly rent',
                        'Status',
                      ],
                      rows: visible.map((u) {
                        final lease = store.currentLease(u.id);
                        return DataRow(
                          onSelectChanged: (_) =>
                              showUnitDetails(context, store, u.id),
                          cells: [
                            DataCell(
                              cellText(
                                u.code,
                                secondary: '${u.type} · ${u.floor}',
                                bold: true,
                              ),
                            ),
                            DataCell(
                              cellText(
                                lease == null
                                    ? 'No current tenant'
                                    : store.leaseNames(lease),
                              ),
                            ),
                            DataCell(cellText(money(u.rent), bold: true)),
                            DataCell(StatusPill(store.unitStatus(u))),
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

class TenantsPage extends StatefulWidget {
  const TenantsPage({super.key, required this.store});
  final WorkspaceStore store;
  @override
  State<TenantsPage> createState() => _TenantsPageState();
}

class _TenantsPageState extends State<TenantsPage> {
  String query = '', filter = 'All tenants';
  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    List<Lease> tenancies(Tenant t) =>
        store.activeLeases.where((l) => l.tenantIds.contains(t.id)).toList();
    final tenants = store.tenants
        .where(
          (t) =>
              (filter == 'Archived' ? t.archived : !t.archived) &&
              (filter != 'Active' || tenancies(t).isNotEmpty) &&
              (filter != 'No active lease' || tenancies(t).isEmpty) &&
              '${t.name} ${t.email} ${t.phone}'.toLowerCase().contains(
                query.toLowerCase(),
              ),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeading(
          title: 'Tenants',
          subtitle: 'Contact details and rental history.',
          action: store.canManageTenants
              ? FilledButton.icon(
                  onPressed: () => editTenant(context, store),
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('Add tenant'),
                )
              : null,
        ),
        const SizedBox(height: 24),
        SearchFilter(
          hint: 'Find a tenant',
          onChanged: (v) => setState(() => query = v),
          values: const [
            'All tenants',
            'Active',
            'No active lease',
            'Archived',
          ],
          selected: filter,
          onSelected: (v) => setState(() => filter = v),
        ),
        const SizedBox(height: 18),
        if (tenants.isEmpty)
          const Surface(
            child: EmptyState(
              title: 'No tenants found',
              message: 'Try a different search or add a tenant.',
            ),
          )
        else
          LayoutBuilder(
            builder: (ctx, box) => box.maxWidth < 720
                ? RecordList(
                    children: tenants.map((t) {
                      final leases = tenancies(t);
                      return RecordTile(
                        title: t.name,
                        subtitle: leases.isEmpty
                            ? 'No active lease${t.phone.isEmpty ? '' : '\n${t.phone}'}'
                            : '${store.unitLabel(leases.first.unitId)}${t.phone.isEmpty ? '' : '\n${t.phone}'}',
                        leading: PersonAvatar(t.name, size: 40),
                        onTap: () => showTenantDetails(context, store, t.id),
                      );
                    }).toList(),
                  )
                : Surface(
                    padding: EdgeInsets.zero,
                    child: RecordTable(
                      minWidth: 760,
                      columns: const [
                        'Tenant',
                        'Contact',
                        'Current home',
                        'Status',
                      ],
                      rows: tenants.map((t) {
                        final leases = tenancies(t);
                        return DataRow(
                          onSelectChanged: (_) =>
                              showTenantDetails(context, store, t.id),
                          cells: [
                            DataCell(
                              Row(
                                children: [
                                  PersonAvatar(t.name),
                                  const SizedBox(width: 12),
                                  cellText(t.name, bold: true),
                                ],
                              ),
                            ),
                            DataCell(
                              cellText(
                                t.email.isEmpty ? 'No email added' : t.email,
                                secondary: t.phone,
                              ),
                            ),
                            DataCell(
                              cellText(
                                leases.isEmpty
                                    ? 'No active lease'
                                    : store
                                          .property(
                                            store
                                                .unit(leases.first.unitId)
                                                .propertyId,
                                          )
                                          .name,
                                secondary: leases.isEmpty
                                    ? null
                                    : store.unit(leases.first.unitId).code,
                              ),
                            ),
                            DataCell(
                              StatusPill(
                                t.archived
                                    ? 'Archived'
                                    : leases.isEmpty
                                    ? 'Unassigned'
                                    : 'Active',
                              ),
                            ),
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
