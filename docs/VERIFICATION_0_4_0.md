# Local verification: 0.4.0+5

18 October 2026, Windows. Flutter 3.47.7 / Dart 3.13.5, Node 22.22.0, isolated PostgreSQL 18.4.

| Check | Result |
| --- | --- |
| Backend TypeScript | `npm run check` passes |
| PostgreSQL integration | 39 tests pass against a disposable test cluster |
| Retained-data upgrade | 001/002 → 003 preserves edited property/revision, prior invoice amounts, ended-lease occupancy and participants; repeat migration is safe |
| Development upgrade | Migration 003 applied without resetting the saved development portfolio |
| Flutter formatting/analysis | Clean |
| Flutter tests | 35 pass, including tenant API submission and moderation retry/revision behavior; tenant layouts at 320 and 1440px |
| Web release | Built with bundled web resources; version 0.4.0, build 5 |
| Android debug | Built; package `ph.kwadra.kwadra_management`, version 0.4.0, versionCode 5, minSdk 24 |
| Landlord Chrome walkthrough | Property → unit → tenant → lease → invoice → repair persisted to PostgreSQL; cookie session restored after reload |
| Phase 2/3 Chrome walkthrough | Public search/metadata, 390px layout, favorites, inquiry/tracking/reply, tenant charges/repair, moderator MFA/review views pass |
| Payment boundary | Browser preview sends zero API requests; payment records remain zero; no payment endpoints/jobs enabled |

Commands and setup are in the [root README](../README.md). Browser scripts are in `kwadra-backend-api/scripts`; screenshots and JSON reports are saved under its ignored `.local/browser-smoke` and `.local/phase-browser-smoke` folders. Synthetic test organizations, inquiries and repairs remain available for inspection. Chrome was headless and local.

Not exercised: a physical Android phone, iOS compilation/runtime, external SMTP, hosted deployment, production load tests or backup/restore drill. [Delivery status and remaining gates](PHASES_1_TO_3.md).
