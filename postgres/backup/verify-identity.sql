DO $identity$
DECLARE
  tbl text;
  seq regclass;
  max_id bigint;
  restored_next bigint;
  actual_next bigint;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['owners','pets','specialties','types','vets','visits'] LOOP
    seq := pg_get_serial_sequence(format('public.%I', tbl), 'id')::regclass;
    IF seq IS NULL THEN
      RAISE EXCEPTION 'Missing identity for public.%', tbl;
    END IF;
    EXECUTE format('SELECT coalesce(max(id),0) FROM public.%I', tbl) INTO max_id;
    EXECUTE format('SELECT last_value + CASE WHEN is_called THEN (SELECT seqincrement FROM pg_sequence WHERE seqrelid = %L::regclass) ELSE 0 END FROM %s', seq, seq) INTO restored_next;
    actual_next := nextval(seq);
    IF actual_next <> restored_next OR actual_next <= max_id THEN
      RAISE EXCEPTION 'Unsafe next value % for % (expected %, maximum id %)', actual_next, tbl, restored_next, max_id;
    END IF;
    RAISE NOTICE '% next value % exceeds maximum restored id %', seq, actual_next, max_id;
  END LOOP;
END
$identity$;
