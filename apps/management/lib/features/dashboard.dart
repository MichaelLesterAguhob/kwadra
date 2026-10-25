import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../core/navigation.dart';
import '../core/theme.dart';
import '../data/workspace_store.dart';
import '../ui/components.dart';
import 'forms.dart';
import 'operations.dart';
import 'portfolio_charts.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({
    super.key,
    required this.store,
    required this.navigate,
    required this.openProperty,
  });
  final WorkspaceStore store;
  final ValueChanged<AppSection> navigate;
  final ValueChanged<String> openProperty;
  @override
  Widget build(BuildContext context) {
    final requests = [...store.openTickets]
      ..sort(
        (a, b) => (b.priority == 'Urgent' ? 1 : 0).compareTo(
          a.priority == 'Urgent' ? 1 : 0,
        ),
      );
    final properties = store.visibleProperties;
    if (properties.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeading(
            title: 'Hi, ${store.ownerName.split(' ').first}.',
            subtitle: 'Let’s add your first rental property.',
          ),
          const SizedBox(height: 28),
          Surface(
            child: EmptyState(
              title: 'Start with your property',
              message: 'Add a property, then its units and tenants.',
              icon: Icons.home_outlined,
              action: FilledButton.icon(
                onPressed: () => editProperty(context, store),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add property'),
              ),
            ),
          ),
        ],
      );
    }
    final propertyList = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading('Your properties'),
        const SizedBox(height: 14),
        RecordList(
          children: properties.map((p) {
            final units = store.unitsFor(p.id),
                occupied = store
                    .unitsFor(p.id)
                    .where((u) => store.currentLease(u.id) != null)
                    .length;
            return RecordTile(
              title: p.name,
              subtitle:
                  '$occupied of ${units.length} units occupied\n${p.address}',
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(
                  'assets/images/${p.image}.jpg',
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                ),
              ),
              onTap: () => openProperty(p.id),
            );
          }).toList(),
        ),
      ],
    );
    final attention = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading('Needs attention'),
        const SizedBox(height: 14),
        if (requests.isEmpty)
          const Surface(
            child: EmptyState(
              title: 'All caught up',
              message: 'No open repair requests.',
              icon: Icons.check_circle_outline_rounded,
            ),
          )
        else
          RecordList(
            children: requests
                .map(
                  (t) => RecordTile(
                    title: t.title,
                    subtitle: store.unitLabel(t.unitId),
                    leading: tileIcon(
                      Icons.handyman_outlined,
                      color: t.priority == 'Urgent'
                          ? KColors.red
                          : KColors.green,
                    ),
                    trailing: t.priority == 'Urgent'
                        ? const StatusPill('Urgent')
                        : null,
                    onTap: () => showTicketDetails(context, store, t.id),
                  ),
                )
                .toList(),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeading(
          title: 'Hi, ${store.ownerName.split(' ').first}.',
          subtitle: 'Here’s a quick look at your rentals.',
        ),
        const SizedBox(height: 25),
        ResponsiveGrid(
          minWidth: 135,
          maxColumns: 2,
          gap: 14,
          children: [
            _HomeNumber(
              'Occupied',
              '${store.occupiedCount} / ${store.visibleUnits.length}',
              'units',
              Icons.home_outlined,
            ),
            _HomeNumber(
              'Available',
              '${store.availableCount}',
              'ready for a tenant',
              Icons.key_outlined,
            ),
          ],
        ),
        const SizedBox(height: 28),
        LayoutBuilder(
          builder: (ctx, box) => box.maxWidth >= 850
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: propertyList),
                    const SizedBox(width: 24),
                    Expanded(flex: 5, child: attention),
                  ],
                )
              : Column(
                  children: [
                    attention,
                    const SizedBox(height: 28),
                    propertyList,
                  ],
                ),
        ),
      ],
    );
  }
}

class _HomeNumber extends StatelessWidget {
  const _HomeNumber(this.label, this.value, this.detail, this.icon);
  final String label, value, detail;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Surface(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 21, color: KColors.green),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(fontSize: 13, color: KColors.muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        FittedBox(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -.7,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          detail,
          style: const TextStyle(fontSize: 12, color: KColors.muted),
        ),
      ],
    ),
  );
}

class PortfolioSummaryPage extends StatelessWidget {
  const PortfolioSummaryPage({super.key, required this.store});
  final WorkspaceStore store;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const PageHeading(
        title: 'Portfolio summary',
        subtitle: 'A closer look at rent and occupancy.',
      ),
      const SizedBox(height: 24),
      Surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Monthly scheduled rent',
              style: TextStyle(fontSize: 14, color: KColors.muted),
            ),
            const SizedBox(height: 10),
            Text(
              money(store.monthlyRent),
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 6),
            const Text(
              'Based on active leases. This is not money collected.',
              style: TextStyle(fontSize: 13, color: KColors.muted),
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      OccupancyChart(store: store),
      const SizedBox(height: 22),
      PortfolioStatus(
        occupied: store.occupiedCount,
        available: store.availableCount,
        maintenance:
            store.visibleUnits.length -
            store.occupiedCount -
            store.availableCount,
      ),
    ],
  );
}
