const months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
DateTime dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);
String shortDate(DateTime date) =>
    '${months[date.month - 1].substring(0, 3)} ${date.day}, ${date.year}';
String monthLabel(DateTime date) => '${months[date.month - 1]} ${date.year}';
String periodKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}';
String money(int centavos, {bool decimals = false}) {
  final negative = centavos < 0;
  final whole = (centavos.abs() ~/ 100).toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (m) => '${m[1]},',
  );
  final cents = centavos.abs() % 100;
  return '${negative ? '-' : ''}₱$whole${decimals || cents != 0 ? '.${cents.toString().padLeft(2, '0')}' : ''}';
}

int? parseMoney(String raw) {
  final value = raw.trim().replaceAll(',', '').replaceAll('₱', '');
  if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch(value)) return null;
  final parts = value.split('.');
  return int.parse(parts[0]) * 100 +
      (parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0);
}

String initials(String name) => name
    .trim()
    .split(RegExp(r'\s+'))
    .where((s) => s.isNotEmpty)
    .take(2)
    .map((s) => s[0])
    .join()
    .toUpperCase();
bool overlaps(DateTime startA, DateTime endA, DateTime startB, DateTime endB) =>
    !endA.isBefore(startB) && !endB.isBefore(startA);
DateTime billingDueDate(DateTime month, int day) => DateTime(
  month.year,
  month.month,
  day.clamp(1, DateTime(month.year, month.month + 1, 0).day),
);
