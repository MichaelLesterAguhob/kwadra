import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/formatters.dart';
import '../data/models.dart';
import '../data/workspace_store.dart';
import '../ui/components.dart';
import 'phase_widgets.dart';

class ManagementExtensionsPage extends StatelessWidget {
  const ManagementExtensionsPage({
    super.key,
    required this.store,
    required this.section,
  });
  final WorkspaceStore store;
  final String section;
  @override
  Widget build(BuildContext context) {
    if (!store.isRemote) {
      return const Notice('Connect to the backend to use this feature.');
    }
    final path = section == 'Team'
        ? '/team'
        : section == 'Notifications'
        ? '/notifications'
        : section == 'Delivery status'
        ? '/deliveries'
        : '/operations';
    return RemoteContent(
      key: ValueKey(section),
      load: () => store.backendGet(path),
      builder: (context, data, reload) {
        Future<void> action(Future<void> Function() work) async {
          await runAction(context, work, 'Saved.');
          await reload();
        }

        VoidCallback? add;
        if (store.canWrite) {
          add = switch (section) {
            'Team' =>
              store.canManage ? () => action(() => invite(context)) : null,
            'Utilities' => () => action(() => meter(context)),
            'Announcements' => () => action(() => announcement(context)),
            'Move-outs' => () => action(() => requestMove(context)),
            'Listings' => () => action(() => listing(context, data)),
            'Documents' => () => action(() => document(context)),
            _ => null,
          };
        }
        final title = section;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeading(
              title: title,
              subtitle: switch (section) {
                'Team' => 'Manage invitations and property access.',
                'Utilities' => 'Review readings and itemized charges.',
                'Listings' =>
                  'Turn available units into public rental listings.',
                'Inquiries' => 'Conversations and viewing requests.',
                'Move-outs' =>
                  'Requests and a nonfinancial handover checklist.',
                'Documents' => 'Private lease documents.',
                'Notifications' => 'Updates for your account.',
                'Delivery status' => 'Delivery attempts and retry status.',
                _ => 'Keep the right people informed.',
              },
              action: add == null
                  ? null
                  : FilledButton.icon(
                      onPressed: add,
                      icon: const Icon(Icons.add_rounded, size: 20),
                      label: Text(switch (section) {
                        'Team' => 'Invite someone',
                        'Utilities' => 'Add meter',
                        'Listings' => 'Add listing',
                        'Documents' => 'Add document',
                        'Move-outs' => 'Request move-out',
                        _ => 'Create announcement',
                      }),
                    ),
            ),
            const SizedBox(height: 24),
            if (section == 'Team') ...[
              RecordList(
                children: records(data, 'members')
                    .map(
                      (m) => RecordTile(
                        title: m['name'],
                        subtitle:
                            '${m['email']} · ${m['role']} · ${m['active'] ? 'Active' : 'Revoked'}',
                        onTap: m['role'] == 'owner'
                            ? null
                            : () => action(() => member(context, m)),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 22),
              const SectionHeading('Invitations'),
              const SizedBox(height: 12),
              ...records(data, 'invitations').map(
                (i) => ListTile(
                  title: Text(i['email']),
                  subtitle: Text(
                    '${i['role']} · ${i['acceptedAt'] != null
                        ? 'Accepted'
                        : DateTime.parse(i['expiresAt']).isBefore(DateTime.now())
                        ? 'Expired'
                        : 'Pending'}',
                  ),
                ),
              ),
            ] else if (section == 'Utilities') ...[
              if (store.canWrite)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => action(() => shared(context)),
                    icon: const Icon(Icons.call_split_rounded),
                    label: const Text('Split a shared utility bill'),
                  ),
                ),
              if (records(data, 'meters').isEmpty)
                const Notice(
                  'Add a meter and its baseline reading. A later reading can be reviewed before you issue a charge.',
                ),
              RecordList(
                children: records(data, 'meters')
                    .map(
                      (m) => RecordTile(
                        title: m['label'],
                        subtitle:
                            '${store.unitLabel(m['unitId'])} · ${money(m['rateCentavos'])} / unit',
                        onTap: () => meterDetails(context, m, data, reload),
                      ),
                    )
                    .toList(),
              ),
            ] else if (section == 'Announcements') ...[
              if (records(data, 'announcements').isEmpty)
                const Notice('No announcements yet.'),
              ...records(data, 'announcements').map(
                (a) => Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Surface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          a['title'],
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          store.property(a['propertyId']).name,
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 12),
                        Text(a['body']),
                      ],
                    ),
                  ),
                ),
              ),
            ] else if (section == 'Move-outs') ...[
              const Notice(
                'This checklist handles handover only. Deposit deductions, refunds, payments and financial closeout are disabled.',
              ),
              const SizedBox(height: 16),
              if (records(data, 'moveOuts').isEmpty)
                const Notice('No move-out requests yet.'),
              RecordList(
                children: records(data, 'moveOuts')
                    .map(
                      (m) => RecordTile(
                        title: store.unitLabel(
                          store.lease(m['leaseId']).unitId,
                        ),
                        subtitle: '${m['requestedOn']} · ${m['status']}',
                        onTap: store.canWrite
                            ? () => action(() => moveOut(context, m))
                            : null,
                      ),
                    )
                    .toList(),
              ),
            ] else if (section == 'Listings') ...[
              Surface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Publisher review: ${data['verification']?['status'] ?? 'Not submitted'}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (store.canManage &&
                        data['verification']?['status'] != 'verified' &&
                        data['verification']?['status'] != 'pending')
                      TextButton(
                        onPressed: () => action(() => verifyPublisher(context)),
                        child: const Text('Submit publisher evidence'),
                      ),
                    const Text(
                      'Only reviewed listings for available units appear publicly.',
                      style: TextStyle(fontSize: 12),
                    ),
                    TextButton(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: marketplaceUrl()),
                      ),
                      child: const Text('Copy marketplace link'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (records(data, 'listings').isEmpty)
                const Notice(
                  'Draft your first rental listing, add photos, then submit it for review.',
                ),
              RecordList(
                children: records(data, 'listings')
                    .map(
                      (l) => RecordTile(
                        title: l['title'],
                        subtitle:
                            '${store.unitLabel(l['unitId'])} · ${l['status']}',
                        onTap: () => listingDetails(context, l, data, reload),
                      ),
                    )
                    .toList(),
              ),
              if (records(data, 'cases').isNotEmpty) ...[
                const SizedBox(height: 22),
                const SectionHeading('Review history'),
                ...records(data, 'cases').map(
                  (c) => ListTile(
                    title: Text(c['reason']),
                    subtitle: Text(c['status']),
                    trailing: store.canWrite && c['status'] == 'resolved'
                        ? TextButton(
                            onPressed: () => action(() => appeal(context, c)),
                            child: const Text('Appeal'),
                          )
                        : null,
                  ),
                ),
              ],
            ] else if (section == 'Inquiries') ...[
              if (records(data, 'inquiries').isEmpty)
                const Notice(
                  'New inquiries from your public listings will appear here.',
                ),
              RecordList(
                children: records(data, 'inquiries')
                    .map(
                      (i) => RecordTile(
                        title: i['name'],
                        subtitle: '${i['email']} · ${i['status']}',
                        onTap: () => inquiry(context, i, data, reload),
                      ),
                    )
                    .toList(),
              ),
            ] else if (section == 'Documents') ...[
              if (records(
                data,
                'documents',
              ).where((d) => d['leaseId'] != null).isEmpty)
                const Notice('No lease documents have been added.'),
              RecordList(
                children: records(data, 'documents')
                    .where((d) => d['leaseId'] != null)
                    .map(
                      (d) => RecordTile(
                        title: d['filename'],
                        subtitle: store.unitLabel(
                          store.lease(d['leaseId']).unitId,
                        ),
                        onTap: () => downloadAttachment(
                          context,
                          store.backendGet,
                          d['id'],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ] else if (section == 'Notifications') ...[
              Surface(
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Email updates'),
                      subtitle: const Text(
                        'Service announcements remain visible in the app.',
                      ),
                      value: data['preferences']?['email'] == true,
                      onChanged: (v) => action(() async {
                        await store.backendCommand(
                          '/notifications/preferences',
                          {
                            'inApp': data['preferences']?['inApp'] ?? true,
                            'email': v,
                          },
                          method: 'PUT',
                        );
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (records(data, 'notifications').isEmpty)
                const Notice('You are all caught up.'),
              RecordList(
                children: records(data, 'notifications')
                    .map(
                      (n) => RecordTile(
                        title: n['title'],
                        subtitle: n['body'],
                        trailing: n['readAt'] == null
                            ? const Icon(Icons.circle, size: 8)
                            : null,
                        onTap: () => action(() async {
                          await store.backendCommand(
                            '/notifications/${n['id']}/read',
                            {},
                          );
                        }),
                      ),
                    )
                    .toList(),
              ),
            ] else if (section == 'Delivery status') ...[
              if (records(data, 'data').isEmpty)
                const Notice('No queued deliveries yet.'),
              RecordList(
                children: records(data, 'data')
                    .map(
                      (d) => RecordTile(
                        title: d['title'],
                        subtitle:
                            '${d['destination']} · ${d['status']} · ${d['attempts']} attempts',
                        onTap: d['status'] == 'failed'
                            ? () => action(() async {
                                await store.backendCommand(
                                  '/deliveries/${d['id']}/retry',
                                  {},
                                );
                              })
                            : null,
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        );
      },
    );
  }

  String marketplaceUrl([String path = '']) =>
      Uri.parse(store.apiUrl)
          .replace(path: '/marketplace$path', query: null, fragment: null)
          .toString();

  Future<void> invite(BuildContext context) async {
    final email = TextEditingController();
    String role = 'staff';
    String? tenantId;
    final selected = <String>{};
    await editor(
      context,
      title: 'Invite someone',
      saveLabel: 'Send invitation',
      note: 'Invitation codes expire in 72 hours. Existing users accept with their current password.',
      fields: (set) => Column(
        children: [
          choice('Access type', role, {
            'staff': 'Staff',
            'viewer': 'Read only',
            'admin': 'Administrator',
            'tenant': 'Tenant portal',
          }, (v) => set(() => role = v)),
          if (role == 'tenant')
            choice(
              'Tenant profile',
              tenantId,
              {
                for (final t in store.tenants.where(
                  (t) => !t.archived && t.email.isNotEmpty,
                ))
                  t.id: t.name,
              },
              (v) => set(() {
                tenantId = v;
                email.text = store.tenant(v).email;
              }),
            ),
          field('Email address', email, keyboard: TextInputType.emailAddress),
          if (['staff', 'viewer'].contains(role))
            ...store.visibleProperties.map(
              (p) => CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(p.name),
                value: selected.contains(p.id),
                onChanged: (v) => set(() {
                  v == true ? selected.add(p.id) : selected.remove(p.id);
                }),
              ),
            ),
        ],
      ),
      save: () async {
        await store.backendCommand('/team/invitations', {
          'email': email.text.trim(),
          'role': role,
          'propertyIds': role == 'tenant' ? [] : selected.toList(),
          if (role == 'tenant') 'tenantId': tenantId,
        });
      },
    );
    email.dispose();
  }

  Future<void> member(BuildContext context, Json m) async {
    String role = m['role'];
    bool active = m['active'], all = m['allProperties'];
    final selected = Set<String>.from(m['propertyIds']);
    await editor(
      context,
      title: 'Member access',
      fields: (set) => Column(
        children: [
          Text(m['name']),
          const SizedBox(height: 16),
          if (role != 'tenant')
            choice('Role', role, {
              'staff': 'Staff',
              'viewer': 'Read only',
              'admin': 'Administrator',
            }, (v) => set(() => role = v)),
          SwitchListTile(
            title: const Text('Access enabled'),
            value: active,
            onChanged: (v) => set(() => active = v),
          ),
          if (!['tenant', 'admin'].contains(role)) ...[
            SwitchListTile(
              title: const Text('All properties'),
              value: all,
              onChanged: (v) => set(() => all = v),
            ),
            if (!all)
              ...store.visibleProperties.map(
                (p) => CheckboxListTile(
                  title: Text(p.name),
                  value: selected.contains(p.id),
                  onChanged: (v) => set(() {
                    v == true ? selected.add(p.id) : selected.remove(p.id);
                  }),
                ),
              ),
          ],
        ],
      ),
      save: () async {
        await store.backendCommand('/team/members/${m['id']}', {
          'role': role,
          'active': active,
          'allProperties': role == 'tenant' ? false : all,
          'propertyIds': role == 'tenant' ? [] : selected.toList(),
        }, method: 'PUT');
      },
    );
  }

  Future<void> meter(BuildContext context) async {
    if (store.visibleUnits.isEmpty) {
      throw const FormatException('Add a rental unit first.');
    }
    String unit = store.visibleUnits.first.id, kind = 'water';
    final label = TextEditingController(), rate = TextEditingController();
    await editor(
      context,
      title: 'Add utility meter',
      fields: (set) => Column(
        children: [
          choice('Unit', unit, {
            for (final u in store.visibleUnits) u.id: store.unitLabel(u.id),
          }, (v) => set(() => unit = v)),
          choice('Utility', kind, {
            'water': 'Water',
            'electricity': 'Electricity',
            'other': 'Other',
          }, (v) => set(() => kind = v)),
          field('Meter label', label),
          field(
            'Rate per consumption unit (PHP)',
            rate,
            keyboard: const TextInputType.numberWithOptions(decimal: true),
          ),
        ],
      ),
      save: () async {
        final cents = parseMoney(rate.text);
        if (cents == null || cents <= 0) {
          throw const FormatException(
            'Enter a positive rate with up to two decimal places.',
          );
        }
        await store.backendCommand('/utilities/meters', {
          'unitId': unit,
          'kind': kind,
          'label': label.text,
          'rateCentavos': cents,
        });
      },
    );
    label.dispose();
    rate.dispose();
  }

  Future<void> meterDetails(
    BuildContext context,
    Json m,
    Json data,
    Future<void> Function() reload,
  ) async {
    await showDetails(
      context,
      title: m['label'],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(store.unitLabel(m['unitId'])),
          const SizedBox(height: 15),
          if (store.canWrite)
            FilledButton(
              onPressed: () async {
                Navigator.pop(context);
                await reading(context, m);
                await reload();
              },
              child: const Text('Add reading'),
            ),
          ...records(data, 'readings')
              .where((r) => r['meterId'] == m['id'])
              .map(
                (r) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${r['value']} · ${r['readOn']}'),
                  subtitle: Text(
                    r['invoiceId'] == null ? 'Not charged' : 'Invoice issued',
                  ),
                  onTap: () async {
                    Navigator.pop(context);
                    await readingDetails(context, r);
                    await reload();
                  },
                ),
              ),
        ],
      ),
    );
  }

  Future<void> reading(BuildContext context, Json m) async {
    final value = TextEditingController(),
        day = TextEditingController(
          text: store.today.toIso8601String().substring(0, 10),
        );
    await editor(
      context,
      title: 'Add reading',
      note: 'The first reading is a baseline. Later readings can be reviewed before issuing an invoice.',
      fields: (_) => Column(
        children: [
          field('Reading date (YYYY-MM-DD)', day),
          field(
            'Meter value (up to 4 decimal places)',
            value,
            keyboard: const TextInputType.numberWithOptions(decimal: true),
          ),
        ],
      ),
      save: () async {
        await store.backendCommand('/utilities/readings', {
          'meterId': m['id'],
          'readOn': day.text.trim(),
          'value': value.text.trim(),
        });
      },
    );
    value.dispose();
    day.dispose();
  }

  Future<void> readingDetails(BuildContext context, Json r) async {
    final preview = await store.backendGet(
      '/utilities/readings/${r['id']}/preview',
    );
    if (!context.mounted) return;
    await showDetails(
      context,
      title: 'Reading preview',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          detailRow('Previous reading', preview['previous'] ?? 'Baseline'),
          detailRow('Current reading', r['value']),
          detailRow('Calculated charge', money(preview['amount'])),
          const SizedBox(height: 14),
          if (preview['canInvoice'] == true && store.canWrite)
            FilledButton(
              onPressed: () async {
                await runAction(context, () async {
                  await store.backendCommand(
                    '/utilities/readings/${r['id']}/issue',
                    {'revision': r['revision'], 'amount': preview['amount']},
                  );
                }, 'Utility invoice issued.');
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Issue utility invoice'),
            ),
          if (r['invoiceId'] == null && store.canWrite)
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                final value = TextEditingController(text: r['value']),
                    reason = TextEditingController();
                await editor(
                  context,
                  title: 'Correct unbilled reading',
                  fields: (_) => Column(
                    children: [
                      field('Corrected value', value),
                      field('Reason for correction', reason, lines: 3),
                    ],
                  ),
                  save: () async {
                    await store.backendCommand(
                      '/utilities/readings/${r['id']}',
                      {
                        'revision': r['revision'],
                        'value': value.text.trim(),
                        'reason': reason.text.trim(),
                      },
                      method: 'PUT',
                    );
                  },
                );
                value.dispose();
                reason.dispose();
              },
              child: const Text('Correct reading'),
            ),
        ],
      ),
    );
  }

  Future<void> shared(BuildContext context) async {
    if (store.visibleProperties.isEmpty) {
      throw const FormatException('Add a property first.');
    }
    String property = store.visibleProperties.first.id;
    final period = TextEditingController(text: periodKey(store.today)),
        amount = TextEditingController(),
        description = TextEditingController();
    Json? preview;
    final ok = await editor(
      context,
      title: 'Shared utility bill',
      saveLabel: 'Preview allocation',
      note: 'Equal share per unit with an eligible active lease. Remaining centavos are allocated in unit-code order.',
      fields: (set) => Column(
        children: [
          choice('Property', property, {
            for (final p in store.visibleProperties) p.id: p.name,
          }, (v) => set(() => property = v)),
          field('Month (YYYY-MM)', period),
          field('Bill reference / description', description),
          field(
            'Total bill (PHP)',
            amount,
            keyboard: const TextInputType.numberWithOptions(decimal: true),
          ),
        ],
      ),
      save: () async {
        final cents = parseMoney(amount.text);
        if (cents == null) throw const FormatException('Enter a valid amount.');
        preview = await store.backendCommand('/utilities/shared/preview', {
          'propertyId': property,
          'period': period.text,
          'amount': cents,
          'description': description.text,
        });
      },
    );
    if (ok && preview != null && context.mounted) {
      final p = preview!;
      final approved = await confirmAction(
        context,
        title: 'Issue shared charges?',
        message: records(
          p,
          'allocations',
        ).map((a) => '${a['unit']}: ${money(a['amount'])}').join('\n'),
        confirm: 'Issue invoices',
      );
      if (approved) {
        await store.backendCommand('/utilities/shared/issue', {
          'propertyId': p['propertyId'],
          'period': p['period'],
          'amount': p['amount'],
          'description': p['description'],
          'expectedAllocations': p['allocations'],
        });
      }
    }
    period.dispose();
    amount.dispose();
    description.dispose();
  }

  Future<void> announcement(BuildContext context) async {
    if (store.visibleProperties.isEmpty) {
      throw const FormatException('Add a property first.');
    }
    String property = store.visibleProperties.first.id;
    final title = TextEditingController(), body = TextEditingController();
    await editor(
      context,
      title: 'Create announcement',
      saveLabel: 'Publish',
      note: 'Only linked tenants in active tenancies at this property receive this announcement.',
      fields: (set) => Column(
        children: [
          choice('Property', property, {
            for (final p in store.visibleProperties) p.id: p.name,
          }, (v) => set(() => property = v)),
          field('Title', title),
          field('Message', body, lines: 5),
        ],
      ),
      save: () async {
        await store.backendCommand('/announcements', {
          'propertyId': property,
          'title': title.text,
          'body': body.text,
        });
      },
    );
    title.dispose();
    body.dispose();
  }

  Future<void> requestMove(BuildContext context) async {
    if (store.activeLeases.isEmpty) {
      throw const FormatException('No current active lease is available.');
    }
    String lease = store.activeLeases.first.id;
    final date = TextEditingController(
          text: store.today.toIso8601String().substring(0, 10),
        ),
        notes = TextEditingController();
    await editor(
      context,
      title: 'Request move-out',
      fields: (set) => Column(
        children: [
          choice('Lease', lease, {
            for (final l in store.activeLeases) l.id: store.unitLabel(l.unitId),
          }, (v) => set(() => lease = v)),
          field('Requested date (YYYY-MM-DD)', date),
          field('Notes', notes, optional: true, lines: 3),
        ],
      ),
      save: () async {
        await store.backendCommand('/move-outs', {
          'leaseId': lease,
          'requestedOn': date.text,
          'notes': notes.text,
        });
      },
    );
    date.dispose();
    notes.dispose();
  }

  Future<void> moveOut(BuildContext context, Json m) async {
    if (['completed', 'cancelled'].contains(m['status'])) {
      await showDetails(
        context,
        title: 'Move-out',
        child: Text('${m['status']}\n${m['notes']}'),
      );
      return;
    }
    String status = 'scheduled';
    final date = TextEditingController(
          text: m['scheduledOn'] ?? m['requestedOn'],
        ),
        notes = TextEditingController(text: m['notes']);
    final checks = Json.from(m['checklist'] ?? {});
    await editor(
      context,
      title: 'Move-out checklist',
      note: 'Completing the handover ends the lease on the server. Deposit and financial settlement remain disabled.',
      fields: (set) => Column(
        children: [
          choice('Status', status, {
            'scheduled': 'Scheduled',
            'completed': 'Complete handover',
            'cancelled': 'Cancel request',
          }, (v) => set(() => status = v)),
          field('Scheduled date (YYYY-MM-DD)', date),
          ...{
            'keysReturned': 'Keys returned',
            'inspectionComplete': 'Inspection complete',
            'recordsReviewed': 'Rental records reviewed',
          }.entries.map(
            (e) => CheckboxListTile(
              title: Text(e.value),
              value: checks[e.key] == true,
              onChanged: (v) => set(() => checks[e.key] = v == true),
            ),
          ),
          field('Notes', notes, optional: true, lines: 3),
        ],
      ),
      save: () async {
        await store.backendCommand('/move-outs/${m['id']}', {
          'revision': m['revision'],
          'status': status,
          'scheduledOn': date.text,
          'notes': notes.text,
          'checklist': {
            for (final k in [
              'keysReturned',
              'inspectionComplete',
              'recordsReviewed',
            ])
              k: checks[k] == true,
          },
        }, method: 'PUT');
      },
    );
    date.dispose();
    notes.dispose();
  }

  Future<void> document(BuildContext context) async {
    if (store.leases.isEmpty) {
      throw const FormatException('Create a lease first.');
    }
    String lease = store.leases.first.id;
    Json? file;
    await editor(
      context,
      title: 'Add lease document',
      fields: (set) => Column(
        children: [
          choice('Lease', lease, {
            for (final l in store.leases) l.id: store.unitLabel(l.unitId),
          }, (v) => set(() => lease = v)),
          OutlinedButton.icon(
            onPressed: () async {
              final selected = await pickAttachment();
              if (selected != null) set(() => file = selected);
            },
            icon: const Icon(Icons.attach_file),
            label: Text(
              file?['filename'] ?? 'Choose PDF or photo (up to 2 MB)',
            ),
          ),
        ],
      ),
      save: () async {
        if (file == null) throw const FormatException('Choose a file first.');
        await store.backendCommand('/leases/$lease/files', file!);
      },
    );
  }

  Future<void> verifyPublisher(BuildContext context) async {
    final notes = TextEditingController();
    Json? file;
    await editor(
      context,
      title: 'Publisher verification',
      saveLabel: 'Submit for review',
      note: 'Evidence is private and available only to the reviewing platform administrator. A review is not a guarantee of a rental.',
      fields: (set) => Column(
        children: [
          field('Review notes', notes, lines: 3),
          OutlinedButton.icon(
            onPressed: () async {
              final selected = await pickAttachment();
              if (selected != null) set(() => file = selected);
            },
            icon: const Icon(Icons.attach_file),
            label: Text(
              file?['filename'] ?? 'Choose review evidence (up to 2 MB)',
            ),
          ),
        ],
      ),
      save: () async {
        if (file == null) throw const FormatException('Choose evidence first.');
        await store.backendCommand('/publisher-verification', {
          'file': file,
          'notes': notes.text,
        });
      },
    );
    notes.dispose();
  }

  Future<void> listing(BuildContext context, Json data, [Json? old]) async {
    if (store.visibleUnits.isEmpty) {
      throw const FormatException('Add a rental unit first.');
    }
    String unit = old?['unitId'] ?? store.visibleUnits.first.id,
        precision = old?['locationPrecision'] ?? 'area',
        policy = old?['contactPolicy'] ?? 'inquiry_only';
    final id = old?['id'] ?? store.newId('listing'),
        title = TextEditingController(text: old?['title']),
        description = TextEditingController(text: old?['description']),
        location = TextEditingController(text: old?['locationLabel']),
        rent = TextEditingController(
          text: ((old?['rent'] ?? store.unit(unit).rent) / 100).toStringAsFixed(
            2,
          ),
        ),
        cost = TextEditingController(
          text: ((old?['moveInCost'] ?? store.unit(unit).rent) / 100)
              .toStringAsFixed(2),
        ),
        rules = TextEditingController(text: old?['houseRules']),
        phone = TextEditingController(text: old?['publicPhone']),
        email = TextEditingController(text: old?['publicEmail']),
        lat = TextEditingController(text: old?['latitude']?.toString()),
        lng = TextEditingController(text: old?['longitude']?.toString());
    final amenities = Set<String>.from(old?['amenityIds'] ?? []);
    await editor(
      context,
      title: old == null ? 'Draft a listing' : 'Edit listing',
      saveLabel: 'Save draft',
      note: 'Editing a listing removes it from public discovery until it is reviewed again.',
      fields: (set) => Column(
        children: [
          choice('Rental unit', unit, {
            for (final u in store.visibleUnits) u.id: store.unitLabel(u.id),
          }, (v) => set(() => unit = v)),
          field('Listing title', title),
          field('Public location (city / neighborhood)', location),
          field('Description', description, lines: 4),
          field('Advertised rent (PHP)', rent),
          field('Total advertised move-in cost (PHP)', cost),
          ExpansionTile(
            title: const Text('Amenities, rules & disclosure'),
            children: [
              ...records(data, 'amenities').map(
                (a) => CheckboxListTile(
                  title: Text(a['name']),
                  value: amenities.contains(a['id']),
                  onChanged: (v) => set(() {
                    v == true
                        ? amenities.add(a['id'])
                        : amenities.remove(a['id']);
                  }),
                ),
              ),
              field('House rules', rules, optional: true, lines: 3),
              choice('Location disclosure', precision, {
                'area': 'Area name only',
                'approximate': 'Approximate coordinates',
                'exact': 'Exact coordinates (public)',
              }, (v) => set(() => precision = v)),
              if (precision != 'area') ...[
                field('Latitude', lat),
                field('Longitude', lng),
              ],
              choice('Contact policy', policy, {
                'inquiry_only': 'Inquiries through Kwadra',
                'show_contact': 'Show these public contact details',
              }, (v) => set(() => policy = v)),
              if (policy == 'show_contact') ...[
                field('Public phone', phone, optional: true),
                field('Public email', email, optional: true),
              ],
            ],
          ),
        ],
      ),
      save: () async {
        final rentCents = parseMoney(rent.text),
            costCents = parseMoney(cost.text);
        if (rentCents == null || costCents == null) {
          throw const FormatException('Check the advertised amounts.');
        }
        await store.backendCommand(
          old == null ? '/listings' : '/listings/$id',
          {
            'id': id,
            'unitId': unit,
            'revision': old?['revision'] ?? 0,
            'title': title.text,
            'description': description.text,
            'locationLabel': location.text,
            'locationPrecision': precision,
            'latitude': precision == 'area' ? null : double.tryParse(lat.text),
            'longitude': precision == 'area' ? null : double.tryParse(lng.text),
            'rent': rentCents,
            'moveInCost': costCents,
            'houseRules': rules.text,
            'contactPolicy': policy,
            'publicPhone': phone.text,
            'publicEmail': email.text,
            'amenityIds': amenities.toList(),
          },
          method: old == null ? 'POST' : 'PUT',
        );
      },
    );
    for (final c in [
      title,
      description,
      location,
      rent,
      cost,
      rules,
      phone,
      email,
      lat,
      lng,
    ]) {
      c.dispose();
    }
  }

  Future<void> listingDetails(
    BuildContext context,
    Json l,
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
      title: l['title'],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatusPill(l['status']),
          const SizedBox(height: 16),
          detailRow('Public location', l['locationLabel']),
          detailRow('Monthly rent', money(l['rent'])),
          detailRow('Move-in cost', money(l['moveInCost'])),
          const SizedBox(height: 12),
          Text(l['description']),
          const SizedBox(height: 15),
          Text('${(l['photos'] as List).length} photos'),
          if (store.canWrite) ...[
            if (['draft', 'rejected', 'unpublished'].contains(l['status']))
              FilledButton(
                onPressed: () => closeThen(() async {
                  await store.backendCommand('/listings/${l['id']}/action', {
                    'revision': l['revision'],
                    'action': 'submit',
                  });
                }),
                child: const Text('Submit for review'),
              ),
            ActionsMenu(
              actions: [
                (
                  'Edit draft',
                  Icons.edit_outlined,
                  () => closeThen(() => listing(context, data, l)),
                ),
                (
                  'Add photo',
                  Icons.add_photo_alternate_outlined,
                  () => closeThen(() async {
                    final file = await pickAttachment(imagesOnly: true);
                    if (file != null) {
                      await store.backendCommand(
                        '/listings/${l['id']}/photos',
                        file,
                      );
                    }
                  }),
                ),
                if (['approved', 'pending'].contains(l['status']))
                  (
                    'Unpublish',
                    Icons.visibility_off_outlined,
                    () => closeThen(() async {
                      await store.backendCommand(
                        '/listings/${l['id']}/action',
                        {'revision': l['revision'], 'action': 'unpublish'},
                      );
                    }),
                  ),
              ],
            ),
          ],
          if (l['status'] == 'approved')
            TextButton(
              onPressed: () => Clipboard.setData(
                ClipboardData(text: marketplaceUrl('/listings/${l['id']}')),
              ),
              child: const Text('Copy public listing link'),
            ),
        ],
      ),
    );
  }

  Future<void> appeal(BuildContext context, Json c) async {
    final reason = TextEditingController();
    await editor(
      context,
      title: 'Appeal review',
      note: 'The listing remains unpublished while your appeal is reviewed.',
      fields: (_) => field('Reason for appeal', reason, lines: 4),
      save: () async {
        await store.backendCommand('/moderation/cases/${c['id']}/appeal', {
          'reason': reason.text,
        });
      },
    );
    reason.dispose();
  }

  Future<void> inquiry(
    BuildContext context,
    Json i,
    Json data,
    Future<void> Function() reload,
  ) async {
    await showDetails(
      context,
      title: 'Inquiry from ${i['name']}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${i['email']}\n${i['phone']}'),
          if (store.canManageTenants && i['convertedTenantId'] == null)
            TextButton(
              onPressed: () async {
                if (await confirmAction(
                      context,
                      title: 'Create tenant profile?',
                      message: 'This copies the seeker’s contact details into your tenant records. Lease creation remains a separate step.',
                      confirm: 'Create profile',
                    ) &&
                    context.mounted) {
                  await runAction(context, () async {
                    await store.backendCommand(
                      '/inquiries/${i['id']}/convert',
                      {'revision': i['revision']},
                    );
                  }, 'Tenant profile ready. Open Tenants to create a lease.');
                  if (context.mounted) Navigator.pop(context);
                  await reload();
                }
              },
              child: const Text('Create tenant profile'),
            ),
          const SizedBox(height: 16),
          ...records(data, 'messages')
              .where((m) => m['inquiryId'] == i['id'])
              .map(
                (m) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Text('${m['sender']}: ${m['body']}'),
                ),
              ),
          if (store.canWrite && i['status'] != 'closed')
            FilledButton(
              onPressed: () async {
                Navigator.pop(context);
                final text = TextEditingController();
                bool close = false;
                await editor(
                  context,
                  title: 'Reply to inquiry',
                  fields: (set) => Column(
                    children: [
                      field('Your reply', text, lines: 4),
                      CheckboxListTile(
                        title: const Text('Close this conversation'),
                        value: close,
                        onChanged: (v) => set(() => close = v == true),
                      ),
                    ],
                  ),
                  save: () async {
                    await store.backendCommand('/inquiries/${i['id']}/reply', {
                      'revision': i['revision'],
                      'message': text.text,
                      'close': close,
                    });
                  },
                );
                text.dispose();
                await reload();
              },
              child: const Text('Reply'),
            ),
          ...records(data, 'viewings')
              .where((v) => v['inquiryId'] == i['id'])
              .map(
                (v) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(shortDate(DateTime.parse(v['scheduledAt']))),
                  subtitle: Text(
                    '${DateTime.parse(v['scheduledAt']).toLocal()} · ${v['status']}',
                  ),
                  onTap:
                      store.canWrite &&
                          [
                            'requested',
                            'proposed',
                            'confirmed',
                          ].contains(v['status'])
                      ? () async {
                          Navigator.pop(context);
                          await viewing(context, v);
                          await reload();
                        }
                      : null,
                ),
              ),
        ],
      ),
    );
  }

  Future<void> viewing(BuildContext context, Json v) async {
    String status = 'confirmed';
    final time = TextEditingController(
      text: DateTime.parse(v['scheduledAt'])
          .toLocal()
          .toIso8601String()
          .substring(0, 16),
    );
    await editor(
      context,
      title: 'Viewing request',
      note: 'Changing the date proposes a new time for the seeker to confirm.',
      fields: (set) => Column(
        children: [
          choice('Action', status, {
            'confirmed': 'Confirm current time',
            'proposed': 'Propose another time',
            'declined': 'Decline request',
            'cancelled': 'Cancel appointment',
            'completed': 'Mark completed',
          }, (s) => set(() => status = s)),
          if (status == 'proposed')
            field('Local date and time (YYYY-MM-DDTHH:MM)', time),
        ],
      ),
      save: () async {
        await store.backendCommand('/viewings/${v['id']}', {
          'revision': v['revision'],
          'status': status,
          if (status == 'proposed')
            'scheduledAt': DateTime.parse(time.text).toUtc().toIso8601String(),
        }, method: 'PUT');
      },
    );
    time.dispose();
  }
}
