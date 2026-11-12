#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/00-check-lab.sh"
set -Eeuo pipefail
exec > >(tee /tmp/p7-01-results.txt) 2>&1
trap 'echo "FAIL: escenario 07.01 interrumpido en línea $LINENO"; exit 1' ERR

echo "ESCENARIO 07.01 - DIAGNOSTICO DE CONSULTAS"
date -u

runuser -u postgres -- /bin/bash <<'POSTGRES'
set -Eeuo pipefail

export PGHOST=/tmp/nobleprog-p7-lab/socket
export PGPORT=5432
export PGUSER=postgres
export PGDATABASE=nobleprog_performance_scenarios

psql -X -v ON_ERROR_STOP=1 <<'SQL'
\pset pager off
\timing on

-- No sobrescribir datos de una ejecución anterior.
DO $check$
BEGIN
    IF to_regclass('performance.orders_01') IS NOT NULL THEN
        RAISE EXCEPTION 'orders_01 ya existe. Conservar y revisar antes de repetir.';
    END IF;
END
$check$;

CREATE TABLE performance.orders_01 (
    id bigint PRIMARY KEY,
    customer_id integer NOT NULL,
    amount numeric(12,2) NOT NULL,
    description text NOT NULL
);

INSERT INTO performance.orders_01
SELECT
    g,
    (g % 10000 + 1)::integer,
    ((g % 50000)::numeric / 100)::numeric(12,2),
    repeat(md5(g::text), 3)
FROM generate_series(1, 200000) AS source(g);

ANALYZE performance.orders_01;

DO $check$
BEGIN
    IF (SELECT count(*) FROM performance.orders_01) <> 200000 THEN
        RAISE EXCEPTION 'Carga incompleta';
    END IF;

    IF (
        SELECT count(*) FROM performance.orders_01
        WHERE customer_id = 4242
    ) <> 20 THEN
        RAISE EXCEPTION 'La consulta debe encontrar 20 filas';
    END IF;

    RAISE NOTICE 'PASS: 200000 filas cargadas; 20 filas para el cliente objetivo';
END
$check$;

-- Conservar los planes JSON para comprobarlos automáticamente.
CREATE TEMP TABLE measured_plans (
    phase text PRIMARY KEY,
    document jsonb NOT NULL
);

-- Registrar la configuración inicial de esta sesión.
SELECT name, setting, unit
FROM pg_settings
WHERE name IN (
    'max_parallel_workers_per_gather',
    'enable_seqscan',
    'enable_indexscan',
    'enable_bitmapscan',
    'work_mem',
    'track_io_timing'
)
ORDER BY name;

-- Aislar aquí el efecto del índice del efecto del paralelismo.
-- Este cambio desaparece al cerrar la conexión.
SET max_parallel_workers_per_gather = 0;

\echo 'BEFORE: EXPLAIN estima; no ejecuta esta consulta.'
EXPLAIN
SELECT id, customer_id, amount
FROM performance.orders_01
WHERE customer_id = 4242;

\echo 'BEFORE: EXPLAIN ANALYZE ejecuta y muestra filas, tiempos y buffers.'
EXPLAIN (ANALYZE, BUFFERS, SETTINGS)
SELECT id, customer_id, amount
FROM performance.orders_01
WHERE customer_id = 4242;

DO $measure$
DECLARE
    plan_document jsonb;
BEGIN
    EXECUTE
        'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
         SELECT id, customer_id, amount
         FROM performance.orders_01
         WHERE customer_id = 4242'
    INTO plan_document;

    INSERT INTO measured_plans VALUES ('BEFORE', plan_document);

    IF plan_document #>> '{0,Plan,Node Type}' <> 'Seq Scan' THEN
        RAISE EXCEPTION 'No se obtuvo el Seq Scan esperado: %', plan_document;
    END IF;

    IF (plan_document #>> '{0,Plan,Actual Rows}')::numeric <> 20 THEN
        RAISE EXCEPTION 'El plan BEFORE no devolvió 20 filas';
    END IF;

    RAISE NOTICE 'PASS: BEFORE usa Seq Scan y devuelve 20 filas';
END
$measure$;

\echo 'CAMBIO: crear un índice B-tree para el filtro.'
CREATE INDEX orders_01_customer_idx
ON performance.orders_01 USING btree (customer_id);

\echo 'AFTER: ejecutar exactamente la misma consulta.'
EXPLAIN (ANALYZE, BUFFERS, SETTINGS)
SELECT id, customer_id, amount
FROM performance.orders_01
WHERE customer_id = 4242;

DO $measure$
DECLARE
    plan_document jsonb;
    node_type text;
BEGIN
    EXECUTE
        'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
         SELECT id, customer_id, amount
         FROM performance.orders_01
         WHERE customer_id = 4242'
    INTO plan_document;

    INSERT INTO measured_plans VALUES ('AFTER', plan_document);
    node_type := plan_document #>> '{0,Plan,Node Type}';

    IF node_type NOT IN ('Index Scan', 'Index Only Scan', 'Bitmap Heap Scan') THEN
        RAISE EXCEPTION 'No se obtuvo acceso por índice: %', plan_document;
    END IF;

    IF plan_document::text NOT LIKE '%orders_01_customer_idx%' THEN
        RAISE EXCEPTION 'No se utilizó el índice experimental';
    END IF;

    IF (plan_document #>> '{0,Plan,Actual Rows}')::numeric <> 20 THEN
        RAISE EXCEPTION 'El plan AFTER no devolvió 20 filas';
    END IF;

    RAISE NOTICE 'PASS: AFTER utiliza el índice y devuelve las mismas 20 filas';
END
$measure$;

\echo 'COMPARACION: mediciones de las ejecuciones JSON.'
SELECT
    phase,
    document #>> '{0,Plan,Node Type}' AS access_method,
    document #>> '{0,Plan,Plan Rows}' AS estimated_rows,
    document #>> '{0,Plan,Actual Rows}' AS actual_rows,
    document #>> '{0,Plan,Rows Removed by Filter}' AS removed_by_filter,
    document #>> '{0,Plan,Shared Hit Blocks}' AS shared_hit_blocks,
    document #>> '{0,Plan,Shared Read Blocks}' AS shared_read_blocks,
    document #>> '{0,Execution Time}' AS execution_ms
FROM measured_plans
ORDER BY CASE phase WHEN 'BEFORE' THEN 1 ELSE 2 END;

-- Ejecutar también la consulta directamente para identificarla en estadísticas.
SELECT id, customer_id, amount
FROM performance.orders_01
WHERE customer_id = 4242;

\echo 'PG_STAT_STATEMENTS: consulta directa, sin reiniciar estadísticas globales.'
SELECT
    queryid,
    calls,
    rows,
    total_exec_time,
    mean_exec_time,
    shared_blks_hit,
    shared_blks_read,
    query
FROM pg_stat_statements
WHERE dbid = (
    SELECT oid FROM pg_database WHERE datname = current_database()
)
AND query LIKE 'SELECT id, customer_id, amount%FROM performance.orders_01%';

DO $check$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_stat_statements
        WHERE dbid = (
            SELECT oid FROM pg_database WHERE datname = current_database()
        )
        AND query LIKE 'SELECT id, customer_id, amount%FROM performance.orders_01%'
        AND calls >= 1
        AND rows >= 20
    ) THEN
        RAISE EXCEPTION 'No se encontró la consulta directa en las estadísticas';
    END IF;

    RAISE NOTICE 'PASS: consulta directa registrada en pg_stat_statements';
END
$check$;

\echo 'RESTAURACION: eliminar el índice experimental.'
DROP INDEX performance.orders_01_customer_idx;

DO $check$
BEGIN
    IF to_regclass('performance.orders_01_customer_idx') IS NOT NULL THEN
        RAISE EXCEPTION 'El índice experimental sigue presente';
    END IF;

    IF (SELECT count(*) FROM performance.orders_01) <> 200000 THEN
        RAISE EXCEPTION 'Se alteró la cantidad de datos';
    END IF;

    RAISE NOTICE 'PASS: índice eliminado y datos conservados';
END
$check$;

RESET max_parallel_workers_per_gather;
SHOW max_parallel_workers_per_gather;

\echo 'PLAN FINAL: acceso original restaurado.'
EXPLAIN
SELECT id, customer_id, amount
FROM performance.orders_01
WHERE customer_id = 4242;
SQL

echo ""
echo "PASS: ESCENARIO 07.01 COMPLETADO"
echo "Datos conservados: performance.orders_01"
echo "Indice experimental eliminado."
POSTGRES
