import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/models.dart';
import 'phase_widgets.dart';

Future<bool> accountAction(
  BuildContext context,
  ApiClient api,
  String action,
) async {
  final email = TextEditingController(),
      name = TextEditingController(),
      organization = TextEditingController(),
      password = TextEditingController(),
      code = TextEditingController();
  final title = switch (action) {
    'register' => 'Create your workspace',
    'register-seeker' => 'Create your renter account',
    'verify' => 'Verify your email',
    'resend' => 'Resend verification email',
    'recover' => 'Reset your password',
    'reset' => 'Set a new password',
    _ => 'Accept an invitation',
  };
  final saved = await editor(
    context,
    title: title,
    saveLabel: switch (action) {
      'register' || 'register-seeker' => 'Create account',
      'recover' => 'Send reset code',
      'resend' => 'Send verification email',
      'verify' => 'Verify email',
      _ => 'Continue',
    },
    note: ['register', 'register-seeker'].contains(action)
        ? 'Use a password with at least 12 characters. Check your email for a verification code.'
        : action == 'accept'
        ? 'Use the invited email and your existing password if you already have an account.'
        : null,
    fields: (_) => Column(
      children: [
        if (['register', 'register-seeker', 'accept'].contains(action))
          field('Your name', name),
        if ([
          'register',
          'register-seeker',
          'recover',
          'resend',
          'accept',
        ].contains(action))
          field('Email address', email, keyboard: TextInputType.emailAddress),
        if (action == 'register') field('Workspace name', organization),
        if (['verify', 'reset', 'accept'].contains(action))
          field('Code from your email', code),
        if (['register', 'register-seeker', 'reset', 'accept'].contains(action))
          Padding(
            padding: const EdgeInsets.only(bottom: 17),
            child: TextFormField(
              controller: password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: action == 'accept'
                    ? 'Account password'
                    : 'New password',
              ),
              validator: (v) =>
                  (v?.length ?? 0) < 12 ? 'Use at least 12 characters.' : null,
            ),
          ),
      ],
    ),
    save: () async {
      final path = switch (action) {
        'register' => '/auth/register',
        'register-seeker' => '/auth/register-seeker',
        'verify' => '/identity/verify',
        'resend' => '/identity/resend-verification',
        'recover' => '/identity/recover',
        'reset' => '/identity/reset',
        _ => '/identity/accept-invitation',
      };
      final Json body = switch (action) {
        'register' => {
          'name': name.text,
          'email': email.text.trim(),
          'password': password.text,
          'organization': organization.text,
        },
        'register-seeker' => {
          'name': name.text,
          'email': email.text.trim(),
          'password': password.text,
        },
        'recover' || 'resend' => {'email': email.text.trim()},
        'verify' => {'token': code.text.trim()},
        'reset' => {'token': code.text.trim(), 'password': password.text},
        _ => {
          'name': name.text,
          'email': email.text.trim(),
          'password': password.text,
          'token': code.text.trim(),
        },
      };
      await api.request('POST', path, body: body, authenticated: false);
    },
  );
  for (final c in [email, name, organization, password, code]) {
    c.dispose();
  }
  return saved;
}
