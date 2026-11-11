#!/bin/bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/00-env.sh"

if [ "$(id -un)" != postgres ]; then
    echo "ERROR: ejecutar como usuario postgres."
    exit 1
fi

trap 'printf "ERROR: linea=%s comando=%s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
export PGDATABASE=nobleprog_maintenance_scenarios

if [ ! -f "$DATA/PG_VERSION" ] ||
   [ ! -f "$E/settings.before" ] ||
   [ ! -f "$E/restore.sql" ]; then
    echo "ERROR: primero ejecutar 00-prepare-lab.sh."
    exit 1
fi

pg_ctl -D "$DATA" status
begin_scenario 03 "ANALYZE y estadisticas"

sql <<'SQL'
CREATE FUNCTION maintenance.plan_probe()
RETURNS TABLE(estimated bigint, actual bigint, node text)
LANGUAGE plpgsql
SET max_parallel_workers_per_gather=0
AS $$
DECLARE document json;
BEGIN
    EXECUTE
      'EXPLAIN (ANALYZE, FORMAT JSON)
       SELECT * FROM maintenance.distribution WHERE estado=''raro'''
    INTO document;
    RETURN QUERY SELECT
      (document->0->'Plan'->>'Plan Rows')::bigint,
      (document->0->'Plan'->>'Actual Rows')::numeric::bigint,
      document->0->'Plan'->>'Node Type';
END;
$$;

SELECT attname,n_distinct,most_common_vals,most_common_freqs
FROM pg_stats
WHERE schemaname='maintenance'
AND tablename='distribution' AND attname='estado';

UPDATE maintenance.distribution SET estado='raro'
WHERE id BETWEEN 101 AND 18000;
SQL

echo "=== PLAN BEFORE ANALYZE ==="
sql -c "EXPLAIN (ANALYZE, BUFFERS)
        SELECT * FROM maintenance.distribution WHERE estado='raro';"

probe_before=$(q "SELECT estimated||'|'||actual||'|'||node
                  FROM maintenance.plan_probe();")
IFS='|' read -r estimate_before actual_before plan_before <<< "$probe_before"

sql -c "ANALYZE VERBOSE maintenance.distribution;"

echo "=== PLAN AFTER ANALYZE ==="
sql -c "EXPLAIN (ANALYZE, BUFFERS)
        SELECT * FROM maintenance.distribution WHERE estado='raro';"

probe_after=$(q "SELECT estimated||'|'||actual||'|'||node
                 FROM maintenance.plan_probe();")
IFS='|' read -r estimate_after actual_after plan_after <<< "$probe_after"

echo "BEFORE estimadas=$estimate_before reales=$actual_before nodo=$plan_before"
echo "AFTER estimadas=$estimate_after reales=$actual_after nodo=$plan_after"

check_sql "Consulta devuelve 18000 filas en ambas mediciones" \
    "SELECT $actual_before=18000 AND $actual_after=18000;"

check_sql "ANALYZE mejora el error absoluto de estimacion" \
    "SELECT abs($estimate_after-$actual_after)
     < abs($estimate_before-$actual_before);"

sql -c "SELECT attname,n_distinct,most_common_vals,most_common_freqs
        FROM pg_stats WHERE schemaname='maintenance'
        AND tablename='distribution' AND attname='estado';"

echo "LIMITE: no se exige cambio de plan ni mejora de tiempo."

end_scenario


printf '\nCOMPROBACIONES DEL SCRIPT: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
