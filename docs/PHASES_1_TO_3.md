# Phase 1–3 delivery status

Version 0.6.0, 25 October 2026. Numbering follows the complete PRD. This is a local implementation of the nonpayment scope, with the exclusions below. Production release and all PRD exit gates are not claimed complete. The [native Flutter marketplace](MOBILE_MARKETPLACE.md) now opens first; account actions require sign-in, and private workspaces are under Account.

## Available workflows

| Phase | Implemented | Where |
| --- | --- | --- |
| 1 | Email verification, recovery, Argon2id passwords, sessions; owner/admin/staff/viewer invitations, property grants and revocation | Sign-in Account options; More → Team |
| 1 | Properties/contact/rules/amenities, unit notes, tenants; draft/activate/end/renew leases, co-tenants, exclusive occupancy; private lease documents | Properties, Tenants, More → Leases / Documents |
| 1 | Idempotent monthly rent charges, itemized records, scheduled generation, dashboard, existing reports/export and audit history | Home; More → Invoices / Reports / Activity |
| 2 | Linked tenant sign-in; own current, upcoming and historical tenancies, itemized charges, documents and announcements | Tenant Home / Charges / More |
| 2 | Tenant repairs, photos/conversation; scoped assignment, acknowledgement, resolution and closure | Tenant Repairs; landlord repair detail → Comments & photos |
| 2 | Meter baselines/readings, exact tariff calculations, confirmed previews, issuance; unissued reading corrections; equal shared bills | Landlord More → Utilities |
| 2 | Announcements, in-app notices/preferences, charge-due reminders, durable email status/retries | More → Announcements / Notifications / Delivery status |
| 2 | Tenant move-out request, scheduling and handover checklist; controlled lease termination preserving charges | Tenant More; landlord More → Move-outs |
| 3 | Public SSR listings, location/price/move-in-cost/type/capacity/amenity filters, sorting/pagination, device-local favorites/share | `/marketplace` |
| 3 | Drafts/photos, public location precision/contact policy, advertised costs, submission/approval/unpublication; immediate availability enforcement | Landlord More → Listings |
| 3 | Inquiries, secret-bound tracking/replies; viewing requests/proposals/confirmation/decline/completion; tenant profile conversion followed by separate lease creation | Public listing; landlord More → Inquiries |
| 3 | Private publisher evidence; MFA moderation, listing review, reports, takedown, appeals/restoration, suspension/session revocation; append-only history | Platform account; landlord listing review cases |
| 3 | Listing metadata/canonical/structured data, robots, current-availability sitemap; private pages excluded from indexing | SSR pages, `/robots.txt`, `/sitemap.xml` |

The landlord retains four primary destinations. Tenants and moderators have separate four-tab views. Organization switching reloads the selected role's workspace.

## Exclusions and release gates

The user's payment exclusion overrides payment items in the documents. Manual payments, proofs, allocations, receipts, reversals, invoice adjustments, deposit collection/refunds/forfeiture, checkout, provider callbacks, reconciliation and subscriptions are absent. Reserved tables remain empty. Payment preview is fictional and sends no API requests. Collected/overdue financial dashboards and financial move-out settlement remain deferred.

Production email transport, domain/TLS, hosted deployment, account provisioning, backup/restore drill, monitoring, separate runtime/migration database roles, load testing, physical-phone/iOS acceptance, research and compliance sign-off remain release work. SMTP integration exists but external email delivery is deliberately disabled for this delivery. Synthetic publisher reviews do not imply verification of real rentals.

Push/SMS, real-time chat, independently billed beds, custom shared-bill formulas, issued-charge financial corrections, automatic backups, PDF malware scanning and distributed job infrastructure are excluded. Larger portfolios still need measured pagination/query/load work. Native sessions now restore from secure storage with rotating refresh credentials. Google sign-in and linking need OAuth client configuration. In-app notices stream foreground invalidations; phone push and external email remain deferred by instruction. See [account delivery](ACCOUNTS_AND_IN_APP_NOTIFICATIONS.md).

## Implemented rules

- API money uses integer centavos; storage uses exact PostgreSQL numeric. Dates use Asia/Manila. Rent is full-month for an overlapping active lease, without proration/late fees. Due days clamp to month end. No future-month generation or closed-lease historical backfill. Rent is unique per lease/month; utility charges have separate sources.
- Draft leases neither reserve occupancy nor generate rent. Activation repeats capacity, archive, maintenance and overlap checks. Renewals create linked terms; prior charges stay immutable. Co-tenants share one exclusive unit lease.
- Readings have four decimal places. First reading is baseline. Delta × tariff rounds half up once to centavos using integer arithmetic. Readings are chronological/nondecreasing. Issuance requires the current preview and revision, once per reading. Billed readings and corrections affecting later billed readings are locked.
- Shared bills split equally across eligible occupied leases in the selected month. Remainder cents follow unit-code/lease-ID order. Confirmed allocations must match current occupancy. Property/month/normalized bill reference is unique. A turnover with multiple qualifying leases for a unit is rejected rather than guessed.
- Jobs run about once a minute within the API. Locks, unique sources and durable logs support retries. Due reminders describe issued charges, not unpaid debt. Email retries stop at five attempts with five-minute backoff. SMTP delivery is at least once: a crash after SMTP acceptance can duplicate an email despite a stable message ID.
- Files are at most 2 MiB each and 50 MiB per organization. JPEG/PNG are decoded, metadata stripped, resized and pixel-limited. PDF/JPEG/PNG magic bytes and MIME must agree. PDFs download as files. Lease documents require participant or property staff access. Repair evidence requires the reporter or property staff. Platform reviewers cannot read tenant contracts or repair evidence. Production scanning/retention policy remains to be reviewed.
- Tenant access derives from linked profiles and lease participation, including historical records. Draft leases are staff-only. Repairs require a current active lease. Announcements target current linked tenants. Move-out completion requires scheduled handover on/before today and all checklist items; it never settles deposits.
- Public listings require verified publishers and approval. Editing or adding photos removes publication until review. Archive, maintenance, current/future reservations and suspended creators hide search/detail/photos/sitemap immediately. Public projection excludes tenancy records/private addresses. Exact coordinates/contact require explicit publisher policy.
- Native favorites and conversations belong to the signed-in account and are revalidated. Native inquiry identity comes from the verified account; those conversations have no anonymous tracking secret. The separate SSR website retains browser-local favorites and guest links. Guest inquiry secrets are hashed, expire after 30 days and use a header; browser links keep the secret in the fragment outside HTTP logs. Forms have rate limits/honeypots. Viewing proposals require confirmation.
- Platform review requires an encrypted TOTP secret and MFA session with counter replay protection. Review/takedown/appeal/suspension decisions require reasons. Appeals never republish automatically. Verification is an evidence-review status, not a rental guarantee.

## Architecture and upgrades

Backend code stays entirely in `kwadra-backend-api`. Migration `003_phases_one_to_three.sql` upgrades 001/002 in place. Seeding inserts missing fictional fixtures without resetting portfolios or edited samples. Add new migrations for future changes; do not edit applied migrations. Back up retained hosted data before upgrades.

Express SSR with assets in `apps/marketplace/public` replaces the initial Next.js proposal for this delivery. Parameterized `pg` SQL replaces Prisma. PostgreSQL jobs/delivery logs replace the proposed Redis/BullMQ setup at this scale. Generated SDKs, Redis infrastructure and production deployment are not claimed delivered.

## Acceptance walkthrough

1. As Alex, create a draft lease, activate it, share a document and verify an overlapping lease fails.
2. Invite a staff member or existing tenant profile in Team. Read `npm run mail:inbox`, then accept via Account options. Existing users must enter their current password.
3. As Isabel, submit a repair/photo. As Alex, comment, assign, resolve and close it. Compare Miguel's portal for privacy.
4. Save a meter baseline and later reading; preview/issue and retry issuance. Preview a shared bill and confirm its reconciled split.
5. Publish an announcement and check delivery/preferences. Request/schedule a move-out; complete only when the handover date/checklist permits.
6. Browse `/marketplace`, filter/save/share, submit an inquiry and retain the private tracking link. Reply as Alex, propose a viewing and confirm as the seeker. Convert to a tenant profile, then create a lease separately.
7. Submit publisher/listing reviews from another workspace. As Platform, use `npm run admin:code`, inspect evidence and record reasoned decisions. Test report/takedown/appeal/restoration. Reserving the unit hides it immediately.
8. Complete Payment preview and confirm no payment record is created.

Account update: a native/Web notification bell now exposes the private account inbox, unread/read actions and in-app preference. Verification resend and optional Google sign-in are included. Docker/Caddy deployment configuration and separate database roles are prepared, but host deployment, backups, real Google-account acceptance and physical-device checks remain pending.
