import 'package:flutter/material.dart';

import '../data/workspace_store.dart';
import '../ui/components.dart';
import 'phase_widgets.dart';

Future<void> repairConversation(
  BuildContext context,
  WorkspaceStore store,
  String id,
) => showDetails(
  context,
  title: 'Request conversation',
  child: RemoteContent(
    load: () => store.backendGet('/operations'),
    builder: (context, data, reload) {
      final ticket = store.tickets.firstWhere((t) => t.id == id),
          metadata = records(
            data,
            'ticketDetails',
          ).firstWhere((t) => t['id'] == id);
      Future<void> action(Future<void> Function() work) async {
        await runAction(context, work, 'Saved.');
        await reload();
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(ticket.title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 14),
          detailRow(
            'Status',
            metadata['closedAt'] != null ? 'Closed' : ticket.status,
          ),
          ...records(data, 'comments')
              .where((c) => c['ticketId'] == id)
              .map(
                (c) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(c['body']),
                  subtitle: Text(c['name']),
                ),
              ),
          ...records(data, 'documents')
              .where((d) => d['ticketId'] == id)
              .map(
                (d) => TextButton.icon(
                  onPressed: () =>
                      downloadAttachment(context, store.backendGet, d['id']),
                  icon: const Icon(Icons.attachment),
                  label: Text(d['filename']),
                ),
              ),
          if (store.canWrite) ...[
            if (metadata['closedAt'] == null)
              FilledButton(
                onPressed: () => action(() async {
                  final body = TextEditingController();
                  await editor(
                    context,
                    title: 'Add comment',
                    fields: (_) => field('Comment', body, lines: 4),
                    save: () async {
                      await store.backendCommand('/tickets/$id/comments', {
                        'body': body.text,
                      });
                    },
                  );
                  body.dispose();
                }),
                child: const Text('Add comment'),
              ),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => action(() async {
                    final file = await pickAttachment(imagesOnly: true);
                    if (file != null) {
                      await store.backendCommand('/tickets/$id/files', file);
                    }
                  }),
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('Add photo'),
                ),
                if (metadata['closedAt'] == null)
                  TextButton(
                    onPressed: () => action(() async {
                      String assigned = metadata['assignedTo'] ?? '';
                      bool close = false;
                      final property = store.unit(ticket.unitId).propertyId;
                      final options = {
                        for (final m in records(data, 'assignments').where(
                          (m) =>
                              m['allProperties'] == true ||
                              ['owner', 'admin'].contains(m['role']) ||
                              (m['propertyIds'] as List).contains(property),
                        ))
                          m['id'] as String: m['name'] as String,
                      };
                      await editor(
                        context,
                        title: 'Assign request',
                        fields: (set) => Column(
                          children: [
                            choice('Responsible staff', assigned, {
                              '': 'Unassigned',
                              ...options,
                            }, (v) => set(() => assigned = v)),
                            if (ticket.status == 'Resolved')
                              CheckboxListTile(
                                title: const Text(
                                  'Close this resolved request',
                                ),
                                value: close,
                                onChanged: (v) => set(() => close = v == true),
                              ),
                          ],
                        ),
                        save: () async {
                          await store.backendCommand(
                            '/tickets/$id/assignment',
                            {
                              'revision': metadata['revision'],
                              'assignedTo': assigned.isEmpty ? null : assigned,
                              'close': close,
                            },
                            method: 'PUT',
                          );
                        },
                      );
                    }),
                    child: const Text('Assign / close'),
                  ),
              ],
            ),
          ],
        ],
      );
    },
  ),
);
