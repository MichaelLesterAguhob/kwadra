# Database scope and integrity

Migrations model the full PRD. Active workflows through Phase 3 are implemented except the user's payment exclusions. [Delivery status](../../docs/PHASES_1_TO_3.md).

| Scope | Tables | Status |
| --- | --- | --- |
| Identity | users, sessions, identity_tokens, invitations | Verification/recovery, one-time invitations, Argon2id; encrypted MFA for moderators |
| Organizations | organizations, memberships, property_assignments | Role/property grants, tenant role, revocation |
| Portfolio/tenancy | properties, units, tenants, leases, lease_participants | CRUD/archive, linked tenant access, draft/activate/end/renew |
| Charges | invoices, invoice_items | Immutable monthly rent and utility charges; no payments |
| Repairs | maintenance_tickets, maintenance_events, maintenance_comments | Tenant requests, assignment, photos, conversation, resolution/closure |
| Private files | attachments, lease_documents, ticket_attachments | Authorized bytes, size/quota/type checks |
| Tenant operations | utility_meters, utility_readings, shared_utility_batches, announcements, notifications, notification_preferences, move_outs | Active |
| Marketplace | amenities, listings, listing_amenities, listing_photos, inquiries, inquiry_messages, viewings | Active |
| Personal marketplace | saved_listings, account_idempotency_keys, users.marketplace_account, inquiries.seeker_id | Active; verified personal sessions without landlord organization grants |
| Moderation | publisher_verifications, listing_reports, moderation_cases, moderation_events, platform_events | Active, MFA-only privileged review |
| Delivery | delivery_logs | Durable email jobs/status/retries |
| Evidence/retries | audit_events, idempotency_keys, schema_migrations | Active |
| Payments/deposits | payments, payment_allocations, payment_proofs, payment_reversals, receipts, invoice_adjustments, deposit_transactions, provider_events | Reserved, empty, no API or jobs |
| Subscriptions | subscription_plans, subscriptions | Reserved, empty, no API |
| Advanced automation | outbox_events, automation_rules | Reserved; delivery_logs is the active email queue |

UUIDs identify records. Organization child foreign keys include organization ID, preventing cross-workspace relationships. Money is `NUMERIC(14,2)` pesos in PostgreSQL and integer centavos over HTTP. Calendar dates are `DATE`; instants are `TIMESTAMPTZ`.

Lease occupancy is a generated `daterange`. A GiST exclusion constraint rejects overlaps for organization/unit, including historical ended occupancy. Draft/cancelled leases occupy no dates. Renewal links have composite ownership and duplicate-active-renewal protection. Co-tenants belong to one exclusive lease.

Business writes take an organization advisory lock. Row revisions prevent stale overwrites; organization revisions track snapshots. Idempotency keys bind actor, organization, operation/path and canonical payload to a committed response. PostgreSQL enforces unit/email uniqueness, parent ownership, occupancy, rent lease/month uniqueness, utility source uniqueness and shared-bill reference uniqueness.

Invoices, invoice items, audit events, repair history/comments, inquiry messages and moderation history reject update/delete through triggers. Issued utility corrections and all financial adjustments are intentionally absent. Local database owners can alter triggers; use separate restricted runtime and migration roles before production.

Attachments contain private bytea content. File relationships/purpose are checked on every read; platform review excludes lease/repair files. Public photos use listing eligibility at request time. No file bytes are written to a public filesystem.

Migration 001 created the management baseline; 002 reserved later module structures; 003 enables nonpayment Phases 1–3 in place, retaining existing records, charges and occupancy. Migrations run under a lock in a transaction. Never edit applied migrations on retained data. Add a migration and back up before upgrades.

Migration 004 adds personal saved rentals/idempotency, an account flag and seeker inquiry indexing. Identity email may have a null organization ID, allowing verified renter registration/recovery without creating a landlord workspace. Personal routes authorize by session user; landlord routes retain membership/property grants. Personal interactions can activate marketplace access for an existing user, preserving personal data after staff membership revocation. Account suspension still revokes sessions. Account-linked inquiries have no guest tracking token.

Archive/end workflows preserve records. Historical tenant rights derive from lease participation. Session expiry is checked on reads; administrative revocation takes effect immediately. General data retention/purging and production backup/restore drills remain follow-up work. App export is not a full database backup.


## 005: accounts and in-app notifications

Additive migration `005_accounts_and_notifications.sql` adds `external_identities`, `native_session_families`, `refresh_credentials`, nullable passwords for Google-only accounts, verification-request timestamps and notification conversation links/indexes. Existing portfolios, leases, charges and sessions remain. Identity changes revoke native session families through a trigger. There are no phone push/device delivery tables. Payment tables and operations remain excluded.
