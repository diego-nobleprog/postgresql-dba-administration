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
begin_scenario 05 "Congelacion y diagnostico preventivo"

for ((i=1; i<=200; i++)); do
    printf 'SELECT pg_current_xact_id();\n'
done > "$E/advance-xid.sql"

psql -X -Atq -v ON_ERROR_STOP=1 \
    -f "$E/advance-xid.sql" > "$E/advance-xid.log"

xid_before=$(q "SELECT age(relfrozenxid) FROM pg_class
               WHERE oid='maintenance.freeze_work'::regclass;")

sql <<'SQL'
SELECT relname,relfrozenxid,age(relfrozenxid) AS xid_age,
       relpages,relallvisible,relallfrozen
FROM pg_class WHERE oid='maintenance.freeze_work'::regclass;

VACUUM (FREEZE, VERBOSE) maintenance.freeze_work;
SQL

xid_after=$(q "SELECT age(relfrozenxid) FROM pg_class
              WHERE oid='maintenance.freeze_work'::regclass;")

echo "Edad relfrozenxid BEFORE=$xid_before AFTER=$xid_after"

check_sql "Edad de XID observable" "SELECT $xid_before>=200;"
check_sql "FREEZE avanzo el horizonte" "SELECT $xid_after<$xid_before;"

check_sql "Paginas marcadas all-frozen" \
    "SELECT relpages>0 AND relallfrozen=relpages FROM pg_class
     WHERE oid='maintenance.freeze_work'::regclass;"

check_sql "FREEZE conservo las filas" \
    "SELECT count(*)=1000 FROM maintenance.freeze_work;"

sql <<'SQL'
SELECT datname,datfrozenxid,age(datfrozenxid) AS xid_age,
       current_setting('autovacuum_freeze_max_age') AS freeze_max_age
FROM pg_database WHERE datallowconn
ORDER BY age(datfrozenxid) DESC;

SELECT c.relname,age(c.relfrozenxid) AS xid_age,
       c.relpages,c.relallvisible,c.relallfrozen,
       s.n_live_tup,s.n_dead_tup,s.last_vacuum,s.last_autovacuum,
       s.last_analyze,s.last_autoanalyze
FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
LEFT JOIN pg_stat_user_tables s ON s.relid=c.oid
WHERE n.nspname='maintenance' AND c.relkind='r'
ORDER BY age(c.relfrozenxid) DESC;

SELECT pid,application_name,state,
       clock_timestamp()-xact_start AS transaction_age,
       backend_xmin,age(backend_xmin) AS xmin_age
FROM pg_stat_activity WHERE xact_start IS NOT NULL
ORDER BY xact_start;

SELECT gid,prepared,owner,database FROM pg_prepared_xacts;
SELECT slot_name,slot_type,active,xmin,catalog_xmin,restart_lsn
FROM pg_replication_slots;
SQL

check_sql "Sin sesiones auxiliares idle in transaction" \
    "SELECT NOT EXISTS (
       SELECT 1 FROM pg_stat_activity
       WHERE application_name LIKE 'p6_%'
       AND state LIKE 'idle in transaction%'
     );"

echo "LIMITE: se demuestra congelacion, no un wraparound real."
echo "LIMITE: edad de XID no es tiempo de reloj."
echo "El diagnostico no constituye una politica de produccion."

end_scenario

# P6_PART_2_END

printf '\nCOMPROBACIONES DEL SCRIPT: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
