import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/formatters.dart';
import '../data/api_client.dart';
import '../data/models.dart';

class RentalPhoto extends StatelessWidget {
  const RentalPhoto({
    super.key,
    required this.api,
    required this.listing,
    this.photoId,
    this.height = 220,
  });
  final ApiClient api;
  final Json listing;
  final String? photoId;
  final double height;
  @override
  Widget build(BuildContext context) {
    final photos = listing['photos'] as List? ?? [];
    final id = photoId ?? photos.firstOrNull?.toString();
    if (id == null) {
      return SizedBox(
        height: height,
        width: double.infinity,
        child: ColoredBox(
          color: KColors.sage,
          child: const Icon(
            Icons.home_outlined,
            size: 54,
            color: KColors.green,
          ),
        ),
      );
    }
    return Image.network(
      '${api.baseUrl}/public/photos/${Uri.encodeComponent(id)}',
      height: height,
      width: double.infinity,
      fit: BoxFit.cover,
      semanticLabel: 'Photo of ${listing['title']}',
      loadingBuilder: (context, child, loading) => loading == null
          ? child
          : SizedBox(
              height: height,
              width: double.infinity,
              child: const ColoredBox(
                color: KColors.sage,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
      errorBuilder: (_, _, _) => SizedBox(
        height: height,
        width: double.infinity,
        child: const ColoredBox(
          color: KColors.sage,
          child: Center(
            child: Icon(
              Icons.image_not_supported_outlined,
              color: KColors.muted,
              size: 38,
            ),
          ),
        ),
      ),
    );
  }
}

class RentalCard extends StatelessWidget {
  const RentalCard({
    super.key,
    required this.api,
    required this.listing,
    required this.onOpen,
    required this.onSave,
    required this.saved,
  });
  final ApiClient api;
  final Json listing;
  final VoidCallback onOpen, onSave;
  final bool saved;
  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    margin: EdgeInsets.zero,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: KColors.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          children: [
            InkWell(
              onTap: onOpen,
              child: RentalPhoto(api: api, listing: listing),
            ),
            Positioned(
              top: 10,
              right: 10,
              child: Material(
                color: Colors.white,
                shape: const CircleBorder(),
                child: IconButton(
                  tooltip: saved ? 'Remove saved rental' : 'Save rental',
                  onPressed: onSave,
                  icon: Icon(
                    saved ? Icons.favorite : Icons.favorite_border,
                    color: KColors.green,
                  ),
                ),
              ),
            ),
          ],
        ),
        InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${money(listing['rent'] as int)} / month',
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(color: KColors.darkGreen),
                ),
                const SizedBox(height: 7),
                Text(
                  listing['title'].toString(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  listing['locationLabel'].toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: KColors.muted),
                ),
                const SizedBox(height: 12),
                Text(
                  '${listing['type']} · Up to ${listing['capacity']} residents',
                  style: const TextStyle(fontSize: 12, color: KColors.muted),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class MarketplaceSignInPrompt extends StatelessWidget {
  const MarketplaceSignInPrompt({
    super.key,
    required this.title,
    required this.message,
    required this.onSignIn,
  });
  final String title, message;
  final VoidCallback onSignIn;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 42, horizontal: 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.person_outline_rounded,
          size: 48,
          color: KColors.green,
        ),
        const SizedBox(height: 18),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 10),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: KColors.muted),
        ),
        const SizedBox(height: 22),
        FilledButton(onPressed: onSignIn, child: const Text('Sign in')),
      ],
    ),
  );
}

class MarketplaceFailure extends StatelessWidget {
  const MarketplaceFailure({
    super.key,
    required this.message,
    required this.retry,
    this.configure,
  });
  final String message;
  final VoidCallback retry;
  final VoidCallback? configure;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.wifi_off_outlined, size: 36, color: KColors.muted),
        const SizedBox(height: 14),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 18),
        FilledButton(onPressed: retry, child: const Text('Retry')),
        if (configure != null)
          TextButton(
            onPressed: configure,
            child: const Text('Server connection'),
          ),
      ],
    ),
  );
}
