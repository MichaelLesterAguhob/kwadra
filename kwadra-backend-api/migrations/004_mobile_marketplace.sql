-- Personal marketplace accounts do not grant landlord/tenant organization access.
ALTER TABLE users ADD COLUMN marketplace_account boolean NOT NULL DEFAULT false;
ALTER TABLE delivery_logs ALTER COLUMN organization_id DROP NOT NULL;
CREATE TABLE saved_listings (
 user_id uuid NOT NULL REFERENCES users(id), listing_id uuid NOT NULL REFERENCES listings(id),
 created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(user_id,listing_id)
);
CREATE INDEX inquiry_seeker ON inquiries(seeker_id,created_at DESC) WHERE seeker_id IS NOT NULL;
CREATE TABLE account_idempotency_keys (
 user_id uuid NOT NULL REFERENCES users(id), key text NOT NULL,
 payload_hash char(64) NOT NULL, response jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(user_id,key)
);
