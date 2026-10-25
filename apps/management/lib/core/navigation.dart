import 'package:flutter/material.dart';

enum AppSection {
  overview('Home', Icons.home_outlined),
  properties('Properties', Icons.apartment_rounded),
  tenants('Tenants', Icons.people_outline_rounded),
  more('More', Icons.more_horiz_rounded),
  leases('Leases', Icons.description_outlined),
  billing('Rent invoices', Icons.receipt_long_outlined),
  paymentPreview('Payment preview', Icons.payments_outlined),
  maintenance('Repairs', Icons.handyman_outlined),
  summary('Portfolio summary', Icons.bar_chart_rounded),
  activity('Activity log', Icons.history_rounded),
  team('Team', Icons.manage_accounts_outlined),
  utilities('Utilities', Icons.water_drop_outlined),
  announcements('Announcements', Icons.campaign_outlined),
  moveOuts('Move-outs', Icons.move_to_inbox_outlined),
  documents('Documents', Icons.folder_outlined),
  listings('Listings', Icons.storefront_outlined),
  inquiries('Inquiries', Icons.forum_outlined),
  notifications('Notifications', Icons.notifications_outlined),
  deliveries('Delivery status', Icons.outgoing_mail),
  settings('Settings', Icons.tune_rounded);

  const AppSection(this.label, this.icon);
  final String label;
  final IconData icon;
}
