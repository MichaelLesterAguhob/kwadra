import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/models.dart';
import '../ui/components.dart';
import 'phase_widgets.dart';

class PlatformConsole extends StatefulWidget {
  const PlatformConsole({super.key, required this.api});
  final ApiClient api;
  @override
  State<PlatformConsole> createState() => _PlatformConsoleState();
}

class _PlatformConsoleState extends State<PlatformConsole> {
  int tab = 0;
  Key reloadKey = UniqueKey();
  ApiClient get api => widget.api;
  Future<void> command(String path, Json body, {String method = 'PUT'}) async {
    await api.request(method, path, body: body);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Kwadra moderation'),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          onPressed: () => setState(() => reloadKey = UniqueKey()),
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: 'Sign out',
          onPressed: () => runAction(context, api.logout, 'Signed out.'),
          icon: const Icon(Icons.logout),
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (v) => setState(() => tab = v),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.verified_user_outlined),
          label: 'Publishers',
        ),
        NavigationDestination(
          icon: Icon(Icons.storefront_outlined),
          label: 'Listings',
        ),
        NavigationDestination(
          icon: Icon(Icons.flag_outlined),
          label: 'Reports',
        ),
        NavigationDestination(icon: Icon(Icons.history), label: 'History'),
      ],
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: RemoteContent(
              key: reloadKey,
              load: () => api.request('GET', '/platform/review'),
              builder: (context, data, reload) {
                Future<void> action(Future<void> Function() work) async {
                  await runAction(context, work, 'Review saved.');
                  await reload();
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PageHeading(
                      title: [
                        'Publisher reviews',
                        'Listing reviews',
                        'Reports & appeals',
                        'Moderation history',
                      ][tab],
                      subtitle: 'MFA-protected moderation. Tenant contracts and financial records are outside this console.',
                    ),
                    const SizedBox(height: 24),
                    if (tab == 0)
                      RecordList(
                        children: records(data, 'verifications')
                            .map(
                              (v) => RecordTile(
                                title: v['name'],
                                subtitle: v['status'],
                                onTap: () =>
                                    action(() => publisher(context, v)),
                              ),
                            )
                            .toList(),
                      ),
                    if (tab == 1)
                      RecordList(
                        children: records(data, 'listings')
                            .map(
                              (l) => RecordTile(
                                title: l['title'],
                                subtitle:
                                    '${l['status']} · ${l['duplicateFlags']} possible duplicates',
                                onTap: () =>
                                    action(() => listing(context, l['id'])),
                              ),
                            )
                            .toList(),
                      ),
                    if (tab == 2) ...[
                      const SectionHeading('Reports'),
                      const SizedBox(height: 12),
                      RecordList(
                        children: records(data, 'reports')
                            .map(
                              (r) => RecordTile(
                                title: r['title'],
                                subtitle: '${r['reason']} · ${r['status']}',
                                onTap: () => action(
                                  () => listing(context, r['listingId']),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                      const SizedBox(height: 22),
                      const SectionHeading('Review cases'),
                      ...records(data, 'cases').map(
                        (c) => ListTile(
                          title: Text(c['title']),
                          subtitle: Text('${c['status']} · ${c['reason']}'),
                          onTap: () async {
                            await showDetails(
                              context,
                              title: 'Review history',
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  ...records(data, 'caseEvents')
                                      .where((e) => e['caseId'] == c['id'])
                                      .map(
                                        (e) => Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 12,
                                          ),
                                          child: Text(e['detail']),
                                        ),
                                      ),
                                  FilledButton(
                                    onPressed: () async {
                                      Navigator.pop(context);
                                      await action(
                                        () => listing(context, c['listingId']),
                                      );
                                    },
                                    child: const Text('Review listing'),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                    if (tab == 3)
                      RecordList(
                        children: records(data, 'events')
                            .map(
                              (e) => RecordTile(
                                title: e['action'],
                                subtitle: '${e['reason']}\n${e['created']}',
                                onTap: null,
                              ),
                            )
                            .toList(),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  Future<void> publisher(BuildContext context, Json v) async {
    String status = 'verified';
    bool reviewed = false;
    final reason = TextEditingController();
    await editor(
      context,
      title: 'Review publisher',
      fields: (set) => Column(
        children: [
          Text(v['name'], style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(v['notes']),
          if (v['attachmentId'] != null)
            TextButton.icon(
              onPressed: () => downloadAttachment(
                context,
                (p) => api.request('GET', p),
                v['attachmentId'],
                platform: true,
              ),
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Open submitted evidence'),
            ),
          choice('Decision', status, {
            'verified': 'Approve publisher',
            'rejected': 'Reject / revoke review',
          }, (s) => set(() => status = s)),
          if (status == 'verified')
            CheckboxListTile(
              title: const Text('I reviewed the submitted evidence'),
              value: reviewed,
              onChanged: (b) => set(() => reviewed = b == true),
            ),
          field('Review reason', reason, lines: 4),
        ],
      ),
      save: () async {
        if (status == 'verified' && !reviewed) {
          throw const FormatException('Review the evidence before approving.');
        }
        await command('/platform/publishers/${v['organizationId']}', {
          'revision': v['revision'],
          'status': status,
          'reason': reason.text,
          'evidenceReviewed': reviewed,
        });
      },
    );
    reason.dispose();
  }

  Future<void> listing(BuildContext context, String id) async {
    final preview = await api.request('GET', '/platform/listings/$id/preview');
    if (!context.mounted) return;
    final l = Json.from(preview['listing']);
    String status = l['status'] == 'pending' ? 'approved' : 'unpublished';
    final reason = TextEditingController();
    await editor(
      context,
      title: 'Review listing',
      fields: (set) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l['title'], style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          Text(l['location']),
          Text(l['description']),
          const SizedBox(height: 12),
          Text('Publisher: ${l['publisherName']}'),
          TextButton.icon(
            onPressed: () async {
              await publisherAccount(context, l);
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.manage_accounts_outlined),
            label: const Text('Manage publisher access'),
          ),
          ...records(preview, 'photos').map(
            (p) => TextButton.icon(
              onPressed: () => downloadAttachment(
                context,
                (path) => api.request('GET', path),
                p['id'],
                platform: true,
              ),
              icon: const Icon(Icons.image_outlined),
              label: Text(p['filename']),
            ),
          ),
          choice('Decision', status, {
            'approved': 'Approve / restore publication',
            'rejected': 'Reject submission',
            'unpublished': 'Take down listing',
          }, (v) => set(() => status = v)),
          field('Review reason', reason, lines: 4),
        ],
      ),
      save: () => command('/platform/listings/$id', {
        'revision': l['revision'],
        'status': status,
        'reason': reason.text,
      }),
    );
    reason.dispose();
  }

  Future<void> publisherAccount(BuildContext context, Json l) async {
    bool disabled = l['publisherDisabled'] != true;
    final reason = TextEditingController();
    await editor(
      context,
      title: 'Publisher account',
      fields: (set) => Column(
        children: [
          Text(l['publisherEmail']),
          SwitchListTile(
            title: const Text('Suspend publisher'),
            subtitle: const Text(
              'Suspension revokes sessions and hides all listings from this publisher.',
            ),
            value: disabled,
            onChanged: (v) => set(() => disabled = v),
          ),
          field('Reason for this decision', reason, lines: 4),
        ],
      ),
      save: () => command('/platform/accounts', {
        'userId': l['publisherId'],
        'disabled': disabled,
        'reason': reason.text,
      }, method: 'POST'),
    );
    reason.dispose();
  }
}
