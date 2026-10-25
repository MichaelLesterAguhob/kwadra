import 'package:flutter/material.dart';

import 'app.dart';
import 'data/workspace_store.dart';
import 'features/session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Backend failures never silently switch to local sample data.
  const localDemo = bool.fromEnvironment('LOCAL_DEMO');
  if (localDemo) {
    final store = await WorkspaceStore.open();
    runApp(KwadraApp(store: store));
  } else {
    runApp(const BackendApp());
  }
}
