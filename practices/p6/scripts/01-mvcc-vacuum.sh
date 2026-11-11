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
begin_scenario 01 "MVCC, versiones obsoletas y VACUUM"

start_holder p6_mvcc_A maintenance.mvcc_work

sql <<'SQL'
UPDATE maintenance.mvcc_work
SET version=version+1 WHERE id<=2000;

DELETE FROM maintenance.mvcc_work
WHERE id BETWEEN 2001 AND 4000;

SELECT count(*) AS filas_visibles,sum(version) AS suma_versiones
FROM maintenance.mvcc_work;

VACUUM (VERBOSE, INDEX_CLEANUP ON) maintenance.mvcc_work;

SELECT relname,n_live_tup,n_dead_tup,vacuum_count
FROM pg_stat_user_tables WHERE relname='mvcc_work';
SQL

check_sql "B observa los cambios confirmados" \
    "SELECT count(*)=8000 AND sum(version)=2000
     FROM maintenance.mvcc_work;"

check_sql "VACUUM conserva versiones requeridas por A" \
    "SELECT n_dead_tup>0 FROM pg_stat_user_tables
     WHERE relid='maintenance.mvcc_work'::regclass;"

check_sql "A sigue reteniendo un horizonte MVCC" \
    "SELECT EXISTS (
       SELECT 1 FROM pg_stat_activity
       WHERE application_name='p6_mvcc_A'
       AND backend_xmin IS NOT NULL
     );"

release_holder

if grep -qx 'BEFORE_COUNT=10000' "$E/p6_mvcc_A.log" &&
   grep -qx 'AFTER_COUNT=10000' "$E/p6_mvcc_A.log" &&
   grep -qx 'BEFORE_VERSION_SUM=0' "$E/p6_mvcc_A.log" &&
   grep -qx 'AFTER_VERSION_SUM=0' "$E/p6_mvcc_A.log"; then
    pass "A mantuvo su snapshot durante los cambios de B"
else
    fail "No se confirmo la estabilidad del snapshot de A"
fi

sql -c "VACUUM (VERBOSE, INDEX_CLEANUP ON) maintenance.mvcc_work;"

check_sql "VACUUM elimina versiones obsoletas tras cerrar A" \
    "SELECT n_dead_tup=0 FROM pg_stat_user_tables
     WHERE relid='maintenance.mvcc_work'::regclass;"

reuse_before=$(q "SELECT pg_relation_size('maintenance.mvcc_work');")

sql -c "INSERT INTO maintenance.mvcc_work
        SELECT g,0,repeat(md5(g::text),8)
        FROM generate_series(10001,12000) AS g;"

reuse_after=$(q "SELECT pg_relation_size('maintenance.mvcc_work');")
echo "HEAP antes de reutilizar=$reuse_before; despues=$reuse_after"

check_sql "Nuevas filas reutilizan espacio sin ampliar el heap" \
    "SELECT $reuse_after <= $reuse_before;"

check_sql "Conteo tras reutilizar espacio" \
    "SELECT count(*)=10000 FROM maintenance.mvcc_work;"

expect_error "VACUUM dentro de BEGIN" 25001 \
    "BEGIN; VACUUM maintenance.mvcc_work; COMMIT;" \
    vacuum-in-transaction

end_scenario

# P6_PART_1_END


printf '\nCOMPROBACIONES DEL SCRIPT: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
