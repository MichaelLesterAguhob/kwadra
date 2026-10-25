import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/navigation.dart';
import 'core/theme.dart';
import 'data/workspace_store.dart';
import 'features/dashboard.dart';
import 'features/operations.dart';
import 'features/payment_preview.dart';
import 'features/management_extensions.dart';
import 'features/portfolio.dart';
import 'features/settings.dart';
import 'features/workspace_search.dart';
import 'ui/components.dart';

const primarySections = [
  AppSection.overview,
  AppSection.properties,
  AppSection.tenants,
  AppSection.more,
];

class KwadraApp extends StatelessWidget {
  const KwadraApp({super.key, required this.store});
  final WorkspaceStore store;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Kwadra',
    debugShowCheckedModeBanner: false,
    theme: kwadraTheme(),
    home: WorkspaceShell(store: store),
  );
}

class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({super.key, required this.store});
  final WorkspaceStore store;
  @override
  State<WorkspaceShell> createState() => WorkspaceShellState();
}

class WorkspaceShellState extends State<WorkspaceShell> {
  final scroll = ScrollController();
  AppSection section = AppSection.overview;
  String? propertyId;
  void navigate(AppSection destination) {
    setState(() {
      section = destination;
      propertyId = null;
    });
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  void openProperty(String id) {
    navigate(AppSection.properties);
    setState(() => propertyId = id);
  }

  void back() {
    if (propertyId != null) {
      setState(() => propertyId = null);
    } else {
      navigate(
        primarySections.contains(section)
            ? AppSection.overview
            : AppSection.more,
      );
    }
  }

  void search() => showDialog<void>(
    context: context,
    builder: (_) => WorkspaceSearchDialog(
      store: widget.store,
      openProperty: openProperty,
      rootContext: context,
    ),
  );
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final store = widget.store;
      if (propertyId != null &&
          !store.properties.any((p) => p.id == propertyId)) {
        propertyId = null;
      }
      return LayoutBuilder(
        builder: (context, box) {
          final desktop = box.maxWidth >= 1080;
          final nested =
              propertyId != null || !primarySections.contains(section);
          final selected = primarySections.contains(section)
              ? section
              : AppSection.more;
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.keyK, control: true):
                  search,
              const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
                  search,
            },
            child: PopScope(
              canPop: section == AppSection.overview && propertyId == null,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) back();
              },
              child: Scaffold(
                bottomNavigationBar: desktop
                    ? null
                    : NavigationBar(
                        height: 72,
                        backgroundColor: Colors.white,
                        surfaceTintColor: Colors.transparent,
                        indicatorColor: KColors.sage,
                        selectedIndex: primarySections.indexOf(selected),
                        onDestinationSelected: (index) =>
                            navigate(primarySections[index]),
                        destinations: primarySections
                            .map(
                              (s) => NavigationDestination(
                                icon: Icon(s.icon, size: 24),
                                label: s.label,
                              ),
                            )
                            .toList(),
                      ),
                body: SafeArea(
                  child: Row(
                    children: [
                      if (desktop)
                        SizedBox(
                          width: 225,
                          child: Material(
                            color: Colors.white,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Padding(
                                  padding: EdgeInsets.fromLTRB(24, 28, 20, 18),
                                  child: Brand(),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    25,
                                    0,
                                    20,
                                    32,
                                  ),
                                  child: Text(
                                    store.organizationName,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: KColors.muted,
                                    ),
                                  ),
                                ),
                                ...primarySections.map(
                                  (s) => Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      14,
                                      0,
                                      14,
                                      8,
                                    ),
                                    child: Material(
                                      color: s == selected
                                          ? KColors.sage
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(10),
                                      child: ListTile(
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        leading: Icon(
                                          s.icon,
                                          size: 23,
                                          color: s == selected
                                              ? KColors.green
                                              : KColors.muted,
                                        ),
                                        title: Text(
                                          s.label,
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: s == selected
                                                ? FontWeight.w800
                                                : FontWeight.w600,
                                            color: s == selected
                                                ? KColors.green
                                                : KColors.ink,
                                          ),
                                        ),
                                        onTap: () => navigate(s),
                                      ),
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Row(
                                    children: [
                                      PersonAvatar(store.ownerName),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              store.ownerName,
                                              style: const TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              store.isRemote
                                                  ? 'Connected workspace'
                                                  : 'Local workspace',
                                              style: TextStyle(
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
                              ],
                            ),
                          ),
                        ),
                      Expanded(
                        child: Column(
                          children: [
                            Container(
                              height: 70,
                              padding: EdgeInsets.symmetric(
                                horizontal: desktop ? 32 : 16,
                              ),
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                border: Border(
                                  bottom: BorderSide(color: KColors.line),
                                ),
                              ),
                              child: Row(
                                children: [
                                  if (nested) ...[
                                    IconButton(
                                      tooltip: propertyId != null
                                          ? 'Back to properties'
                                          : 'Back to More',
                                      onPressed: back,
                                      icon: const Icon(
                                        Icons.arrow_back_rounded,
                                        size: 23,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        propertyId != null
                                            ? 'Property details'
                                            : section.label,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ] else
                                    Expanded(
                                      child: desktop
                                          ? Text(
                                              section.label,
                                              style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            )
                                          : const Align(
                                              alignment: Alignment.centerLeft,
                                              child: Brand(small: true),
                                            ),
                                    ),
                                  if (store.isRemote)
                                    if (store.organizations.length > 1)
                                      PopupMenuButton<String>(
                                        tooltip: 'Switch workspace',
                                        onSelected: store.selectOrganization,
                                        itemBuilder: (_) => store.organizations
                                            .map(
                                              (o) => PopupMenuItem<String>(
                                                value: o['id'],
                                                child: Text(o['name']),
                                              ),
                                            )
                                            .toList(),
                                        icon: const Icon(
                                          Icons.swap_horiz_rounded,
                                        ),
                                      ),
                                  if (store.isRemote)
                                    IconButton(
                                      tooltip: 'Refresh workspace',
                                      onPressed: store.refreshing
                                          ? null
                                          : () => runAction(
                                              context,
                                              store.refresh,
                                              'Workspace refreshed.',
                                            ),
                                      icon: const Icon(
                                        Icons.refresh_rounded,
                                        size: 24,
                                      ),
                                    ),
                                  IconButton(
                                    tooltip: 'Search workspace',
                                    onPressed: search,
                                    icon: const Icon(
                                      Icons.search_rounded,
                                      size: 24,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (store.refreshing)
                              const LinearProgressIndicator(minHeight: 2),
                            if (store.refreshError != null)
                              MaterialBanner(
                                content: Text(store.refreshError!),
                                actions: [
                                  TextButton(
                                    onPressed: () => runAction(
                                      context,
                                      store.refresh,
                                      'Workspace refreshed.',
                                    ),
                                    child: const Text('Retry'),
                                  ),
                                ],
                              ),
                            Expanded(
                              child: RefreshIndicator(
                                onRefresh: store.refresh,
                                child: Scrollbar(
                                  controller: scroll,
                                  child: SingleChildScrollView(
                                    controller: scroll,
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    padding: EdgeInsets.fromLTRB(
                                      desktop ? 32 : 18,
                                      desktop ? 30 : 24,
                                      desktop ? 32 : 18,
                                      32,
                                    ),
                                    child: Align(
                                      alignment: Alignment.topCenter,
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 1200,
                                        ),
                                        child: KeyedSubtree(
                                          key: ValueKey(
                                            '${section.name}-$propertyId',
                                          ),
                                          child: switch (section) {
                                            AppSection.team ||
                                            AppSection.utilities ||
                                            AppSection.announcements ||
                                            AppSection.moveOuts ||
                                            AppSection.documents ||
                                            AppSection.listings ||
                                            AppSection.inquiries ||
                                            AppSection.notifications ||
                                            AppSection.deliveries =>
                                              ManagementExtensionsPage(
                                                store: store,
                                                section: section.label,
                                              ),
                                            AppSection.overview =>
                                              DashboardPage(
                                                store: store,
                                                navigate: navigate,
                                                openProperty: openProperty,
                                              ),
                                            AppSection.properties =>
                                              PropertiesPage(
                                                store: store,
                                                selectedId: propertyId,
                                                openProperty: openProperty,
                                                back: () => setState(
                                                  () => propertyId = null,
                                                ),
                                              ),
                                            AppSection.tenants => TenantsPage(
                                              store: store,
                                            ),
                                            AppSection.more => _MorePage(
                                              store: store,
                                              navigate: navigate,
                                            ),
                                            AppSection.leases => LeasesPage(
                                              store: store,
                                            ),
                                            AppSection.billing => BillingPage(
                                              store: store,
                                            ),
                                            AppSection.paymentPreview =>
                                              const PaymentPreviewPage(),
                                            AppSection.maintenance =>
                                              MaintenancePage(store: store),
                                            AppSection.summary =>
                                              PortfolioSummaryPage(
                                                store: store,
                                              ),
                                            AppSection.activity => ActivityPage(
                                              store: store,
                                            ),
                                            AppSection.settings => SettingsPage(
                                              store: store,
                                            ),
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

class _MorePage extends StatelessWidget {
  const _MorePage({required this.store, required this.navigate});
  final WorkspaceStore store;
  final ValueChanged<AppSection> navigate;
  @override
  Widget build(BuildContext context) {
    Widget group(String title, List<(AppSection, String)> sections) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(title),
        const SizedBox(height: 14),
        RecordList(
          children: sections
              .map(
                (item) => RecordTile(
                  title: item.$1.label,
                  subtitle: item.$2,
                  leading: tileIcon(item.$1.icon),
                  onTap: () => navigate(item.$1),
                ),
              )
              .toList(),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeading(
          title: 'More',
          subtitle: 'Everything else, when you need it.',
        ),
        const SizedBox(height: 28),
        ResponsiveGrid(
          minWidth: 330,
          maxColumns: 2,
          gap: 26,
          children: [
            group('Manage your rentals', [
              (AppSection.leases, 'Rental agreements and move-out dates'),
              (AppSection.billing, 'Monthly rent schedules and invoices'),
              (
                AppSection.paymentPreview,
                'Try a sample flow; no payment is saved',
              ),
              (
                AppSection.maintenance,
                '${store.openTickets.length} open repair requests',
              ),
            ]),
            group('Your workspace', [
              (AppSection.summary, 'Rent totals and occupancy trends'),
              (AppSection.activity, 'Review changes to your records'),
              (AppSection.settings, 'Your profile, backups and app settings'),
              if (store.isRemote) ...[
                (AppSection.notifications, 'Updates and delivery preferences'),
                if (store.canManage)
                  (AppSection.team, 'Invitations, roles and property access'),
                if (store.canManage)
                  (AppSection.deliveries, 'Check email delivery attempts'),
              ],
            ]),
            if (store.isRemote)
              group('Property operations', [
                (
                  AppSection.utilities,
                  'Readings, shared bills and charge previews',
                ),
                (AppSection.announcements, 'Messages for your tenants'),
                (AppSection.documents, 'Private lease documents'),
                (AppSection.moveOuts, 'Requests and handover checklists'),
              ]),
            if (store.isRemote)
              group('Find your next tenant', [
                (AppSection.listings, 'Draft and publish available rentals'),
                (AppSection.inquiries, 'Conversations and viewing requests'),
              ]),
          ],
        ),
        const SizedBox(height: 28),
        TextButton.icon(
          onPressed: () => showGuide(context),
          icon: const Icon(Icons.help_outline_rounded, size: 20),
          label: const Text('Getting started'),
        ),
      ],
    );
  }
}
