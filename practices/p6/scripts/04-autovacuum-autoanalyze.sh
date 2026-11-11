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
begin_scenario 04 "Autovacuum y Autoanalyze"

sql -c "ALTER SYSTEM SET autovacuum_naptime='1s';"
sql -c "ALTER SYSTEM SET log_autovacuum_min_duration='0';"
sql -c "SELECT pg_reload_conf();"

poll_sql "Configuracion temporal aplicada" 10 \
    "SELECT
       (SELECT setting='1' FROM pg_settings
        WHERE name='autovacuum_naptime')
       AND
       (SELECT setting='0' FROM pg_settings
        WHERE name='log_autovacuum_min_duration');"

if [ "$POLL_OK" -ne 1 ]; then
    exit 1
fi

sql <<'SQL'
ALTER TABLE maintenance.auto_work SET (
    autovacuum_enabled=false,
    autovacuum_vacuum_threshold=25,
    autovacuum_vacuum_scale_factor=0,
    autovacuum_vacuum_insert_threshold=-1,
    autovacuum_analyze_threshold=25,
    autovacuum_analyze_scale_factor=0
);

INSERT INTO maintenance.auto_work
SELECT g,0,repeat(md5(g::text),8)
FROM generate_series(1,12000) AS g;

UPDATE maintenance.auto_work
SET version=version+1 WHERE id<=6000;

SELECT relname,reltuples,reloptions FROM pg_class
WHERE oid='maintenance.auto_work'::regclass;

SELECT name,setting,unit FROM pg_settings
WHERE name IN (
    'autovacuum_naptime',
    'autovacuum_vacuum_threshold',
    'autovacuum_vacuum_scale_factor',
    'autovacuum_vacuum_max_threshold',
    'autovacuum_analyze_threshold',
    'autovacuum_analyze_scale_factor'
) ORDER BY name;
SQL

sleep 3

check_sql "Sin ejecuciones automaticas mientras esta deshabilitado" \
    "SELECT autovacuum_count=0 AND autoanalyze_count=0
     FROM pg_stat_user_tables
     WHERE relid='maintenance.auto_work'::regclass;"

check_sql "Versiones obsoletas superan el umbral" \
    "SELECT n_dead_tup>25 FROM pg_stat_user_tables
     WHERE relid='maintenance.auto_work'::regclass;"

sql -c "ALTER TABLE maintenance.auto_work SET (autovacuum_enabled=true);"

echo "Esperando ambos procesos; limite de 90 segundos."

poll_sql "Autovacuum y Autoanalyze ejecutados realmente" 90 \
    "SELECT autovacuum_count>0 AND autoanalyze_count>0
     AND last_autovacuum IS NOT NULL
     AND last_autoanalyze IS NOT NULL
     FROM pg_stat_user_tables
     WHERE relid='maintenance.auto_work'::regclass;"

sql -c "SELECT relname,n_live_tup,n_dead_tup,n_mod_since_analyze,
        vacuum_count,analyze_count,autovacuum_count,autoanalyze_count,
        last_autovacuum,last_autoanalyze
        FROM pg_stat_user_tables
        WHERE relid='maintenance.auto_work'::regclass;"

check_sql "No se uso mantenimiento manual en auto_work" \
    "SELECT vacuum_count=0 AND analyze_count=0
     FROM pg_stat_user_tables
     WHERE relid='maintenance.auto_work'::regclass;"

check_sql "Mantenimiento automatico conservo los datos" \
    "SELECT count(*)=12000 AND sum(version)=6000
     FROM maintenance.auto_work;"

echo "LIMITE: n_dead_tup y n_live_tup son estimaciones."
echo "Deshabilitar autovacuum ordinario no anula la proteccion antiwraparound."

end_scenario


printf '\nCOMPROBACIONES DEL SCRIPT: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
