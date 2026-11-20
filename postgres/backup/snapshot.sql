-- Run within the dump snapshot on Primary and against the isolated restored database.
SET LOCAL search_path = pg_catalog;
SET LOCAL DateStyle = 'ISO, YMD';
SET LOCAL TimeZone = 'UTC';

-- Hash every row while retaining duplicates, without logging row contents.
SELECT format(
  'SELECT %L, %L, count(*), encode(sha256(convert_to(COALESCE(string_agg(h, '''' ORDER BY h COLLATE "C"), ''''), ''UTF8'')), ''hex'')
     FROM (SELECT encode(sha256(convert_to(to_jsonb(r)::text, ''UTF8'')), ''hex'') AS h FROM %I.%I AS r) AS rows',
  'TABLE', c.relname, n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r','p')
ORDER BY c.relname COLLATE "C"
\gexec

SELECT 'COLUMN', c.relname, a.attname, format_type(a.atttypid, a.atttypmod),
       a.attnotnull, a.attidentity, a.attgenerated, COALESCE(pg_get_expr(d.adbin,d.adrelid), '')
FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
WHERE c.relnamespace='public'::regnamespace AND c.relkind IN ('r','p')
  AND a.attnum>0 AND NOT a.attisdropped
ORDER BY c.relname COLLATE "C", a.attnum;

SELECT 'CONSTRAINT', c.relname, con.conname, con.contype, con.convalidated, pg_get_constraintdef(con.oid)
FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid
WHERE c.relnamespace='public'::regnamespace
ORDER BY c.relname COLLATE "C", con.conname COLLATE "C";

SELECT 'INDEX', c.relname, i.relname, ix.indisvalid, pg_get_indexdef(ix.indexrelid)
FROM pg_index ix JOIN pg_class c ON c.oid=ix.indrelid JOIN pg_class i ON i.oid=ix.indexrelid
WHERE c.relnamespace='public'::regnamespace
ORDER BY c.relname COLLATE "C", i.relname COLLATE "C";

SELECT 'SEQUENCE', c.relname, format_type(s.seqtypid,NULL), s.seqstart,
       s.seqincrement,s.seqmax,s.seqmin,s.seqcache,s.seqcycle
FROM pg_sequence s JOIN pg_class c ON c.oid=s.seqrelid
WHERE c.relnamespace='public'::regnamespace
ORDER BY c.relname COLLATE "C";
