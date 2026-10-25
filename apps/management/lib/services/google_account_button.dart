import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'google_button_render.dart'
    if (dart.library.js_interop) 'google_button_render_web.dart';

Future<void>? _initializing;
String? _initializedClient;

class GoogleAccountButton extends StatefulWidget {
  static bool get supported =>
      kIsWeb ||
      [
        TargetPlatform.android,
        TargetPlatform.iOS,
      ].contains(defaultTargetPlatform);
  const GoogleAccountButton({
    super.key,
    required this.clientId,
    this.iosClientId,
    required this.onToken,
    required this.onError,
    this.enabled = true,
  });
  final String clientId;
  final String? iosClientId;
  final ValueChanged<String> onToken;
  final ValueChanged<Object> onError;
  final bool enabled;
  @override
  State<GoogleAccountButton> createState() => _GoogleAccountButtonState();
}

class _GoogleAccountButtonState extends State<GoogleAccountButton> {
  StreamSubscription<GoogleSignInAuthenticationEvent>? events;
  bool ready = false, busy = false;
  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    try {
      if (_initializedClient != null && _initializedClient != widget.clientId) {
        throw const FormatException(
          'Restart Kwadra after changing Google sign-in configuration.',
        );
      }
      _initializedClient = widget.clientId;
      _initializing ??= GoogleSignIn.instance.initialize(
        clientId: kIsWeb ? widget.clientId : widget.iosClientId,
        serverClientId: widget.clientId,
      );
      await _initializing;
      if (!mounted) return;
      if (kIsWeb) {
        events = GoogleSignIn.instance.authenticationEvents.listen(
          (event) {
            if (event is GoogleSignInAuthenticationEventSignIn &&
                mounted &&
                widget.enabled) {
              deliver(event.user);
            }
          },
          onError: (Object e) {
            if (mounted) widget.onError(e);
          },
        );
      }
      setState(() => ready = true);
    } catch (e) {
      if (mounted) widget.onError(e);
    }
  }

  void deliver(GoogleSignInAccount account) {
    final token = account.authentication.idToken;
    if (token == null) {
      widget.onError(
        const FormatException('Google did not return a sign-in token.'),
      );
    } else {
      widget.onToken(token);
    }
  }

  Future<void> authenticate() async {
    if (!ready || busy) return;
    setState(() => busy = true);
    try {
      deliver(await GoogleSignIn.instance.authenticate());
    } on GoogleSignInException catch (e) {
      if (e.code != GoogleSignInExceptionCode.canceled && mounted) {
        widget.onError(e);
      }
    } catch (e) {
      if (mounted) widget.onError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    events?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return const SizedBox(
        height: 44,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (kIsWeb) {
      return IgnorePointer(ignoring: !widget.enabled, child: googleWebButton());
    }
    return OutlinedButton(
      onPressed: widget.enabled && !busy ? authenticate : null,
      child: Text(busy ? 'Connecting…' : 'Continue with Google'),
    );
  }
}
