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
begin_scenario 02 "Bloat y bloqueo de VACUUM FULL"

heap_initial=$(q "SELECT pg_relation_size('maintenance.bloat_work');")
node_initial=$(q "SELECT pg_relation_filenode('maintenance.bloat_work');")

sql <<'SQL'
DELETE FROM maintenance.bloat_work WHERE id%10<>0;
VACUUM (VERBOSE, TRUNCATE FALSE) maintenance.bloat_work;

SELECT count(*) AS filas_restantes FROM maintenance.bloat_work;
SELECT pg_relation_size('maintenance.bloat_work') AS heap_bytes,
       pg_indexes_size('maintenance.bloat_work') AS index_bytes,
       pg_total_relation_size('maintenance.bloat_work') AS total_bytes;
SQL

heap_plain=$(q "SELECT pg_relation_size('maintenance.bloat_work');")
echo "HEAP inicial=$heap_initial; tras VACUUM=$heap_plain"

check_sql "VACUUM sin truncado conserva el tamano del heap" \
    "SELECT $heap_plain=$heap_initial;"

check_sql "Eliminacion del 90 por ciento confirmada" \
    "SELECT count(*)=3000 FROM maintenance.bloat_work;"

start_holder p6_bloat_A maintenance.bloat_work

sql -c "VACUUM (VERBOSE, TRUNCATE FALSE) maintenance.bloat_work;"
pass "VACUUM normal completo con el lector A abierto"

PGAPPNAME=p6_full timeout 60 psql -X -v ON_ERROR_STOP=1 \
    -c "VACUUM (FULL, VERBOSE) maintenance.bloat_work;" \
    > "$E/vacuum-full.log" 2>&1 &
full_pid=$!

poll_sql "FULL espera un AccessExclusiveLock" 10 \
    "SELECT EXISTS (
       SELECT 1 FROM pg_stat_activity a
       JOIN pg_locks l ON l.pid=a.pid
       WHERE a.application_name='p6_full'
       AND l.relation='maintenance.bloat_work'::regclass
       AND l.mode='AccessExclusiveLock'
       AND NOT l.granted
       AND cardinality(pg_blocking_pids(a.pid))>0
     );"

if [ "$POLL_OK" -ne 1 ]; then
    cat "$E/vacuum-full.log"
    echo "ERROR DE COORDINACION: no se observo la espera de FULL."
    exit 1
fi

expect_error "Nuevo lector espera detras de FULL" 55P03 \
    "SET lock_timeout='700ms'; SELECT count(*) FROM maintenance.bloat_work;" \
    full-lock-timeout

release_holder

if wait "$full_pid"; then
    pass "FULL completo despues de liberar A"
else
    fail "FULL termino con error"
fi
cat "$E/vacuum-full.log"

heap_full=$(q "SELECT pg_relation_size('maintenance.bloat_work');")
node_full=$(q "SELECT pg_relation_filenode('maintenance.bloat_work');")
echo "HEAP FULL=$heap_full; filenode BEFORE=$node_initial AFTER=$node_full"

check_sql "FULL redujo el heap a menos de la mitad" \
    "SELECT $heap_full < $heap_plain/2;"

check_sql "FULL reescribio la relacion" \
    "SELECT $node_full <> $node_initial;"

check_sql "FULL conservo las filas" \
    "SELECT count(*)=3000 FROM maintenance.bloat_work;"

echo "LIMITE: no se calcula un porcentaje exacto de bloat."
echo "TRUNCATE FALSE controla el experimento de VACUUM normal."

end_scenario


printf '\nCOMPROBACIONES DEL SCRIPT: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
