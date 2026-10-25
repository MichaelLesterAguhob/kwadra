import 'package:flutter/services.dart';

Future<String> exportText(String filename, String contents, String mime) async {
  await Clipboard.setData(ClipboardData(text: contents));
  return 'Copied $filename to your clipboard. Paste it into a file to keep a copy.';
}
