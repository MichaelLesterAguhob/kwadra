# Accounts and in-app notifications — 0.6.0+7

25 October 2026. This delivery follows the latest instruction: **in-app notifications only; no phone push or external email delivery for now**. Express/PostgreSQL and the single Flutter mobile/web client remain in place. Payment operations remain excluded.

## Available behavior

- Native sign-in saves only access/refresh credentials in platform secure storage, separately for each API address. Android backups are disabled; iOS credentials use device-bound Keychain storage. Passwords and authenticator codes are never saved.
- On restart, the app restores the account without blocking public marketplace browsing. Expired access credentials refresh automatically. Browser sessions continue to use HttpOnly cookies, never browser token storage.
- A native session can be remembered for 30 days from sign-in. Access credentials last up to 12 hours; refresh credentials rotate once per use. Reusing an old refresh credential revokes that session family. Administrator sessions remain capped at 12 hours and require MFA again. Logout, password changes, suspension and MFA changes revoke remembered credentials.
- Account options includes **Resend verification email**. Requests use a generic response, a one-minute account cooldown and replacement of older verification codes. Verification/recovery codes remain available to the local developer through `npm run mail:inbox`.
- The marketplace header has a notification bell, unread badge, private inbox, read/unread actions and an in-app preference. Opening an inquiry/viewing notification opens its conversation. New updates show a short in-app alert while the app is being used.
- Foreground notifications use an authenticated SSE connection to the existing API. The server checks for changes every five seconds, with a maximum of five live connections per account per API process. Streams carry invalidation signals only; private content is read from the authorized inbox. Connections revalidate sessions, reconnect after interruptions and stop when the app goes into the background or signs out. The bell also refreshes on resume and periodically as a fallback.
- Landlord replies and viewing decisions now notify signed-in renters. Existing landlord/tenant notices also appear in their account inbox; inaccessible organization notices are filtered out.
- Google sign-in and explicit account linking are implemented without Firebase Authentication. They remain hidden until real OAuth client IDs are configured. A matching email never silently merges accounts or grants organization access. Existing password users sign in, open the bell/account page and link Google using their current password. Administrator MFA remains required.

There are no Firebase dependencies, phone notification permissions, FCM sender or phone push endpoints. Nothing runs as an OS notification service. Email delivery is disabled by default, even if SMTP settings exist: `EMAIL_DELIVERY_ENABLED` must be explicitly enabled in a future delivery. Development jobs spool mail locally; production jobs leave queued mail pending while delivery is disabled.

## Run locally

```powershell
cd kwadra-backend-api
npm ci
npm run dev
```

Restart an already-running API to load the new source. The generated local database receives additive migration `005_accounts_and_notifications.sql`; edited portfolios and charges are retained. Do not reset the database. For a retained external database, back it up and apply `npm run db:migrate` before starting the updated API.

```powershell
cd apps/management
flutter pub get
flutter run -d chrome --web-port 8080
```

For a phone, use the computer's Wi-Fi address in **Account → Server connection**, including `/api/v1`. Install the rebuilt debug APK when testing outside the IDE. Native release builds require an HTTPS API address.

Without external email, new password accounts need a local verification step:

1. Create the renter account in the app.
2. Run `npm run mail:inbox` in the backend folder.
3. Use the newest verification code in **Account options → Verify email**.

That inbox is development-only. Production password signup remains unavailable without verified email delivery; it is not bypassed automatically. Configured Google accounts whose email Google controls can sign in without Kwadra email delivery. Other Google email accounts still need Kwadra verification.

## Google configuration

Create Google Cloud OAuth clients and configure the consent screen. No OAuth client secret belongs in Flutter.

- Backend `.env`: set `GOOGLE_WEB_CLIENT_ID`; set `GOOGLE_IOS_CLIENT_ID` if supporting iOS. Restart the API. The public provider endpoint exposes only these non-secret client IDs.
- Android: register package `ph.kwadra.kwadra_management` and the SHA signing fingerprints for the build being tested. Use `android/gradlew signingReport` to inspect fingerprints. Google sign-in does not need Firebase configuration files.
- Web: authorize the exact local and hosted JavaScript origins, such as `http://localhost:3000`, `http://localhost:8080` and the eventual HTTPS domain. The API permits Google popup communication.
- iOS: run the helper with real public client IDs, then rebuild on macOS:

```powershell
python scripts/configure-google-ios.py --client-id=IOS_CLIENT_ID.apps.googleusercontent.com --server-client-id=WEB_CLIENT_ID.apps.googleusercontent.com
```

The helper adds the required iOS URL scheme. Real Google-account acceptance still requires your configured project; automated tests inject identities only to exercise Kwadra's account-linking and permission rules. Production token signature, issuer, audience and expiry verification use Google's official library.

References: [Google backend verification](https://developers.google.com/identity/sign-in/android/backend-auth), [Flutter Google plugin](https://pub.dev/packages/google_sign_in), [Android setup without Firebase](https://pub.dev/packages/google_sign_in_android), [web origin and popup setup](https://developers.google.com/identity/gsi/web/guides/get-google-api-clientid).

## New API surface

| Endpoint under `/api/v1` | Purpose |
| --- | --- |
| `POST /auth/refresh` | Rotate a native refresh credential |
| `GET /auth/providers` | Public optional Google configuration |
| `POST /auth/google` | Verify Google identity and establish a Kwadra session |
| `POST /auth/google/link` | Authenticated linking with current password |
| `POST /identity/resend-verification` | Generic verification resend request |
| `GET /account/notifications` | Own visible notices, unread count and preference |
| `GET /account/notifications/events` | Foreground invalidation stream |
| `POST /account/notifications/read` | Mark own visible IDs as read |
| `PUT /account/notification-preferences` | Set `{ "inApp": true }` |

Personal endpoints do not require an organization grant. Browser writes require CSRF protection. Organization permissions still apply to the linked private records. Read marking and preference updates are naturally idempotent; they do not create financial records.

## Device and browser acceptance

The regression suite covers stored-credential restoration, concurrent refresh, logout, verification resend screens, notification preferences and read state. Backend tests also cover token replay, suspension, administrator MFA, account linking, private SSE updates, renter reply/viewing notices and runtime database permissions.

The real-device test uses the actual secure-storage plugin and a disposable/demo account:

```powershell
cd apps/management
flutter test integration_test/account_session_test.dart -d ANDROID_DEVICE_ID --dart-define=KWADRA_TEST_API_URL=http://YOUR_PC_IP:3000/api/v1
```

The default credentials are the fictional `renter@example.com` account. Only use a test account/database. A native process restart, airplane-mode recovery, simultaneous devices and background/resume should also be checked manually. No physical Android phone was attached during implementation; iOS needs macOS/Xcode. These are pending acceptance checks, not completed device tests.

## Hosted deployment preparation

All backend deployment files are under `kwadra-backend-api/deploy`. The Docker image contains the compiled API, existing marketplace assets and built Flutter website. PostgreSQL is private; Caddy serves HTTPS. The API runs without root privileges on a read-only filesystem. Schema changes use a separate migration account; the runtime database account cannot change the schema or migration history.

1. Build Flutter Web in `apps/management`:

```powershell
flutter build web --release --no-web-resources-cdn --no-wasm-dry-run
```

2. From `kwadra-backend-api`, generate a private configuration for the **real domain**:

```powershell
npm run deploy:prepare -- --domain=rentals.example.com --email=owner@example.com
```

This creates ignored `deploy/.env.production` with generated database passwords and an MFA encryption key; it refuses to overwrite an existing file. The email argument is Caddy's certificate contact, not an email-delivery provider. Keep the file protected and backed up. Configure optional Google IDs locally. Delivery remains disabled in Compose.

3. On a Linux server with Docker Compose, point DNS to that server, allow ports 80/443 and run from `kwadra-backend-api/deploy`:

```sh
chmod 600 .env.production
docker compose --env-file .env.production -f compose.yml config --quiet
docker compose --env-file .env.production -f compose.yml up -d --build
```

The first deployment creates an empty production database and applies migrations; it does not add fictional demo fixtures or automatically copy development records. Retaining existing data needs an explicit backup/restore or an existing hosted PostgreSQL configuration. Do not replace a retained database with an empty one.

Check `/health` and `/ready`, then test public browsing, authorized sign-in and cross-account boundaries on the real HTTPS domain. `npm run services:check` verifies connectivity/migration presence without printing credentials or sending mail. Before a public release, arrange encrypted off-server backups and restore verification, monitoring, rollback, privacy review and actual target-device acceptance.

No host/domain or OAuth client IDs were supplied. Docker is not installed in this Windows environment, so the container stack has not been built or deployed here. Its database permission model is exercised against isolated PostgreSQL in the integration suite. Live deployment, real Google sign-in and physical-device acceptance remain pending.

## Recorded verification

63 backend integration tests and 50 Flutter tests passed. Flutter analysis and formatting are clean. Node type checks and compiled server build passed. Flutter Web release and Android debug APK builds succeeded; Android package `ph.kwadra.kwadra_management`, version 0.6.0 / code 7, min SDK 24, target SDK 36. The APK has no phone-notification permission.

Both Chrome acceptance walkthroughs passed against an isolated QA database: native Flutter marketplace/account notifications/read state/live stream, landlord navigation, public SSR pages, tenant repairs/charges and moderator MFA/views. Reports contain zero payment requests and no runtime failures. Disposable QA services were stopped after validation.

The generated development database was verified against its local credentials, started and upgraded additively to five migrations. Counts before and after matched: properties 6, units 26, tenants 20, leases 20, invoices 20, payments 0. The updated development API was started on port 3000 with external email delivery explicitly disabled; `/health` and `/ready` returned 200.

Evidence: backend `.local/accounts-test-run.log`, `.local/mobile-marketplace-smoke/report.json`, `.local/phase-browser-smoke/report.json`; Flutter `build/account-flutter-tests.log`, `build/account-flutter-analysis.log`, `build/account-web-build.log`, `build/account-android-build.log`. The Docker stack and physical devices were not exercised here.
