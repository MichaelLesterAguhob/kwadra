import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../core/theme.dart';
import '../ui/components.dart';

/// A deliberately self-contained UX sample. It has no repository, network
/// client, persistence, file upload, receipt generation, or financial effects.
class PaymentPreviewPage extends StatefulWidget {
  const PaymentPreviewPage({super.key});
  @override
  State<PaymentPreviewPage> createState() => _PaymentPreviewPageState();
}

class _PaymentPreviewPageState extends State<PaymentPreviewPage> {
  final amount = TextEditingController(text: '5000.00');
  final reference = TextEditingController(text: 'SAMPLE-001');
  final form = GlobalKey<FormState>();
  String method = 'Cash';
  int stage = 0, sampleAmount = 500000;
  @override
  void dispose() {
    amount.dispose();
    reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const PageHeading(
        title: 'Payment preview',
        subtitle: 'A sample workflow you can explore.',
      ),
      const SizedBox(height: 20),
      const Notice(
        'Demo only. These details are fictional. Nothing is sent, saved, collected or deducted from a real invoice.',
      ),
      const SizedBox(height: 20),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (stage < 3)
                Text(
                  'Step ${stage + 1} of 3',
                  style: const TextStyle(color: KColors.muted, fontSize: 12),
                ),
              const SizedBox(height: 12),
              if (stage == 0) ...[
                Text(
                  'Choose a sample invoice',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                const Text('Jamie Sample · Demo Unit 01'),
                const SizedBox(height: 8),
                const Text(
                  'SAMPLE-INV-001 · Monthly rent',
                  style: TextStyle(color: KColors.muted),
                ),
                const SizedBox(height: 16),
                Text(
                  money(500000),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => setState(() => stage = 1),
                  child: const Text('Continue sample'),
                ),
              ] else if (stage == 1) ...[
                Text(
                  'Enter sample details',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                Form(
                  key: form,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: amount,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Sample amount (PHP)',
                        ),
                        validator: (v) {
                          final cents = parseMoney(v ?? '');
                          return cents == null || cents <= 0 || cents > 500000
                              ? 'Enter an amount from PHP 0.01 to PHP 5,000.00.'
                              : null;
                        },
                      ),
                      const SizedBox(height: 18),
                      DropdownButtonFormField<String>(
                        initialValue: method,
                        decoration: const InputDecoration(
                          labelText: 'Sample method',
                        ),
                        items: ['Cash', 'Bank transfer', 'E-wallet']
                            .map(
                              (v) => DropdownMenuItem(value: v, child: Text(v)),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setState(() => method = v);
                        },
                      ),
                      const SizedBox(height: 18),
                      TextFormField(
                        controller: reference,
                        decoration: const InputDecoration(
                          labelText: 'Sample reference (optional)',
                        ),
                        maxLength: 80,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () {
                    if (form.currentState!.validate()) {
                      setState(() {
                        sampleAmount = parseMoney(amount.text)!;
                        stage = 2;
                      });
                    }
                  },
                  child: const Text('Review sample'),
                ),
                TextButton(
                  onPressed: () => setState(() => stage = 0),
                  child: const Text('Back'),
                ),
              ] else if (stage == 2) ...[
                Text(
                  'Review sample',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                detailRow('Fictional tenant', 'Jamie Sample'),
                detailRow('Sample invoice', 'SAMPLE-INV-001'),
                detailRow('Sample amount', money(sampleAmount)),
                detailRow('Sample method', method),
                if (reference.text.trim().isNotEmpty)
                  detailRow('Sample reference', reference.text.trim()),
                detailRow(
                  'Illustrative remaining amount',
                  money(500000 - sampleAmount),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => setState(() => stage = 3),
                  child: const Text('Finish preview'),
                ),
                TextButton(
                  onPressed: () => setState(() => stage = 1),
                  child: const Text('Back'),
                ),
              ] else ...[
                const Icon(
                  Icons.check_circle_outline_rounded,
                  color: KColors.green,
                  size: 48,
                ),
                const SizedBox(height: 18),
                Text(
                  'Preview complete',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                const Text(
                  'No payment was made or recorded. No receipt was issued. Your rental records are unchanged.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => setState(() {
                    stage = 0;
                    amount.text = '5000.00';
                    reference.text = 'SAMPLE-001';
                    method = 'Cash';
                  }),
                  child: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      ),
    ],
  );
}
