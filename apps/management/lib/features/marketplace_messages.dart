import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/formatters.dart';
import '../data/api_client.dart';
import '../data/models.dart';
import '../ui/components.dart';
import 'phase_widgets.dart';

class MarketplaceConversation extends StatefulWidget {
  const MarketplaceConversation({
    super.key,
    required this.api,
    required this.id,
  });
  final ApiClient api;
  final String id;
  @override
  State<MarketplaceConversation> createState() =>
      _MarketplaceConversationState();
}

class _MarketplaceConversationState extends State<MarketplaceConversation> {
  final reply = TextEditingController();
  bool sending = false;
  String? error;
  String get path => '/marketplace/inquiries/${widget.id}';
  final remote = GlobalKey<_ConversationBodyState>();
  @override
  void dispose() {
    reply.dispose();
    super.dispose();
  }

  Future<void> send() async {
    final text = reply.text.trim();
    if (text.isEmpty || sending) return;
    setState(() {
      sending = true;
      error = null;
    });
    try {
      await widget.api.request(
        'POST',
        '$path/messages',
        body: {'message': text},
      );
      reply.clear();
      await remote.currentState?.reload();
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> viewing(Json? current, String action) async {
    if (action == 'request') {
      final now = DateTime.now();
      final date = await showDatePicker(
        context: context,
        initialDate: now.add(const Duration(days: 1)),
        firstDate: now,
        lastDate: now.add(const Duration(days: 89)),
      );
      if (date == null || !mounted) return;
      final time = await showTimePicker(
        context: context,
        initialTime: const TimeOfDay(hour: 10, minute: 0),
      );
      if (time == null || !mounted) return;
      final when = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      if (!when.isAfter(now)) {
        toast(context, 'Choose a future viewing time.');
        return;
      }
      await runAction(context, () async {
        await widget.api.request(
          'POST',
          '$path/viewings',
          body: {
            'action': 'request',
            'scheduledAt': when.toUtc().toIso8601String(),
          },
        );
        await remote.currentState?.reload();
      }, 'Viewing requested. Wait for the landlord’s confirmation.');
    } else {
      await runAction(context, () async {
        await widget.api.request(
          'POST',
          '$path/viewings',
          body: {
            'id': current!['id'],
            'revision': current['revision'],
            'action': action,
          },
        );
        await remote.currentState?.reload();
      }, action == 'confirm' ? 'Viewing confirmed.' : 'Viewing cancelled.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Conversation'),
      actions: [
        IconButton(
          tooltip: 'Refresh conversation',
          onPressed: () => remote.currentState?.reload(),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 850),
          child: _ConversationBody(
            key: remote,
            api: widget.api,
            path: path,
            builder: (context, data) {
              final closed = data['status'] == 'closed';
              final appointments = records(data, 'viewings');
              final active = appointments.any(
                (v) => [
                  'requested',
                  'proposed',
                  'confirmed',
                ].contains(v['status']),
              );
              return ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    data['title'],
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    closed
                        ? 'This inquiry is closed.'
                        : 'Your conversation with the landlord.',
                    style: const TextStyle(color: KColors.muted),
                  ),
                  const SizedBox(height: 24),
                  ...records(data, 'messages').map(
                    (m) => Align(
                      alignment: m['sender'] == 'seeker'
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 620),
                        padding: const EdgeInsets.all(16),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: m['sender'] == 'seeker'
                              ? KColors.sage
                              : Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: KColors.line),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m['sender'] == 'seeker' ? 'You' : 'Landlord',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: KColors.green,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(m['body']),
                            const SizedBox(height: 8),
                            Text(
                              _date(m['created']),
                              style: const TextStyle(
                                color: KColors.muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!closed) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: reply,
                      maxLines: 3,
                      maxLength: 3000,
                      decoration: const InputDecoration(
                        labelText: 'Reply to landlord',
                        hintText: 'Write your message',
                      ),
                    ),
                    if (error != null)
                      Text(error!, style: const TextStyle(color: KColors.red)),
                    FilledButton(
                      onPressed: sending ? null : send,
                      child: Text(sending ? 'Sending…' : 'Send reply'),
                    ),
                  ],
                  const SizedBox(height: 30),
                  const SectionHeading('Viewings'),
                  const SizedBox(height: 12),
                  if (appointments.isEmpty)
                    const Text(
                      'No viewing requested yet.',
                      style: TextStyle(color: KColors.muted),
                    ),
                  ...appointments.map(
                    (v) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Surface(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _date(v['scheduledAt']),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            StatusPill(v['status'].toString()),
                            if (v['status'] == 'requested')
                              const Padding(
                                padding: EdgeInsets.only(top: 10),
                                child: Text(
                                  'Waiting for landlord confirmation.',
                                ),
                              ),
                            if (v['status'] == 'proposed')
                              const Padding(
                                padding: EdgeInsets.only(top: 10),
                                child: Text(
                                  'The landlord proposed this time. Confirm if it works for you.',
                                ),
                              ),
                            if (!closed &&
                                [
                                  'requested',
                                  'proposed',
                                  'confirmed',
                                ].contains(v['status']))
                              Wrap(
                                spacing: 8,
                                children: [
                                  if (v['status'] == 'proposed')
                                    TextButton(
                                      onPressed: () => viewing(v, 'confirm'),
                                      child: const Text(
                                        'Confirm proposed time',
                                      ),
                                    ),
                                  TextButton(
                                    onPressed: () => viewing(v, 'cancel'),
                                    child: const Text('Cancel viewing'),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!closed && !active)
                    OutlinedButton.icon(
                      onPressed: () => viewing(null, 'request'),
                      icon: const Icon(Icons.calendar_month_outlined),
                      label: const Text('Request a viewing'),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

String _date(dynamic value) {
  final d = DateTime.tryParse(value.toString())?.toLocal();
  return d == null
      ? value.toString()
      : '${shortDate(d)} · ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class _ConversationBody extends StatefulWidget {
  const _ConversationBody({
    super.key,
    required this.api,
    required this.path,
    required this.builder,
  });
  final ApiClient api;
  final String path;
  final Widget Function(BuildContext, Json) builder;
  @override
  State<_ConversationBody> createState() => _ConversationBodyState();
}

class _ConversationBodyState extends State<_ConversationBody> {
  Json? data;
  String? error;
  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final next = await widget.api.request('GET', widget.path);
      if (mounted) {
        setState(() {
          data = next;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) => error != null
      ? Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error!),
                TextButton(onPressed: reload, child: const Text('Retry')),
              ],
            ),
          ),
        )
      : data == null
      ? const Center(child: CircularProgressIndicator())
      : widget.builder(context, data!);
}
