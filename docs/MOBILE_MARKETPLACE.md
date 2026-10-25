# Mobile marketplace: 0.6.0+7

Kwadra now opens directly to a native Flutter marketplace. The website at `/marketplace` remains available separately. No WebView is required.

## App flow

1. **Explore:** browse available rentals without signing in. Search by area/title, filter price, move-in cost, type, capacity and amenities, sort, and load more results. Open a rental for photos, advertised costs, rules and publisher review information.
2. **Saved:** sign in to save/remove rentals. Favorites belong to the account and are available after signing in on another device. Unavailable rentals are hidden from the active saved list.
3. **Messages:** sign in to send inquiries, read landlord replies, reply, request a viewing, confirm a proposed time or cancel a viewing. Requested viewings are not confirmed bookings.
4. **Account:** sign in/register, access your landlord/tenant/moderator workspace, create a landlord workspace from a renter account, or sign out.

Tapping a protected action opens sign-in. Cancelling returns to browsing; successful sign-in resumes the requested action. Signing in alone keeps the user in the marketplace. Landlords use **Account → Manage rentals**, tenants use **Account → My tenancy**, and moderators use **Account → Moderation console**. Back navigation returns to the marketplace.

Saving, messaging, viewing requests, copying a rental link, reporting and revealing public contact information require sign-in in the mobile app. Public listings and photos remain readable without an account. The existing SSR website retains its separate guest inquiry/private-link workflow and browser-local favorites.

## Accounts and connection

- Fictional renter: `renter@example.com`, password `KwadraDemo!2026`.
- Existing landlord: `alex@example.com`, same password.
- Other sample roles remain documented in the root README.

New renter accounts need name, email and a password of at least 12 characters. Registration does **not** create a landlord organization or grant management permissions. Verify email before signing in. Account options also provides recovery, verification and invitation acceptance. With external delivery deferred, development verification codes are available with `npm run mail:inbox`; they are not shown publicly in the app. Production password signup remains unavailable while external email delivery is disabled.

For a physical phone, use **Account → Server connection**, or the same action on a connection error, to set `http://YOUR_PC_WIFI_IP:3000/api/v1`. The phone and PC must share a network. Android emulator defaults to `http://10.0.2.2:3000/api/v1`. Web builds use their own origin; the documented Flutter development server on port 8080 connects to port 3000. `API_BASE_URL` can override the default at build time.

An app distributed to other users needs an accessible HTTPS API configured at build time. This change does not deploy a hosted service. Native credentials now use platform secure storage and rotating refresh credentials. Account restoration runs without blocking public browsing. See [account/session details](ACCOUNTS_AND_IN_APP_NOTIFICATIONS.md).

## Backend upgrade and contract

Backend source remains in `kwadra-backend-api`. Migration `004_mobile_marketplace.sql` adds saved rentals, account idempotency records, a personal marketplace account flag and seeker inquiry indexing. Identity mail can be queued without a landlord organization. Existing portfolios, leases, invoices and other records are retained.

Restart the backend to load the new routes. `npm run dev` applies migrations and adds missing fictional fixtures only for the generated local database. For an externally configured database, run `npm run db:migrate` explicitly before `npm start`. Never reset a retained database for this upgrade.

| Endpoint | Purpose |
| --- | --- |
| `POST /api/v1/auth/register-seeker` | Register a renter; email verification required |
| `GET /api/v1/auth/me` | Restore personal identity and optional organization memberships |
| `GET /api/v1/marketplace/saved` | Own available favorites |
| `PUT /api/v1/marketplace/saved/:id` | Save/remove a rental |
| `GET /api/v1/marketplace/inquiries` | Own conversation inbox |
| `POST /api/v1/marketplace/listings/:id/inquiries` | Send an inquiry using verified account identity |
| `GET /api/v1/marketplace/inquiries/:id` | Own conversation and viewings |
| `POST /api/v1/marketplace/inquiries/:id/messages` | Reply |
| `POST /api/v1/marketplace/inquiries/:id/viewings` | Request, confirm or cancel |
| `POST /api/v1/marketplace/listings/:id/report` | Report a listing |
| `POST /api/v1/marketplace/organization` | Create a landlord workspace for the signed-in account |

These personal routes use a verified session without an organization grant. Browser writes still require CSRF protection; mutations require an idempotency key. Account identity comes from the server, not a client-supplied seeker ID or email. Foreign conversations return 404. Organization management routes retain their separate membership/property checks. Staff access revocation does not grant access to landlord records through personal routes; account suspension revokes sessions.

Account-linked inquiries have no anonymous tracking secret. Old guest inquiry links remain separate. Messages and viewing updates notify the authorized landlord team. Conversation refresh remains explicit; live in-app notification invalidations now alert users to new activity.

Payment operations remain excluded. Messaging, saving or confirming a viewing never creates a lease, payment, deposit transaction or receipt.

## Validation

63 PostgreSQL integration tests and 50 Flutter tests pass. Flutter analysis is clean. Browser acceptance covers guest landing, sign-in continuation, account messaging, viewing requests/proposals/confirmation, favorites across reload, and access/back navigation to landlord operations. The existing tenant/moderator browser walkthrough also passes through the new Account entry points.

Web release and Android debug output use version 0.6.0+7. APK: `apps/management/build/app/outputs/flutter-apk/app-debug.apk`. Physical Android-device testing and iOS compilation were not performed.

For isolated browser QA, run `npm run qa:serve` in the backend folder, then `npm run qa:marketplace` in another terminal after the server reports ready. It uses port 3001 and a disposable database, with no email delivery worker. Screenshots/reports are in `.local/mobile-marketplace-smoke`. Stop the owned QA server/database when finished.
