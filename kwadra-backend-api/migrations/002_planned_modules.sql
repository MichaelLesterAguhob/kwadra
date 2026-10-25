-- Full-scope foundations ONLY. No public routes, jobs, or payment operations
-- target these tables. Their presence is not implementation of later phases.
CREATE TABLE invitations (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES organizations(id), email text NOT NULL,
  role text NOT NULL CHECK (role IN ('admin','staff','viewer','tenant')), token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL, accepted_at timestamptz, created_by uuid NOT NULL REFERENCES users(id)
);
CREATE TABLE identity_tokens (
  token_hash text PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id),
  purpose text NOT NULL CHECK (purpose IN ('verify_email','recover_password')),
  expires_at timestamptz NOT NULL, consumed_at timestamptz
);
CREATE TABLE attachments (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES organizations(id),
  uploaded_by uuid NOT NULL REFERENCES users(id), storage_key text NOT NULL UNIQUE,
  filename text NOT NULL, media_type text NOT NULL, byte_size bigint NOT NULL CHECK (byte_size>0),
  created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (organization_id,id)
);
CREATE TABLE lease_documents (
  organization_id uuid NOT NULL, lease_id uuid NOT NULL, attachment_id uuid NOT NULL,
  PRIMARY KEY (organization_id,lease_id,attachment_id),
  FOREIGN KEY (organization_id,lease_id) REFERENCES leases(organization_id,id),
  FOREIGN KEY (organization_id,attachment_id) REFERENCES attachments(organization_id,id)
);
CREATE TABLE ticket_attachments (
  organization_id uuid NOT NULL, ticket_id uuid NOT NULL, attachment_id uuid NOT NULL,
  PRIMARY KEY (organization_id,ticket_id,attachment_id),
  FOREIGN KEY (organization_id,ticket_id) REFERENCES maintenance_tickets(organization_id,id),
  FOREIGN KEY (organization_id,attachment_id) REFERENCES attachments(organization_id,id)
);
CREATE TABLE utility_meters (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, unit_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('water','electricity','other')), label text NOT NULL,
  UNIQUE (organization_id,id), FOREIGN KEY (organization_id,unit_id) REFERENCES units(organization_id,id)
);
CREATE TABLE utility_readings (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, meter_id uuid NOT NULL,
  read_on date NOT NULL, value numeric(16,4) NOT NULL CHECK (value>=0),
  UNIQUE (organization_id,meter_id,read_on),
  FOREIGN KEY (organization_id,meter_id) REFERENCES utility_meters(organization_id,id)
);
CREATE TABLE announcements (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, property_id uuid NOT NULL,
  title text NOT NULL, body text NOT NULL, published_at timestamptz,
  FOREIGN KEY (organization_id,property_id) REFERENCES properties(organization_id,id)
);
CREATE TABLE notifications (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES organizations(id),
  recipient_id uuid NOT NULL REFERENCES users(id), title text NOT NULL, body text NOT NULL,
  read_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE move_outs (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, lease_id uuid NOT NULL,
  requested_on date NOT NULL, scheduled_on date, completed_on date, notes text NOT NULL DEFAULT '',
  status text NOT NULL CHECK (status IN ('requested','scheduled','completed','cancelled')),
  UNIQUE (organization_id,lease_id), FOREIGN KEY (organization_id,lease_id) REFERENCES leases(organization_id,id)
);
CREATE TABLE amenities (id uuid PRIMARY KEY, name text NOT NULL UNIQUE);
CREATE TABLE listings (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, unit_id uuid NOT NULL,
  title text NOT NULL, description text NOT NULL, latitude numeric(9,6), longitude numeric(9,6),
  advertised_rent numeric(14,2) NOT NULL CHECK (advertised_rent>0),
  status text NOT NULL CHECK (status IN ('draft','pending','approved','rejected','unpublished')),
  published_at timestamptz, UNIQUE (organization_id,id),
  FOREIGN KEY (organization_id,unit_id) REFERENCES units(organization_id,id)
);
CREATE TABLE listing_amenities (
  organization_id uuid NOT NULL, listing_id uuid NOT NULL, amenity_id uuid NOT NULL REFERENCES amenities(id),
  PRIMARY KEY (organization_id,listing_id,amenity_id),
  FOREIGN KEY (organization_id,listing_id) REFERENCES listings(organization_id,id)
);
CREATE TABLE listing_photos (
  organization_id uuid NOT NULL, listing_id uuid NOT NULL, attachment_id uuid NOT NULL, position smallint NOT NULL,
  PRIMARY KEY (organization_id,listing_id,attachment_id),
  FOREIGN KEY (organization_id,listing_id) REFERENCES listings(organization_id,id),
  FOREIGN KEY (organization_id,attachment_id) REFERENCES attachments(organization_id,id)
);
CREATE TABLE inquiries (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, listing_id uuid NOT NULL,
  seeker_id uuid REFERENCES users(id), name text NOT NULL, email text NOT NULL, message text NOT NULL,
  status text NOT NULL CHECK (status IN ('new','contacted','closed')), created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id,id), FOREIGN KEY (organization_id,listing_id) REFERENCES listings(organization_id,id)
);
CREATE TABLE viewings (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, inquiry_id uuid NOT NULL, scheduled_at timestamptz NOT NULL,
  status text NOT NULL CHECK (status IN ('requested','confirmed','completed','cancelled')),
  FOREIGN KEY (organization_id,inquiry_id) REFERENCES inquiries(organization_id,id)
);
CREATE TABLE moderation_cases (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, listing_id uuid NOT NULL, reason text NOT NULL,
  status text NOT NULL CHECK (status IN ('open','reviewing','resolved','appealed')),
  created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (organization_id,id),
  FOREIGN KEY (organization_id,listing_id) REFERENCES listings(organization_id,id)
);
CREATE TABLE moderation_events (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, case_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES users(id), detail text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (organization_id,case_id) REFERENCES moderation_cases(organization_id,id)
);
CREATE TABLE publisher_verifications (
  organization_id uuid PRIMARY KEY REFERENCES organizations(id), status text NOT NULL CHECK (status IN ('pending','verified','rejected')),
  reviewed_by uuid REFERENCES users(id), reviewed_at timestamptz, notes text NOT NULL DEFAULT ''
);

-- Reserved financial structures. Deliberately empty: no API, service, webhook,
-- payment provider, seed payment, balance calculation or transaction workflow.
CREATE TABLE payments (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, tenant_id uuid NOT NULL,
  amount numeric(14,2) NOT NULL CHECK (amount>0), method text NOT NULL,
  status text NOT NULL CHECK (status IN ('pending','confirmed','reversed')),
  external_reference text, received_at timestamptz NOT NULL, UNIQUE (organization_id,id),
  FOREIGN KEY (organization_id,tenant_id) REFERENCES tenants(organization_id,id)
);
CREATE TABLE payment_allocations (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, payment_id uuid NOT NULL, invoice_id uuid NOT NULL,
  amount numeric(14,2) NOT NULL CHECK (amount>0),
  UNIQUE (organization_id,payment_id,invoice_id),
  FOREIGN KEY (organization_id,payment_id) REFERENCES payments(organization_id,id),
  FOREIGN KEY (organization_id,invoice_id) REFERENCES invoices(organization_id,id)
);
CREATE TABLE payment_proofs (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, tenant_id uuid NOT NULL, attachment_id uuid NOT NULL,
  status text NOT NULL CHECK (status IN ('pending','approved','rejected')), payment_id uuid,
  FOREIGN KEY (organization_id,tenant_id) REFERENCES tenants(organization_id,id),
  FOREIGN KEY (organization_id,attachment_id) REFERENCES attachments(organization_id,id),
  FOREIGN KEY (organization_id,payment_id) REFERENCES payments(organization_id,id)
);
CREATE TABLE payment_reversals (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, payment_id uuid NOT NULL, reason text NOT NULL,
  actor_id uuid NOT NULL REFERENCES users(id), created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id,payment_id), FOREIGN KEY (organization_id,payment_id) REFERENCES payments(organization_id,id)
);
CREATE TABLE receipts (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, payment_id uuid NOT NULL, number text NOT NULL,
  issued_at timestamptz NOT NULL DEFAULT now(), UNIQUE (organization_id,number), UNIQUE (organization_id,payment_id),
  FOREIGN KEY (organization_id,payment_id) REFERENCES payments(organization_id,id)
);
CREATE TABLE invoice_adjustments (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, invoice_id uuid NOT NULL,
  amount numeric(14,2) NOT NULL CHECK (amount<>0), reason text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), FOREIGN KEY (organization_id,invoice_id) REFERENCES invoices(organization_id,id)
);
CREATE TABLE deposit_transactions (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, lease_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('received','refunded','deducted')), amount numeric(14,2) NOT NULL CHECK (amount>0),
  reason text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (organization_id,lease_id) REFERENCES leases(organization_id,id)
);
CREATE TABLE provider_events (
  provider text NOT NULL, event_id text NOT NULL, payload jsonb NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(), processed_at timestamptz, PRIMARY KEY (provider,event_id)
);
CREATE TABLE subscription_plans (
  id uuid PRIMARY KEY, name text NOT NULL, price numeric(14,2) NOT NULL CHECK (price>=0), entitlements jsonb NOT NULL
);
CREATE TABLE subscriptions (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES organizations(id), plan_id uuid NOT NULL REFERENCES subscription_plans(id),
  status text NOT NULL CHECK (status IN ('trial','active','grace','cancelled')), starts_at timestamptz NOT NULL, ends_at timestamptz
);
CREATE TABLE outbox_events (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES organizations(id), kind text NOT NULL,
  payload jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), dispatched_at timestamptz, attempts integer NOT NULL DEFAULT 0
);
CREATE INDEX outbox_pending ON outbox_events(created_at) WHERE dispatched_at IS NULL;
CREATE TABLE automation_rules (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES organizations(id), kind text NOT NULL,
  enabled boolean NOT NULL DEFAULT false, configuration jsonb NOT NULL
);
