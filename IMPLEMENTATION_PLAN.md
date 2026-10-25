# Kwadra implementation plan

> Account update: 0.6.0+7 adds secure remembered native sessions, verification resend, live in-app notices and optional Google sign-in. Phone push and external email delivery are deferred by the latest user instruction. Deployment files are prepared; no host/domain is configured. See [current account delivery](docs/ACCOUNTS_AND_IN_APP_NOTIFICATIONS.md).

> Current delivery: version 0.5.0 implements the nonpayment workflows through PRD Phase 3 for local testing. See [current scope, rules and remaining release gates](docs/PHASES_1_TO_3.md). Backend code is entirely in kwadra-backend-api. Express SSR replaces the original Next.js proposal; pg SQL replaces Prisma; PostgreSQL-backed jobs replace the proposed Redis/BullMQ infrastructure for this delivery. Payment operations remain excluded. The sections below preserve the original planning baseline, not a claim of current production readiness.

Current mobile update: version 0.5.0 adds a native marketplace landing screen, renter registration, account saved rentals/conversations and viewing interactions. Browsing is public; mobile interactions require sign-in. Private workspaces are under Account. See [mobile scope and validation](docs/MOBILE_MARKETPLACE.md). Backend migration 004 retains existing data; payment operations remain excluded.

Prepared: 17 October 2026. Status: proposed implementation baseline for review.

Implementation update: Flutter is in `apps/management`; the PostgreSQL-backed API, migrations, jobs and tests are in `kwadra-backend-api`. The public marketplace uses Express SSR and `apps/marketplace/public`. Nonpayment workflows through Phase 3 are implemented for local testing. Payment and subscription tables remain reserved and empty. Refer to the current delivery status above for limits; the following sections preserve the original planning baseline.

## 1. Basis and current folder

Read in full:

- `Kwadra Initial System Architecture.docx` — architecture v1.0, October 2026.
- `Kwadra_Complete_PRD_Phased_Development_Scope.docx` — PRD v1.0, 9 October 2026, draft.

The root currently contains these two documents. There is no application scaffold, dependency manifest, or Git repository. No applicable `AGENTS.md` was found in the root or its ancestor folders. This plan adds documentation only; application implementation and environment readiness checks remain future work.

Use the PRD's Phase 0–5 numbering. The architecture's numbered delivery phases describe similar work but use different numbers; the PRD provides the more detailed scope and acceptance criteria. Keep both source documents intact.

Build landlord operations first, tenant operations second, marketplace third, and integrated payments/subscriptions fourth. Treat privacy, financial integrity, backups, and authorization as requirements throughout.

## 2. Proposed technical decisions

| Area | Proposal | Purpose |
| --- | --- | --- |
| Repository | One monorepo in this root | Keep clients, contracts, backend, migrations, infrastructure, and documentation together |
| Management app | One responsive Flutter project for Android, iOS, and authenticated web | Share landlord and later tenant features; adapt navigation and tables to phone/desktop |
| Public marketplace | Next.js, introduced in Phase 3 | Render indexable public listing pages separately from private operations |
| API | TypeScript + Express, modular monolith, Zod validation | Implement one backend with clear business module boundaries |
| Database | PostgreSQL + Prisma, reviewed SQL migrations where needed | Enforce relational and financial integrity |
| Background work | Redis + BullMQ worker and PostgreSQL transactional outbox | Support billing schedules and retryable delivery without coupling commits to notifications |
| Contracts | Versioned OpenAPI; generated Dart and TypeScript clients | Keep client models and API behavior aligned |
| Hosting | Docker Compose on Ubuntu/Contabo, Caddy, Cloudflare | Follow the supplied architecture with private database/queue networking |
| Files | Authorized private file storage with quotas and backup | Protect contracts, receipts, and later payment proofs |

The Flutter portal choice resolves an open engineering question as a recommendation, not an approved product decision. Use one project at `apps/management` rather than creating separate mobile and portal projects with duplicated features. Revisit a dedicated portal only if measured web usability or product needs justify it.

Create the marketplace project when Phase 3 starts. Choose supported, mutually compatible runtime/package versions during scaffolding, pin them, and commit lockfiles. Do not guess versions from the planning documents.

Keep server-side financial calculations authoritative. Flutter may preview values but must display the server's confirmed results. Initial offline behavior is safe read/error/retry handling; offline financial writes and synchronization need separate scope.

## 3. Target folder structure

```text
kwadra/
  Kwadra Initial System Architecture.docx
  Kwadra_Complete_PRD_Phased_Development_Scope.docx
  IMPLEMENTATION_PLAN.md
  README.md
  .gitignore
  .env.example
  .github/workflows/
  apps/
    management/                 # Flutter: Android, iOS, authenticated web
      lib/
        app/                    # Bootstrap, routes, session, responsive shell
        core/                   # Shared UI, errors, configuration
        features/               # Auth, portfolio, leases, billing, payments...
      test/
      integration_test/
    api/                        # Express startup, HTTP routes and middleware
    worker/                     # Schedules, outbox dispatcher, job handlers
    marketplace/                # Next.js; created in Phase 3
  packages/
    backend/                    # Server-only services shared by API and worker
      src/modules/              # Identity, organizations, properties, leases...
      prisma/                   # Schema, migrations, synthetic seed fixtures
    api-contracts/              # OpenAPI source and TypeScript client generation
    kwadra_api/                 # Generated Dart API package
  infrastructure/
    docker/                     # Development/staging/production Compose files
    caddy/
    backups/
    monitoring/
  scripts/                      # Setup, code generation, verification, restore
  tests/
    integration/
    acceptance/
    fixtures/
  docs/
    architecture/               # Decisions, ERD, permission matrix
    product/                    # Business rules, research, feature traceability
    api/
    ux/
    operations/                 # Deploy, rollback, restore, incident procedures
```

Create directories as their first real files are introduced. TypeScript workspace tooling manages server packages; Flutter uses Dart tooling. The generated Dart package is the client/server contract boundary. The API and worker reuse server services, database access, and transaction rules; neither duplicates billing logic. No business module becomes a separate network service at this stage.

## 4. Phase 0: decisions and engineering foundation

### Product and data design

Prepare the business-rule register with IDs BR-01–BR-12, examples, edge cases, owner, status, and linked acceptance tests. Add missing billing decisions: first/last-month proration, due days 29–31, billing-period boundaries, rounding, invoice numbering, and receipt numbering.

Document these proposals for review:

- Email/password first, verified email recovery and invitations; phone retained as optional contact. Phone OTP is a separate provider/cost decision.
- Explicit organization membership and assigned-property permissions for staff. Tenant access derives from linked tenancy, not a staff role.
- Separate organization-owned tenant profiles from login accounts, so landlords can record tenants before portal invitations.
- Co-tenants can participate in one lease, subject to unit capacity. Independently billed bedspaces require an explicit rentable-bed/occupancy model before activation; a capacity field alone is insufficient.
- Partial allocations and unapplied credit are supported; late penalties remain deferred as the PRD proposes.
- Deposit transactions remain separate from rent charges and rental collections from the start; tenant closeout screens arrive in Phase 2.
- A landlord's manual-payment confirmation records their verification of received funds. Tenant screenshots remain pending evidence until the Phase 2 review workflow confirms them.

Unresolved rules remain visibly open. Build independent platform work while discovery continues; do not encode disputed financial or occupancy behavior as approved policy.

Complete the PRD's research deliverable (10 landlords, 10 tenants, 10 active seekers), workflow synthesis, target-segment decision, Phase 1 wireframes, ERD/table dictionary, status transitions, and permission matrix. Interviews and sign-off require actual participants and designated owners; software scaffolding does not satisfy them.

### Engineering foundation

1. Initialize Git, ignore secrets/build outputs, add environment templates and root setup instructions.
2. Check Flutter/Dart, Node, Docker, Android tooling, and CI compatibility. Use Windows for web/Android development; arrange macOS/Xcode for iOS builds and device verification.
3. Establish development, test, staging, and production configurations with isolated data and credentials. Use synthetic fixtures.
4. Start PostgreSQL and Redis locally; scaffold API health/readiness endpoints, worker, Flutter shell, structured logs, and request IDs.
5. Define `/api/v1` contracts, validation, errors, pagination, filters, idempotency behavior, and generated clients. Fail CI on contract/client drift.
6. Implement authentication, verification/recovery, session revocation, invitation token expiry, and permission middleware. Browser sessions use protected cookies with CSRF defenses; mobile uses secure credential storage and revocable refresh rotation. Avoid persistent browser token storage. Require MFA for platform administrators and define privileged-owner/staff MFA policy.
7. Add CI formatting, static analysis, relevant tests, builds, dependency/secret checks, and migration validation. Build versioned deployment images.
8. Prepare staging TLS, private service networking, protected secrets, monitoring, encrypted off-site backups, restore verification, and rollback procedures.

Exit evidence: reviewed Phase 0 artifacts, working staging baseline, demonstrated rollback and isolated restore, and approved/deferred business rules with clear scope. Credentials, hosting accounts, email delivery, backup destination, and DNS access are dependencies for live demonstrations; a local script alone is not evidence of a successful deployment.

## 5. Phase 1: landlord MVP delivery sequence

Deliver each package as a working API + Flutter workflow + migration + relevant tests + acceptance demonstration. Add authorization/audit checks with each feature.

| Order | PRD requirements | Deliverable and acceptance evidence |
| --- | --- | --- |
| 1. Accounts and organizations | AUTH-001, ORG-001 | Register/verify/login/recover, create organization, invite staff, scope properties, revoke access. A second organization cannot access the first organization's data. |
| 2. Portfolio | PROP-001, UNIT-001 | Property and unit create/edit/archive, rent/capacity/status fields, vacancy views. Two properties and 15 rooms produce correct inventory counts; active leases block unsafe archival. |
| 3. Tenancy | TEN-001, LEASE-001 | Tenant profiles, participants, lease draft/activation/end/renewal, documents, occupancy checks. Concurrent activations cannot overbook an exclusive unit or approved shared capacity. |
| 4. Charges | BILL-001 | Billing schedule, month preview, recurring job, invoices/items, adjustments, due/overdue balances. Reruns, concurrent jobs, and restart recovery create one invoice per lease/period. |
| 5. Collections | PAY-001 | Manual cash/bank/e-wallet payment confirmation, invoice allocations, unapplied credit, receipt, reversal with reason, basic deposit transaction recording. PHP 5,000 paid as PHP 2,000 then PHP 3,000 reaches zero balance. |
| 6. Operational views | DASH-001, AUD-001 | Occupancy, charges, collections, overdue balances, due dates, ledger drill-down, audit viewer, CSV export. All totals reconcile with source transactions and obey staff scope. |
| 7. Private-beta gate | All Phase 1 scenarios | End-to-end workflow, concurrency/security regression, restore drill, migration/rollback rehearsal, target-device usability, agreed-load performance results, and product/QA sign-off. |

Build these screens in the same order: access/onboarding, portfolio, property/unit detail, tenant list/detail, lease editor/detail, invoice list/detail, record payment/receipt, dashboard, audit/export, staff/settings.

Every screen needs loading, empty, validation, permission-denied, network-error, and retry behavior. Use desktop navigation/tables and phone navigation/cards where appropriate; check labels, keyboard operation, readable text, and low-bandwidth use.

The first demonstration is one authenticated landlord creating a property/unit/tenant/lease, generating rent once, recording a partial payment, and seeing the correct remaining balance. It is a development milestone; private beta additionally requires every release gate.

## 6. Database and financial integrity

Phase 1 entities include users, sessions, verification/recovery tokens, organizations, memberships, invitations, property assignments, properties, units, tenant profiles, leases, participants, invoice periods, invoices/items, adjustments/credit notes, payments, allocations, reversals, deposit transactions, attachments, audit events, and outbox events.

- Use UUIDs, required foreign keys, and organization-scoped indexes. Use composite ownership constraints where practical to prevent cross-organization parent/child links at the database boundary as well as in services.
- Validate requested organization context against current membership, property grants, and resource ownership on every request. Apply the same controls to exports, downloads, search, reports, and background tasks.
- Use PostgreSQL NUMERIC/Prisma Decimal for money, decimal strings in JSON, and explicit precision/rounding. Use TIMESTAMPTZ for instants and DATE for billing dates interpreted in Asia/Manila. Do not calculate money with binary floating-point arithmetic.
- Enforce unique unit codes within a property and invoices within an organization/lease/period. Use reviewed SQL constraints where Prisma cannot express the required rule.
- For exclusive occupancy, use database-backed date-overlap protection. For approved shared capacity, serialize competing occupancy changes and test capacity across date boundaries. A pre-insert availability query alone is insufficient.
- Confirm payments, validate allocation limits, write allocations/audit/outbox events, and update any projections in one database transaction. Lock affected rows or use suitable transaction isolation with bounded retries to prevent concurrent over-allocation.
- Give write requests and jobs durable idempotency keys. Bind keys to actor/organization, operation, and payload; reject conflicting reuse. Distinguish retry detection from duplicate external payment references requiring review.
- Preserve issued financial records. Correct them using linked adjustments, credit notes, and reversals. Derive balances from valid posted entries; any cached summary must reconcile to those entries.
- Define invoice amount due, unapplied cash credit, deposit liability, and net account position separately. Show overpayment rather than losing it by clamping every balance to zero. Keep rent collections, deposits, and later platform subscription revenue distinct.
- Keep deposit collection/refund/deduction history from Phase 1 even though the complete move-out workflow is Phase 2.
- Restrict audit mutation with database permissions and preserve safe actor/action details without logging secrets or unnecessary personal information.
- Save outbox events with the financial transaction; dispatch after commit. Expect retries and deduplicate consumers. Queue availability or a failed notification must not undo or double-post rent/payments. PostgreSQL remains the durable source for job recovery.

## 7. Later phases

| Phase | Scope and dependency | Exit evidence |
| --- | --- | --- |
| 2. Tenant operations | Lease invitations and own-record access; payment proof review; maintenance lifecycle. Add utility calculations, announcements/reminders, and move-out/deposit closeout according to Should-priority decisions. | Tenant/landlord ledger agreement; proof approval posts once, rejection never changes balance; attachment authorization; maintenance history; reviewed utility and closeout examples. |
| 3. Marketplace | Next.js public listing pages; safe public-field projections; vacancy/approval-linked publishing; location/price/type/amenity filters; inquiries/viewings; publisher verification, reports, moderation, appeal history. | Occupied/unapproved listings unavailable for discovery; private data absent; correct filters and inquiry routing; indexable metadata and usable mobile loading. |
| 4. Payments and business model | Approved provider checkout, signed callbacks, durable provider-event deduplication, settlement/refund/reconciliation; then separate landlord subscription plans and entitlements. | Duplicate callbacks do not double-credit; provider reconciliation balances; defined downgrade/grace behavior preserves records; required financial/legal/provider/privacy reviews complete before live money movement. |
| 5. Optimization | Aging/trend reports, approved automation, measured query/cache improvements, object storage or dedicated database/worker hosting, availability improvements. | Source-reconciled reports and measured load/recovery targets with tested migration/rollback. |

Initial MVP exclusions follow the PRD: automatic GCash/Maya collection, public discovery, advanced tenant self-service, complex utility metering, AI pricing, automated legal decisions, and full general-ledger accounting. Model extensibility where required, but build these features in their assigned phase.

## 8. Verification and deployment

Maintain requirement-to-test traceability using PRD IDs. Use focused unit tests for date/money/state rules, integration tests against real PostgreSQL for constraints and transactions, and API/Flutter end-to-end tests for critical journeys. Cross-organization/property/tenant denial tests must cover direct IDs, nested requests, downloads, exports, and revoked access.

Include concurrent lease activation, repeated billing, duplicate payments, partial allocation, overpayment, reversal, deposit separation, job crash/retry, and permission changes. Migration checks must cover both a clean database and upgrading representative prior-version data.

On Contabo, expose only intended web endpoints through Caddy/Cloudflare; keep PostgreSQL, Redis, worker, and private files off public service ports. Use hardened SSH administration, protected production secrets, file limits/type checks, redacted logs, health checks, and alerts for disk, errors, latency, failed jobs, and backups. Never cache authenticated API responses as public CDN content.

Use immutable images and backward-compatible migrations. Rehearse application rollback without assuming schema downgrade is safe. Back up PostgreSQL with base backups and WAL archiving, plus files/configuration, encrypted outside the VPS with separate credentials and documented retention. Test the database/file recovery boundary and full restore monthly. Validate the provisional RPO of one hour and RTO of 4–8 hours through drills.

Measure the PRD's provisional p95 below 500 ms for common non-search API requests under an agreed workload. A successful local request or an untested VPS size does not establish production capacity. One VPS remains a single point of failure.

## 9. Decisions and delivery expectations

Before dependent implementation, resolve: initial target segment, shared/co-tenant/bedspace model, proration and due-date rules, deposit/credit allocation and refund policy, identity channel, manual-payment confirmation authority, and data retention. Set owners and deadlines in the rules register. Approve UX and the proposed Flutter portal choice through Phase 0 review.

The next implementation package is repository setup, local services, API/worker/Flutter skeletons, initial contracts, ERD, and rules register, followed by the first end-to-end landlord workflow. Track work as Foundation A/B, Operations A/B/C, and Hardening, as proposed in the PRD. These are dependency-ordered packages, not fixed-duration sprints.

Estimate dates after business rules, wireframes, staffing, provider access, and environment readiness are known. Production readiness requires the PRD's security, data-integrity, backups, operations, UX, privacy, and product gates; code completion alone does not close those gates.

## 10. Technical references checked

- [Flutter web FAQ](https://docs.flutter.dev/platform-integration/web/faq): suitability for authenticated app experiences and limitations for indexable document-style public content.
- [Flutter iOS setup](https://docs.flutter.dev/platform-integration/ios/setup): Xcode/macOS tooling and device setup.
- [Prisma schema reference](https://docs.prisma.io/docs/orm/reference/prisma-schema-reference): explicit native numeric precision.
- [Prisma custom migrations](https://www.prisma.io/docs/orm/prisma-migrate/workflows/unsupported-database-features): reviewed SQL for database features outside the schema model.
- [PostgreSQL range constraints](https://www.postgresql.org/docs/current/rangetypes.html#RANGETYPES-CONSTRAINT): exclusion constraints for overlap prevention.

These references support the proposed technical approach; Kwadra business scope and acceptance criteria come from the two supplied documents.


