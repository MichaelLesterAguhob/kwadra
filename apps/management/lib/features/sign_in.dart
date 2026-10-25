import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../data/api_client.dart';
import '../ui/components.dart';
import '../core/theme.dart';
import 'account_extensions.dart';
import '../services/google_account_button.dart';

class SignInPage extends StatefulWidget {
  const SignInPage({
    super.key,
    required this.client,
    required this.configureServer,
    this.purpose,
  });
  final ApiClient Function() client;
  final Future<void> Function() configureServer;
  final String? purpose;
  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final email = TextEditingController(),
      password = TextEditingController(),
      mfa = TextEditingController();
  final form = GlobalKey<FormState>();
  bool busy = false, needsMfa = false;
  String? error;
  String? googleCredential;
  Map<String, dynamic>? googleProvider;
  @override
  void initState() {
    super.initState();
    loadProviders();
  }

  Future<void> loadProviders() async {
    try {
      final providers = await widget.client().request(
        'GET',
        '/auth/providers',
        authenticated: false,
      );
      if (mounted) {
        setState(
          () => googleProvider = providers['google'] as Map<String, dynamic>?,
        );
      }
    } catch (_) {
      /* Email sign-in remains available during a configuration outage. */
    }
  }

  Future<void> googleLogin(String token) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.client().loginGoogle(token, mfaCode: mfa.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = friendlyError(e);
          if (e is ApiException &&
              ['MFA_REQUIRED', 'MFA_INVALID'].contains(e.code)) {
            googleCredential = token;
            needsMfa = true;
          }
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> login() async {
    if (busy || !form.currentState!.validate()) return;
    if (googleCredential != null) {
      await googleLogin(googleCredential!);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.client().login(
        email.text,
        password.text,
        mfaCode: mfa.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = friendlyError(e);
          if (e is ApiException &&
              ['MFA_REQUIRED', 'MFA_INVALID'].contains(e.code)) {
            needsMfa = true;
          }
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> options() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in [
                ('register-seeker', 'Create a renter account'),
                ('register', 'Create a landlord workspace'),
                ('verify', 'Verify email'),
                ('resend', 'Resend verification email'),
                ('accept', 'Accept an invitation'),
                ('recover', 'Forgot password'),
                ('reset', 'Use a password reset code'),
              ])
                ListTile(
                  title: Text(item.$2),
                  onTap: () => Navigator.pop(context, item.$1),
                ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    final done = await accountAction(context, widget.client(), action);
    if (!mounted || !done) return;
    if (['register-seeker', 'register'].contains(action)) {
      toast(context, 'Account created. Verify your email, then sign in.');
      await accountAction(context, widget.client(), 'verify');
    } else {
      toast(
        context,
        action == 'verify'
            ? 'Email verified. You can sign in.'
            : 'Done. Check your email if a code was requested.',
      );
    }
  }

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    mfa.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Surface(
                child: Form(
                  key: form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Brand(),
                      ),
                      const SizedBox(height: 26),
                      Text(
                        'Welcome back',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.purpose ?? 'Sign in to save rentals, message landlords and access your workspace.',
                        style: const TextStyle(color: KColors.muted),
                      ),
                      const SizedBox(height: 24),
                      if (googleCredential == null)
                        TextFormField(
                          controller: email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.username],
                          decoration: const InputDecoration(
                            labelText: 'Email address',
                          ),
                          validator: (v) => v == null || !v.contains('@')
                              ? 'Enter your email address.'
                              : null,
                        ),
                      const SizedBox(height: 18),
                      if (googleCredential == null)
                        TextFormField(
                          controller: password,
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          decoration: const InputDecoration(
                            labelText: 'Password',
                          ),
                          validator: (v) => (v?.isEmpty ?? true)
                              ? 'Enter your password.'
                              : null,
                          onFieldSubmitted: (_) => login(),
                        ),
                      if (needsMfa) ...[
                        const SizedBox(height: 18),
                        TextFormField(
                          controller: mfa,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          decoration: const InputDecoration(
                            labelText: 'Authenticator code',
                          ),
                          validator: (v) => v?.length != 6
                              ? 'Enter your current six-digit code.'
                              : null,
                        ),
                      ],
                      if (error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          error!,
                          style: const TextStyle(color: KColors.red),
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: busy ? null : login,
                        child: Text(busy ? 'Signing in…' : 'Sign in'),
                      ),
                      if (googleProvider?['enabled'] == true &&
                          (kIsWeb ||
                              [
                                TargetPlatform.android,
                                TargetPlatform.iOS,
                              ].contains(defaultTargetPlatform))) ...[
                        const SizedBox(height: 12),
                        GoogleAccountButton(
                          clientId: googleProvider!['webClientId'] as String,
                          iosClientId:
                              googleProvider!['iosClientId'] as String?,
                          enabled: !busy,
                          onToken: googleLogin,
                          onError: (e) {
                            if (mounted) {
                              setState(() => error = friendlyError(e));
                            }
                          },
                        ),
                      ],
                      TextButton(
                        onPressed: busy ? null : options,
                        child: const Text('Account options'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () async {
                                await widget.configureServer();
                                await loadProviders();
                                if (mounted) setState(() => error = null);
                              },
                        child: const Text('Server connection'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
