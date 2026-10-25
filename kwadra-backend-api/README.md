# Kwadra backend API

Version 0.6.0 supports the native Flutter marketplace and nonpayment workflows through PRD Phase 3. Renter accounts need no landlord organization; saved rentals and conversations have personal authorization. All backend code, schema, jobs, dependencies, tests and local data stay in this folder. [Mobile marketplace](../docs/MOBILE_MARKETPLACE.md) · [Phase scope](../docs/PHASES_1_TO_3.md).

## Local startup

Requires Node 22.16–24 and npm. Flutter uses Flutter 3.47.7 / Dart 3.13.5 in this workspace.

```powershell
npm ci
npm run dev
```

The development runner owns an isolated PostgreSQL 18.4 cluster at `.local/postgres` on loopback port **55432**, with random credentials in the ignored `.env`. It does not modify the system PostgreSQL service. Startup applies pending migrations and inserts missing fictional fixtures without replacing existing records. First database initialization may take about a minute. Stop from the terminal when finished; do not terminate unrelated PostgreSQL services.

| URL | Purpose |
| --- | --- |
| http://localhost:3000 | Compiled Flutter landlord / tenant / moderator app |
| http://localhost:3000/marketplace | Public rental search and listing pages |
| http://localhost:3000/docs | Interactive API explorer |
| http://localhost:3000/openapi.json | Versioned API contract |
| http://localhost:3000/health | Process health |
| http://localhost:3000/ready | Database/migration readiness |

Build Flutter first if no compiled web app exists:

```powershell
cd ..\apps\management
flutter pub get
flutter build web --release --no-web-resources-cdn --no-wasm-dry-run
```

For hot reload run `flutter run -d chrome --web-port 8080`. VS Code has backend and management web launch configurations. A phone on the same Wi-Fi uses `http://YOUR_PC_WIFI_IP:3000/api/v1` in Server connection. Emulator uses `10.0.2.2`. PostgreSQL stays private on loopback; only API port 3000 needs local-network access. Debug Android permits HTTP; release requires HTTPS.

## Fictional accounts

All use **`KwadraDemo!2026`**, never production credentials.

| Email | Access |
| --- | --- |
| alex@example.com | Owner of Kwadra Living; sample properties, leases, repairs and public listings |
| staff@example.com | Staff for The Palm Residences only |
| viewer@example.com | Read-only organization view |
| beth@example.com | Separate initially empty organization |
| renter@example.com | Personal renter account; no landlord organization required |
| isabel.reyes@example.com | Linked tenant for first sample lease |
| miguel.cruz@example.com | Second linked tenant |
| platform@example.com | Moderator; requires current TOTP code |

For the local moderator, run `npm run admin:code`. Initial sign-in reveals the authenticator field. A successfully used counter cannot be reused; wait for the next 30-second code before another login. The demo TOTP secret is public test data, not suitable for production.

Registration creates a new owner and empty workspace and queues an email verification code. Before signing in, select Account options → Verify email. Invitations and recovery use the same entry point.

The app now opens to Explore. Account options also includes renter registration, which creates no organization. Sign in to save rentals, contact landlords or request viewings. Workspaces are under Account → Manage rentals / My tenancy / Moderation console. Native personal routes use `/api/v1/marketplace/*` with session, CSRF and idempotency protection, without an organization grant. They do not grant landlord permissions. The existing SSR website retains its independent guest inquiry/private-link workflow.

## Email, jobs and files

```powershell
npm run mail:inbox
npm run jobs:run
```

Without SMTP, email is written to the private local inbox and `.local/mail`, never sent externally. `mail:inbox` includes live identity codes; keep its output private. Delivery status is visible to organization managers. Configure `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_USER`, `SMTP_PASSWORD`, `MAIL_FROM` in `.env` to use SMTP; TLS is enforced. Production never falls back to local mail. External delivery requires separate credentials/testing.

The API runs background jobs every minute: idempotent current-month charges, charge-due reminders and durable delivery processing. `jobs:run` runs the same work manually. Up to five email attempts, five-minute backoff; failed delivery does not roll back an issued charge. SMTP delivery is at least once, not exactly once.

Files are stored privately in PostgreSQL with MIME/signature checks, 2 MiB/file and 50 MiB/organization quotas. Images are decoded/resized and metadata removed. PDF downloads are attachments. Access is checked per lease/repair/review purpose. Back up attachment bytes together with the database.

## API conventions and manipulation

In `/docs`, execute `POST /auth/login` with `client: "web"`. The explorer attaches the selected organization, CSRF token and fresh idempotency keys. Refreshing the explorer clears its selection; sign in again. Moderator login additionally supplies `mfaCode`.

Native/API clients use `client: "native"` and send `Authorization: Bearer TOKEN`, `X-Organization-Id` and `Idempotency-Key` for business mutations. Browser cookies require `X-CSRF-Token` for writes. Login/logout and public identity routes have their own rules. Reuse the same idempotency key with the identical body only for retrying that operation.

Money is integer centavos (`125050` = PHP 1,250.50). Dates use `YYYY-MM-DD`, Asia/Manila. IDs are UUIDs. Create management records with `revision: 0`; edits use the revision returned by reads. Stale edits return 409. New phase endpoints with server-generated IDs do not need client IDs unless their documented schema requires one.

Core collections support `page`, `pageSize` (max 100), `q` and relevant property/unit/status filters. `/workspace` returns the authorized landlord snapshot; `/operations` adds utility/files/marketplace records. Tenants use `/tenant/portal` and cannot enter landlord routes. Platform reviewers require MFA and receive only moderation projections, never tenant contracts.

Public `/public/listings` supports rent/move-in-cost/type/capacity/amenity filters and sort/page. Inquiry tracking uses the secret returned at creation in `X-Inquiry-Token`, never a query string. Public form posts are rate limited; private business mutations use transactional idempotency. See `/openapi.json` for endpoints and [workflow rules](../docs/PHASES_1_TO_3.md) for policies.

```powershell
npm run db:inspect
npm run db:migrate
npm run db:seed
npm run check
npm test
```

The database is `kwadra`, host `127.0.0.1`, port `55432`, user `kwadra_app`; use your ignored `.env` for the password. Never put credentials in Flutter. Migrations 001–004 apply transactionally in order; do not edit applied migrations. Migration 004 retains existing records and adds personal marketplace state. Restart the backend to load the new routes, then fully restart Flutter.

Optional **destructive** local reset is limited to this folder's generated database credentials and port. Export needed data first and pause edits:

```powershell
npm run db:reset -- --confirm=RESET_KWADRA_DEVELOPMENT
```

The app has no database-reset/import endpoint. Visible-record exports are not full database backups. Old device-local demo data is preserved, not imported.

## Payments and release boundaries

No payment, proof, allocation, receipt, deposit transaction, adjustment, refund, checkout, provider callback or subscription API/job exists. Reserved financial tables remain empty. Flutter's payment preview is a fictional, nonpersistent UI sample. Lease deposit terms and advertised move-in costs do not collect money.

Rent uses the existing full-month, no-proration policy; utilities have exact preview/confirm issuance. Issued charges are immutable. Financial corrections remain disabled. See [phase status](../docs/PHASES_1_TO_3.md) for complete rules, architecture choices and excluded release gates.

## Hosted database and production preparation

Configure `DATABASE_URL`, run migrations explicitly, then `npm start`. Start never seeds/migrates automatically. Dev auto-seeds only its isolated database. `DATABASE_SSL=true` enables certificate-verified database TLS.

Production requires `NODE_ENV=production`, `COOKIE_SECURE=true`, a canonical HTTPS `PUBLIC_ORIGIN`, exact `CORS_ORIGINS`, a private database, SMTP and a stable 64-hex-character `ENCRYPTION_KEY` for MFA. Back up the encryption key separately; losing it prevents decrypting authenticator secrets. Development generates its ignored key at `.local/encryption-key`. A single trusted reverse-proxy hop is assumed. Public owner registration and demo seeding are disabled in production; provision accounts through a reviewed process.

A trusted operator can enroll an already verified account with `npm run admin:enroll -- --email=ACCOUNT_EMAIL`. It creates a separate moderation workspace, revokes existing sessions and prints a private authenticator enrollment URI. Keep that URI secret and store recovery procedures offline.

Production password signup requires enabled email delivery and verification; external delivery is currently deferred. A verified renter can create their own landlord workspace through the personal marketplace API. This grants no access to another organization's records.

Deployment/TLS, backup and restore drill, runtime/migration role separation, monitoring, load tests, physical-device/iOS acceptance, production file scanning/retention and compliance sign-off remain open. No hosted service is deployed. The local runtime role owns schema; production should use a restricted role. PostgreSQL version support must be verified on the target host.

## Verification

`npm test` uses a fresh isolated PostgreSQL cluster, not the development DB. It covers organization/property/tenant boundaries, concurrency, leases/invoices, files, identity tokens, MFA replay, utilities, move-outs, moderation and inquiry/viewing state changes, jobs and empty payment tables.

With the compiled web app and backend running:

```powershell
node scripts/browser-smoke.mjs
node scripts/phase-browser-smoke.mjs
```

The first drives the property → unit → tenant → lease → invoice → repair workflow and checks PostgreSQL, restored cookie sessions and zero payment-preview network calls. The second exercises marketplace and tenant/moderator browser views. Chrome runs hidden; screenshots/reports stay in ignored `.local`. Browser checks preserve synthetic test organizations for inspection and never reset the samples.

Native marketplace acceptance can use a separate disposable server: run `npm run qa:serve`, then `npm run qa:marketplace` in another terminal. It listens on 3001, uses its own database and starts no email jobs. See [mobile verification](../docs/MOBILE_MARKETPLACE.md). The suite now has 63 API tests and 50 Flutter tests.


## Account update: 0.6.0

Migration 005 adds external Google identities, rotating native session families and account notification indexing. The app has a personal notification inbox and foreground SSE invalidations. Phone push is excluded; external email delivery defaults off, including when SMTP values are present. Local verification codes remain available with `npm run mail:inbox`. See [implementation, OAuth setup, tests and deployment](../docs/ACCOUNTS_AND_IN_APP_NOTIFICATIONS.md).

Use `npm run build` for a compiled Node deployment, `npm run services:check` for connectivity/migration checks, and `npm run db:upgrade-local` only for the generated local database. Deployment files stay under `deploy`; no live deployment is claimed.
