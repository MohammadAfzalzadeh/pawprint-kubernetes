-- psql must invoke this file with --single-transaction and ON_ERROR_STOP.
SELECT pg_advisory_xact_lock(70538011);
SET ROLE petclinic_owner;
CREATE SCHEMA IF NOT EXISTS pawprint_meta;
CREATE TABLE IF NOT EXISTS pawprint_meta.bootstrap (version text PRIMARY KEY);
SELECT NOT EXISTS (SELECT FROM pawprint_meta.bootstrap WHERE version = 'petclinic-v1') AS initialize \gset
\if :initialize
DO $pawprint$
BEGIN
  IF EXISTS (SELECT FROM pg_class WHERE relnamespace = 'public'::regnamespace
               AND relkind IN ('r','p','S','v','m','f')) THEN
    RAISE EXCEPTION 'Existing public objects require operator review before bootstrap';
  END IF;
END
$pawprint$;
\ir schema.sql
\ir data.sql
INSERT INTO pawprint_meta.bootstrap VALUES ('petclinic-v1');
\ir reporting.sql
\echo petclinic-v1 applied
\else
\echo petclinic-v1 already applied
\endif
