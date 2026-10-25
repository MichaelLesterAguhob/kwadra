import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/workspace_store.dart';
import '../ui/components.dart';
import 'operations.dart';
import 'portfolio.dart';

void showGuide(BuildContext context) => showDetails(
  context,
  title: 'A good place to begin',
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Notice(
        'Add a property, create units and tenant profiles, then link them with a lease.',
      ),
      const SizedBox(height: 18),
      ...const [
        (
          '01',
          'Add your property',
          'Give it a name, location, and a few useful notes.',
        ),
        ('02', 'Make room', 'Add rental units, monthly rent, and capacity.'),
        (
          '03',
          'Welcome your tenants',
          'Create their profiles, then link them to a lease.',
        ),
        (
          '04',
          'Keep the details together',
          'Review rent invoices and track maintenance requests.',
        ),
        (
          '05',
          'Keep a copy',
          'Use More → Settings to export a copy of the records you can access.',
        ),
      ].map(
        (step) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: KColors.sage,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  step.$1,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: KColors.green,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      step.$2,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      step.$3,
                      style: const TextStyle(
                        fontSize: 11,
                        color: KColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  ),
);

class WorkspaceSearchDialog extends StatefulWidget {
  const WorkspaceSearchDialog({
    super.key,
    required this.store,
    required this.openProperty,
    required this.rootContext,
  });
  final WorkspaceStore store;
  final ValueChanged<String> openProperty;
  final BuildContext rootContext;
  @override
  State<WorkspaceSearchDialog> createState() => WorkspaceSearchDialogState();
}

class WorkspaceSearchDialogState extends State<WorkspaceSearchDialog> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    bool matches(String value) =>
        value.toLowerCase().contains(query.toLowerCase());
    final results = <(String, String, IconData, VoidCallback)>[
      ...store.visibleProperties
          .where((p) => matches('${p.name} ${p.address}'))
          .map(
            (p) => (
              p.name,
              'Property · ${p.address}',
              Icons.apartment_rounded,
              () => widget.openProperty(p.id),
            ),
          ),
      if (query.isNotEmpty)
        ...store.visibleUnits
            .where(
              (u) => matches('${u.code} ${store.property(u.propertyId).name}'),
            )
            .take(8)
            .map(
              (u) => (
                store.unitLabel(u.id),
                'Unit · ${store.unitStatus(u)}',
                Icons.door_front_door_outlined,
                () => showUnitDetails(widget.rootContext, store, u.id),
              ),
            ),
      ...store.tenants
          .where((t) => !t.archived && matches('${t.name} ${t.email}'))
          .take(query.isEmpty ? 3 : 8)
          .map(
            (t) => (
              t.name,
              'Tenant · ${t.email}',
              Icons.person_outline_rounded,
              () => showTenantDetails(widget.rootContext, store, t.id),
            ),
          ),
      if (query.isNotEmpty)
        ...store.tickets
            .where((t) => matches('${t.title} ${store.unitLabel(t.unitId)}'))
            .take(5)
            .map(
              (t) => (
                t.title,
                'Maintenance · ${store.unitLabel(t.unitId)}',
                Icons.handyman_outlined,
                () => showTicketDetails(widget.rootContext, store, t.id),
              ),
            ),
    ];
    return Dialog(
      child: SizedBox(
        width: 600,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                autofocus: true,
                onChanged: (v) => setState(() => query = v),
                decoration: InputDecoration(
                  hintText: 'Search properties, units, tenants, requests…',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: IconButton(
                    tooltip: 'Close search',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 19),
                  ),
                ),
              ),
              const SizedBox(height: 15),
              Flexible(
                child: SizedBox(
                  height: 370,
                  child: results.isEmpty
                      ? const EmptyState(
                          title: 'Nothing here just yet',
                          message: 'Try another name, unit code, or keyword.',
                        )
                      : ListView(
                          children: results
                              .take(20)
                              .map(
                                (r) => ListTile(
                                  leading: Icon(
                                    r.$3,
                                    color: KColors.green,
                                    size: 20,
                                  ),
                                  title: Text(
                                    r.$1,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  subtitle: Text(
                                    r.$2,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: KColors.muted,
                                    ),
                                  ),
                                  trailing: const Icon(
                                    Icons.north_east_rounded,
                                    size: 15,
                                    color: KColors.muted,
                                  ),
                                  onTap: () {
                                    Navigator.pop(context);
                                    r.$4();
                                  },
                                ),
                              )
                              .toList(),
                        ),
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                'Search a little. Find a lot.',
                style: TextStyle(fontSize: 10, color: KColors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
