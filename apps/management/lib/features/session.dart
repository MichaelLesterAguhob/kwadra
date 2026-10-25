import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../core/theme.dart';
import '../data/api_client.dart';
import '../data/workspace_store.dart';
import '../ui/components.dart';
import 'marketplace.dart';
import 'phase_widgets.dart';
import 'sign_in.dart';
import 'tenant_portal.dart';
import 'platform_console.dart';
import '../services/in_app_notifications.dart';

class BackendApp extends StatelessWidget {
  const BackendApp({super.key, this.api});
  final ApiClient? api;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Kwadra',
    debugShowCheckedModeBanner: false,
    theme: kwadraTheme(),
    home: _SessionGate(injectedApi: api),
  );
}

class _SessionGate extends StatefulWidget {
  const _SessionGate({this.injectedApi});
  final ApiClient? injectedApi;
  @override
  State<_SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<_SessionGate>
    with WidgetsBindingObserver {
  ApiClient? api;
  bool loading = true, authenticated = false;
  Future<bool>? pendingLogin;
  Future<void>? restoringSession;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    restore();
  }

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    api =
        widget.injectedApi ??
        ApiClient(
          baseUrl: prefs.getString('kwadra.api.url') ?? defaultApiUrl(),
        );
    api!.onSessionExpired = sessionEnded;
    if (mounted) setState(() => loading = false);
    restoringSession = restoreSavedSession(api!);
    await restoringSession;
    restoringSession = null;
  }

  Future<void> restoreSavedSession(ApiClient client) async {
    try {
      final restored = await client.restoreSaved();
      if (restored && mounted && identical(api, client)) {
        setState(() => authenticated = true);
        connectNotifications(client);
      }
    } catch (_) {
      /* Public browsing does not wait for a session. */
    }
  }

  void sessionEnded() {
    if (api != null) InAppNotifications.forApi(api!).pause();
    if (!mounted || !authenticated) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    setState(() => authenticated = false);
  }

  Future<bool> requireLogin() async {
    if (restoringSession != null) await restoringSession;
    if (!mounted) return false;
    if (authenticated) return true;
    if (api!.hasCredentials) {
      await restoreSavedSession(api!);
      if (authenticated) return true;
    }
    if (!mounted) return false;
    if (pendingLogin != null) return pendingLogin!;
    final login = Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            SignInPage(client: () => api!, configureServer: configureServer),
      ),
    );
    pendingLogin = login.then((v) => v == true);
    try {
      final signedIn = await pendingLogin!;
      if (signedIn && mounted) setState(() => authenticated = true);
      if (signedIn && mounted) connectNotifications(api!);
      return signedIn;
    } finally {
      pendingLogin = null;
    }
  }

  void connectNotifications(ApiClient client) {
    if ([
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.detached,
    ].contains(WidgetsBinding.instance.lifecycleState)) {
      return;
    }
    final notices = InAppNotifications.forApi(client);
    notices.resume();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (api == null) return;
    if (state == AppLifecycleState.resumed && authenticated) {
      connectNotifications(api!);
    } else if ([
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.detached,
    ].contains(state)) {
      InAppNotifications.forApi(api!).pause();
    }
  }

  Future<void> configureServer() async {
    final address = TextEditingController(text: api!.baseUrl);
    final form = GlobalKey<FormState>();
    final saved = await editor(
      context,
      title: 'Server connection',
      fields: (_) => Form(
        key: form,
        child: TextFormField(
          controller: address,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'API address',
            hintText: 'http://192.168.1.10:3000/api/v1',
          ),
          validator: (v) {
            final uri = Uri.tryParse(v?.trim() ?? '');
            if (uri == null ||
                !uri.hasAuthority ||
                !['http', 'https'].contains(uri.scheme) ||
                uri.query.isNotEmpty ||
                uri.fragment.isNotEmpty ||
                uri.userInfo.isNotEmpty) {
              return 'Enter an HTTP or HTTPS API address.';
            }
            if (kReleaseMode && !kIsWeb && uri.scheme != 'https') {
              return 'Release apps require an HTTPS server.';
            }
            return null;
          },
        ),
      ),
      note: 'For local phone testing, use your computer’s Wi-Fi IP and include /api/v1.',
      save: () async {
        if (!form.currentState!.validate()) {
          throw const FormatException('Check the API address.');
        }
      },
    );
    if (saved && mounted) {
      final url = address.text.trim();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('kwadra.api.url', url);
      if (api != null) {
        InAppNotifications.forApi(api!).pause();
        api!.onSessionExpired = null;
      }
      api?.close();
      if (mounted) {
        setState(() {
          api = ApiClient(baseUrl: url)..onSessionExpired = sessionEnded;
          authenticated = false;
        });
        if (pendingLogin != null) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      }
    }
    address.dispose();
  }

  Future<void> openWorkspace() async {
    if (!await requireLogin() || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'workspace'),
        builder: (_) => _WorkspacePortal(api: api!),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (api != null) InAppNotifications.forApi(api!).pause();
    api?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => loading
      ? const Scaffold(body: Center(child: CircularProgressIndicator()))
      : MarketplaceShell(
          key: ValueKey(api!.baseUrl),
          api: api!,
          signedIn: authenticated,
          requireSignIn: requireLogin,
          configureServer: configureServer,
          openWorkspace: openWorkspace,
          onAccountChanged: () {
            if (mounted) setState(() => authenticated = true);
          },
        );
}

class _WorkspacePortal extends StatefulWidget {
  const _WorkspacePortal({required this.api});
  final ApiClient api;
  @override
  State<_WorkspacePortal> createState() => _WorkspacePortalState();
}

class _WorkspacePortalState extends State<_WorkspacePortal> {
  WorkspaceStore? store;
  final retired = <WorkspaceStore>[];
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    widget.api.onOrganizationChanged = switchWorkspace;
    load();
  }

  Future<void> load() async {
    try {
      final next = widget.api.accountKind == 'management'
          ? await WorkspaceStore.connect(widget.api)
          : null;
      if (!mounted) {
        next?.dispose();
        return;
      }
      if (store != null) retired.add(store!);
      setState(() {
        store = next;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = friendlyError(e);
          loading = false;
        });
      }
    }
  }

  Future<void> switchWorkspace(String id) async {
    final old = widget.api.organizationId;
    widget.api.organizationId = id;
    try {
      final next = widget.api.accountKind == 'management'
          ? await WorkspaceStore.connect(widget.api)
          : null;
      if (!mounted) {
        next?.dispose();
        return;
      }
      Navigator.of(context)
          .popUntil((r) => r.settings.name == 'workspace' || r.isFirst);
      if (store != null) retired.add(store!);
      setState(() {
        store = next;
        error = null;
      });
    } catch (e) {
      widget.api.organizationId = old;
      if (mounted) toast(context, friendlyError(e));
    }
  }

  @override
  void dispose() {
    widget.api.onOrganizationChanged = null;
    store?.dispose();
    for (final item in retired) {
      item.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Your workspace')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error!),
                TextButton(onPressed: load, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      );
    }
    return switch (widget.api.accountKind) {
      'tenant' => TenantPortal(
        key: ValueKey(widget.api.organizationId),
        api: widget.api,
      ),
      'platform' => PlatformConsole(api: widget.api),
      'management' => Scaffold(
        appBar: AppBar(title: const Text('Manage rentals')),
        body: WorkspaceShell(key: ValueKey(store), store: store!),
      ),
      _ => const Scaffold(
        body: Center(
          child: Text(
            'Create a landlord workspace from Account to manage rentals.',
          ),
        ),
      ),
    };
  }
}
