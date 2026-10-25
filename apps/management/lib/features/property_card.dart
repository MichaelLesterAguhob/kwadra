import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../data/workspace_store.dart';

class PropertyCard extends StatelessWidget {
  const PropertyCard({
    super.key,
    required this.property,
    required this.store,
    required this.onTap,
  });
  final RentalProperty property;
  final WorkspaceStore store;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final units = store.unitsFor(property.id),
        occupied = store
            .unitsFor(property.id)
            .where((u) => store.currentLease(u.id) != null)
            .length;
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: KColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Image.asset(
              'assets/images/${property.image}.jpg',
              height: 160,
              width: double.infinity,
              fit: BoxFit.cover,
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          property.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: KColors.muted,
                        size: 20,
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(
                    property.address,
                    style: const TextStyle(fontSize: 13, color: KColors.muted),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    '$occupied of ${units.length} units occupied',
                    style: const TextStyle(fontSize: 13, color: KColors.green),
                  ),
                  const SizedBox(height: 9),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: units.isEmpty ? 0 : occupied / units.length,
                      minHeight: 5,
                      backgroundColor: KColors.sage,
                      color: KColors.green,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
