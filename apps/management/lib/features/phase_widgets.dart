import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/models.dart';
import '../ui/components.dart';

typedef Command = Future<Json> Function(
  String path,
  Json body, {
  String method,
});

List<Json> records(Json data, String key) =>
    (data[key] as List? ?? []).map((v) => Json.from(v)).toList();
Widget field(
  String label,
  TextEditingController controller, {
  bool optional = false,
  int lines = 1,
  TextInputType? keyboard,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 17),
  child: TextFormField(
    controller: controller,
    maxLines: lines,
    keyboardType: keyboard,
    decoration: InputDecoration(labelText: label),
    validator: (v) => !optional && (v?.trim().isEmpty ?? true)
        ? 'This field is required.'
        : null,
  ),
);
Widget choice(
  String label,
  String? value,
  Map<String, String> values,
  ValueChanged<String> changed,
) => Padding(
  padding: const EdgeInsets.only(bottom: 17),
  child: DropdownButtonFormField<String>(
    initialValue: values.containsKey(value) ? value : null,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: values.entries
        .map(
          (e) => DropdownMenuItem(
            value: e.key,
            child: Text(e.value, overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged: (v) {
      if (v != null) changed(v);
    },
    validator: (v) => v == null ? 'Select an option.' : null,
  ),
);

Future<bool> editor(
  BuildContext context, {
  required String title,
  required Widget Function(StateSetter set) fields,
  required Future<void> Function() save,
  String saveLabel = 'Save',
  String? note,
}) async {
  final route = DialogRoute<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PhaseEditor(
      title: title,
      fields: fields,
      save: save,
      saveLabel: saveLabel,
      note: note,
    ),
  );
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  return result == true;
}

class _PhaseEditor extends StatefulWidget {
  const _PhaseEditor({
    required this.title,
    required this.fields,
    required this.save,
    required this.saveLabel,
    this.note,
  });
  final String title, saveLabel;
  final String? note;
  final Widget Function(StateSetter) fields;
  final Future<void> Function() save;
  @override
  State<_PhaseEditor> createState() => _PhaseEditorState();
}

class _PhaseEditorState extends State<_PhaseEditor> {
  final form = GlobalKey<FormState>();
  bool busy = false;
  String? error;
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Dialog(
      insetPadding: const EdgeInsets.all(18),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    onPressed: busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              if (widget.note != null) ...[
                const SizedBox(height: 10),
                Notice(widget.note!),
              ],
              const SizedBox(height: 20),
              Flexible(
                child: SingleChildScrollView(
                  child: Form(key: form, child: widget.fields(setState)),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        if (!form.currentState!.validate()) return;
                        setState(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await widget.save();
                          if (context.mounted) Navigator.pop(context, true);
                        } catch (e) {
                          if (mounted) {
                            setState(() {
                              busy = false;
                              error = friendlyError(e);
                            });
                          }
                        }
                      },
                child: Text(busy ? 'Saving…' : widget.saveLabel),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<Json?> pickAttachment({bool imagesOnly = false}) async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: imagesOnly
        ? ['png', 'jpg', 'jpeg']
        : ['pdf', 'png', 'jpg', 'jpeg'],
  );
  if (file == null) return null;
  final size = await file.length();
  if (size != null && size > 2097152) {
    throw const ApiException('Choose a file up to 2 MB.');
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > 2097152) {
    throw const ApiException('Choose a file up to 2 MB.');
  }
  final ext = file.name.split('.').last.toLowerCase();
  return {
    'filename': file.name,
    'mediaType': ext == 'pdf'
        ? 'application/pdf'
        : ext == 'png'
        ? 'image/png'
        : 'image/jpeg',
    'base64': base64Encode(bytes),
  };
}

Future<void> downloadAttachment(
  BuildContext context,
  Future<Json> Function(String) get,
  String id, {
  bool platform = false,
}) async {
  try {
    final file = await get(platform ? '/platform/files/$id' : '/files/$id');
    if (!context.mounted) return;
    await FilePicker.saveFile(
      fileName: file['filename'] as String,
      bytes: base64Decode(file['base64'] as String),
    );
  } catch (e) {
    if (context.mounted) toast(context, friendlyError(e));
  }
}

class RemoteContent extends StatefulWidget {
  const RemoteContent({super.key, required this.load, required this.builder});
  final Future<Json> Function() load;
  final Widget Function(BuildContext, Json, Future<void> Function()) builder;
  @override
  State<RemoteContent> createState() => _RemoteContentState();
}

class _RemoteContentState extends State<RemoteContent> {
  Json? data;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final loaded = await widget.load();
      if (mounted) {
        setState(() {
          data = loaded;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (data == null) {
      return Padding(
        padding: const EdgeInsets.all(30),
        child: Center(
          child: error == null
              ? const CircularProgressIndicator()
              : Column(
                  children: [
                    Text(error!),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: refresh,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (busy) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          MaterialBanner(
            content: Text(error!),
            actions: [
              TextButton(onPressed: refresh, child: const Text('Retry')),
            ],
          ),
        widget.builder(context, data!, refresh),
      ],
    );
  }
}
