const uuid = { type: "string", format: "uuid" };
const cents = {
  type: "integer",
  minimum: 1,
  maximum: 99999999999999,
  description: "Integer centavos. PHP 1,250.50 is 125050.",
};
const str = { type: "string" };
const revision = { type: "integer", minimum: 0, default: 0 };
const object = (
  properties: Record<string, unknown>,
  required = Object.keys(properties),
) => ({ type: "object", additionalProperties: false, properties, required });
const schemas: Record<string, any> = {
  Login: object(
    {
      email: { type: "string", format: "email" },
      password: { type: "string", format: "password" },
      client: { type: "string", enum: ["web", "native"], default: "web" },
      mfaCode: { type: "string", pattern: "^[0-9]{6}$" },
    },
    ["email", "password"],
  ),
  Register: object({
    name: str,
    email: { type: "string", format: "email" },
    password: { type: "string", minLength: 12 },
    organization: str,
  }),
  Property: object({
    id: uuid,
    name: str,
    address: str,
    type: str,
    image: { type: "string", enum: ["residence", "apartment", "studio"] },
    notes: str,
    archived: { type: "boolean" },
    revision,
    details: object(
      {
        contact: str,
        houseRules: str,
        amenities: { type: "array", items: str },
      },
      [],
    ),
  }),
  Unit: object({
    id: uuid,
    propertyId: uuid,
    code: str,
    type: str,
    rent: cents,
    capacity: { type: "integer", minimum: 1, maximum: 20 },
    floor: str,
    maintenance: { type: "boolean" },
    notes: str,
    revision,
  }),
  Tenant: object({
    id: uuid,
    name: str,
    email: str,
    phone: str,
    emergency: str,
    archived: { type: "boolean" },
    revision,
  }),
  Lease: object(
    {
      id: uuid,
      unitId: uuid,
      tenantIds: { type: "array", items: uuid, minItems: 1 },
      start: { type: "string", format: "date" },
      end: { type: "string", format: "date" },
      rent: cents,
      deposit: { ...cents, minimum: 0 },
      dueDay: { type: "integer", minimum: 1, maximum: 31 },
      status: { type: "string", enum: ["draft", "active"], default: "active" },
    },
    ["id", "unitId", "tenantIds", "start", "end", "rent", "deposit", "dueDay"],
  ),
  Ticket: object({
    id: uuid,
    unitId: uuid,
    title: str,
    description: str,
    category: {
      type: "string",
      enum: [
        "General",
        "Plumbing",
        "Electrical",
        "Appliance",
        "Structural",
        "Other",
      ],
    },
    priority: { type: "string", enum: ["Low", "Normal", "Urgent"] },
    status: { type: "string", enum: ["Open", "In progress", "Resolved"] },
    revision,
  }),
  EndLease: object({ revision: { type: "integer", minimum: 1 } }),
  Period: object({
    period: {
      type: "string",
      pattern: "^\\d{4}-(0[1-9]|1[0-2])$",
      example: "2026-10",
    },
  }),
  Profile: object({
    name: str,
    email: { type: "string", format: "email" },
    organization: str,
    revision: { type: "integer", minimum: 1 },
  }),
};
const paths: Record<string, unknown> = {};
function endpoint(
  path: string,
  method: string,
  summary: string,
  schema?: string,
  publicRoute = false,
  resourceId = false,
) {
  const mutation = ["post", "put"].includes(method) && !publicRoute;
  const parameters: unknown[] = [];
  if (!publicRoute)
    parameters.push({
      name: "X-Organization-Id",
      in: "header",
      required: true,
      schema: uuid,
    });
  if (mutation)
    parameters.push({
      name: "Idempotency-Key",
      in: "header",
      required: true,
      schema: { type: "string", minLength: 8 },
      description:
        "A new UUID per operation; reuse it unchanged when retrying.",
    });
  if (resourceId)
    parameters.push({ name: "id", in: "path", required: true, schema: uuid });
  const operation = {
    summary,
    tags: [path.split("/")[1]],
    parameters,
    security: publicRoute ? [] : [{ bearerAuth: [] }, { cookieAuth: [] }],
    ...(schema
      ? {
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: { $ref: `#/components/schemas/${schema}` },
              },
            },
          },
        }
      : {}),
    responses: {
      "200": {
        description:
          "Success. Mutations return { data, revision }; reads return JSON.",
      },
      "401": { description: "Sign in required" },
      "403": { description: "Insufficient permission or invalid CSRF token" },
      "409": {
        description: "Conflict, stale revision, overlap or retry key mismatch",
      },
      "422": { description: "Invalid request" },
    },
  };
  paths[path] = { ...((paths[path] as object) ?? {}), [method]: operation };
}
endpoint(
  "/auth/login",
  "post",
  "Sign in. In this page, organization and CSRF headers are filled automatically after login.",
  "Login",
  true,
);
endpoint(
  "/auth/register",
  "post",
  "Create an owner account and an empty organization (development).",
  "Register",
  true,
);
endpoint("/auth/me", "get", "Current account and memberships");
endpoint("/auth/logout", "post", "Revoke the current session");
endpoint(
  "/workspace",
  "get",
  "Authorized workspace snapshot with row revisions and permissions",
);
for (const [resource, schema] of [
  ["properties", "Property"],
  ["units", "Unit"],
  ["tenants", "Tenant"],
  ["tickets", "Ticket"],
]) {
  endpoint(
    `/${resource}`,
    "get",
    `List ${resource} with page, pageSize, q and optional propertyId/unitId/status filters`,
  );
  endpoint(`/${resource}`, "post", `Create ${resource}`, schema);
  endpoint(
    `/${resource}/{id}`,
    "get",
    `Read one ${resource} record`,
    undefined,
    false,
    true,
  );
  endpoint(
    `/${resource}/{id}`,
    "put",
    `Update ${resource}; include the revision returned by GET`,
    schema,
    false,
    true,
  );
}
endpoint("/leases", "get", "List leases");
endpoint(
  "/leases",
  "post",
  "Create a lease with exclusive occupancy and co-tenants",
  "Lease",
);
endpoint("/leases/{id}", "get", "Read one lease", undefined, false, true);
endpoint(
  "/leases/{id}/end",
  "post",
  "End or cancel a lease; invoices remain unchanged",
  "EndLease",
  false,
  true,
);
endpoint("/invoices", "get", "List monthly rent charges");
endpoint("/invoices/{id}", "get", "Read one invoice", undefined, false, true);
endpoint(
  "/invoices/generate",
  "post",
  "Generate full-month rent charges once per lease/month; no payments or proration",
  "Period",
);
endpoint("/activity", "get", "Read authorized audit history");
endpoint(
  "/profile",
  "put",
  "Update profile name and organization; login email is immutable",
  "Profile",
);

const ref = (name: string) => ({ $ref: `#/components/schemas/${name}` });
const bool = { type: "boolean" };
const date = { type: "string", format: "date" };
const rev = { type: "integer", minimum: 1 };
const list = (items: unknown) => ({ type: "array", items });
const enumeration = (...values: string[]) => ({ type: "string", enum: values });
Object.assign(schemas, {
  Token: object({ token: { type: "string", minLength: 64, maxLength: 64 } }),
  Recover: object({ email: { type: "string", format: "email" } }),
  Reset: object({
    token: str,
    password: { type: "string", minLength: 12, maxLength: 256 },
  }),
  AcceptInvitation: object({
    token: str,
    email: { type: "string", format: "email" },
    name: str,
    password: { type: "string", minLength: 12 },
  }),
  Invitation: object(
    {
      email: { type: "string", format: "email" },
      role: enumeration("admin", "staff", "viewer", "tenant"),
      propertyIds: list(uuid),
      tenantId: uuid,
    },
    ["email", "role"],
  ),
  Member: object({
    role: enumeration("admin", "staff", "viewer", "tenant"),
    active: bool,
    allProperties: bool,
    propertyIds: list(uuid),
  }),
  File: object({
    filename: str,
    mediaType: enumeration("image/jpeg", "image/png", "application/pdf"),
    base64: {
      type: "string",
      description:
        "Base64 file bytes, at most 2 MiB before encoding. Images are sanitized. Repair/listing uploads accept images only.",
    },
  }),
  TenantTicket: object({
    leaseId: uuid,
    title: str,
    description: str,
    category: schemas.Ticket.properties.category,
    priority: schemas.Ticket.properties.priority,
  }),
  Comment: object({ body: { type: "string", minLength: 1, maxLength: 3000 } }),
  Assignment: object(
    { revision: rev, assignedTo: { ...uuid, nullable: true }, close: bool },
    ["revision", "assignedTo"],
  ),
  MoveOut: object({ leaseId: uuid, requestedOn: date, notes: str }, [
    "leaseId",
    "requestedOn",
  ]),
  MoveOutUpdate: object(
    {
      revision: rev,
      status: enumeration("scheduled", "completed", "cancelled"),
      scheduledOn: date,
      notes: str,
      checklist: object({
        keysReturned: bool,
        inspectionComplete: bool,
        recordsReviewed: bool,
      }),
    },
    ["revision", "status", "checklist"],
  ),
  Preferences: object({ inApp: bool, email: bool }),
  Announcement: object({ propertyId: uuid, title: str, body: str }),
  Meter: object({
    unitId: uuid,
    kind: enumeration("water", "electricity", "other"),
    label: str,
    rateCentavos: { type: "integer", minimum: 1, maximum: 1000000 },
  }),
  Reading: object({
    meterId: uuid,
    readOn: date,
    value: {
      type: "string",
      pattern: "^[0-9]+(\\.[0-9]{1,4})?$",
      example: "125.1234",
    },
  }),
  ReadingCorrection: object({
    revision: rev,
    value: { type: "string" },
    reason: { type: "string", minLength: 10 },
  }),
  IssueReading: object({ revision: rev, amount: cents }),
  SharedPreview: object({
    propertyId: uuid,
    period: schemas.Period.properties.period,
    amount: cents,
    description: str,
  }),
  SharedIssue: object({
    propertyId: uuid,
    period: schemas.Period.properties.period,
    amount: cents,
    description: str,
    expectedAllocations: list(
      object({
        leaseId: uuid,
        unit: str,
        amount: { type: "integer", minimum: 0 },
      }),
    ),
  }),
  Listing: object({
    id: uuid,
    unitId: uuid,
    revision,
    title: str,
    description: str,
    locationLabel: str,
    locationPrecision: enumeration("area", "approximate", "exact"),
    latitude: { type: "number", nullable: true, minimum: -90, maximum: 90 },
    longitude: { type: "number", nullable: true, minimum: -180, maximum: 180 },
    rent: cents,
    moveInCost: { ...cents, minimum: 0 },
    houseRules: str,
    contactPolicy: enumeration("inquiry_only", "show_contact"),
    publicPhone: str,
    publicEmail: str,
    amenityIds: list(uuid),
  }),
  ListingAction: object({
    revision: rev,
    action: enumeration("submit", "unpublish"),
  }),
  PublisherEvidence: object({
    file: ref("File"),
    notes: { type: "string", minLength: 10 },
  }),
  Appeal: object({ reason: { type: "string", minLength: 10 } }),
  Inquiry: object(
    {
      name: str,
      email: { type: "string", format: "email" },
      phone: str,
      message: { type: "string", minLength: 10, maxLength: 3000 },
      viewingAt: { type: "string", format: "date-time" },
      website: { type: "string", maxLength: 0 },
    },
    ["name", "email", "message"],
  ),
  Reply: object({ revision: rev, message: str, close: bool }, [
    "revision",
    "message",
  ]),
  TrackedMessage: object({ message: str }),
  TrackedViewing: object(
    {
      id: uuid,
      revision: rev,
      action: enumeration("request", "confirm", "cancel"),
      scheduledAt: { type: "string", format: "date-time" },
    },
    ["action"],
  ),
  Viewing: object(
    {
      revision: rev,
      status: enumeration(
        "proposed",
        "confirmed",
        "declined",
        "completed",
        "cancelled",
      ),
      scheduledAt: { type: "string", format: "date-time" },
    },
    ["revision", "status"],
  ),
  Report: object(
    {
      reason: { type: "string", minLength: 10 },
      email: { type: "string" },
      website: { type: "string", maxLength: 0 },
    },
    ["reason"],
  ),
  PublisherReview: object(
    {
      revision: rev,
      status: enumeration("verified", "rejected"),
      reason: { type: "string", minLength: 10 },
      evidenceReviewed: bool,
    },
    ["revision", "status", "reason"],
  ),
  ListingReview: object({
    revision: rev,
    status: enumeration("approved", "rejected", "unpublished"),
    reason: { type: "string", minLength: 10 },
  }),
  Suspension: object({
    userId: uuid,
    disabled: bool,
    reason: { type: "string", minLength: 10 },
  }),
});
for (const [path, method, summary, schema, isPublic] of [
  [
    "/identity/verify",
    "post",
    "Verify email using a one-time code",
    "Token",
    true,
  ],
  [
    "/identity/recover",
    "post",
    "Request password recovery; generic response",
    "Recover",
    true,
  ],
  [
    "/identity/reset",
    "post",
    "Reset password and revoke every session",
    "Reset",
    true,
  ],
  [
    "/identity/accept-invitation",
    "post",
    "Accept email-bound invitation; existing users enter their current password",
    "AcceptInvitation",
    true,
  ],
  ["/operations", "get", "Authorized nonfinancial operations snapshot"],
  [
    "/tenant/portal",
    "get",
    "Linked tenant tenancy, charges, repairs, history, documents and announcements",
  ],
  [
    "/tenant/tickets",
    "post",
    "Submit a repair for your current active tenancy",
    "TenantTicket",
  ],
  [
    "/tickets/{id}/comments",
    "post",
    "Append an authorized repair comment",
    "Comment",
  ],
  [
    "/tickets/{id}/assignment",
    "put",
    "Assign or close a resolved repair",
    "Assignment",
  ],
  ["/tickets/{id}/files", "post", "Attach a repair photo", "File"],
  ["/leases/{id}/files", "post", "Share a private lease document", "File"],
  ["/files/{id}", "get", "Authorized private attachment as base64 JSON"],
  [
    "/leases/{id}/activate",
    "post",
    "Activate a draft after occupancy checks",
    "EndLease",
  ],
  [
    "/leases/{id}/renew",
    "post",
    "Create linked next-term lease; never rewrite prior charges",
    "Lease",
  ],
  ["/move-outs", "post", "Request nonfinancial handover", "MoveOut"],
  [
    "/move-outs/{id}",
    "put",
    "Schedule, complete checklist, or cancel handover",
    "MoveOutUpdate",
  ],
  ["/team", "get", "Members and pending invitations"],
  [
    "/team/invitations",
    "post",
    "Invite staff or link a tenant profile",
    "Invitation",
  ],
  [
    "/team/members/{id}",
    "put",
    "Edit role, grants or revoke membership; owner protected",
    "Member",
  ],
  ["/notifications", "get", "Own notifications and preferences"],
  [
    "/notifications/preferences",
    "put",
    "Set optional in-app and email preferences",
    "Preferences",
  ],
  ["/notifications/{id}/read", "post", "Mark your own notification read"],
  [
    "/announcements",
    "post",
    "Announce to this property's current linked tenants",
    "Announcement",
  ],
  ["/deliveries", "get", "Privileged email delivery status"],
  ["/deliveries/{id}/retry", "post", "Retry failed email delivery"],
  [
    "/utilities/meters",
    "post",
    "Create a unit meter and fixed centavo tariff",
    "Meter",
  ],
  [
    "/utilities/readings",
    "post",
    "Save ordered reading, first reading is baseline",
    "Reading",
  ],
  [
    "/utilities/readings/{id}",
    "put",
    "Correct an unissued reading with a reason",
    "ReadingCorrection",
  ],
  ["/utilities/readings/{id}/preview", "get", "Preview exact usage and charge"],
  [
    "/utilities/readings/{id}/issue",
    "post",
    "Confirm preview and issue immutable charge",
    "IssueReading",
  ],
  [
    "/utilities/shared/preview",
    "post",
    "Preview equal split across occupied units",
    "SharedPreview",
  ],
  [
    "/utilities/shared/issue",
    "post",
    "Confirm allocation snapshot and issue once per reference",
    "SharedIssue",
  ],
  ["/listings", "post", "Draft a listing", "Listing"],
  [
    "/listings/{id}",
    "put",
    "Edit a listing; automatically unpublish and require new review",
    "Listing",
  ],
  [
    "/listings/{id}/photos",
    "post",
    "Add a sanitized listing image; require new review",
    "File",
  ],
  [
    "/listings/{id}/action",
    "post",
    "Submit for review or unpublish",
    "ListingAction",
  ],
  [
    "/publisher-verification",
    "post",
    "Submit private publisher evidence",
    "PublisherEvidence",
  ],
  [
    "/moderation/cases/{id}/appeal",
    "post",
    "Appeal without republishing",
    "Appeal",
  ],
  [
    "/inquiries/{id}/reply",
    "post",
    "Reply or close a listing inquiry",
    "Reply",
  ],
  [
    "/inquiries/{id}/convert",
    "post",
    "Create a tenant profile from an inquiry; no automatic lease",
    "EndLease",
  ],
  [
    "/viewings/{id}",
    "put",
    "Propose, confirm, decline or complete a viewing",
    "Viewing",
  ],
  [
    "/platform/review",
    "get",
    "MFA-protected review queue and append-only history",
  ],
  ["/platform/listings/{id}/preview", "get", "Private moderation preview"],
  [
    "/platform/files/{id}",
    "get",
    "Review evidence or listing photo; excludes tenant documents",
  ],
  [
    "/platform/publishers/{id}",
    "put",
    "Review publisher evidence",
    "PublisherReview",
  ],
  [
    "/platform/listings/{id}",
    "put",
    "Approve, take down or restore listing",
    "ListingReview",
  ],
  [
    "/platform/accounts",
    "post",
    "Suspend or restore a publisher and revoke sessions",
    "Suspension",
  ],
  ["/public/amenities", "get", "Public amenity choices", undefined, true],
  [
    "/public/listings",
    "get",
    "Search approved available listings only",
    undefined,
    true,
  ],
  [
    "/public/listings/{id}",
    "get",
    "Public listing; unavailable is 404",
    undefined,
    true,
  ],
  [
    "/public/photos/{id}",
    "get",
    "Public image only while its listing is eligible",
    undefined,
    true,
  ],
  [
    "/public/listings/{id}/inquiries",
    "post",
    "Send inquiry; response contains one-time tracking secret",
    "Inquiry",
    true,
  ],
  [
    "/public/listings/{id}/report",
    "post",
    "Report an active listing",
    "Report",
    true,
  ],
  [
    "/public/inquiries/{id}",
    "get",
    "Track inquiry using X-Inquiry-Token",
    undefined,
    true,
  ],
  [
    "/public/inquiries/{id}/messages",
    "post",
    "Reply using X-Inquiry-Token",
    "TrackedMessage",
    true,
  ],
  [
    "/public/inquiries/{id}/viewings",
    "post",
    "Request, confirm or cancel with X-Inquiry-Token",
    "TrackedViewing",
    true,
  ],
] as const)
  endpoint(path, method, summary, schema, !!isPublic, path.includes("{id}"));
for (const [path, methods] of Object.entries(paths)) {
  for (const [method, op] of Object.entries(methods as Record<string, any>)) {
    if (path.startsWith("/public/inquiries/"))
      op.parameters.push({
        name: "X-Inquiry-Token",
        in: "header",
        required: true,
        schema: { type: "string", minLength: 64, maxLength: 64 },
        description:
          "Secret returned when the inquiry was submitted, expires after 30 days. Never put it in a query string.",
      });
    if (path === "/auth/me" || path === "/auth/logout")
      op.parameters = op.parameters.filter(
        (p: any) => !["Idempotency-Key", "X-Organization-Id"].includes(p.name),
      );
    if (
      method === "get" &&
      [
        "/public/listings",
        "/properties",
        "/units",
        "/tenants",
        "/tickets",
        "/leases",
        "/invoices",
      ].includes(path)
    )
      op.parameters.push(
        ...["q", "page", "pageSize"].map((name) => ({
          name,
          in: "query",
          schema: name === "q" ? str : { type: "integer", minimum: 1 },
        })),
      );
  }
}
for (const name of [
  "minRent",
  "maxRent",
  "maxMoveInCost",
  "capacity",
  "type",
  "amenity",
  "sort",
])
  (paths["/public/listings"] as any).get.parameters.push({
    name,
    in: "query",
    schema: ["type", "amenity", "sort"].includes(name)
      ? str
      : { type: "integer", minimum: 0 },
  });

Object.assign(schemas, {
  RenterRegistration: object({
    name: str,
    email: { type: "string", format: "email" },
    password: { type: "string", minLength: 12, maxLength: 256 },
  }),
  SavedRental: object({ saved: bool }),
  AccountInquiry: object(
    {
      message: { type: "string", minLength: 10, maxLength: 3000 },
      phone: str,
      viewingAt: { type: "string", format: "date-time" },
    },
    ["message"],
  ),
  LandlordWorkspace: object({
    name: { type: "string", minLength: 1, maxLength: 160 },
  }),
});
endpoint(
  "/auth/register-seeker",
  "post",
  "Register a renter; email verification required, no landlord organization is created",
  "RenterRegistration",
  true,
);
for (const [path, method, summary, schema] of [
  [
    "/marketplace/saved",
    "get",
    "Own saved rentals, revalidated for public availability",
  ],
  [
    "/marketplace/saved/{id}",
    "put",
    "Save or remove a rental for your own account",
    "SavedRental",
  ],
  [
    "/marketplace/inquiries",
    "get",
    "Your account conversations; no organization grants required",
  ],
  [
    "/marketplace/listings/{id}/inquiries",
    "post",
    "Send an inquiry using your verified name/email; replay-safe",
    "AccountInquiry",
  ],
  [
    "/marketplace/inquiries/{id}",
    "get",
    "Read your own conversation; another account receives 404",
  ],
  [
    "/marketplace/inquiries/{id}/messages",
    "post",
    "Reply to your landlord",
    "TrackedMessage",
  ],
  [
    "/marketplace/inquiries/{id}/viewings",
    "post",
    "Request, confirm or cancel your viewing",
    "TrackedViewing",
  ],
  [
    "/marketplace/listings/{id}/report",
    "post",
    "Report a rental using your account identity",
    "Appeal",
  ],
  [
    "/marketplace/organization",
    "post",
    "Create your own landlord workspace while retaining your renter account",
    "LandlordWorkspace",
  ],
] as const) {
  endpoint(path, method, summary, schema, false, path.includes("{id}"));
  (paths[path] as any)[method].parameters = (paths[path] as any)[
    method
  ].parameters.filter((p: any) => p.name !== "X-Organization-Id");
}

Object.assign(schemas, {
  Refresh: object({
    refreshToken: { type: "string", pattern: "^[a-f0-9]{64}$" },
  }),
  GoogleLogin: object(
    {
      idToken: str,
      client: { type: "string", enum: ["native", "web"] },
      mfaCode: { type: "string", pattern: "^[0-9]{6}$" },
    },
    ["idToken"],
  ),
  GoogleLink: object({
    idToken: str,
    password: { type: "string", format: "password" },
  }),
  NotificationRead: object({
    ids: { type: "array", minItems: 1, maxItems: 100, items: uuid },
  }),
  AccountPreferences: object({ inApp: bool }),
});
endpoint(
  "/identity/resend-verification",
  "post",
  "Request a new verification code; generic response and one-minute account cooldown",
  "Recover",
  true,
);
endpoint(
  "/auth/providers",
  "get",
  "Public sign-in and messaging configuration",
  undefined,
  true,
);
endpoint(
  "/auth/google",
  "post",
  "Verify Google identity and issue a Kwadra session; admin MFA remains required",
  "GoogleLogin",
  true,
);
endpoint(
  "/auth/refresh",
  "post",
  "Rotate a native refresh credential; reuse revokes the family",
  "Refresh",
  true,
);
for (const [path, method, summary, schema] of [
  [
    "/auth/google/link",
    "post",
    "Link Google using the signed-in account and current password",
    "GoogleLink",
  ],
  [
    "/account/notifications",
    "get",
    "Own notifications; inaccessible organization notices are excluded",
    undefined,
  ],
  [
    "/account/notifications/events",
    "get",
    "Foreground SSE invalidations; no private notification content",
    undefined,
  ],
  [
    "/account/notifications/read",
    "post",
    "Mark only your own visible notices as read",
    "NotificationRead",
  ],
  [
    "/account/notification-preferences",
    "put",
    "Set in-app notification preference",
    "AccountPreferences",
  ],
] as const) {
  endpoint(path, method, summary, schema);
  (paths[path] as any)[method].parameters = (paths[path] as any)[
    method
  ].parameters.filter(
    (p: any) => !["X-Organization-Id", "Idempotency-Key"].includes(p.name),
  );
}

export const openapi = {
  openapi: "3.0.3",
  info: {
    title: "Kwadra development API",
    version: "0.6.0",
    description:
      "Landlord operations, linked tenant portal and moderated public marketplace. Sign in first for private routes and use an organization UUID from login. Browser mutations require X-CSRF-Token (automatically set here); native clients use Bearer tokens. Every private business mutation requires a fresh Idempotency-Key; reuse unchanged for retries. Money is integer centavos; calendar dates use Asia/Manila. Tenant routes expose only linked tenancy records. Platform review requires an MFA-verified platform administrator session. Local verification/invitation/recovery email is written to the private development inbox; SMTP is configurable. No payment, proof, allocation, receipt, refund, deposit transaction or subscription operations exist.",
  },
  servers: [{ url: "/api/v1" }],
  paths,
  components: {
    schemas,
    securitySchemes: {
      bearerAuth: { type: "http", scheme: "bearer" },
      cookieAuth: { type: "apiKey", in: "cookie", name: "kwadra_session" },
    },
  },
};
