import 'package:flutter/material.dart';

import '../data/api_client.dart';

import '../core/formatters.dart';
import '../core/theme.dart';

class Brand extends StatelessWidget {
  const Brand({super.key, this.small = false});
  final bool small;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(small ? 8 : 10),
        child: Image.asset(
          'assets/branding/kwadra-logo.png',
          width: small ? 30 : 36,
          height: small ? 30 : 36,
          fit: BoxFit.contain,
          cacheWidth: 144,
          semanticLabel: 'Kwadra tropical hut mascot',
        ),
      ),
      const SizedBox(width: 10),
      Flexible(
        child: Text(
          'kwadra',
          maxLines: 1,
          style: TextStyle(
            fontSize: small ? 25 : 29,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.6,
            color: KColors.darkGreen,
          ),
        ),
      ),
      const Padding(
        padding: EdgeInsets.only(left: 2, top: 16),
        child: Text(
          '·',
          style: TextStyle(
            fontSize: 27,
            fontWeight: FontWeight.w800,
            color: KColors.green,
          ),
        ),
      ),
    ],
  );
}

class Surface extends StatelessWidget {
  const Surface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(22),
    this.color = Colors.white,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  @override
  Widget build(BuildContext context) => Material(
    color: color,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: KColors.line),
    ),
    child: Padding(padding: padding, child: child),
  );
}

class PageHeading extends StatelessWidget {
  const PageHeading({
    super.key,
    required this.title,
    required this.subtitle,
    this.action,
    this.eyebrow,
  });
  final String title, subtitle;
  final String? eyebrow;
  final Widget? action;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final text = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (eyebrow != null) ...[
            Text(
              eyebrow!.toUpperCase(),
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.6,
                color: KColors.green,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            title,
            style: box.maxWidth < 600
                ? Theme.of(context).textTheme.headlineMedium
                : Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 7),
          Text(
            subtitle,
            style: const TextStyle(
              color: KColors.muted,
              fontSize: 14,
              height: 1.6,
            ),
          ),
        ],
      );
      if (box.maxWidth < 650) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            text,
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: text),
          if (action != null) ...[const SizedBox(width: 20), action!],
        ],
      );
    },
  );
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.subtitle, this.action});
  final String title;
  final String? subtitle;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: const TextStyle(color: KColors.muted, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
      ?action,
    ],
  );
}

class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({
    super.key,
    required this.children,
    this.minWidth = 250,
    this.maxColumns = 4,
    this.gap = 18,
  });
  final List<Widget> children;
  final double minWidth, gap;
  final int maxColumns;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final count = ((box.maxWidth + gap) / (minWidth + gap)).floor().clamp(
        1,
        maxColumns,
      );
      final width = (box.maxWidth - gap * (count - 1)) / count;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: children
            .map((child) => SizedBox(width: width, child: child))
            .toList(),
      );
    },
  );
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, this.color, this.dot = true});
  final String label;
  final Color? color;
  final bool dot;
  @override
  Widget build(BuildContext context) {
    final c =
        color ??
        switch (label) {
          'Occupied' || 'Active' || 'Resolved' => KColors.green,
          'Available' || 'Upcoming' => const Color(0xFF588478),
          'Urgent' || 'Overdue' => KColors.red,
          'Open' ||
          'In progress' ||
          'Maintenance' ||
          'Normal' => KColors.orange,
          _ => KColors.muted,
        };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: c,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class PersonAvatar extends StatelessWidget {
  const PersonAvatar(this.name, {super.key, this.size = 36});
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) {
    const colors = [
      Color(0xFFEBE6DE),
      Color(0xFFE1EBE4),
      Color(0xFFE6E6F1),
      Color(0xFFF4E6E0),
    ];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors[name.codeUnits.fold(0, (a, b) => a + b) % colors.length],
        shape: BoxShape.circle,
      ),
      child: Text(
        initials(name),
        style: TextStyle(
          fontSize: size * .31,
          fontWeight: FontWeight.w800,
          color: KColors.green,
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.message,
    this.action,
    this.icon = Icons.search_off_rounded,
  });
  final String title, message;
  final Widget? action;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 44, horizontal: 24),
    child: Center(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: KColors.sage,
            ),
            child: Icon(icon, color: KColors.green, size: 28),
          ),
          const SizedBox(height: 18),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 7),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: KColors.muted),
          ),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    ),
  );
}

class SearchBox extends StatelessWidget {
  const SearchBox({super.key, required this.hint, required this.onChanged});
  final String hint;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: TextField(
      onChanged: onChanged,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(
          Icons.search_rounded,
          size: 19,
          color: KColors.muted,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 10,
        ),
      ),
    ),
  );
}

class FilterTabs extends StatelessWidget {
  const FilterTabs({
    super.key,
    required this.values,
    required this.selected,
    required this.onSelected,
  });
  final List<String> values;
  final String selected;
  final ValueChanged<String> onSelected;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 5,
    runSpacing: 6,
    children: values
        .map(
          (v) => ChoiceChip(
            label: Text(v),
            selected: v == selected,
            onSelected: (_) => onSelected(v),
            showCheckmark: false,
            selectedColor: KColors.sage,
            backgroundColor: Colors.white,
            side: BorderSide(
              color: v == selected ? const Color(0xFFCCDBD1) : KColors.line,
            ),
            labelStyle: TextStyle(
              fontFamily: 'Manrope',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: v == selected ? KColors.green : KColors.muted,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
        )
        .toList(),
  );
}

class Notice extends StatelessWidget {
  const Notice(
    this.message, {
    super.key,
    this.icon = Icons.info_outline_rounded,
  });
  final String message;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: KColors.sage,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: KColors.green),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              fontSize: 11,
              height: 1.7,
              color: KColors.green,
            ),
          ),
        ),
      ],
    ),
  );
}

void toast(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
  );
}

String friendlyError(Object error) => error is ApiException
    ? error.message
    : error is FormatException
    ? error.message.toString()
    : error is StateError
    ? error.message.toString()
    : 'The change could not be saved. Check the details and try again.';

Future<void> runAction(
  BuildContext context,
  Future<void> Function() action,
  String message,
) async {
  try {
    await action();
    if (context.mounted) toast(context, message);
  } catch (error) {
    if (context.mounted) toast(context, friendlyError(error));
  }
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirm = 'Confirm',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Text(message),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirm),
          ),
        ],
      ),
    ) ??
    false;

Future<void> showDetails(
  BuildContext context, {
  required String title,
  required Widget child,
  Widget? action,
}) => showDialog<void>(
  context: context,
  builder: (ctx) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: Theme.of(ctx).textTheme.titleLarge),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Flexible(child: SingleChildScrollView(child: child)),
            if (action != null) ...[const SizedBox(height: 20), action],
          ],
        ),
      ),
    ),
  ),
);

Widget detailRow(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 9),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 115,
        child: Text(
          label,
          style: const TextStyle(color: KColors.muted, fontSize: 13),
        ),
      ),
      Expanded(
        child: SelectableText(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    ],
  ),
);

class RecordTable extends StatelessWidget {
  const RecordTable({
    super.key,
    required this.columns,
    required this.rows,
    this.minWidth = 700,
  });
  final List<String> columns;
  final List<DataRow> rows;
  final double minWidth;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: box.maxWidth > minWidth ? box.maxWidth : minWidth,
          ),
          child: DataTable(
            showCheckboxColumn: false,
            horizontalMargin: 20,
            columnSpacing: 25,
            headingRowHeight: 46,
            dataRowMinHeight: 66,
            dataRowMaxHeight: 74,
            dividerThickness: .6,
            headingRowColor: const WidgetStatePropertyAll(Color(0xFFFAFBFA)),
            border: const TableBorder(
              horizontalInside: BorderSide(color: KColors.line, width: .6),
            ),
            columns: columns
                .map(
                  (c) => DataColumn(
                    label: Text(
                      c.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .8,
                        color: KColors.muted,
                      ),
                    ),
                  ),
                )
                .toList(),
            rows: rows,
          ),
        ),
      ),
    ),
  );
}

Widget cellText(String text, {String? secondary, bool bold = false}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 8),
  child: Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      if (secondary != null) ...[
        const SizedBox(height: 4),
        Text(
          secondary,
          style: const TextStyle(fontSize: 12, color: KColors.muted),
        ),
      ],
    ],
  ),
);

Widget tileIcon(IconData icon, {Color color = KColors.green}) => Container(
  width: 42,
  height: 42,
  decoration: BoxDecoration(
    color: color.withValues(alpha: .08),
    borderRadius: BorderRadius.circular(10),
  ),
  child: Icon(icon, size: 22, color: color),
);

class RecordList extends StatelessWidget {
  const RecordList({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Surface(
    padding: EdgeInsets.zero,
    child: Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child: Divider(),
            ),
          children[i],
        ],
      ],
    ),
  );
}

class RecordTile extends StatelessWidget {
  const RecordTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.leading,
    this.trailing,
  });
  final String title, subtitle;
  final VoidCallback? onTap;
  final Widget? leading, trailing;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 14)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    subtitle,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.65,
                      color: KColors.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
          if (onTap != null) const SizedBox(width: 8),
          if (onTap != null)
            const Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: KColors.muted,
            ),
        ],
      ),
    ),
  );
}

class SearchFilter extends StatelessWidget {
  const SearchFilter({
    super.key,
    required this.hint,
    required this.onChanged,
    required this.values,
    required this.selected,
    required this.onSelected,
  });
  final String hint, selected;
  final List<String> values;
  final ValueChanged<String> onChanged, onSelected;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: SearchBox(hint: hint, onChanged: onChanged),
      ),
      const SizedBox(width: 8),
      PopupMenuButton<String>(
        tooltip: 'Filter: $selected',
        initialValue: selected,
        onSelected: onSelected,
        icon: Badge(
          isLabelVisible: selected != values.first,
          smallSize: 6,
          child: const Icon(Icons.filter_list_rounded, color: KColors.green),
        ),
        itemBuilder: (_) => values
            .map(
              (v) => CheckedPopupMenuItem(
                value: v,
                checked: v == selected,
                child: Text(v),
              ),
            )
            .toList(),
      ),
    ],
  );
}

class ActionsMenu extends StatelessWidget {
  const ActionsMenu({
    super.key,
    required this.actions,
    this.tooltip = 'More actions',
  });
  final List<(String, IconData, VoidCallback)> actions;
  final String tooltip;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: tooltip,
    onSelected: (label) => actions.firstWhere((a) => a.$1 == label).$3(),
    icon: const Icon(Icons.more_vert_rounded, color: KColors.muted),
    itemBuilder: (_) => actions
        .map(
          (a) => PopupMenuItem(
            value: a.$1,
            child: Row(
              children: [
                Icon(a.$2, size: 19, color: KColors.muted),
                const SizedBox(width: 12),
                Text(a.$1, style: const TextStyle(fontSize: 14)),
              ],
            ),
          ),
        )
        .toList(),
  );
}
