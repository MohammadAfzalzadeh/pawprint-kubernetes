SET LOCAL search_path = pg_catalog;

-- Compare to the actual SEQUENCE SET archive entries before consuming any values.
SELECT format('SELECT format(%L, last_value, is_called::text) FROM %I.%I',
              format('SELECT pg_catalog.setval(%L, %%s, %%s);', 'public.'||c.relname),
              n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relkind='S'
\gexec
