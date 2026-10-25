-- Extend existing records in place. Payment structures remain unused.
ALTER TABLE users ADD COLUMN email_verified_at timestamptz;
UPDATE users SET email_verified_at=created_at;
ALTER TABLE users ADD COLUMN platform_admin boolean NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN mfa_secret text;
ALTER TABLE sessions ADD COLUMN mfa_verified boolean NOT NULL DEFAULT false;
ALTER TABLE sessions ADD COLUMN mfa_counter bigint;
ALTER TABLE users ADD COLUMN last_mfa_counter bigint;
ALTER TABLE memberships DROP CONSTRAINT memberships_role_check;
ALTER TABLE memberships ADD CONSTRAINT memberships_role_check CHECK (role IN ('owner','admin','staff','viewer','tenant'));
ALTER TABLE invitations ADD COLUMN tenant_id uuid;
ALTER TABLE invitations ADD COLUMN property_ids uuid[] NOT NULL DEFAULT '{}';
ALTER TABLE invitations ADD CONSTRAINT invitation_tenant FOREIGN KEY (organization_id,tenant_id) REFERENCES tenants(organization_id,id);
ALTER TABLE properties ADD COLUMN details jsonb NOT NULL DEFAULT '{}';
ALTER TABLE units ADD COLUMN notes text NOT NULL DEFAULT '';

DO $$ DECLARE c record; BEGIN
 FOR c IN SELECT conname FROM pg_constraint WHERE conrelid='leases'::regclass AND contype='c' AND pg_get_constraintdef(oid) LIKE '%status%' LOOP
  EXECUTE format('ALTER TABLE leases DROP CONSTRAINT %I',c.conname);
 END LOOP;
END $$;
ALTER TABLE leases DROP COLUMN occupancy CASCADE;
ALTER TABLE leases ADD CONSTRAINT lease_status CHECK (status IN ('draft','active','ended','cancelled'));
ALTER TABLE leases ADD CONSTRAINT lease_termination CHECK ((status IN ('draft','active') AND terminated_on IS NULL) OR (status IN ('ended','cancelled') AND terminated_on IS NOT NULL));
ALTER TABLE leases ADD CONSTRAINT lease_end_after_start CHECK (status<>'ended' OR terminated_on>=starts_on);
ALTER TABLE leases ADD COLUMN occupancy daterange GENERATED ALWAYS AS (
 CASE WHEN status IN ('cancelled','draft') THEN NULL ELSE daterange(starts_on,
 CASE WHEN status='ended' THEN least(ends_on+1,terminated_on) ELSE ends_on+1 END,'[)') END
) STORED;
ALTER TABLE leases ADD EXCLUDE USING gist (organization_id WITH =,unit_id WITH =,occupancy WITH &&);
ALTER TABLE leases ADD COLUMN renewal_of uuid;
ALTER TABLE leases ADD CONSTRAINT renewal_parent FOREIGN KEY (organization_id,renewal_of) REFERENCES leases(organization_id,id);
CREATE UNIQUE INDEX lease_renewal ON leases(organization_id,renewal_of) WHERE renewal_of IS NOT NULL AND status<>'cancelled';

ALTER TABLE invoices ADD COLUMN kind text NOT NULL DEFAULT 'rent' CHECK (kind IN ('rent','utility'));
ALTER TABLE invoices ADD COLUMN source_key text;
ALTER TABLE invoices DROP CONSTRAINT invoices_organization_id_lease_id_period_key;
CREATE UNIQUE INDEX invoice_rent_period ON invoices(organization_id,lease_id,period) WHERE kind='rent';
CREATE UNIQUE INDEX invoice_source ON invoices(organization_id,source_key) WHERE source_key IS NOT NULL;
ALTER TABLE attachments ADD COLUMN content bytea;
ALTER TABLE attachments ADD COLUMN purpose text CHECK (purpose IN ('lease','maintenance','listing','verification'));
ALTER TABLE attachments ADD CONSTRAINT attachment_limit CHECK (byte_size<=2097152);
ALTER TABLE maintenance_tickets ADD COLUMN acknowledged_at timestamptz;
ALTER TABLE maintenance_tickets ADD COLUMN closed_at timestamptz;
CREATE TABLE maintenance_comments (
 id uuid PRIMARY KEY, organization_id uuid NOT NULL, ticket_id uuid NOT NULL,
 actor_id uuid NOT NULL REFERENCES users(id), body text NOT NULL CHECK (length(body) BETWEEN 1 AND 3000),
 created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY (organization_id,ticket_id) REFERENCES maintenance_tickets(organization_id,id)
);
CREATE TRIGGER immutable_comments BEFORE UPDATE OR DELETE ON maintenance_comments FOR EACH ROW EXECUTE FUNCTION prevent_history_rewrite();
ALTER TABLE utility_meters ADD COLUMN rate_centavos integer NOT NULL DEFAULT 0 CHECK (rate_centavos>=0);
ALTER TABLE utility_meters ADD COLUMN revision integer NOT NULL DEFAULT 1;
ALTER TABLE utility_readings ADD COLUMN revision integer NOT NULL DEFAULT 1;
ALTER TABLE utility_readings ADD COLUMN invoice_id uuid;
ALTER TABLE utility_readings ADD COLUMN correction_reason text NOT NULL DEFAULT '';
ALTER TABLE utility_readings ADD CONSTRAINT reading_id UNIQUE (organization_id,id);
ALTER TABLE utility_readings ADD CONSTRAINT reading_invoice FOREIGN KEY (organization_id,invoice_id) REFERENCES invoices(organization_id,id);
CREATE TABLE shared_utility_batches (
 id uuid PRIMARY KEY, organization_id uuid NOT NULL, property_id uuid NOT NULL,
 period date NOT NULL CHECK (extract(day FROM period)=1), description text NOT NULL,
 amount numeric(14,2) NOT NULL CHECK (amount>0), allocations jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY (organization_id,property_id) REFERENCES properties(organization_id,id)
);
CREATE TRIGGER immutable_shared_utilities BEFORE UPDATE OR DELETE ON shared_utility_batches FOR EACH ROW EXECUTE FUNCTION prevent_history_rewrite();
CREATE UNIQUE INDEX shared_utility_reference ON shared_utility_batches(organization_id,property_id,period,lower(trim(description)));
ALTER TABLE move_outs ADD COLUMN checklist jsonb NOT NULL DEFAULT '{}';
ALTER TABLE move_outs ADD COLUMN revision integer NOT NULL DEFAULT 1;
ALTER TABLE move_outs ADD COLUMN requested_by uuid REFERENCES users(id);
ALTER TABLE notifications ADD COLUMN source_key text;
CREATE UNIQUE INDEX notification_source ON notifications(recipient_id,source_key) WHERE source_key IS NOT NULL;
CREATE TABLE notification_preferences (
 user_id uuid PRIMARY KEY REFERENCES users(id), in_app boolean NOT NULL DEFAULT true, email boolean NOT NULL DEFAULT false
);
CREATE TABLE delivery_logs (
 id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES organizations(id), recipient_id uuid REFERENCES users(id),
 channel text NOT NULL CHECK (channel IN ('in_app','email')), destination text NOT NULL,
 title text NOT NULL, body text NOT NULL, source_key text NOT NULL, status text NOT NULL CHECK (status IN ('pending','delivered','failed')),
 attempts integer NOT NULL DEFAULT 0, last_error text, next_attempt_at timestamptz NOT NULL DEFAULT now(),
 created_at timestamptz NOT NULL DEFAULT now(), delivered_at timestamptz,
 UNIQUE (organization_id,channel,destination,source_key)
);
CREATE INDEX delivery_pending ON delivery_logs(next_attempt_at) WHERE status<>'delivered';
ALTER TABLE outbox_events ADD COLUMN dedupe_key text;
CREATE UNIQUE INDEX outbox_dedupe ON outbox_events(organization_id,dedupe_key) WHERE dedupe_key IS NOT NULL;

ALTER TABLE listings ADD COLUMN location_label text NOT NULL DEFAULT '';
ALTER TABLE listings ADD COLUMN location_precision text NOT NULL DEFAULT 'area' CHECK (location_precision IN ('area','approximate','exact'));
ALTER TABLE listings ADD COLUMN move_in_cost numeric(14,2) NOT NULL DEFAULT 0 CHECK (move_in_cost>=0);
ALTER TABLE listings ADD COLUMN house_rules text NOT NULL DEFAULT '';
ALTER TABLE listings ADD COLUMN contact_policy text NOT NULL DEFAULT 'inquiry_only' CHECK (contact_policy IN ('inquiry_only','show_contact'));
ALTER TABLE listings ADD COLUMN public_phone text NOT NULL DEFAULT '';
ALTER TABLE listings ADD COLUMN public_email text NOT NULL DEFAULT '';
ALTER TABLE listings ADD COLUMN revision integer NOT NULL DEFAULT 1;
ALTER TABLE listings ADD COLUMN created_by uuid REFERENCES users(id);
ALTER TABLE listings ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
CREATE UNIQUE INDEX listing_unit ON listings(organization_id,unit_id);
CREATE INDEX listing_discovery ON listings(status,advertised_rent,published_at);
ALTER TABLE publisher_verifications ADD COLUMN attachment_id uuid;
ALTER TABLE publisher_verifications ADD COLUMN submitted_by uuid REFERENCES users(id);
ALTER TABLE publisher_verifications ADD COLUMN revision integer NOT NULL DEFAULT 1;
ALTER TABLE publisher_verifications ADD CONSTRAINT verification_attachment FOREIGN KEY (organization_id,attachment_id) REFERENCES attachments(organization_id,id);
ALTER TABLE inquiries ADD COLUMN phone text NOT NULL DEFAULT '';
ALTER TABLE inquiries ADD COLUMN tracking_hash text;
ALTER TABLE inquiries ADD COLUMN tracking_expires_at timestamptz;
ALTER TABLE inquiries ADD COLUMN revision integer NOT NULL DEFAULT 1;
ALTER TABLE inquiries ADD COLUMN converted_tenant_id uuid;
ALTER TABLE inquiries ADD CONSTRAINT inquiry_tenant FOREIGN KEY (organization_id,converted_tenant_id) REFERENCES tenants(organization_id,id);
CREATE UNIQUE INDEX inquiry_tracking ON inquiries(tracking_hash) WHERE tracking_hash IS NOT NULL;
CREATE TABLE inquiry_messages (
 id uuid PRIMARY KEY, organization_id uuid NOT NULL, inquiry_id uuid NOT NULL,
 actor_id uuid REFERENCES users(id), sender text NOT NULL CHECK (sender IN ('seeker','landlord')),
 body text NOT NULL CHECK (length(body) BETWEEN 1 AND 3000), created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY (organization_id,inquiry_id) REFERENCES inquiries(organization_id,id)
);
CREATE TRIGGER immutable_inquiry_messages BEFORE UPDATE OR DELETE ON inquiry_messages FOR EACH ROW EXECUTE FUNCTION prevent_history_rewrite();
ALTER TABLE viewings DROP CONSTRAINT viewings_status_check;
ALTER TABLE viewings ADD CONSTRAINT viewing_status CHECK (status IN ('requested','proposed','confirmed','declined','completed','cancelled'));
ALTER TABLE viewings ADD COLUMN revision integer NOT NULL DEFAULT 1;
CREATE UNIQUE INDEX viewing_active ON viewings(organization_id,inquiry_id) WHERE status IN ('requested','proposed','confirmed');
CREATE TABLE listing_reports (
 id uuid PRIMARY KEY, organization_id uuid NOT NULL, listing_id uuid NOT NULL,
 reason text NOT NULL CHECK (length(reason) BETWEEN 10 AND 2000), email text NOT NULL DEFAULT '',
 status text NOT NULL DEFAULT 'new' CHECK (status IN ('new','reviewed')), created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY (organization_id,listing_id) REFERENCES listings(organization_id,id)
);
CREATE TABLE platform_events (
 id uuid PRIMARY KEY, actor_id uuid NOT NULL REFERENCES users(id), action text NOT NULL,
 resource_id uuid, reason text NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER immutable_platform_events BEFORE UPDATE OR DELETE ON platform_events FOR EACH ROW EXECUTE FUNCTION prevent_history_rewrite();
CREATE TRIGGER immutable_moderation_events BEFORE UPDATE OR DELETE ON moderation_events FOR EACH ROW EXECUTE FUNCTION prevent_history_rewrite();
