#!/bin/bash
set -Eeuo pipefail

[[ "${P8_ROLE:-}" == "prod" ]] || exit 1

runuser -u postgres -- psql -X -q -h 127.0.0.1 -U postgres -d reportes_db -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
    fdw_password text;
BEGIN
    SELECT substr(opt, length('password=') + 1)
      INTO fdw_password
      FROM pg_user_mapping m
      JOIN pg_foreign_server s ON s.oid = m.umserver
      JOIN pg_roles r ON r.oid = m.umuser
      CROSS JOIN LATERAL unnest(m.umoptions) AS x(opt)
     WHERE r.rolname = 'p8_reporter'
       AND s.srvname = 'p8_ventas_server'
       AND opt LIKE 'password=%';

    IF fdw_password IS NULL OR fdw_password = '' THEN
        RAISE EXCEPTION 'FDW configuration unavailable';
    END IF;

    EXECUTE format('ALTER ROLE p8_reporter PASSWORD %L', fdw_password);
END
$$;
SQL
