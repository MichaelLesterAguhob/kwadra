import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../core/formatters.dart';
import '../data/api_client.dart';
import '../data/models.dart';
import '../ui/components.dart';
import 'phase_widgets.dart';
import 'marketplace_widgets.dart';
import 'marketplace_messages.dart';

class RentalDetails extends StatefulWidget {
  const RentalDetails({
    super.key,
    required this.api,
    required this.id,
    required this.requireSignIn,
    required this.isSignedIn,
    required this.isSaved,
    required this.savedChanges,
    required this.toggleSaved,
  });
  final ApiClient api;
  final String id;
  final Future<bool> Function() requireSignIn;
  final bool Function() isSignedIn, isSaved;
  final Listenable savedChanges;
  final Future<void> Function(String) toggleSaved;
  @override
  State<RentalDetails> createState() => _RentalDetailsState();
}

class _RentalDetailsState extends State<RentalDetails> {
  Json? listing;
  String? error;
  int photo = 0;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => error = null);
    try {
      final data = await widget.api.request(
        'GET',
        '/public/listings/${widget.id}',
        authenticated: false,
      );
      if (mounted) setState(() => listing = Json.from(data['data']));
    } catch (e) {
      if (mounted) {
        setState(() {
          error = friendlyError(e);
          listing = null;
        });
      }
    }
  }

  Future<void> saveRental() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.toggleSaved(widget.id);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> inquire() async {
    if (!await widget.requireSignIn() || !mounted) return;
    final message = TextEditingController(), phone = TextEditingController();
    String? inquiryId;
    final sent = await editor(
      context,
      title: 'Message landlord',
      saveLabel: 'Send inquiry',
      note: 'Your name and verified email will be shared with the landlord. You can continue the conversation in Messages.',
      fields: (_) => Column(
        children: [
          field('Your message', message, lines: 4),
          field(
            'Phone (optional)',
            phone,
            optional: true,
            keyboard: TextInputType.phone,
          ),
        ],
      ),
      save: () async {
        if (message.text.trim().length < 10) {
          throw const FormatException(
            'Write a message with at least 10 characters.',
          );
        }
        final result = await widget.api.request(
          'POST',
          '/marketplace/listings/${widget.id}/inquiries',
          body: {'message': message.text.trim(), 'phone': phone.text.trim()},
        );
        inquiryId = result['data']['id'];
      },
    );
    message.dispose();
    phone.dispose();
    if (sent && mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              MarketplaceConversation(api: widget.api, id: inquiryId!),
        ),
      );
    }
  }

  Future<void> report() async {
    if (!await widget.requireSignIn() || !mounted) return;
    final reason = TextEditingController();
    final sent = await editor(
      context,
      title: 'Report this rental',
      fields: (_) => field('What should we review?', reason, lines: 4),
      save: () async {
        await widget.api.request(
          'POST',
          '/marketplace/listings/${widget.id}/report',
          body: {'reason': reason.text},
        );
      },
    );
    reason.dispose();
    if (sent && mounted) toast(context, 'Report sent for review.');
  }

  Future<void> share() async {
    if (!await widget.requireSignIn() || !mounted) return;
    final base = Uri.parse(widget.api.baseUrl);
    await Clipboard.setData(
      ClipboardData(text: '${base.origin}/marketplace/listings/${widget.id}'),
    );
    if (mounted) toast(context, 'Rental link copied.');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.savedChanges,
    builder: (context, _) => buildDetails(context),
  );

  Widget buildDetails(BuildContext context) {
    final l = listing;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rental details'),
        actions: [
          IconButton(
            tooltip: 'Copy rental link',
            onPressed: share,
            icon: const Icon(Icons.ios_share_outlined),
          ),
        ],
      ),
      bottomNavigationBar: l == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
                child: Center(
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: inquire,
                            icon: const Icon(Icons.chat_bubble_outline),
                            label: const Text('Message landlord'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton.filledTonal(
                          tooltip: widget.isSaved()
                              ? 'Remove saved rental'
                              : 'Save rental',
                          onPressed: busy ? null : saveRental,
                          icon: Icon(
                            widget.isSaved()
                                ? Icons.favorite
                                : Icons.favorite_border,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
      body: error != null
          ? Center(
              child: MarketplaceFailure(message: error!, retry: load),
            )
          : l == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LayoutBuilder(
                          builder: (context, box) {
                            final photos = l['photos'] as List? ?? [];
                            final height = box.maxWidth < 600 ? 270.0 : 440.0;
                            return Stack(
                              children: [
                                SizedBox(
                                  height: height,
                                  child: photos.isEmpty
                                      ? RentalPhoto(
                                          api: widget.api,
                                          listing: l,
                                          height: height,
                                        )
                                      : PageView.builder(
                                          itemCount: photos.length,
                                          onPageChanged: (i) =>
                                              setState(() => photo = i),
                                          itemBuilder: (_, i) => RentalPhoto(
                                            api: widget.api,
                                            listing: l,
                                            photoId: photos[i].toString(),
                                            height: height,
                                          ),
                                        ),
                                ),
                                if (photos.length > 1)
                                  Positioned(
                                    bottom: 16,
                                    right: 18,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        '${photo + 1} / ${photos.length}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.all(22),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '${money(l['rent'] as int)} / month',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(color: KColors.darkGreen),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                l['title'],
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 10),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(
                                    Icons.location_on_outlined,
                                    size: 18,
                                    color: KColors.muted,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      l['locationLabel'],
                                      style: const TextStyle(
                                        color: KColors.muted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${l['locationPrecision']} location disclosure',
                                style: const TextStyle(
                                  color: KColors.muted,
                                  fontSize: 12,
                                ),
                              ),
                              if (l['latitude'] != null &&
                                  l['longitude'] != null)
                                Text(
                                  'Coordinates: ${l['latitude']}, ${l['longitude']}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: KColors.muted,
                                  ),
                                ),
                              const SizedBox(height: 22),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  Chip(label: Text(l['type'])),
                                  Chip(
                                    label: Text(
                                      'Up to ${l['capacity']} residents',
                                    ),
                                  ),
                                  ...records(
                                    l,
                                    'amenities',
                                  ).map((a) => Chip(label: Text(a['name']))),
                                ],
                              ),
                              const SizedBox(height: 24),
                              const SectionHeading('About this place'),
                              const SizedBox(height: 12),
                              Text(l['description']),
                              const SizedBox(height: 26),
                              Surface(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const SectionHeading('Move-in costs'),
                                    const SizedBox(height: 12),
                                    detailRow(
                                      'Advertised total',
                                      money(l['moveInCost'] as int),
                                    ),
                                    const Text(
                                      'Confirm the complete rental terms and any additional costs with the landlord.',
                                      style: TextStyle(
                                        color: KColors.muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (l['houseRules'].toString().isNotEmpty) ...[
                                const SizedBox(height: 24),
                                const SectionHeading('House rules'),
                                const SizedBox(height: 12),
                                Text(l['houseRules']),
                              ],
                              const SizedBox(height: 24),
                              const SectionHeading('Publisher review'),
                              const SizedBox(height: 12),
                              const Text(
                                'This publisher’s submitted documentation was reviewed. This describes the review performed and does not guarantee a rental.',
                                style: TextStyle(color: KColors.muted),
                              ),
                              if (l['contactPolicy'] == 'show_contact') ...[
                                const SizedBox(height: 18),
                                if (widget.isSignedIn()) ...[
                                  if (l['publicPhone'].toString().isNotEmpty)
                                    SelectableText(l['publicPhone']),
                                  if (l['publicEmail'].toString().isNotEmpty)
                                    SelectableText(l['publicEmail']),
                                ] else
                                  TextButton(
                                    onPressed: () async {
                                      await widget.requireSignIn();
                                      if (mounted) setState(() {});
                                    },
                                    child: const Text(
                                      'Sign in to view contact details',
                                    ),
                                  ),
                              ],
                              const SizedBox(height: 16),
                              TextButton.icon(
                                onPressed: report,
                                icon: const Icon(Icons.flag_outlined),
                                label: const Text('Report this rental'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
