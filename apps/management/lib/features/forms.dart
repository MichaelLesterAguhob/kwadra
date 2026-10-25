import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/workspace_store.dart';
import '../ui/components.dart';

// Wait until the reverse transition removes the form before its caller disposes
// field controllers. Navigator.push completes earlier, at pop time.
Future<bool?> _showEditor({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = false,
}) async {
  final route = DialogRoute<bool>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
  );
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  return result;
}

String? requiredValue(String? value) =>
    value == null || value.trim().isEmpty ? 'This field is required.' : null;
String? emailValue(String? value) =>
    value != null &&
        value.isNotEmpty &&
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)
    ? 'Enter a valid email address.'
    : null;
Widget input(
  String label,
  TextEditingController controller, {
  String? hint,
  int lines = 1,
  TextInputType? keyboard,
  String? Function(String?)? validator,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 17),
  child: TextFormField(
    controller: controller,
    maxLines: lines,
    keyboardType: keyboard,
    validator: validator ?? requiredValue,
    textCapitalization: keyboard == TextInputType.emailAddress
        ? TextCapitalization.none
        : TextCapitalization.sentences,
    decoration: InputDecoration(labelText: label, hintText: hint),
  ),
);
Widget selectField(
  String label,
  String value,
  List<String> values,
  ValueChanged<String> changed,
) => Padding(
  padding: const EdgeInsets.only(bottom: 17),
  child: DropdownButtonFormField<String>(
    initialValue: value,
    isExpanded: true,
    menuMaxHeight: 320,
    decoration: InputDecoration(labelText: label),
    items: values
        .map(
          (v) => DropdownMenuItem(
            value: v,
            child: Text(
              v,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        )
        .toList(),
    onChanged: (v) {
      if (v != null) changed(v);
    },
  ),
);
String? rentValue(String? value) =>
    parseMoney(value ?? '') == null || parseMoney(value ?? '')! <= 0
    ? 'Enter a positive amount with up to two decimal places.'
    : null;

class _Editor extends StatefulWidget {
  const _Editor({
    required this.title,
    required this.subtitle,
    required this.fields,
    required this.save,
    this.saveLabel = 'Save changes',
  });
  final String title, subtitle, saveLabel;
  final Widget Function(BuildContext, StateSetter) fields;
  final Future<void> Function() save;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  final _form = GlobalKey<FormState>();
  bool _saving = false;
  String? _error;
  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.save();
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Dialog(
      insetPadding: const EdgeInsets.all(18),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                widget.subtitle,
                style: const TextStyle(color: KColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 24),
              Flexible(
                child: SingleChildScrollView(
                  child: Form(
                    key: _form,
                    child: widget.fields(context, setState),
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: KColors.red, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 17,
                            height: 17,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(widget.saveLabel),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> editProperty(
  BuildContext context,
  WorkspaceStore store, [
  RentalProperty? existing,
]) async {
  final name = TextEditingController(text: existing?.name),
      address = TextEditingController(text: existing?.address),
      notes = TextEditingController(text: existing?.notes),
      contact = TextEditingController(text: existing?.details['contact']),
      rules = TextEditingController(text: existing?.details['houseRules']),
      amenities = TextEditingController(
        text: (existing?.details['amenities'] as List? ?? []).join(', '),
      );
  var type = existing?.type ?? 'Apartment',
      image = existing?.image ?? 'residence';
  final recordId = existing?.id ?? store.newId('property');
  final saved = await _showEditor(
    context: context,
    barrierDismissible: false,
    builder: (_) => _Editor(
      title: existing == null ? 'Add property' : 'Edit property',
      subtitle: 'Start with its name and address.',
      saveLabel: existing == null ? 'Add property' : 'Save changes',
      fields: (ctx, set) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          input('Property name', name, hint: 'e.g. The Palm Residences'),
          input('Location / address', address, hint: 'Street, barangay, city'),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text(
              'More details (optional)',
              style: TextStyle(fontSize: 14),
            ),
            children: [
              selectField('Property type', type, [
                'Apartment',
                'Boarding house',
                'Condominium',
                'House',
              ], (v) => type = v),
              input('Property notes', notes, lines: 3, validator: (_) => null),
              input(
                'Contact for your tenants',
                contact,
                validator: (_) => null,
              ),
              input('House rules', rules, lines: 3, validator: (_) => null),
              input(
                'Amenities (comma separated)',
                amenities,
                validator: (_) => null,
              ),
              const Text(
                'Choose a cover',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Row(
                children: ['residence', 'apartment', 'studio']
                    .map(
                      (asset) => Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Semantics(
                            label: '$asset cover',
                            selected: image == asset,
                            button: true,
                            child: InkWell(
                              onTap: () => set(() => image = asset),
                              borderRadius: BorderRadius.circular(9),
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: image == asset
                                        ? KColors.green
                                        : KColors.line,
                                    width: 2,
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(5),
                                  child: Image.asset(
                                    'assets/images/$asset.jpg',
                                    height: 75,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ],
      ),
      save: () => store.saveProperty(
        RentalProperty(
          id: recordId,
          revision: existing?.revision ?? 0,
          name: name.text.trim(),
          address: address.text.trim(),
          type: type,
          image: image,
          notes: notes.text.trim(),
          details: {
            'contact': contact.text.trim(),
            'houseRules': rules.text.trim(),
            'amenities': amenities.text
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList(),
          },
          archived: existing?.archived ?? false,
        ),
      ),
    ),
  );
  name.dispose();
  address.dispose();
  notes.dispose();
  contact.dispose();
  rules.dispose();
  amenities.dispose();
  if (saved == true && context.mounted) {
    toast(
      context,
      existing == null
          ? 'Property added. Make room for good things.'
          : 'Property updated.',
    );
  }
}

Future<void> editUnit(
  BuildContext context,
  WorkspaceStore store,
  String propertyId, [
  RentalUnit? existing,
]) async {
  final code = TextEditingController(text: existing?.code),
      rent = TextEditingController(
        text: existing == null ? '' : (existing.rent / 100).toStringAsFixed(2),
      ),
      capacity = TextEditingController(text: '${existing?.capacity ?? 2}'),
      floor = TextEditingController(text: existing?.floor ?? 'Ground floor'),
      notes = TextEditingController(text: existing?.notes);
  var type = existing?.type ?? 'Studio',
      maintenance = existing?.maintenance ?? false;
  final recordId = existing?.id ?? store.newId('unit');
  final saved = await _showEditor(
    context: context,
    barrierDismissible: false,
    builder: (_) => _Editor(
      title: existing == null ? 'Add a rental unit' : 'Edit unit',
      subtitle: store.property(propertyId).name,
      saveLabel: existing == null ? 'Add unit' : 'Save changes',
      fields: (ctx, set) => Column(
        children: [
          input('Unit code', code, hint: 'e.g. A-01'),
          selectField('Unit type', type, [
            'Studio',
            '1 Bedroom',
            '2 Bedroom',
            'Room',
            'House',
          ], (v) => type = v),
          input(
            'Monthly rent (PHP)',
            rent,
            keyboard: const TextInputType.numberWithOptions(decimal: true),
            validator: rentValue,
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: input(
                  'Capacity',
                  capacity,
                  keyboard: TextInputType.number,
                  validator: (v) {
                    final n = int.tryParse(v ?? '');
                    return n == null || n < 1 || n > 20
                        ? 'Enter 1–20 people.'
                        : null;
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(child: input('Floor', floor)),
            ],
          ),
          ExpansionTile(
            title: const Text('Unit notes (optional)'),
            children: [input('Notes', notes, lines: 3, validator: (_) => null)],
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Under maintenance',
              style: TextStyle(fontSize: 13),
            ),
            subtitle: const Text(
              'Keep this unit unavailable for new leases.',
              style: TextStyle(fontSize: 11),
            ),
            value: maintenance,
            onChanged: (v) => set(() => maintenance = v),
          ),
        ],
      ),
      save: () => store.saveUnit(
        RentalUnit(
          id: recordId,
          revision: existing?.revision ?? 0,
          propertyId: propertyId,
          notes: notes.text.trim(),
          code: code.text.trim(),
          type: type,
          rent: parseMoney(rent.text)!,
          capacity: int.parse(capacity.text),
          floor: floor.text.trim(),
          maintenance: maintenance,
        ),
      ),
    ),
  );
  code.dispose();
  rent.dispose();
  capacity.dispose();
  floor.dispose();
  notes.dispose();
  if (saved == true && context.mounted) toast(context, 'Unit saved.');
}

Future<void> editTenant(
  BuildContext context,
  WorkspaceStore store, [
  Tenant? existing,
]) async {
  final name = TextEditingController(text: existing?.name),
      email = TextEditingController(text: existing?.email),
      phone = TextEditingController(text: existing?.phone),
      emergency = TextEditingController(text: existing?.emergency);
  final recordId = existing?.id ?? store.newId('tenant');
  final saved = await _showEditor(
    context: context,
    barrierDismissible: false,
    builder: (_) => _Editor(
      title: existing == null ? 'Add tenant' : 'Edit tenant',
      subtitle: 'Add their contact details.',
      saveLabel: existing == null ? 'Add tenant' : 'Save changes',
      fields: (ctx, set) => Column(
        children: [
          input('Full name', name),
          input(
            'Email address',
            email,
            keyboard: TextInputType.emailAddress,
            validator: emailValue,
          ),
          input(
            'Phone number',
            phone,
            keyboard: TextInputType.phone,
            validator: (_) => null,
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text(
              'Emergency contact (optional)',
              style: TextStyle(fontSize: 14),
            ),
            children: [
              input('Emergency contact', emergency, validator: (_) => null),
            ],
          ),
          const Notice(
            'This saves a tenant record. It does not send an account invitation.',
          ),
        ],
      ),
      save: () => store.saveTenant(
        Tenant(
          id: recordId,
          revision: existing?.revision ?? 0,
          name: name.text.trim(),
          email: email.text.trim(),
          phone: phone.text.trim(),
          emergency: emergency.text.trim(),
          archived: existing?.archived ?? false,
        ),
      ),
    ),
  );
  name.dispose();
  email.dispose();
  phone.dispose();
  emergency.dispose();
  if (saved == true && context.mounted) toast(context, 'Tenant profile saved.');
}

Future<void> createLease(
  BuildContext context,
  WorkspaceStore store, {
  String? unitId,
  String? tenantId,
  Lease? renewalOf,
}) async {
  final units = store.visibleUnits.where((u) => !u.maintenance).toList(),
      tenants = store.tenants.where((t) => !t.archived).toList();
  if (units.isEmpty || tenants.isEmpty) {
    toast(context, 'Add a rentable unit and a tenant before creating a lease.');
    return;
  }
  var selectedUnit =
      renewalOf?.unitId ??
      unitId ??
      units
          .firstWhere(
            (u) => store.currentLease(u.id) == null,
            orElse: () => units.first,
          )
          .id;
  var start = store.today,
      end = DateTime(
        store.today.year + 1,
        store.today.month,
        store.today.day - 1,
      );
  if (renewalOf != null) {
    start = renewalOf.end.add(const Duration(days: 1));
    end = DateTime(start.year + 1, start.month, start.day - 1);
  }
  var draft = false;
  final selectedTenants = <String>[
    ...?renewalOf?.tenantIds,
    if (renewalOf == null && tenantId != null) tenantId,
  ];
  final rent = TextEditingController(
        text: ((renewalOf?.rent ?? store.unit(selectedUnit).rent) / 100)
            .toStringAsFixed(2),
      ),
      deposit = TextEditingController(
        text: ((renewalOf?.deposit ?? 0) / 100).toStringAsFixed(2),
      ),
      due = TextEditingController(text: '${renewalOf?.dueDay ?? 5}');
  final recordId = store.newId('lease');
  final saved = await _showEditor(
    context: context,
    barrierDismissible: false,
    builder: (_) => _Editor(
      title: renewalOf == null ? 'Create lease' : 'Renew lease',
      subtitle: 'Choose a unit, tenants and rental dates.',
      saveLabel: renewalOf == null ? 'Create lease' : 'Create renewal',
      fields: (ctx, set) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (store.isRemote)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Save as draft'),
              subtitle: const Text(
                'A draft does not reserve the unit or generate charges.',
              ),
              value: draft,
              onChanged: (v) => set(() => draft = v),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 17),
            child: DropdownButtonFormField<String>(
              initialValue: selectedUnit,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Rental unit'),
              items: units
                  .map(
                    (u) => DropdownMenuItem(
                      value: u.id,
                      child: Text(
                        store.unitLabel(u.id),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  set(() {
                    selectedUnit = v;
                    rent.text = (store.unit(v).rent / 100).toStringAsFixed(2);
                  });
                }
              },
            ),
          ),
          DropdownButtonFormField<String>(
            key: ValueKey(selectedTenants.length),
            initialValue: null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText:
                  'Add tenant · capacity ${store.unit(selectedUnit).capacity}',
            ),
            items: tenants
                .where((t) => !selectedTenants.contains(t.id))
                .map((t) => DropdownMenuItem(value: t.id, child: Text(t.name)))
                .toList(),
            onChanged: (v) {
              if (v != null) set(() => selectedTenants.add(v));
            },
            validator: (_) => selectedTenants.isEmpty
                ? 'Select at least one tenant.'
                : selectedTenants.length > store.unit(selectedUnit).capacity
                ? 'Too many tenants for this unit.'
                : null,
          ),
          if (selectedTenants.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                children: selectedTenants
                    .map(
                      (id) => InputChip(
                        label: Text(
                          store.tenant(id).name,
                          style: const TextStyle(fontSize: 11),
                        ),
                        onDeleted: () => set(() => selectedTenants.remove(id)),
                      ),
                    )
                    .toList(),
              ),
            ),
          const SizedBox(height: 17),
          Row(
            children: [
              Expanded(
                child: _DateField(
                  label: 'Start date',
                  value: start,
                  changed: (v) => set(() => start = v),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _DateField(
                  label: 'End date (inclusive)',
                  value: end,
                  changed: (v) => set(() => end = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 17),
          input(
            'Monthly rent (PHP)',
            rent,
            keyboard: const TextInputType.numberWithOptions(decimal: true),
            validator: rentValue,
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: input(
                  'Deposit agreed (PHP)',
                  deposit,
                  keyboard: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (v) => parseMoney(v ?? '') == null
                      ? 'Enter a valid amount.'
                      : null,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: input(
                  'Due day of month',
                  due,
                  keyboard: TextInputType.number,
                  validator: (v) {
                    final n = int.tryParse(v ?? '');
                    return n == null || n < 1 || n > 31
                        ? 'Enter a day from 1–31.'
                        : null;
                  },
                ),
              ),
            ],
          ),
          const Notice(
            'Co-tenants share one lease. Dates include the final day. Deposit is an agreed term only; no money is collected. Due days beyond a month’s length use its final day.',
          ),
        ],
      ),
      save: () async {
        final value = Lease(
          id: recordId,
          draft: draft,
          unitId: selectedUnit,
          tenantIds: List.of(selectedTenants),
          start: dateOnly(start),
          end: dateOnly(end),
          rent: parseMoney(rent.text)!,
          deposit: parseMoney(deposit.text)!,
          dueDay: int.parse(due.text),
        );
        if (renewalOf == null) {
          await store.addLease(value);
        } else {
          await store.renewLease(value, renewalOf.id);
        }
      },
    ),
  );
  rent.dispose();
  deposit.dispose();
  due.dispose();
  if (saved == true && context.mounted) {
    toast(context, 'Lease created. Here’s to a good stay.');
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.changed,
  });
  final String label;
  final DateTime value;
  final ValueChanged<DateTime> changed;
  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(10),
    onTap: () async {
      final date = await showDatePicker(
        context: context,
        initialDate: value,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
      );
      if (date != null) changed(date);
    },
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: const Icon(Icons.calendar_today_outlined, size: 16),
      ),
      child: Text(shortDate(value), style: const TextStyle(fontSize: 11)),
    ),
  );
}

Future<void> editTicket(
  BuildContext context,
  WorkspaceStore store, [
  MaintenanceTicket? existing,
]) async {
  if (store.visibleUnits.isEmpty) {
    toast(context, 'Add a property and unit first.');
    return;
  }
  final title = TextEditingController(text: existing?.title),
      description = TextEditingController(text: existing?.description);
  var unitId = existing?.unitId ?? store.visibleUnits.first.id,
      category = existing?.category ?? 'General',
      priority = existing?.priority ?? 'Normal';
  final recordId = existing?.id ?? store.newId('request');
  final saved = await _showEditor(
    context: context,
    barrierDismissible: false,
    builder: (_) => _Editor(
      title: existing == null
          ? 'A little care goes a long way'
          : 'Edit maintenance request',
      subtitle: 'What needs fixing, and where?',
      saveLabel: existing == null ? 'Create request' : 'Save changes',
      fields: (ctx, set) => Column(
        children: [
          input('Request title', title, hint: 'e.g. Kitchen faucet leaking'),
          Padding(
            padding: const EdgeInsets.only(bottom: 17),
            child: DropdownButtonFormField<String>(
              initialValue: unitId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Property and unit'),
              items: store.visibleUnits
                  .map(
                    (u) => DropdownMenuItem(
                      value: u.id,
                      child: Text(
                        store.unitLabel(u.id),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) unitId = v;
              },
            ),
          ),
          selectField('Category', category, [
            'General',
            'Plumbing',
            'Electrical',
            'Appliance',
            'Structural',
          ], (v) => category = v),
          selectField('Priority', priority, [
            'Low',
            'Normal',
            'Urgent',
          ], (v) => priority = v),
          input('Describe what needs attention', description, lines: 4),
        ],
      ),
      save: () => store.saveTicket(
        MaintenanceTicket(
          id: recordId,
          revision: existing?.revision ?? 0,
          unitId: unitId,
          title: title.text.trim(),
          description: description.text.trim(),
          category: category,
          priority: priority,
          status: existing?.status ?? 'Open',
          created: existing?.created ?? store.today,
          history: [
            ...?existing?.history,
            '${shortDate(store.today)} · ${existing == null ? 'Created' : 'Updated'} by ${store.ownerName}',
          ],
        ),
      ),
    ),
  );
  title.dispose();
  description.dispose();
  if (saved == true && context.mounted) {
    toast(context, 'Maintenance request saved.');
  }
}
