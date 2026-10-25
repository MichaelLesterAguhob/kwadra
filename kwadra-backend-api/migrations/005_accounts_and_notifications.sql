-- Additive upgrade: existing users, sessions, portfolios and charges survive.
ALTER TABLE users ALTER COLUMN password_hash DROP NOT NULL;
ALTER TABLE identity_tokens ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();
CREATE TABLE external_identities (
 provider text NOT NULL CHECK (provider='google'), subject text NOT NULL,
 user_id uuid NOT NULL REFERENCES users(id), created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(provider,subject), UNIQUE(user_id,provider)
);
CREATE TABLE native_session_families (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id),
 expires_at timestamptz NOT NULL, revoked_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE sessions ADD COLUMN family_id uuid REFERENCES native_session_families(id) ON DELETE CASCADE;
CREATE INDEX sessions_family ON sessions(family_id) WHERE family_id IS NOT NULL;
CREATE TABLE refresh_credentials (
 token_hash char(64) PRIMARY KEY, family_id uuid NOT NULL REFERENCES native_session_families(id) ON DELETE CASCADE,
 consumed_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX refresh_family ON refresh_credentials(family_id);
-- Password recovery, suspension and MFA changes revoke remembered devices too.
CREATE FUNCTION revoke_changed_identity() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.password_hash IS DISTINCT FROM OLD.password_hash OR
    (NEW.disabled AND NOT OLD.disabled) OR
    NEW.mfa_secret IS DISTINCT FROM OLD.mfa_secret OR
    NEW.platform_admin IS DISTINCT FROM OLD.platform_admin THEN
  DELETE FROM native_session_families WHERE user_id=NEW.id;
  DELETE FROM sessions WHERE user_id=NEW.id;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER identity_revocation AFTER UPDATE ON users FOR EACH ROW EXECUTE FUNCTION revoke_changed_identity();
ALTER TABLE notifications ALTER COLUMN organization_id DROP NOT NULL;
ALTER TABLE notifications ADD COLUMN inquiry_id uuid REFERENCES inquiries(id);
CREATE INDEX notification_inbox ON notifications(recipient_id,created_at DESC);
