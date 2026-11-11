#!/bin/bash
set -Eeuo pipefail
exec 2>&1

export LC_ALL=C
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
export PGHOST=/tmp/nobleprog-p6-lab/socket
export PGPORT=5546
export PGUSER=postgres
export PGDATABASE=postgres
export PGAPPNAME=p6_runner
export PGOPTIONS="-c statement_timeout=30000"

ROOT=/tmp/nobleprog-p6-lab
DATA=$ROOT/data
E=$ROOT/evidence
PASS=0
FAIL=0
STARTED=0
RESTORE=0
CURRENT=""
POLL_OK=0
HOLDER_PID=""
HOLDER_GATE=""
HOLDER_LOG=""

declare -A RESULTS=(
    [00]=NO_PROBADO
    [01]=NO_PROBADO
    [02]=NO_PROBADO
    [03]=NO_PROBADO
    [04]=NO_PROBADO
    [05]=NO_PROBADO
)

pass() {
    PASS=$((PASS + 1))
    printf 'PASS | %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL | %s\n' "$1"
}

sql() {
    psql -X -v ON_ERROR_STOP=1 -P pager=off -e "$@"
}

q() {
    psql -X -Atq -v ON_ERROR_STOP=1 -c "$1"
}

check_sql() {
    local value
    value=$(q "$2")
    if [ "$value" = t ]; then
        pass "$1"
    else
        fail "$1; resultado=$value"
    fi
}

begin_scenario() {
    CURRENT=$1
    SCENARIO_FAIL_START=$FAIL
    RESULTS[$CURRENT]=EN_EJECUCION
    printf '\n========== ESCENARIO %s: %s ==========\n' "$1" "$2"
}

end_scenario() {
    if [ "$FAIL" -eq "$SCENARIO_FAIL_START" ]; then
        RESULTS[$CURRENT]=PASS
    else
        RESULTS[$CURRENT]=FAIL
    fi
    CURRENT=""
}

poll_sql() {
    local label=$1
    local limit=$2
    local query=$3
    local deadline=$((SECONDS + limit))
    local value

    POLL_OK=0
    while [ "$SECONDS" -lt "$deadline" ]; do
        value=$(q "$query")
        if [ "$value" = t ]; then
            POLL_OK=1
            pass "$label"
            return 0
        fi
        sleep 1
    done

    fail "$label; no se observo dentro de ${limit}s"
    return 0
}

settings_snapshot() {
    q "SELECT name || '=' || setting || '|' || COALESCE(unit,'')
       FROM pg_settings
       WHERE name IN (
         'autovacuum','autovacuum_naptime',
         'log_autovacuum_min_duration','track_counts'
       )
       ORDER BY name;"
}

options_snapshot() {
    q "SELECT c.relname || '|' ||
              COALESCE(c.reloptions::text,'NULL')
       FROM pg_class c
       JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='maintenance' AND c.relkind='r'
       ORDER BY c.relname;"
}

expect_error() {
    local label=$1
    local state=$2
    local statement=$3
    local name=$4
    local code

    printf '%s\n' "$statement" > "$E/$name.sql"
    printf '\nPRUEBA NEGATIVA: %s\n' "$label"

    if timeout 15 psql -X -v ON_ERROR_STOP=1 \
        -v VERBOSITY=verbose -f "$E/$name.sql" \
        > "$E/$name.log" 2>&1; then
        cat "$E/$name.log"
        fail "$label; el comando no produjo el error esperado"
    else
        code=$?
        cat "$E/$name.log"
        if [ "$code" -eq 3 ] &&
           grep -Eq "ERROR: +${state}:" "$E/$name.log"; then
            pass "$label; error esperado SQLSTATE=$state, salida=$code"
        else
            fail "$label; error inesperado, salida=$code"
        fi
    fi
}

# P6_BLOCK_03_END

start_holder() {
    local name=$1
    local relation=$2
    local input=$E/$name.sql
    local deadline
    local value

    HOLDER_GATE=$E/$name.release
    HOLDER_LOG=$E/$name.log

    value=$(q "SELECT EXISTS (
        SELECT 1 FROM pg_stat_activity
        WHERE application_name='$name'
    );")

    if [ "$value" != f ]; then
        fail "Ya existe una sesion activa llamada $name"
        exit 1
    fi

    rm -f -- "$E/$name.ready" "$HOLDER_GATE"

    cat > "$input" <<SQL
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT 'BEFORE_COUNT=' || count(*) FROM $relation;
SELECT 'BEFORE_VERSION_SUM=' || sum(version) FROM $relation;
\! touch $E/$name.ready
\! timeout 120 /usr/bin/bash $E/wait-gate.sh $HOLDER_GATE
SELECT 'AFTER_COUNT=' || count(*) FROM $relation;
SELECT 'AFTER_VERSION_SUM=' || sum(version) FROM $relation;
COMMIT;
SQL

    PGAPPNAME="$name" timeout 150 psql -X -Atq \
        -v ON_ERROR_STOP=1 -f "$input" \
        > "$HOLDER_LOG" 2>&1 &
    HOLDER_PID=$!

    deadline=$((SECONDS + 15))

    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -f "$E/$name.ready" ]; then
            value=$(q "SELECT EXISTS (
                SELECT 1 FROM pg_stat_activity
                WHERE application_name='$name'
                AND state='idle in transaction'
                AND backend_xmin IS NOT NULL
            );")

            if [ "$value" = t ]; then
                pass "$name conserva una transaccion, snapshot y senal"
                return 0
            fi
        fi

        if ! kill -0 "$HOLDER_PID" 2>/dev/null; then
            cat "$HOLDER_LOG"
            fail "La sesion $name termino antes de quedar preparada"
            exit 1
        fi

        sleep 0.2
    done

    cat "$HOLDER_LOG"
    fail "No se confirmaron conjuntamente snapshot y senal de $name"
    exit 1
}

release_holder() {
    touch "$HOLDER_GATE"

    if wait "$HOLDER_PID"; then
        pass "Sesion A finalizo con COMMIT"
    else
        fail "La sesion A termino con error"
    fi

    cat "$HOLDER_LOG"
    HOLDER_PID=""
}

# P6_BLOCK_04_END

finish() {
    local original_rc=$?
    local restore_rc=0

    trap - ERR EXIT
    set +e

    if [ "$original_rc" -ne 0 ] && [ -n "$CURRENT" ]; then
        RESULTS[$CURRENT]=INTERRUMPIDO
    fi

    printf '\n========== RESTAURACION Y CIERRE ==========\n'

    if [ "$STARTED" -eq 1 ]; then
        touch "$E/p6_mvcc_A.release" "$E/p6_bloat_A.release"

        q "SELECT pg_terminate_backend(pid)
           FROM pg_stat_activity
           WHERE application_name LIKE 'p6_%'
             AND pid<>pg_backend_pid()
             AND backend_type='client backend';" \
           > "$E/session-cleanup.log" 2>&1

        if [ "$?" -ne 0 ]; then
            fail "No se pudo confirmar el cierre de sesiones auxiliares"
        fi

        if [ "$RESTORE" -eq 1 ]; then
            psql -X -v ON_ERROR_STOP=1 -f "$E/restore.sql"
            restore_rc=$?

            if [ "$restore_rc" -eq 0 ]; then
                pass "Restauracion de opciones de tablas ejecutada"
            else
                fail "No se pudieron restaurar todas las opciones de tablas"
            fi

            cp "$E/postgresql.auto.conf.before" \
               "$DATA/postgresql.auto.conf"

            if [ "$?" -ne 0 ]; then
                fail "No se pudo restaurar postgresql.auto.conf"
            else
                q "SELECT pg_reload_conf();"
                if [ "$?" -ne 0 ]; then
                    fail "No se pudo solicitar la recarga final"
                fi
            fi

            sleep 2

            settings_snapshot > "$E/settings.after"
            if [ "$?" -eq 0 ] &&
               cmp -s "$E/settings.before" "$E/settings.after"; then
                pass "Configuracion global igual al estado original"
            else
                fail "La configuracion global no coincide con BEFORE"
                diff -u "$E/settings.before" "$E/settings.after"
            fi

            options_snapshot > "$E/options.after"
            if [ "$?" -eq 0 ] &&
               cmp -s "$E/options.before" "$E/options.after"; then
                pass "Opciones de tablas iguales al estado original"
            else
                fail "Las opciones de tablas no coinciden con BEFORE"
                diff -u "$E/options.before" "$E/options.after"
            fi
        fi

        pg_ctl -D "$DATA" -m fast -w -t 30 stop

        if [ "$?" -eq 0 ]; then
            pass "Instancia temporal detenida"
        else
            fail "No se pudo confirmar la detencion de PostgreSQL"
        fi
    fi

    printf '\n========== RESUMEN POR ESCENARIO ==========\n'

    for number in 00 01 02 03 04 05; do
        printf '%s: %s\n' "$number" "${RESULTS[$number]}"
        if [ "$original_rc" -eq 0 ] &&
           [ "${RESULTS[$number]}" != PASS ] &&
           [ "${RESULTS[$number]}" != FAIL ]; then
            fail "Escenario $number sin completar"
        fi
    done

    printf '\nTOTAL PASS: %s\nTOTAL FAIL: %s\n' "$PASS" "$FAIL"
    printf 'CODIGO EJECUTOR: %s\n' "$original_rc"

    if [ "$original_rc" -eq 0 ] && [ "$FAIL" -eq 0 ]; then
        echo "RESULTADO: VALIDACION TEMPORAL EXITOSA"
        echo "=== FIN VALIDACION P6 ==="
        exit 0
    fi

    echo "RESULTADO: REQUIERE REVISION"

    if [ -f "$E/server.log" ]; then
        echo "=== ULTIMAS LINEAS DEL LOG POSTGRESQL ==="
        tail -n 35 "$E/server.log"
    fi

    echo "=== FIN VALIDACION P6 ==="
    exit 1
}

trap finish EXIT
trap 'printf "ERROR NO ESPERADO: linea=%s comando=%s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# P6_BLOCK_05_END

begin_scenario 00 "Preparacion y estado inicial"

test "$(id -un)" = postgres
test ! -e "$DATA"

initdb -D "$DATA" -U postgres -A trust --no-locale -E UTF8 \
    > "$E/initdb.log" 2>&1

cat >> "$DATA/postgresql.conf" <<CONFIG
listen_addresses = ''
port = 5546
unix_socket_directories = '/tmp/nobleprog-p6-lab/socket'
shared_buffers = '32MB'
max_connections = 20
autovacuum = on
track_counts = on
logging_collector = off
log_line_prefix = '%m [%p] %a '
CONFIG

STARTED=1
pg_ctl -D "$DATA" -l "$E/server.log" -w -t 30 start

sql -c "CREATE DATABASE nobleprog_maintenance_scenarios;"
export PGDATABASE=nobleprog_maintenance_scenarios

sql <<'SQL'
SELECT version();
CREATE SCHEMA maintenance;

CREATE TABLE maintenance.mvcc_work (
    id integer PRIMARY KEY,
    version integer NOT NULL DEFAULT 0,
    payload text NOT NULL
);
CREATE TABLE maintenance.bloat_work (
    id integer PRIMARY KEY,
    version integer NOT NULL DEFAULT 0,
    payload text NOT NULL
);
CREATE TABLE maintenance.distribution (
    id integer PRIMARY KEY,
    estado text NOT NULL,
    payload text NOT NULL
);
CREATE TABLE maintenance.auto_work (
    id integer PRIMARY KEY,
    version integer NOT NULL DEFAULT 0,
    payload text NOT NULL
);
CREATE TABLE maintenance.freeze_work (
    id integer PRIMARY KEY,
    payload text NOT NULL
);
SQL

settings_snapshot > "$E/settings.before"
options_snapshot > "$E/options.before"
cp "$DATA/postgresql.auto.conf" "$E/postgresql.auto.conf.before"

cat > "$E/restore.sql" <<'SQL'
SET lock_timeout = '5s';
SET statement_timeout = '20s';
ALTER TABLE maintenance.mvcc_work RESET (autovacuum_enabled);
ALTER TABLE maintenance.bloat_work RESET (autovacuum_enabled);
ALTER TABLE maintenance.distribution RESET (autovacuum_enabled);
ALTER TABLE maintenance.freeze_work RESET (autovacuum_enabled);
ALTER TABLE maintenance.auto_work RESET (
    autovacuum_enabled,
    autovacuum_vacuum_threshold,
    autovacuum_vacuum_scale_factor,
    autovacuum_vacuum_insert_threshold,
    autovacuum_analyze_threshold,
    autovacuum_analyze_scale_factor
);
SQL

RESTORE=1

cat > "$E/wait-gate.sh" <<'SH'
#!/bin/bash
set -eu
while [ ! -f "$1" ]; do
    sleep 1
done
SH

sql <<'SQL'
ALTER TABLE maintenance.mvcc_work SET (autovacuum_enabled=false);
ALTER TABLE maintenance.bloat_work SET (autovacuum_enabled=false);
ALTER TABLE maintenance.distribution SET (autovacuum_enabled=false);
ALTER TABLE maintenance.freeze_work SET (autovacuum_enabled=false);
ALTER TABLE maintenance.auto_work SET (autovacuum_enabled=false);

INSERT INTO maintenance.mvcc_work
SELECT g,0,repeat(md5(g::text),8)
FROM generate_series(1,10000) AS g;

INSERT INTO maintenance.bloat_work
SELECT g,0,repeat(md5(g::text),16)
FROM generate_series(1,30000) AS g;

INSERT INTO maintenance.distribution
SELECT g,CASE WHEN g<=100 THEN 'raro' ELSE 'normal' END,
       repeat(md5(g::text),4)
FROM generate_series(1,20000) AS g;

CREATE INDEX distribution_estado_idx
ON maintenance.distribution(estado);

INSERT INTO maintenance.freeze_work
SELECT g,md5(g::text)
FROM generate_series(1,1000) AS g;

ANALYZE maintenance.mvcc_work;
ANALYZE maintenance.bloat_work;
ANALYZE maintenance.distribution;

SELECT name,setting,unit,source,pending_restart
FROM pg_settings
WHERE name IN (
    'autovacuum','autovacuum_naptime',
    'log_autovacuum_min_duration','track_counts',
    'autovacuum_freeze_max_age','vacuum_freeze_min_age'
)
ORDER BY name;
SQL

check_sql "Version mayor PostgreSQL 18" \
    "SELECT current_setting('server_version_num')::int
     BETWEEN 180000 AND 189999;"

check_sql "Autovacuum y track_counts habilitados" \
    "SELECT current_setting('autovacuum')='on'
     AND current_setting('track_counts')='on';"

check_sql "Carga inicial completa" \
    "SELECT (SELECT count(*) FROM maintenance.mvcc_work)=10000
     AND (SELECT count(*) FROM maintenance.bloat_work)=30000
     AND (SELECT count(*) FROM maintenance.distribution)=20000
     AND (SELECT count(*) FROM maintenance.freeze_work)=1000;"

end_scenario

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
