#!/bin/sh
set -eu
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set=ON_ERROR_STOP=1 <<'SQL'
\getenv runtime_password KWADRA_APP_PASSWORD
CREATE ROLE kwadra_app LOGIN PASSWORD :'runtime_password';
GRANT CONNECT ON DATABASE kwadra TO kwadra_app;
GRANT USAGE ON SCHEMA public TO kwadra_app;
ALTER DEFAULT PRIVILEGES FOR ROLE kwadra_migrate IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO kwadra_app;
ALTER DEFAULT PRIVILEGES FOR ROLE kwadra_migrate IN SCHEMA public GRANT USAGE,SELECT ON SEQUENCES TO kwadra_app;
SQL
