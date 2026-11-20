\getenv postgres_password POSTGRES_PASSWORD
SET log_statement = 'none';
SET log_min_error_statement = 'panic';
ALTER ROLE postgres PASSWORD :'postgres_password';
SET ROLE petclinic_owner;
CREATE SCHEMA pawprint_meta;
CREATE TABLE pawprint_meta.bootstrap (version text PRIMARY KEY);
INSERT INTO pawprint_meta.bootstrap VALUES ('petclinic-v1');
\ir reporting.sql

DO $owners$
BEGIN
  IF EXISTS (SELECT FROM pg_class WHERE relnamespace = 'public'::regnamespace
            AND relkind IN ('r', 'S', 'p', 'v', 'm', 'f') AND relowner <> 'petclinic_owner'::regrole)
  THEN RAISE EXCEPTION 'Recovered public objects must be owned by petclinic_owner';
  END IF;
END
$owners$;
