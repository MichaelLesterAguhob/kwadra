import 'dart:async';

import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/models.dart';
import '../services/in_app_notifications.dart';
import '../services/google_account_button.dart';
import '../ui/components.dart';
import 'phase_widgets.dart';
import 'marketplace_messages.dart';

class AccountNotificationsPage extends StatefulWidget {
  const AccountNotificationsPage({super.key, required this.api});
  final ApiClient api;
  @override
  State<AccountNotificationsPage> createState() =>
      _AccountNotificationsPageState();
}

class _AccountNotificationsPageState extends State<AccountNotificationsPage> {
  Json? data, google;
  String? error;
  bool busy = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    load();
    InAppNotifications.updates.addListener(changed);
    timer = Timer.periodic(const Duration(seconds: 30), (_) => load());
  }

  void changed() {
    load();
  }

  Future<void> load() async {
    try {
      final values = await Future.wait([
        widget.api.request('GET', '/account/notifications'),
        widget.api.request('GET', '/auth/providers', authenticated: false),
      ]);
      if (mounted) {
        setState(() {
          data = values[0];
          google = values[1]['google'] as Json?;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    }
  }

  Future<void> preferences(String key, bool value) async {
    if (busy || data == null) return;
    setState(() => busy = true);
    final next = Json.from(data!['preferences'])..[key] = value;
    try {
      await widget.api.request(
        'PUT',
        '/account/notification-preferences',
        body: next,
      );
      await load();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> linkGoogle(String token) async {
    final password = TextEditingController();
    await editor(
      context,
      title: 'Link your Google account',
      note: 'Enter your current Kwadra password to link a Google account with the same email address.',
      fields: (_) => TextFormField(
        controller: password,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'Current password'),
      ),
      save: () async {
        await widget.api.request(
          'POST',
          '/auth/google/link',
          body: {'idToken': token, 'password': password.text},
        );
      },
    );
    password.dispose();
  }

  @override
  void dispose() {
    timer?.cancel();
    InAppNotifications.updates.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Notifications & account')),
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (error != null) Notice(error!),
          if (data == null)
            const Center(child: CircularProgressIndicator())
          else ...[
            Text(
              'Notification preferences',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SwitchListTile(
              title: const Text('In-app updates'),
              value: data!['preferences']['inApp'] == true,
              onChanged: busy ? null : (v) => preferences('inApp', v),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Your updates',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if ((data!['notifications'] as List).any(
                  (n) => n['readAt'] == null,
                ))
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            await runAction(context, () async {
                              await widget.api.request(
                                'POST',
                                '/account/notifications/read',
                                body: {
                                  'ids': (data!['notifications'] as List)
                                      .where((n) => n['readAt'] == null)
                                      .map((n) => n['id'])
                                      .toList(),
                                },
                              );
                              await load();
                            }, 'Marked as read.');
                          },
                    child: const Text('Mark all read'),
                  ),
              ],
            ),
            if ((data!['notifications'] as List).isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'You’re all caught up. New updates will appear here.',
                ),
              ),
            for (final n in data!['notifications'])
              ListTile(
                leading: Icon(
                  n['readAt'] == null
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_none,
                ),
                title: Text(n['title']),
                subtitle: Text(n['body']),
                onTap: () async {
                  try {
                    await widget.api.request(
                      'POST',
                      '/account/notifications/read',
                      body: {
                        'ids': [n['id']],
                      },
                    );
                    if (n['inquiryId'] != null && context.mounted) {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => MarketplaceConversation(
                            api: widget.api,
                            id: n['inquiryId'],
                          ),
                        ),
                      );
                    }
                    await load();
                  } catch (e) {
                    if (context.mounted) toast(context, friendlyError(e));
                  }
                },
              ),
          ],
          if (google?['enabled'] == true && GoogleAccountButton.supported) ...[
            const Divider(height: 40),
            Text(
              'Google account',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            GoogleAccountButton(
              clientId: google!['webClientId'],
              iosClientId: google!['iosClientId'],
              onToken: linkGoogle,
              onError: (e) => toast(context, friendlyError(e)),
            ),
          ],
        ],
      ),
    ),
  );
}

class AccountNotificationBell extends StatefulWidget {
  const AccountNotificationBell({super.key, required this.api});
  final ApiClient api;
  @override
  State<AccountNotificationBell> createState() =>
      _AccountNotificationBellState();
}

class _AccountNotificationBellState extends State<AccountNotificationBell>
    with WidgetsBindingObserver {
  int unread = 0;
  bool loading = false;
  bool loadedOnce = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    InAppNotifications.updates.addListener(changed);
    load();
    timer = Timer.periodic(const Duration(seconds: 60), (_) => load());
  }

  void changed() {
    load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  Future<void> load() async {
    if (loading ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
      return;
    }
    loading = true;
    try {
      final inbox = await widget.api.request('GET', '/account/notifications');
      if (mounted) {
        final count = inbox['unread'] as int? ?? 0;
        if (loadedOnce &&
            count > unread &&
            inbox['preferences']?['inApp'] == true) {
          final notices = inbox['notifications'] as List? ?? [];
          toast(
            context,
            notices.isEmpty
                ? 'You have a new update.'
                : notices.first['title'].toString(),
          );
        }
        setState(() {
          unread = count;
          loadedOnce = true;
        });
      }
    } catch (_) {
      /* Retain the last count during network errors. */
    } finally {
      loading = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    InAppNotifications.updates.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Notifications',
    icon: Badge(
      isLabelVisible: unread > 0,
      label: Text(unread > 99 ? '99+' : '$unread'),
      child: const Icon(Icons.notifications_outlined),
    ),
    onPressed: () async {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => AccountNotificationsPage(api: widget.api),
        ),
      );
      if (mounted) await load();
    },
  );
}
