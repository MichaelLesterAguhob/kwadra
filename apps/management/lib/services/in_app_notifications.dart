import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/api_client.dart';

/// Foreground updates only: no OS notifications, Firebase or email provider.
class InAppNotifications {
  InAppNotifications._(this.api);
  static final _instances = Expando<InAppNotifications>();
  static InAppNotifications forApi(ApiClient api) =>
      _instances[api] ??= InAppNotifications._(api);
  static final updates = ValueNotifier<int>(0);
  final ApiClient api;
  StreamSubscription<void>? subscription;
  Timer? reconnect;
  bool active = false;
  void resume() {
    if (active || !api.liveNotifications) return;
    active = true;
    connect();
  }

  void connect() {
    if (!active) return;
    subscription = api.notificationEvents().listen(
      (_) => updates.value++,
      onError: (Object _) {},
      onDone: () {
        if (active) reconnect = Timer(const Duration(seconds: 5), connect);
      },
    );
  }

  void pause() {
    active = false;
    reconnect?.cancel();
    subscription?.cancel();
    subscription = null;
  }
}
