import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/formatters.dart';
import '../data/api_client.dart';
import '../data/models.dart';
import '../ui/components.dart';
import 'phase_widgets.dart';
import 'marketplace_widgets.dart';
import 'marketplace_messages.dart';
import 'rental_details.dart';
import 'account_notifications.dart';

class MarketplaceShell extends StatefulWidget {
  const MarketplaceShell({
    super.key,
    required this.api,
    required this.signedIn,
    required this.requireSignIn,
    required this.configureServer,
    required this.openWorkspace,
    required this.onAccountChanged,
  });
  final ApiClient api;
  final bool signedIn;
  final Future<bool> Function() requireSignIn;
  final Future<void> Function() configureServer, openWorkspace;
  final VoidCallback onAccountChanged;
  @override
  State<MarketplaceShell> createState() => _MarketplaceShellState();
}

class _MarketplaceShellState extends State<MarketplaceShell> {
  int tab = 0,
      page = 1,
      total = 0,
      requestVersion = 0,
      accountVersion = 0,
      unavailableCount = 0;
  final search = TextEditingController();
  List<Json> rentals = [],
      amenities = [],
      savedRentals = [],
      conversations = [];
  final Set<String> savedIds = {};
  final savedChanges = ValueNotifier<int>(0);
  final Set<String> saving = {};
  Map<String, String> filters = {};
  bool loading = true, loadingMore = false, personalLoading = false;
  String? error, personalError;
  @override
  void initState() {
    super.initState();
    load();
    loadAmenities();
    if (widget.signedIn) loadPersonal();
  }

  @override
  void didUpdateWidget(covariant MarketplaceShell old) {
    super.didUpdateWidget(old);
    if (old.signedIn != widget.signedIn) {
      accountVersion++;
      if (widget.signedIn) {
        loadPersonal();
      } else {
        savedIds.clear();
        savedRentals = [];
        conversations = [];
        personalError = null;
        personalLoading = false;
        tab = 0;
      }
    }
  }

  @override
  void dispose() {
    search.dispose();
    savedChanges.dispose();
    super.dispose();
  }

  Future<void> loadAmenities() async {
    try {
      final data = await widget.api.request(
        'GET',
        '/public/amenities',
        authenticated: false,
      );
      if (mounted) setState(() => amenities = records(data, 'data'));
    } catch (_) {
      /* Search remains usable when optional filters cannot load. */
    }
  }

  Future<void> load({bool more = false}) async {
    if (more && loadingMore) return;
    final version = ++requestVersion, next = more ? page + 1 : 1;
    setState(() {
      if (more) {
        loadingMore = true;
      } else {
        loading = true;
        rentals = [];
      }
      error = null;
    });
    final query = Uri(
      queryParameters: {
        ...filters,
        if (search.text.trim().isNotEmpty) 'q': search.text.trim(),
        'page': '$next',
        'pageSize': '12',
      },
    ).query;
    try {
      final result = await widget.api.request(
        'GET',
        '/public/listings?$query',
        authenticated: false,
      );
      if (!mounted || version != requestVersion) return;
      setState(() {
        rentals = more
            ? [...rentals, ...records(result, 'data')]
            : records(result, 'data');
        page = next;
        total = result['total'] as int;
      });
    } catch (e) {
      if (mounted && version == requestVersion) {
        setState(() => error = friendlyError(e));
      }
    } finally {
      if (mounted && version == requestVersion) {
        setState(() {
          loading = false;
          loadingMore = false;
        });
      }
    }
  }

  Future<void> loadPersonal() async {
    if (!widget.signedIn) return;
    final version = ++accountVersion;
    setState(() {
      personalLoading = true;
      personalError = null;
    });
    try {
      final result = await Future.wait([
        widget.api.request('GET', '/marketplace/saved'),
        widget.api.request('GET', '/marketplace/inquiries'),
      ]);
      if (!mounted || version != accountVersion || !widget.signedIn) return;
      setState(() {
        savedRentals = records(result[0], 'data');
        savedIds
          ..clear()
          ..addAll(savedRentals.map((l) => l['id'] as String));
        unavailableCount = result[0]['unavailableCount'] as int? ?? 0;
        conversations = records(result[1], 'data');
      });
      savedChanges.value++;
    } catch (e) {
      if (mounted && version == accountVersion) {
        setState(() => personalError = friendlyError(e));
      }
    } finally {
      if (mounted && version == accountVersion) {
        setState(() => personalLoading = false);
      }
    }
  }

  Future<void> toggleSaved(String id) async {
    final shouldSave = !savedIds.contains(id);
    if (saving.contains(id) || !await widget.requireSignIn() || !mounted) {
      return;
    }
    setState(() => saving.add(id));
    try {
      await widget.api.request(
        'PUT',
        '/marketplace/saved/$id',
        body: {'saved': shouldSave},
      );
      await loadPersonal();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => saving.remove(id));
    }
  }

  Future<void> openRental(Json l) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => RentalDetails(
          api: widget.api,
          id: l['id'],
          requireSignIn: widget.requireSignIn,
          isSignedIn: () => widget.signedIn,
          isSaved: () => savedIds.contains(l['id']),
          savedChanges: savedChanges,
          toggleSaved: toggleSaved,
        ),
      ),
    );
    if (mounted && widget.signedIn) await loadPersonal();
  }

  Future<void> showFilters() async {
    final min = TextEditingController(
          text: filters['minRent'] == null
              ? ''
              : (int.parse(filters['minRent']!) / 100).toString(),
        ),
        max = TextEditingController(
          text: filters['maxRent'] == null
              ? ''
              : (int.parse(filters['maxRent']!) / 100).toString(),
        ),
        move = TextEditingController(
          text: filters['maxMoveInCost'] == null
              ? ''
              : (int.parse(filters['maxMoveInCost']!) / 100).toString(),
        );
    String type = filters['type'] ?? '',
        capacity = filters['capacity'] ?? '',
        amenity = filters['amenity'] ?? '',
        sort = filters['sort'] ?? 'newest';
    final changed = await editor(
      context,
      title: 'Find your rental',
      saveLabel: 'Show rentals',
      fields: (set) => Column(
        children: [
          Row(
            children: [
              Expanded(
                child: field(
                  'Min rent (PHP)',
                  min,
                  optional: true,
                  keyboard: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: field(
                  'Max rent (PHP)',
                  max,
                  optional: true,
                  keyboard: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              ),
            ],
          ),
          field(
            'Max move-in cost (PHP)',
            move,
            optional: true,
            keyboard: const TextInputType.numberWithOptions(decimal: true),
          ),
          choice('Space type', type, {
            '': 'Any type',
            'Room': 'Room',
            'Studio': 'Studio',
            '1 Bedroom': '1 Bedroom',
            '2 Bedroom': '2 Bedroom',
            'Apartment': 'Apartment',
            'Bedspace': 'Bedspace',
          }, (v) => set(() => type = v)),
          choice('Residents', capacity, {
            '': 'Any capacity',
            for (int i = 1; i <= 10; i++) '$i': 'At least $i',
          }, (v) => set(() => capacity = v)),
          if (amenities.isNotEmpty)
            choice('Amenity', amenity, {
              '': 'Any amenity',
              for (final a in amenities) a['id'] as String: a['name'] as String,
            }, (v) => set(() => amenity = v)),
          choice('Sort by', sort, {
            'newest': 'Newest',
            'rent_asc': 'Lowest rent',
            'rent_desc': 'Highest rent',
          }, (v) => set(() => sort = v)),
          TextButton(
            onPressed: () => set(() {
              min.clear();
              max.clear();
              move.clear();
              type = '';
              capacity = '';
              amenity = '';
              sort = 'newest';
            }),
            child: const Text('Clear filters'),
          ),
        ],
      ),
      save: () async {
        final next = <String, String>{};
        for (final entry in [
          ('minRent', min),
          ('maxRent', max),
          ('maxMoveInCost', move),
        ]) {
          if (entry.$2.text.trim().isNotEmpty) {
            final n = parseMoney(entry.$2.text);
            if (n == null) {
              throw const FormatException(
                'Enter valid amounts with up to two decimal places.',
              );
            }
            next[entry.$1] = '$n';
          }
        }
        if (next['minRent'] != null &&
            next['maxRent'] != null &&
            int.parse(next['minRent']!) > int.parse(next['maxRent']!)) {
          throw const FormatException(
            'Minimum rent cannot exceed maximum rent.',
          );
        }
        if (type.isNotEmpty) next['type'] = type;
        if (capacity.isNotEmpty) next['capacity'] = capacity;
        if (amenity.isNotEmpty) next['amenity'] = amenity;
        if (sort != 'newest') next['sort'] = sort;
        filters = next;
      },
    );
    min.dispose();
    max.dispose();
    move.dispose();
    if (changed && mounted) await load();
  }

  Widget grid(List<Json> list) => LayoutBuilder(
    builder: (context, box) {
      final columns = box.maxWidth >= 1050
          ? 3
          : box.maxWidth >= 650
          ? 2
          : 1;
      final width = (box.maxWidth - (columns - 1) * 18) / columns;
      return Wrap(
        spacing: 18,
        runSpacing: 18,
        children: list
            .map(
              (l) => SizedBox(
                width: width,
                child: RentalCard(
                  api: widget.api,
                  listing: l,
                  onOpen: () => openRental(l),
                  onSave: () => toggleSaved(l['id']),
                  saved: savedIds.contains(l['id']),
                ),
              ),
            )
            .toList(),
      );
    },
  );
  Widget browse() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 8),
      Text(
        'Find your next home.',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 10),
      const Text(
        'Explore available rentals and connect with their landlords.',
        style: TextStyle(color: KColors.muted),
      ),
      const SizedBox(height: 24),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: search,
              maxLength: 160,
              decoration: InputDecoration(
                labelText: 'Where would you like to live?',
                hintText: 'City, area or rental name',
                counterText: '',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: 'Search rentals',
                  onPressed: () => load(),
                  icon: const Icon(Icons.arrow_forward_rounded),
                ),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => load(),
            ),
          ),
          const SizedBox(width: 10),
          Badge(
            isLabelVisible: filters.isNotEmpty,
            label: Text('${filters.length}'),
            child: IconButton.filledTonal(
              tooltip: 'Filter rentals',
              onPressed: showFilters,
              icon: const Icon(Icons.tune_rounded),
            ),
          ),
        ],
      ),
      const SizedBox(height: 25),
      Row(
        children: [
          Expanded(
            child: Text(
              loading
                  ? 'Finding rentals…'
                  : '$total available ${total == 1 ? 'rental' : 'rentals'}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (filters.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() => filters = {});
                load();
              },
              child: const Text('Clear filters'),
            ),
        ],
      ),
      const SizedBox(height: 16),
      if (loading)
        const Padding(
          padding: EdgeInsets.all(48),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (error != null && rentals.isEmpty)
        MarketplaceFailure(
          message: error!,
          retry: () => load(),
          configure: widget.configureServer,
        )
      else if (rentals.isEmpty)
        Surface(
          child: EmptyState(
            title: 'No rentals found',
            message: 'Try a different area or adjust your filters.',
            icon: Icons.search_off_outlined,
            action: TextButton(
              onPressed: () {
                search.clear();
                setState(() => filters = {});
                load();
              },
              child: const Text('Show all rentals'),
            ),
          ),
        )
      else ...[
        grid(rentals),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(error!, style: const TextStyle(color: KColors.red)),
          ),
        if (rentals.length < total)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: OutlinedButton(
              onPressed: loadingMore ? null : () => load(more: true),
              child: Text(loadingMore ? 'Loading…' : 'Load more rentals'),
            ),
          ),
      ],
    ],
  );
  Widget privateTab({required bool saved}) {
    if (!widget.signedIn) {
      return MarketplaceSignInPrompt(
        title: saved
            ? 'Keep your favorites together'
            : 'Talk to your next landlord',
        message: saved
            ? 'Sign in to save rentals and find them again on any device.'
            : 'Sign in to send inquiries, read replies and arrange viewings.',
        onSignIn: () => widget.requireSignIn(),
      );
    }
    if (personalLoading && savedRentals.isEmpty && conversations.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(48),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (personalError != null) {
      return MarketplaceFailure(message: personalError!, retry: loadPersonal);
    }
    if (saved) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Your saved rentals',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 20),
          if (unavailableCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Notice(
                '$unavailableCount previously saved ${unavailableCount == 1 ? 'rental is' : 'rentals are'} no longer available.',
              ),
            ),
          if (savedRentals.isEmpty)
            const Surface(
              child: EmptyState(
                title: 'A home worth saving',
                message: 'Tap the heart on a rental to keep it here.',
                icon: Icons.favorite_border,
              ),
            )
          else
            grid(savedRentals),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Your conversations',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 20),
        if (conversations.isEmpty)
          const Surface(
            child: EmptyState(
              title: 'Start a conversation',
              message: 'Open a rental and tap Message landlord. Replies and viewing requests will appear here.',
              icon: Icons.chat_bubble_outline,
            ),
          )
        else
          RecordList(
            children: conversations
                .map(
                  (i) => RecordTile(
                    title: i['title'],
                    subtitle: '${i['lastMessage'] ?? i['status']}',
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => MarketplaceConversation(
                            api: widget.api,
                            id: i['id'],
                          ),
                        ),
                      );
                      if (mounted) await loadPersonal();
                    },
                  ),
                )
                .toList(),
          ),
      ],
    );
  }

  Future<void> becomeLandlord() async {
    final name = TextEditingController(
      text: '${widget.api.user['name']}’s rentals',
    );
    final created = await editor(
      context,
      title: 'Your landlord workspace',
      note: 'Keep browsing with this account and manage your properties in a separate workspace.',
      fields: (_) => field('Workspace name', name),
      save: () async {
        await widget.api.request(
          'POST',
          '/marketplace/organization',
          body: {'name': name.text.trim()},
        );
        await widget.api.restore();
      },
    );
    name.dispose();
    if (created && mounted) {
      widget.onAccountChanged();
      await widget.openWorkspace();
    }
  }

  Widget account() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Your account', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 20),
      if (!widget.signedIn)
        MarketplaceSignInPrompt(
          title: 'Make your next move',
          message: 'Browse freely. Sign in or create an account to save rentals, contact landlords and request viewings.',
          onSignIn: () => widget.requireSignIn(),
        )
      else
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.api.user['name']?.toString() ?? 'Your account',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                widget.api.user['email']?.toString() ?? '',
                style: const TextStyle(color: KColors.muted),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: widget.api.accountKind == 'seeker'
                    ? becomeLandlord
                    : widget.openWorkspace,
                icon: Icon(
                  widget.api.accountKind == 'tenant'
                      ? Icons.home_outlined
                      : widget.api.accountKind == 'platform'
                      ? Icons.verified_user_outlined
                      : Icons.apartment_outlined,
                ),
                label: Text(
                  widget.api.accountKind == 'tenant'
                      ? 'My tenancy'
                      : widget.api.accountKind == 'platform'
                      ? 'Moderation console'
                      : widget.api.accountKind == 'seeker'
                      ? 'List my property'
                      : 'Manage rentals',
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () =>
                    runAction(context, widget.api.logout, 'Signed out.'),
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      if (!widget.signedIn) ...[
        const SizedBox(height: 20),
        TextButton.icon(
          onPressed: widget.configureServer,
          icon: const Icon(Icons.settings_ethernet_outlined),
          label: const Text('Server connection'),
        ),
      ],
    ],
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Brand(small: true),
      actions: [
        if (widget.signedIn) AccountNotificationBell(api: widget.api),
        if (tab < 3)
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => tab == 0 ? load() : loadPersonal(),
            icon: const Icon(Icons.refresh_rounded),
          ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (i) {
        setState(() => tab = i);
        if ((i == 1 || i == 2) && widget.signedIn) loadPersonal();
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.search_rounded),
          label: 'Explore',
        ),
        NavigationDestination(
          icon: Icon(Icons.favorite_border),
          label: 'Saved',
        ),
        NavigationDestination(
          icon: Icon(Icons.chat_bubble_outline),
          label: 'Messages',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          label: 'Account',
        ),
      ],
    ),
    body: SafeArea(
      child: RefreshIndicator(
        onRefresh: () => tab == 0 ? load() : loadPersonal(),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200),
              child: switch (tab) {
                0 => browse(),
                1 => privateTab(saved: true),
                2 => privateTab(saved: false),
                _ => account(),
              },
            ),
          ),
        ),
      ),
    ),
  );
}
