import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<String> exportText(String filename, String contents, String mime) async {
  final blob = web.Blob([contents.toJS].toJS, web.BlobPropertyBag(type: mime));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  Future<void>.delayed(
    const Duration(seconds: 2),
    () => web.URL.revokeObjectURL(url),
  );
  return 'Downloaded $filename.';
}
