import 'package:flutter/material.dart';

import '../core/export_file.dart';
import '../core/formatters.dart';
import '../core/theme.dart';
import '../data/workspace_store.dart';
import '../ui/components.dart';
import 'forms.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.store});
  final WorkspaceStore store;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.store.ownerName),
      email = TextEditingController(text: widget.store.ownerEmail),
      organization = TextEditingController(text: widget.store.organizationName);
  bool saving = false;
  @override
  void dispose() {
    name.dispose();
    email.dispose();
    organization.dispose();
    super.dispose();
  }

  void refresh() {
    name.text = widget.store.ownerName;
    email.text = widget.store.ownerEmail;
    organization.text = widget.store.organizationName;
  }

  Future<void> export() async {
    try {
      final message = await exportText(
        'kwadra-workspace-${periodKey(widget.store.today)}.json',
        widget.store.exportJson(),
        'application/json',
      );
      if (mounted) toast(context, message);
    } catch (error) {
      if (mounted) toast(context, friendlyError(error));
    }
  }

  Future<void> reset(bool sample) async {
    final confirmed = await confirmAction(
      context,
      title: sample ? 'Reload sample data?' : 'Clear your workspace?',
      message: 'This replaces all local properties, tenants, leases, invoices and repair requests. Export a backup first to keep your records.',
      confirm: sample ? 'Reload sample data' : 'Clear workspace',
    );
    if (confirmed && mounted) {
      await runAction(
        context,
        sample ? widget.store.resetDemo : widget.store.clearWorkspace,
        sample ? 'Sample data loaded.' : 'Workspace cleared.',
      );
      if (mounted) setState(refresh);
    }
  }

  @override
  Widget build(BuildContext context) => widget.store.isRemote
      ? _BackendSettings(store: widget.store)
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const PageHeading(
              title: 'Settings',
              subtitle: 'Your profile and workspace.',
            ),
            const SizedBox(height: 24),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Surface(
                    child: Form(
                      key: form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          input('Your name', name),
                          input('Workspace name', organization),
                          input(
                            'Email address',
                            email,
                            keyboard: TextInputType.emailAddress,
                            validator: emailValue,
                          ),
                          FilledButton(
                            onPressed: saving
                                ? null
                                : () async {
                                    if (!form.currentState!.validate()) return;
                                    setState(() => saving = true);
                                    await runAction(
                                      context,
                                      () => widget.store.updateProfile(
                                        name: name.text,
                                        email: email.text,
                                        organization: organization.text,
                                      ),
                                      'Settings saved.',
                                    );
                                    if (mounted) setState(() => saving = false);
                                  },
                            child: Text(saving ? 'Saving?' : 'Save changes'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Surface(
                    padding: EdgeInsets.zero,
                    child: ExpansionTile(
                      title: const Text(
                        'Backup & data',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: const Text(
                        'Export, restore or start fresh',
                        style: TextStyle(fontSize: 12, color: KColors.muted),
                      ),
                      children: [
                        ListTile(
                          leading: const Icon(Icons.file_download_outlined),
                          title: const Text('Export workspace'),
                          onTap: export,
                        ),
                        ListTile(
                          leading: const Icon(Icons.file_upload_outlined),
                          title: const Text('Restore a backup'),
                          onTap: () async {
                            await showDialog<void>(
                              context: context,
                              builder: (_) =>
                                  _ImportDialog(store: widget.store),
                            );
                            if (mounted) setState(refresh);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.restart_alt_rounded),
                          title: const Text('Reload sample data'),
                          onTap: () => reset(true),
                        ),
                        ListTile(
                          leading: const Icon(
                            Icons.delete_outline_rounded,
                            color: KColors.red,
                          ),
                          title: const Text(
                            'Clear workspace',
                            style: TextStyle(color: KColors.red),
                          ),
                          onTap: () => reset(false),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Notice(
                    'Your records are saved on this device. Online sync is not connected. Export a backup before switching devices.',
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Philippine peso · Asia/Manila billing dates\nKwadra 0.5.0 local demo',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.8,
                      color: KColors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
}

class _BackendSettings extends StatefulWidget {
  const _BackendSettings({required this.store});
  final WorkspaceStore store;
  @override
  State<_BackendSettings> createState() => _BackendSettingsState();
}

class _BackendSettingsState extends State<_BackendSettings> {
  late final name = TextEditingController(text: widget.store.ownerName),
      organization = TextEditingController(text: widget.store.organizationName);
  bool saving = false;
  late int profileRevision = widget.store.revision;
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    name.dispose();
    organization.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeading(
            title: 'Settings',
            subtitle: 'Your account and connected workspace.',
          ),
          const SizedBox(height: 24),
          Surface(
            child: Form(
              key: form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (store.canManage) ...[
                    input('Your name', name),
                    input('Workspace name', organization),
                  ] else ...[
                    Text(store.ownerName),
                    const SizedBox(height: 12),
                    Text(store.organizationName),
                    const SizedBox(height: 12),
                  ],
                  Text(
                    store.ownerEmail,
                    style: const TextStyle(color: KColors.muted),
                  ),
                  const SizedBox(height: 18),
                  if (store.canManage)
                    FilledButton(
                      onPressed: saving
                          ? null
                          : () async {
                              if (!form.currentState!.validate()) return;
                              setState(() => saving = true);
                              await runAction(context, () async {
                                await store.updateProfile(
                                  name: name.text,
                                  email: store.ownerEmail,
                                  organization: organization.text,
                                  expectedRevision: profileRevision,
                                );
                                profileRevision = store.revision;
                              }, 'Settings saved.');
                              if (mounted) setState(() => saving = false);
                            },
                      child: Text(saving ? 'Saving…' : 'Save changes'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Surface(
            padding: EdgeInsets.zero,
            child: ExpansionTile(
              title: const Text('Connection & export'),
              children: [
                ListTile(
                  title: const Text('API server'),
                  subtitle: SelectableText(store.apiUrl),
                ),
                ListTile(
                  title: const Text('Access'),
                  subtitle: Text(
                    '${store.permissions['role']} · ${store.permissions['allProperties'] == true ? 'All properties' : 'Assigned properties'}',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('Export visible records'),
                  subtitle: const Text(
                    'A JSON copy of records available to your account',
                  ),
                  onTap: () async {
                    try {
                      await store.refresh();
                      final message = await exportText(
                        'kwadra-records-${periodKey(store.today)}.json',
                        store.exportJson(),
                        'application/json',
                      );
                      if (context.mounted) toast(context, message);
                    } catch (error) {
                      if (context.mounted) toast(context, friendlyError(error));
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Notice(
            'Changes are saved to the connected database. Pull down or use Refresh to see changes made by another user. Database restore and sample-data tools run from the backend terminal.',
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () => runAction(context, store.signOut, 'Signed out.'),
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Sign out'),
          ),
          const SizedBox(height: 18),
          const Text(
            'Philippine peso · Asia/Manila billing dates\nKwadra 0.5.0',
            style: TextStyle(fontSize: 12, color: KColors.muted, height: 1.8),
          ),
        ],
      ),
    );
  }
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.store});
  final WorkspaceStore store;
  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final text = TextEditingController();
  bool saving = false;
  String? error;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Restore your workspace'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Notice(
              'Restoring replaces the local workspace. Export your current data first, then paste the full contents of a Kwadra JSON export below.',
            ),
            const SizedBox(height: 18),
            TextField(
              controller: text,
              maxLines: 10,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              decoration: const InputDecoration(
                hintText: 'Paste your Kwadra workspace JSON…',
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  error!,
                  style: const TextStyle(color: KColors.red, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: saving
            ? null
            : () async {
                if (text.text.trim().isEmpty) {
                  setState(() => error = 'Paste a workspace export first.');
                  return;
                }
                setState(() {
                  saving = true;
                  error = null;
                });
                try {
                  await widget.store.importJson(text.text);
                  if (context.mounted) {
                    Navigator.pop(context);
                    toast(context, 'Workspace restored. Welcome back.');
                  }
                } catch (e) {
                  if (mounted) {
                    setState(() {
                      saving = false;
                      error = 'This export could not be restored. Check that it is a complete Kwadra workspace file. Your existing data is unchanged.';
                    });
                  }
                }
              },
        child: Text(saving ? 'Restoring…' : 'Replace & restore'),
      ),
    ],
  );
}

class ActivityPage extends StatefulWidget {
  const ActivityPage({super.key, required this.store});
  final WorkspaceStore store;
  @override
  State<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends State<ActivityPage> {
  String query = '', filter = 'All activity';
  @override
  Widget build(BuildContext context) {
    final events = widget.store.activities
        .where(
          (a) =>
              (filter == 'All activity' || a.kind == filter.toLowerCase()) &&
              '${a.title} ${a.detail}'.toLowerCase().contains(
                query.toLowerCase(),
              ),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeading(
          title: 'Activity log',
          subtitle: 'Changes to your workspace records.',
        ),
        const SizedBox(height: 24),
        SearchFilter(
          hint: 'Find an activity',
          onChanged: (v) => setState(() => query = v),
          values: const [
            'All activity',
            'Property',
            'Tenant',
            'Lease',
            'Invoice',
            'Maintenance',
            'Settings',
          ],
          selected: filter,
          onSelected: (v) => setState(() => filter = v),
        ),
        const SizedBox(height: 18),
        Surface(
          child: events.isEmpty
              ? const EmptyState(
                  title: 'No activity found',
                  message: 'Try a different search.',
                )
              : Column(
                  children: events
                      .map(
                        (event) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              tileIcon(Icons.history_rounded),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      event.title,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      event.detail,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: KColors.muted,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      shortDate(event.created),
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: KColors.muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
      ],
    );
  }
}
