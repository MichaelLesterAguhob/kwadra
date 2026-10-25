import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../data/api_client.dart';
import '../data/models.dart';
import '../ui/components.dart';
import 'payment_preview.dart';
import 'phase_widgets.dart';

class TenantPortal extends StatefulWidget {
  const TenantPortal({super.key, required this.api});
  final ApiClient api;
  @override
  State<TenantPortal> createState() => _TenantPortalState();
}

class _TenantPortalState extends State<TenantPortal> {
  int tab = 0;
  Key reloadKey = UniqueKey();
  ApiClient get api => widget.api;
  Future<void> command(String path, Json body, {String method = 'POST'}) async {
    await api.request(method, path, body: body);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Brand(small: true),
      actions: [
        if (api.organizations.length > 1)
          PopupMenuButton<String>(
            tooltip: 'Switch workspace',
            onSelected: api.onOrganizationChanged,
            itemBuilder: (_) => api.organizations
                .map(
                  (o) => PopupMenuItem<String>(
                    value: o['id'],
                    child: Text(o['name']),
                  ),
                )
                .toList(),
            icon: const Icon(Icons.swap_horiz_rounded),
          ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: () => setState(() => reloadKey = UniqueKey()),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (v) => setState(() => tab = v),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
        NavigationDestination(
          icon: Icon(Icons.receipt_long_outlined),
          label: 'Charges',
        ),
        NavigationDestination(
          icon: Icon(Icons.handyman_outlined),
          label: 'Repairs',
        ),
        NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
      ],
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: RemoteContent(
              key: reloadKey,
              load: () => api.request('GET', '/tenant/portal'),
              builder: (context, data, reload) {
                final leases = records(data, 'leases');
                final today = data['today'] as String;
                final active = leases
                    .where(
                      (l) =>
                          l['status'] == 'active' &&
                          l['start'].compareTo(today) <= 0 &&
                          l['end'].compareTo(today) >= 0,
                    )
                    .toList();
                Future<void> action(Future<void> Function() work) async {
                  await runAction(context, work, 'Saved.');
                  await reload();
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PageHeading(
                      title: [
                        'Your home',
                        'Your charges',
                        'Your repairs',
                        'More',
                      ][tab],
                      subtitle: tab == 0
                          ? 'Hi, ${data['user']['name'].toString().split(' ').first}. Your tenancy details are here.'
                          : tab == 1
                          ? 'Rent and utility charges linked to your leases.'
                          : tab == 2
                          ? 'Requests you submitted and their progress.'
                          : 'Documents, messages and your account.',
                      action: tab == 2 && active.isNotEmpty
                          ? FilledButton.icon(
                              onPressed: () =>
                                  action(() => repair(context, active)),
                              icon: const Icon(Icons.add),
                              label: const Text('Add request'),
                            )
                          : null,
                    ),
                    const SizedBox(height: 22),
                    if (tab == 0) ...[
                      if (active.isEmpty)
                        const Notice(
                          'You have no current active tenancy. Historical and upcoming leases remain available below.',
                        ),
                      ...leases.map(
                        (l) => Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Surface(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${l['property']} · ${l['unit']}',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 8),
                                Text(l['address']),
                                const SizedBox(height: 18),
                                detailRow(
                                  'Term',
                                  '${l['start']} – ${l['end']}',
                                ),
                                detailRow('Monthly rent', money(l['rent'])),
                                detailRow('Due day', 'Day ${l['dueDay']}'),
                                detailRow('Status', l['status']),
                                if (l['contact'].toString().isNotEmpty)
                                  detailRow('Property contact', l['contact']),
                                TextButton(
                                  onPressed: () => setState(() => tab = 1),
                                  child: const Text('View charges'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (records(data, 'announcements').isNotEmpty) ...[
                        const SectionHeading('Property announcements'),
                        const SizedBox(height: 12),
                        ...records(data, 'announcements').map(
                          (a) => Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: Surface(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    a['title'],
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(a['body']),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ] else if (tab == 1) ...[
                      const Notice(
                        'Payment tracking is not enabled. These are issued charges, not statements of money collected or remaining balances.',
                      ),
                      const SizedBox(height: 16),
                      if (records(data, 'invoices').isEmpty)
                        const Notice(
                          'No charges have been issued for your leases.',
                        ),
                      RecordList(
                        children: records(data, 'invoices')
                            .map(
                              (i) => RecordTile(
                                title: i['number'],
                                subtitle: '${i['kind']} · Due ${i['due']}',
                                trailing: Text(money(i['amount'])),
                                onTap: () => showDetails(
                                  context,
                                  title: i['number'],
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      detailRow('Month', i['period']),
                                      detailRow('Due', i['due']),
                                      detailRow(
                                        'Total charge',
                                        money(i['amount']),
                                      ),
                                      ...records(i, 'items').map(
                                        (item) => detailRow(
                                          item['description'],
                                          money(item['amount']),
                                        ),
                                      ),
                                      const Notice(
                                        'This is not a payment receipt.',
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ] else if (tab == 2) ...[
                      if (records(data, 'tickets').isEmpty)
                        const Notice('No repair requests yet.'),
                      RecordList(
                        children: records(data, 'tickets')
                            .map(
                              (t) => RecordTile(
                                title: t['title'],
                                subtitle:
                                    '${t['status']}${t['closedAt'] != null ? ' · Closed' : ''}',
                                onTap: () => ticket(context, t, data, reload),
                              ),
                            )
                            .toList(),
                      ),
                    ] else ...[
                      const SectionHeading('Your documents'),
                      const SizedBox(height: 12),
                      if (records(data, 'documents').isEmpty)
                        const Notice(
                          'No documents have been shared with you yet.',
                        ),
                      RecordList(
                        children: records(data, 'documents')
                            .map(
                              (d) => RecordTile(
                                title: d['filename'],
                                subtitle: d['leaseId'] != null
                                    ? 'Lease document'
                                    : 'Repair photo',
                                onTap: () => downloadAttachment(
                                  context,
                                  (p) => api.request('GET', p),
                                  d['id'],
                                ),
                              ),
                            )
                            .toList(),
                      ),
                      const SizedBox(height: 24),
                      const SectionHeading('Move-out requests'),
                      const SizedBox(height: 12),
                      ...records(data, 'moveOuts').map(
                        (m) => ListTile(
                          title: Text('${m['requestedOn']} · ${m['status']}'),
                          subtitle: Text(m['notes']),
                        ),
                      ),
                      if (active.isNotEmpty)
                        OutlinedButton(
                          onPressed: () =>
                              action(() => moveOut(context, active)),
                          child: const Text('Request a move-out'),
                        ),
                      const SizedBox(height: 16),
                      const Notice(
                        'Move-out requests do not end your lease automatically. Deposit transactions and financial closeout are disabled.',
                      ),
                      const SizedBox(height: 18),
                      TextButton.icon(
                        onPressed: () => notifications(context),
                        icon: const Icon(Icons.notifications_outlined),
                        label: const Text('Your notifications'),
                      ),
                      TextButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => Scaffold(
                              appBar: AppBar(
                                title: const Text('Payment preview'),
                              ),
                              body: const SingleChildScrollView(
                                padding: EdgeInsets.all(20),
                                child: PaymentPreviewPage(),
                              ),
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.payments_outlined),
                        label: const Text('Try the payment preview'),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: () =>
                            runAction(context, api.logout, 'Signed out.'),
                        icon: const Icon(Icons.logout),
                        label: const Text('Sign out'),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  Future<void> repair(BuildContext context, List<Json> leases) async {
    String lease = leases.first['id'],
        category = 'General',
        priority = 'Normal';
    final title = TextEditingController(),
        description = TextEditingController();
    await editor(
      context,
      title: 'Report a repair',
      saveLabel: 'Send request',
      fields: (set) => Column(
        children: [
          choice('Your home', lease, {
            for (final l in leases) l['id']: '${l['property']} · ${l['unit']}',
          }, (v) => set(() => lease = v)),
          field('Request title', title),
          choice('Category', category, {
            for (final v in [
              'General',
              'Plumbing',
              'Electrical',
              'Appliance',
              'Structural',
              'Other',
            ])
              v: v,
          }, (v) => set(() => category = v)),
          choice('Priority', priority, {
            'Low': 'Low',
            'Normal': 'Normal',
            'Urgent': 'Urgent',
          }, (v) => set(() => priority = v)),
          field('Describe what needs attention', description, lines: 4),
        ],
      ),
      save: () => command('/tenant/tickets', {
        'leaseId': lease,
        'title': title.text,
        'description': description.text,
        'category': category,
        'priority': priority,
      }),
    );
    title.dispose();
    description.dispose();
  }

  Future<void> ticket(
    BuildContext context,
    Json t,
    Json data,
    Future<void> Function() reload,
  ) async {
    Future<void> closeThen(Future<void> Function() work) async {
      Navigator.pop(context);
      await runAction(context, work, 'Saved.');
      await reload();
    }

    await showDetails(
      context,
      title: t['title'],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatusPill(t['status']),
          const SizedBox(height: 12),
          Text(t['description']),
          const SizedBox(height: 20),
          ...records(data, 'history')
              .where((h) => h['ticketId'] == t['id'])
              .map(
                (h) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(h['detail']),
                ),
              ),
          ...records(data, 'comments')
              .where((c) => c['ticketId'] == t['id'])
              .map(
                (c) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(c['body']),
                  subtitle: Text(c['name']),
                ),
              ),
          ...records(data, 'documents')
              .where((d) => d['ticketId'] == t['id'])
              .map(
                (d) => TextButton(
                  onPressed: () => downloadAttachment(
                    context,
                    (p) => api.request('GET', p),
                    d['id'],
                  ),
                  child: Text(d['filename']),
                ),
              ),
          if (t['closedAt'] == null)
            FilledButton(
              onPressed: () => closeThen(() async {
                final body = TextEditingController();
                await editor(
                  context,
                  title: 'Add a comment',
                  fields: (_) => field('Comment', body, lines: 4),
                  save: () => command('/tickets/${t['id']}/comments', {
                    'body': body.text,
                  }),
                );
                body.dispose();
              }),
              child: const Text('Add comment'),
            ),
          TextButton.icon(
            onPressed: () => closeThen(() async {
              final file = await pickAttachment(imagesOnly: true);
              if (file != null) {
                await command('/tickets/${t['id']}/files', file);
              }
            }),
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Add photo'),
          ),
        ],
      ),
    );
  }

  Future<void> moveOut(BuildContext context, List<Json> leases) async {
    String lease = leases.first['id'];
    final day = TextEditingController(
          text: DateTime.now().toIso8601String().substring(0, 10),
        ),
        notes = TextEditingController();
    await editor(
      context,
      title: 'Request move-out',
      note: 'The landlord will review this request and arrange a handover. Financial settlement is not enabled.',
      fields: (set) => Column(
        children: [
          choice('Lease', lease, {
            for (final l in leases) l['id']: '${l['property']} · ${l['unit']}',
          }, (v) => set(() => lease = v)),
          field('Requested date (YYYY-MM-DD)', day),
          field('Notes', notes, optional: true, lines: 3),
        ],
      ),
      save: () => command('/move-outs', {
        'leaseId': lease,
        'requestedOn': day.text,
        'notes': notes.text,
      }),
    );
    day.dispose();
    notes.dispose();
  }

  Future<void> notifications(BuildContext context) async {
    await showDetails(
      context,
      title: 'Your notifications',
      child: RemoteContent(
        load: () => api.request('GET', '/notifications'),
        builder: (context, data, reload) => Column(
          children: [
            SwitchListTile(
              title: const Text('Email updates'),
              value: data['preferences']?['email'] == true,
              onChanged: (v) async {
                await runAction(
                  context,
                  () => command('/notifications/preferences', {
                    'inApp': true,
                    'email': v,
                  }, method: 'PUT'),
                  'Preferences saved.',
                );
                await reload();
              },
            ),
            ...records(data, 'notifications').map(
              (n) => ListTile(
                title: Text(n['title']),
                subtitle: Text(n['body']),
                onTap: () async {
                  await command('/notifications/${n['id']}/read', {});
                  await reload();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
