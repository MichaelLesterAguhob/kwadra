# Kwadra

Kwadra **0.6.0+7** opens directly to a native Flutter rental marketplace. Visitors browse freely; signing in unlocks saved rentals, landlord conversations and viewings. Landlord, tenant and moderator workspaces are available under Account. The PostgreSQL backend implements nonpayment workflows through PRD Phase 3 for local testing. See [mobile marketplace](docs/MOBILE_MARKETPLACE.md) and [phase status](docs/PHASES_1_TO_3.md).

Secure native session restoration, verification resend and live in-app notifications are now available. Google sign-in can be enabled with your OAuth client IDs. Phone push and external email delivery remain deferred. See [account improvements and setup](docs/ACCOUNTS_AND_IN_APP_NOTIFICATIONS.md).

## Projects

- `apps/management`: Flutter marketplace plus landlord, tenant and moderator workspaces.
- `apps/marketplace/public`: public marketplace assets; the API renders indexable HTML.
- `kwadra-backend-api`: all backend code, dependencies, migrations, jobs, configuration, tests and local database files.

## Run

```powershell
cd kwadra-backend-api
npm ci
npm run dev
```

This starts Kwadra's isolated PostgreSQL on **55432** and API on **3000**, applies pending migrations and adds missing fictional fixtures. Existing records are preserved. It does not use the system PostgreSQL service.

- [Public marketplace](http://localhost:3000/marketplace)
- [API explorer](http://localhost:3000/docs)
- [Management / tenant / moderator app](http://localhost:3000), using the compiled Flutter web build

For Flutter development, open another terminal:

```powershell
cd apps/management
flutter pub get
flutter run -d chrome --web-port 8080
```

All sample accounts use **`KwadraDemo!2026`**:

| Account | Access |
| --- | --- |
| `alex@example.com` | Landlord with fictional properties, tenants and approved sample listings |
| `staff@example.com` | Staff assigned to The Palm Residences |
| `viewer@example.com` | Read-only landlord workspace |
| `beth@example.com` | Separate workspace for your own test records |
| `renter@example.com` | Personal renter account for saving rentals, messaging and viewings |
| `isabel.reyes@example.com` | Tenant linked to the first sample lease |
| `miguel.cruz@example.com` | Another tenant for privacy checks |
| `platform@example.com` | Platform moderator; requires an authenticator code |

Run **`npm run admin:code`** in the backend folder for the current development moderator code. Sign in once to reveal the authenticator field, then submit the code. Codes expire every 30 seconds and cannot be reused after a successful login.

Registration, invitations and recovery use one-time email codes. Without SMTP, email stays in the private development inbox: **`npm run mail:inbox`**. Paste the relevant code into the sign-in screen's Account options. See [backend setup](kwadra-backend-api/README.md).

The app starts on **Explore**. Use **Account → Sign in**, or tap Save rental / Message landlord to sign in and resume that action. Landlords open **Account → Manage rentals**; linked tenants open **Account → My tenancy**. New renters can register without creating a landlord organization.

## Android testing

Install [the debug APK](apps/management/build/app/outputs/flutter-apk/app-debug.apk) on a phone on the same Wi-Fi. Open **Account → Server connection** while signed out, or Server connection on a loading error, and enter `http://YOUR_PC_WIFI_IP:3000/api/v1`. Keep the backend running. Android emulator defaults to `http://10.0.2.2:3000/api/v1`. Check `/health` from the phone browser if connectivity fails; Windows Firewall may need Node access on the private network.

After upgrading, **restart the backend and fully restart Flutter**. Migration 004 retains existing portfolios. `npm run dev` applies it for the generated local database and adds the renter fixture; externally configured databases need `npm run db:migrate` explicitly.

Debug allows local HTTP. Native release builds need HTTPS. iOS has not been built on Windows. VS Code launch configurations are in `.vscode/launch.json`; this workspace selects Flutter at `C:/src/flutter` (Flutter 3.47.7 / Dart 3.13.5).

## Data and payments

Flutter uses the API by default. Web sessions use HttpOnly cookies; native tokens stay in memory, so restarting requires signing in again. Refresh loads another client's changes. The old local demo remains available explicitly with `--dart-define=LOCAL_DEMO=true` and is never uploaded automatically.

**Payments remain excluded.** No payment, proof, allocation, receipt, deposit transaction, refund, checkout, provider callback or subscription API/job is enabled. More → Payment preview uses fictional UI data and makes no network requests. Rent and utility charges are not collections or balance statements. A lease deposit amount is a contractual term only.

See [workflow rules](docs/PHASES_1_TO_3.md) and [database scope](kwadra-backend-api/docs/DATABASE.md). A hosted database can be configured in the backend `.env`; Flutter never receives database credentials. No online service has been deployed.

## Checks and builds

```powershell
cd kwadra-backend-api
npm run check
npm test
node scripts/browser-smoke.mjs
node scripts/phase-browser-smoke.mjs

cd ..\apps\management
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build web --release --no-web-resources-cdn --no-wasm-dry-run
flutter build apk --debug
```

Backend tests use their own PostgreSQL cluster. Browser checks require the running backend, compiled Flutter web app and Chrome; synthetic records remain available for inspection. Web output is `apps/management/build/web`; APK output is `apps/management/build/app/outputs/flutter-apk/app-debug.apk`.

Verified: **63 backend tests, 50 Flutter tests**, clean static checks, web release and Android debug builds. Native Flutter browser acceptance covers guest landing, sign-in continuation, messages, viewing confirmation, saved rentals across reload, and landlord navigation. Tenant/moderator browser checks also pass. See [mobile implementation and verification](docs/MOBILE_MARKETPLACE.md). [0.4 verification](docs/VERIFICATION_0_4_0.md) remains historical.

Android disables Kotlin incremental compilation because the project and Pub cache are on different Windows drives.

## Assets and planning

The supplied hut mascot remains at `apps/management/assets/branding/kwadra-logo.png`. Regenerate platform icons with `powershell -File scripts/generate-icons.ps1`. Manrope uses the SIL Open Font License. Photo attribution: [ATTRIBUTION.md](apps/management/assets/ATTRIBUTION.md).

Both original Word documents remain intact. [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) retains the original proposal; [current delivery status](docs/PHASES_1_TO_3.md) records implementation choices and remaining work.

