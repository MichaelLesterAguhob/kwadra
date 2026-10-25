-- Active management schema. Money is exact NUMERIC; API money uses integer
-- centavos. All organization-owned relationships enforce composite ownership.
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE users (
  id uuid PRIMARY KEY, email text NOT NULL, name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
  password_hash text NOT NULL, disabled boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX users_email ON users(lower(email));
CREATE TABLE organizations (
  id uuid PRIMARY KEY, name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  currency char(3) NOT NULL DEFAULT 'PHP' CHECK (currency='PHP'),
  timezone text NOT NULL DEFAULT 'Asia/Manila' CHECK (timezone='Asia/Manila'),
  revision integer NOT NULL DEFAULT 1, next_invoice_number integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE memberships (
  organization_id uuid NOT NULL REFERENCES organizations(id), user_id uuid NOT NULL REFERENCES users(id),
  role text NOT NULL CHECK (role IN ('owner','admin','staff','viewer')),
  all_properties boolean NOT NULL DEFAULT false, active boolean NOT NULL DEFAULT true,
  PRIMARY KEY (organization_id,user_id)
);
CREATE TABLE sessions (
  token_hash char(64) PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id),
  csrf_token text NOT NULL, expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sessions_expiry ON sessions(expires_at);
CREATE INDEX sessions_user ON sessions(user_id);

CREATE TABLE properties (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES organizations(id),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  address text NOT NULL CHECK (length(trim(address)) BETWEEN 1 AND 500),
  type text NOT NULL, image text NOT NULL DEFAULT 'residence' CHECK (image IN ('residence','apartment','studio')),
  notes text NOT NULL DEFAULT '', archived boolean NOT NULL DEFAULT false,
  revision integer NOT NULL DEFAULT 1, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id,id)
);
CREATE INDEX properties_org ON properties(organization_id,archived);
CREATE TABLE property_assignments (
  organization_id uuid NOT NULL, user_id uuid NOT NULL, property_id uuid NOT NULL,
  PRIMARY KEY (organization_id,user_id,property_id),
  FOREIGN KEY (organization_id,user_id) REFERENCES memberships(organization_id,user_id),
  FOREIGN KEY (organization_id,property_id) REFERENCES properties(organization_id,id)
);
CREATE TABLE units (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, property_id uuid NOT NULL,
  code text NOT NULL CHECK (length(trim(code)) BETWEEN 1 AND 40), type text NOT NULL,
  rent numeric(14,2) NOT NULL CHECK (rent>0), capacity smallint NOT NULL CHECK (capacity BETWEEN 1 AND 20),
  floor text NOT NULL DEFAULT 'Ground floor', maintenance boolean NOT NULL DEFAULT false,
  revision integer NOT NULL DEFAULT 1, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id,id),
  FOREIGN KEY (organization_id,property_id) REFERENCES properties(organization_id,id)
);
CREATE UNIQUE INDEX units_code ON units(organization_id,property_id,lower(trim(code)));
CREATE INDEX units_property ON units(organization_id,property_id);
CREATE TABLE tenants (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES organizations(id),
  user_id uuid REFERENCES users(id), name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  email text NOT NULL DEFAULT '', phone text NOT NULL DEFAULT '', emergency text NOT NULL DEFAULT '',
  archived boolean NOT NULL DEFAULT false, revision integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (organization_id,id)
);
CREATE UNIQUE INDEX tenants_email ON tenants(organization_id,lower(email)) WHERE email<>'' AND NOT archived;
CREATE TABLE leases (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, unit_id uuid NOT NULL,
  starts_on date NOT NULL, ends_on date NOT NULL CHECK (ends_on>=starts_on),
  rent numeric(14,2) NOT NULL CHECK (rent>0), deposit_terms numeric(14,2) NOT NULL DEFAULT 0 CHECK (deposit_terms>=0),
  due_day smallint NOT NULL CHECK (due_day BETWEEN 1 AND 31),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','ended','cancelled')),
  terminated_on date, revision integer NOT NULL DEFAULT 1, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id,id),
  FOREIGN KEY (organization_id,unit_id) REFERENCES units(organization_id,id),
  CHECK ((status='active' AND terminated_on IS NULL) OR (status<>'active' AND terminated_on IS NOT NULL)),
  CHECK (status<>'ended' OR terminated_on>=starts_on),
  occupancy daterange GENERATED ALWAYS AS (
    CASE WHEN status='cancelled' THEN NULL
      ELSE daterange(starts_on, CASE WHEN status='ended' THEN least(ends_on+1,terminated_on) ELSE ends_on+1 END, '[)') END
  ) STORED,
  EXCLUDE USING gist (organization_id WITH =, unit_id WITH =, occupancy WITH &&)
);
CREATE INDEX leases_org ON leases(organization_id,status,ends_on);
CREATE TABLE lease_participants (
  organization_id uuid NOT NULL, lease_id uuid NOT NULL, tenant_id uuid NOT NULL,
  is_primary boolean NOT NULL DEFAULT false,
  PRIMARY KEY (organization_id,lease_id,tenant_id),
  FOREIGN KEY (organization_id,lease_id) REFERENCES leases(organization_id,id),
  FOREIGN KEY (organization_id,tenant_id) REFERENCES tenants(organization_id,id)
);
CREATE INDEX participants_tenant ON lease_participants(organization_id,tenant_id);
CREATE TABLE invoices (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, lease_id uuid NOT NULL,
  number text NOT NULL, period date NOT NULL CHECK (extract(day FROM period)=1), due_on date NOT NULL,
  amount numeric(14,2) NOT NULL CHECK (amount>0), created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id,id), UNIQUE (organization_id,number), UNIQUE (organization_id,lease_id,period),
  FOREIGN KEY (organization_id,lease_id) REFERENCES leases(organization_id,id)
);
CREATE INDEX invoices_period ON invoices(organization_id,period,due_on);
CREATE TABLE invoice_items (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, invoice_id uuid NOT NULL,
  description text NOT NULL, amount numeric(14,2) NOT NULL CHECK (amount>0),
  FOREIGN KEY (organization_id,invoice_id) REFERENCES invoices(organization_id,id)
);
CREATE TABLE maintenance_tickets (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, unit_id uuid NOT NULL,
  title text NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 160), description text NOT NULL DEFAULT '',
  category text NOT NULL, priority text NOT NULL CHECK (priority IN ('Low','Normal','Urgent')),
  status text NOT NULL DEFAULT 'Open' CHECK (status IN ('Open','In progress','Resolved')),
  reported_by uuid REFERENCES users(id), assigned_to uuid REFERENCES users(id),
  revision integer NOT NULL DEFAULT 1, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id,id),
  FOREIGN KEY (organization_id,unit_id) REFERENCES units(organization_id,id)
);
CREATE INDEX tickets_status ON maintenance_tickets(organization_id,status,created_at);
CREATE TABLE maintenance_events (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL, ticket_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES users(id), detail text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (organization_id,ticket_id) REFERENCES maintenance_tickets(organization_id,id)
);
CREATE TABLE audit_events (
  id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES organizations(id), actor_id uuid REFERENCES users(id),
  property_id uuid, kind text NOT NULL, title text NOT NULL, detail text NOT NULL,
  resource_type text NOT NULL, resource_id uuid, created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (organization_id,property_id) REFERENCES properties(organization_id,id)
);
CREATE INDEX audit_org ON audit_events(organization_id,created_at);
CREATE FUNCTION prevent_history_rewrite() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Issued invoices and audit/history records are append-only' USING ERRCODE='23514'; END; $$;
CREATE TRIGGER immutable_audit BEFORE UPDATE OR DELETE ON audit_events FOR EACH ROW EXECUTE FUNCTION prevent_history_rewrite();
CREATE TRIGGER immutable_ticket_history BEFORE UPDATE OR DELETE ON maintenance_events FOR EACH ROW EXECUTE FUNCTION prevent_history_rewrite();
CREATE TRIGGER immutable_invoices BEFORE UPDATE OR DELETE ON invoices FOR EACH ROW EXECUTE FUNCTION prevent_history_rewrite();
CREATE TRIGGER immutable_invoice_items BEFORE UPDATE OR DELETE ON invoice_items FOR EACH ROW EXECUTE FUNCTION prevent_history_rewrite();

CREATE TABLE idempotency_keys (
  organization_id uuid NOT NULL, actor_id uuid NOT NULL, key text NOT NULL, operation text NOT NULL,
  payload_hash char(64) NOT NULL, response jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,actor_id,key),
  FOREIGN KEY (organization_id,actor_id) REFERENCES memberships(organization_id,user_id)
);
