import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../core/theme.dart';
import '../data/workspace_store.dart';
import '../ui/components.dart';

class OccupancyChart extends StatefulWidget {
  const OccupancyChart({super.key, required this.store});
  final WorkspaceStore store;
  @override
  State<OccupancyChart> createState() => OccupancyChartState();
}

class OccupancyChartState extends State<OccupancyChart> {
  int range = 6;
  @override
  Widget build(BuildContext context) {
    final store = widget.store, total = store.visibleUnits.length;
    final dates = List.generate(
      range,
      (i) => DateTime(store.today.year, store.today.month - range + i + 2, 0),
    );
    final counts = dates
        .map(
          (d) => store.leases
              .where(
                (l) =>
                    !store.property(store.unit(l.unitId).propertyId).archived &&
                    l.occupiedAt(d.isAfter(store.today) ? store.today : d),
              )
              .length,
        )
        .toList();
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'More than units. Homes.',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Occupancy across your portfolio',
                      style: TextStyle(fontSize: 10, color: KColors.muted),
                    ),
                  ],
                ),
              ),
              DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: range,
                  isDense: true,
                  style: const TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 10,
                    color: KColors.muted,
                  ),
                  items: const [
                    DropdownMenuItem(value: 6, child: Text('6 months')),
                    DropdownMenuItem(value: 12, child: Text('12 months')),
                  ],
                  onChanged: (v) => setState(() => range = v!),
                ),
              ),
            ],
          ),
          const SizedBox(height: 25),
          SizedBox(
            height: 156,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '$total',
                      style: const TextStyle(fontSize: 9, color: KColors.muted),
                    ),
                    Text(
                      '${total ~/ 2}',
                      style: const TextStyle(fontSize: 9, color: KColors.muted),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 21),
                      child: Text(
                        '0',
                        style: TextStyle(fontSize: 9, color: KColors.muted),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Stack(
                    children: [
                      Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: List.generate(
                          3,
                          (_) => const Padding(
                            padding: EdgeInsets.only(bottom: 22),
                            child: Divider(),
                          ),
                        ),
                      ),
                      Row(
                        children: List.generate(
                          range,
                          (i) => Expanded(
                            child: _MonthBar(
                              date: dates[i],
                              count: counts[i],
                              total: total,
                              current: i == range - 1,
                              compact: range == 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 17),
          const Row(
            children: [
              Icon(Icons.circle, size: 7, color: KColors.green),
              SizedBox(width: 6),
              Text(
                'Occupied units',
                style: TextStyle(fontSize: 9, color: KColors.muted),
              ),
              Spacer(),
              Icon(Icons.trending_up_rounded, size: 14, color: KColors.green),
              SizedBox(width: 5),
              Text(
                'Based on lease dates',
                style: TextStyle(fontSize: 9, color: KColors.green),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MonthBar extends StatelessWidget {
  const _MonthBar({
    required this.date,
    required this.count,
    required this.total,
    required this.current,
    required this.compact,
  });
  final DateTime date;
  final int count, total;
  final bool current, compact;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      Expanded(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Tooltip(
            message: '${months[date.month - 1]}: $count occupied units',
            child: FractionallySizedBox(
              heightFactor: total == 0 ? .01 : (count / total).clamp(.015, 1.0),
              widthFactor: compact ? .6 : .48,
              child: Container(
                decoration: BoxDecoration(
                  color: current ? KColors.green : const Color(0xFFCADCCE),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(5),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 10),
      Text(
        months[date.month - 1].substring(0, compact ? 1 : 3),
        style: TextStyle(
          fontSize: 9,
          color: current ? KColors.green : KColors.muted,
          fontWeight: current ? FontWeight.w800 : FontWeight.w500,
        ),
      ),
    ],
  );
}

class PortfolioStatus extends StatelessWidget {
  const PortfolioStatus({
    super.key,
    required this.occupied,
    required this.available,
    required this.maintenance,
  });
  final int occupied, available, maintenance;
  @override
  Widget build(BuildContext context) {
    final total = occupied + available + maintenance;
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'A place for everyone',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          const Text(
            'Your units, right now',
            style: TextStyle(fontSize: 10, color: KColors.muted),
          ),
          const SizedBox(height: 20),
          Center(
            child: SizedBox(
              width: 138,
              height: 138,
              child: CustomPaint(
                painter: _DonutPainter(occupied, available, maintenance),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${total == 0 ? 0 : (occupied / total * 100).round()}%',
                      style: const TextStyle(
                        fontSize: 29,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1,
                      ),
                    ),
                    const Text(
                      'occupancy',
                      style: TextStyle(fontSize: 9, color: KColors.muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _legend('Occupied', occupied, KColors.green),
              _legend('Available', available, const Color(0xFFB4CE98)),
              _legend('Care', maintenance, const Color(0xFFE5C49B)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legend(String label, int count, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(Icons.circle, color: color, size: 6),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 9, color: KColors.muted),
          ),
        ],
      ),
      const SizedBox(height: 5),
      Text(
        '$count ${count == 1 ? 'unit' : 'units'}',
        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
      ),
    ],
  );
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.occupied, this.available, this.maintenance);
  final int occupied, available, maintenance;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(8, 8, size.width - 16, size.height - 16);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round;
    paint.color = KColors.sage;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint);
    final total = occupied + available + maintenance;
    if (total == 0) return;
    var angle = -math.pi / 2;
    final values = [occupied, available, maintenance],
        colors = [
          KColors.green,
          const Color(0xFFB4CE98),
          const Color(0xFFE5C49B),
        ];
    for (var i = 0; i < 3; i++) {
      final sweep = values[i] / total * math.pi * 2;
      paint.color = colors[i];
      if (sweep > .06) {
        canvas.drawArc(rect, angle + .025, sweep - .05, false, paint);
      }
      angle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.occupied != occupied ||
      old.available != available ||
      old.maintenance != maintenance;
}
