RESET ROLE;
-- Expose only receiver health to the report login. Never expose conninfo.
CREATE OR REPLACE FUNCTION pawprint_meta.replica_health()
RETURNS TABLE (in_recovery boolean, streaming boolean, last_message timestamptz,
               last_replay timestamptz, pending_bytes bigint)
LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT pg_is_in_recovery(),
         COALESCE((SELECT status = 'streaming' FROM pg_stat_wal_receiver), false),
         (SELECT last_msg_receipt_time FROM pg_stat_wal_receiver),
         pg_last_xact_replay_timestamp(),
         CASE WHEN pg_last_wal_receive_lsn() IS NOT NULL AND pg_last_wal_replay_lsn() IS NOT NULL
           THEN greatest(0, pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()))::bigint
         END;
$$;
REVOKE ALL ON FUNCTION pawprint_meta.replica_health() FROM PUBLIC;
GRANT USAGE ON SCHEMA pawprint_meta TO reporting_user;
GRANT EXECUTE ON FUNCTION pawprint_meta.replica_health() TO reporting_user;
