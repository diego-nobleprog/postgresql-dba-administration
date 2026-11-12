#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/00-check-lab.sh"
set -Eeuo pipefail
exec > >(tee /tmp/p7-06-results.txt) 2>&1
trap 'echo "FAIL: escenario 07.06 interrumpido en línea $LINENO"; exit 1' ERR

echo "ESCENARIO 07.06 - TROUBLESHOOTING Y BENCHMARKING"
date -u

runuser -u postgres -- /bin/bash <<'POSTGRES'
set -Eeuo pipefail
export PGHOST=/tmp/nobleprog-p7-lab/socket
export PGPORT=5432
export PGUSER=postgres
export PGDATABASE=nobleprog_performance_scenarios
unset PGOPTIONS

WORK=/tmp/nobleprog-p7-lab/06-details
if [ -e "$WORK" ]; then
    echo "FAIL: ya existe el directorio de evidencias de 07.06"
    exit 1
fi
mkdir -m 700 "$WORK"

BENCH_PID=
MONITOR_PID=

cleanup() {
    local code=$?
    trap - EXIT
    set +e
    if [ -n "$BENCH_PID" ]; then
        kill "$BENCH_PID" 2>/dev/null
        wait "$BENCH_PID" 2>/dev/null
    fi
    if [ -n "$MONITOR_PID" ]; then
        wait "$MONITOR_PID" 2>/dev/null
    fi
    echo "Detalle conservado: $WORK"
    exit "$code"
}
trap cleanup EXIT

sql_value() {
    psql -X -qAt -v ON_ERROR_STOP=1 -c "$1"
}

snapshot() {
    local phase="$1"
    {
        echo "SNAPSHOT: $phase"
        date -u
        for file in cpu.max cpu.stat memory.max memory.current memory.events io.stat; do
            if [ -f "/sys/fs/cgroup/$file" ]; then
                echo "CGROUP: $file"
                cat "/sys/fs/cgroup/$file"
            fi
        done
        psql -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT jsonb_build_object('view', 'pg_stat_database', 'data', to_jsonb(s))
FROM pg_stat_database s WHERE datname = current_database();

SELECT jsonb_build_object('view', 'pg_stat_wal', 'data', to_jsonb(s))
FROM pg_stat_wal s;

SELECT jsonb_build_object('view', 'pg_stat_checkpointer', 'data', to_jsonb(s))
FROM pg_stat_checkpointer s;

SELECT jsonb_build_object('view', 'pg_stat_io', 'data', to_jsonb(s))
FROM pg_stat_io s;
SQL
    } > "$WORK/$phase-snapshot.txt"
}

psql -X -v ON_ERROR_STOP=1 <<'SQL'
\pset pager off
DO $check$
BEGIN
    IF to_regclass('performance.orders_01') IS NULL THEN
        RAISE EXCEPTION 'Se requiere orders_01 de 07.01';
    END IF;

    IF (SELECT count(*) FROM performance.orders_01) <> 200000 THEN
        RAISE EXCEPTION 'orders_01 no tiene la carga esperada';
    END IF;

    IF to_regclass('performance.benchmark_data_06') IS NOT NULL
       OR to_regclass('performance.benchmark_results_06') IS NOT NULL
       OR to_regclass('performance.wal_probe_06') IS NOT NULL
       OR to_regclass('performance.benchmark_baseline_06') IS NOT NULL THEN
        RAISE EXCEPTION 'Ya existen recursos de 07.06. No sobrescribir.';
    END IF;
END
$check$;

CREATE TABLE performance.benchmark_data_06 (
    id bigint PRIMARY KEY,
    customer_id integer NOT NULL,
    amount numeric(12,2) NOT NULL,
    description text NOT NULL
);

INSERT INTO performance.benchmark_data_06
SELECT id, customer_id, amount, description
FROM performance.orders_01;

ANALYZE performance.benchmark_data_06;

CREATE TABLE performance.benchmark_baseline_06 AS
SELECT count(*) AS row_count, sum(amount) AS amount_sum
FROM performance.benchmark_data_06;

CREATE TABLE performance.benchmark_results_06 (
    case_name text PRIMARY KEY,
    tps numeric NOT NULL,
    latency_ms numeric NOT NULL
);

CREATE TABLE performance.wal_probe_06 (
    id integer PRIMARY KEY,
    balance integer NOT NULL
);

INSERT INTO performance.wal_probe_06
SELECT g, 0 FROM generate_series(1, 1000) AS source(g);

SELECT name, setting, unit
FROM pg_settings
WHERE name IN (
    'shared_buffers', 'work_mem', 'max_connections',
    'checkpoint_timeout', 'checkpoint_completion_target',
    'max_wal_size', 'full_page_writes', 'synchronous_commit'
)
ORDER BY name;
SQL

cat > "$WORK/workload.sql" <<'SQL'
\set customer_id random(1, 10000)
SELECT sum(amount)
FROM performance.benchmark_data_06
WHERE customer_id = :customer_id;
SQL

monitor() {
    local target_pid="$1"
    local destination="$2"

    while kill -0 "$target_pid" 2>/dev/null; do
        {
            echo "SAMPLE"
            date -u
            for file in cpu.stat memory.current io.stat; do
                if [ -f "/sys/fs/cgroup/$file" ]; then
                    echo "$file"
                    cat "/sys/fs/cgroup/$file"
                fi
            done

            psql -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT jsonb_build_object(
    'at', clock_timestamp(),
    'database_connections', (
        SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database()
    ),
    'benchmark_states', (
        SELECT jsonb_agg(to_jsonb(s))
        FROM (
            SELECT state, wait_event_type, wait_event, count(*) AS connections
            FROM pg_stat_activity
            WHERE datname = current_database()
              AND application_name = 'p7_06_benchmark'
            GROUP BY state, wait_event_type, wait_event
        ) s
    ),
    'blocked_benchmark_connections', (
        SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database()
          AND application_name = 'p7_06_benchmark'
          AND cardinality(pg_blocking_pids(pid)) > 0
    )
);
SQL
        } >> "$destination"

        sleep 1
    done
}

run_benchmark() {
    local case_name="$1"
    local log="$WORK/$case_name-pgbench.txt"

    echo ""
    echo "BENCHMARK: $case_name"
    snapshot "$case_name-before"

    PGAPPNAME=p7_06_benchmark pgbench \
        -n -M prepared -c 4 -j 4 -T 3 \
        -f "$WORK/workload.sql" "$PGDATABASE" \
        > "$WORK/$case_name-warmup.txt" 2>&1

    PGAPPNAME=p7_06_benchmark pgbench \
        -n -M prepared -c 4 -j 4 -T 10 -P 5 -r \
        -f "$WORK/workload.sql" "$PGDATABASE" \
        > "$log" 2>&1 &
    BENCH_PID=$!

    monitor "$BENCH_PID" "$WORK/$case_name-samples.txt" &
    MONITOR_PID=$!

    local bench_code=0
    local monitor_code=0
    wait "$BENCH_PID" || bench_code=$?
    BENCH_PID=

    wait "$MONITOR_PID" || monitor_code=$?
    MONITOR_PID=

    cat "$log"

    if [ "$bench_code" -ne 0 ] || [ "$monitor_code" -ne 0 ]; then
        echo "FAIL: pgbench=$bench_code monitor=$monitor_code"
        return 1
    fi

    if ! grep -Eq '^number of failed transactions: *0([[:space:]]|$)' "$log"; then
        echo "FAIL: no se confirmó cero transacciones fallidas"
        return 1
    fi

    local tps
    local latency
    tps=$(awk '/^tps =/{print $3}' "$log")
    latency=$(awk '/^latency average =/{print $4}' "$log")

    if [ -z "$tps" ] || [ -z "$latency" ]; then
        echo "FAIL: faltan TPS o latencia"
        return 1
    fi

    psql -X -v ON_ERROR_STOP=1 \
        -v case_name="$case_name" -v tps="$tps" -v latency="$latency" <<'SQL'
INSERT INTO performance.benchmark_results_06
VALUES (:'case_name', :'tps'::numeric, :'latency'::numeric);
SQL

    snapshot "$case_name-after"
    echo "MUESTRAS DE RECURSOS Y CONEXIONES: $case_name"
    cat "$WORK/$case_name-samples.txt"
    echo "PASS: benchmark y monitor completos para $case_name"
}

echo "PLAN BEFORE: consulta selectiva sin índice sobre customer_id."
psql -X -qAt -v ON_ERROR_STOP=1 \
    -c 'EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) SELECT sum(amount) FROM performance.benchmark_data_06 WHERE customer_id = 4242' \
    > "$WORK/plan-before.json"
cat "$WORK/plan-before.json"

run_benchmark before_1

psql -X -v ON_ERROR_STOP=1 \
    -c 'CREATE INDEX benchmark_customer_06_idx ON performance.benchmark_data_06 (customer_id)'

echo "PLAN AFTER: misma consulta con índice."
psql -X -qAt -v ON_ERROR_STOP=1 \
    -c 'EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) SELECT sum(amount) FROM performance.benchmark_data_06 WHERE customer_id = 4242' \
    > "$WORK/plan-after.json"
cat "$WORK/plan-after.json"

psql -X -v ON_ERROR_STOP=1 <<'SQL'
DO $check$
DECLARE
    plan_document jsonb;
BEGIN
    plan_document := pg_read_file('/tmp/nobleprog-p7-lab/06-details/plan-after.json')::jsonb;

    IF plan_document::text NOT LIKE '%benchmark_customer_06_idx%' THEN
        RAISE EXCEPTION 'El plan AFTER no utiliza el índice';
    END IF;

    RAISE NOTICE 'PASS: consulta de diagnóstico utiliza el índice';
END
$check$;
SQL

run_benchmark after_1
run_benchmark after_2

psql -X -v ON_ERROR_STOP=1 \
    -c 'DROP INDEX performance.benchmark_customer_06_idx'

run_benchmark before_2

echo ""
echo "WAL: actualizar y restaurar 1000 filas de una tabla auxiliar."
snapshot wal-before
LSN_BEFORE=$(sql_value 'SELECT pg_current_wal_insert_lsn()')

psql -X -v ON_ERROR_STOP=1 <<'SQL'
UPDATE performance.wal_probe_06 SET balance = 1;
UPDATE performance.wal_probe_06 SET balance = 0;
SQL

psql -X -v ON_ERROR_STOP=1 -v initial_lsn="$LSN_BEFORE" <<'SQL'
SELECT
    :'initial_lsn'::pg_lsn AS initial_lsn,
    pg_current_wal_insert_lsn() AS final_lsn,
    pg_wal_lsn_diff(pg_current_wal_insert_lsn(), :'initial_lsn'::pg_lsn) AS generated_wal_bytes;

SELECT pg_wal_lsn_diff(
    pg_current_wal_insert_lsn(), :'initial_lsn'::pg_lsn
) > 0 AS wal_generated
\gset

\if :wal_generated
    \echo 'PASS: avance de WAL confirmado'
\else
    \echo 'FAIL: no se observó avance de WAL'
    DO $$ BEGIN RAISE EXCEPTION 'No se observó WAL'; END $$;
\endif
SQL

echo ""
echo "CHECKPOINT: solicitud explícita solo dentro del laboratorio P7."
CHECKPOINTS_BEFORE=$(sql_value 'SELECT num_requested FROM pg_stat_checkpointer')
psql -X -v ON_ERROR_STOP=1 -c 'CHECKPOINT'

checkpoint_seen=0
for attempt in $(seq 1 20); do
    current=$(sql_value 'SELECT num_requested FROM pg_stat_checkpointer')
    if [ "$current" -gt "$CHECKPOINTS_BEFORE" ]; then
        checkpoint_seen=1
        break
    fi
    sleep 1
done

if [ "$checkpoint_seen" -ne 1 ]; then
    echo "FAIL: no se publicó el incremento de checkpoints solicitados"
    exit 1
fi

echo "PASS: checkpoints solicitados BEFORE=$CHECKPOINTS_BEFORE AFTER=$current"
snapshot wal-after

echo "ESTADISTICAS BEFORE: WAL Y CHECKPOINTER"
grep -E '"view": "pg_stat_(wal|checkpointer)"' "$WORK/wal-before-snapshot.txt"
echo "ESTADISTICAS AFTER: WAL Y CHECKPOINTER"
grep -E '"view": "pg_stat_(wal|checkpointer)"' "$WORK/wal-after-snapshot.txt"

psql -X -v ON_ERROR_STOP=1 <<'SQL'
\pset pager off
\echo 'RESUMEN DE BENCHMARKS'
SELECT * FROM performance.benchmark_results_06
ORDER BY CASE case_name
    WHEN 'before_1' THEN 1
    WHEN 'after_1' THEN 2
    WHEN 'after_2' THEN 3
    ELSE 4
END;

\echo 'PG_STAT_STATEMENTS: estadísticas acumuladas de todas las fases.'
SELECT
    calls, rows, total_exec_time, mean_exec_time,
    shared_blks_hit, shared_blks_read, query
FROM pg_stat_statements
WHERE dbid = (
    SELECT oid FROM pg_database WHERE datname = current_database()
)
AND query LIKE 'SELECT sum(amount)%performance.benchmark_data_06%'
ORDER BY total_exec_time DESC;

DO $check$
BEGIN
    IF (SELECT count(*) FROM performance.benchmark_results_06) <> 4 THEN
        RAISE EXCEPTION 'Faltan benchmarks';
    END IF;

    IF EXISTS (
        SELECT 1 FROM performance.benchmark_results_06
        WHERE tps <= 0 OR latency_ms <= 0
    ) THEN
        RAISE EXCEPTION 'Métricas de benchmark inválidas';
    END IF;

    IF to_regclass('performance.benchmark_customer_06_idx') IS NOT NULL THEN
        RAISE EXCEPTION 'El índice experimental sigue presente';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM performance.benchmark_baseline_06 b
        WHERE b.row_count <> (SELECT count(*) FROM performance.benchmark_data_06)
           OR b.amount_sum IS DISTINCT FROM (
               SELECT sum(amount) FROM performance.benchmark_data_06
           )
    ) THEN
        RAISE EXCEPTION 'Cambió la carga de benchmarking';
    END IF;

    IF (SELECT count(*) FROM performance.wal_probe_06) <> 1000
       OR EXISTS (SELECT 1 FROM performance.wal_probe_06 WHERE balance <> 0) THEN
        RAISE EXCEPTION 'No se restauró la tabla auxiliar de WAL';
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_stat_activity
        WHERE datname = current_database()
          AND application_name = 'p7_06_benchmark'
    ) THEN
        RAISE EXCEPTION 'Quedaron conexiones de pgbench';
    END IF;

    RAISE NOTICE 'PASS: cuatro benchmarks, índice eliminado, datos restaurados y conexiones cerradas';
END
$check$;
SQL

echo ""
echo "PASS: ESCENARIO 07.06 COMPLETADO"
echo "Snapshots, planes, carga y logs disponibles en $WORK"
POSTGRES
