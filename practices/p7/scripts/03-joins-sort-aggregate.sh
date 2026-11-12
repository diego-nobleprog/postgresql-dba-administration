#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/00-check-lab.sh"
set -Eeuo pipefail
exec > >(tee /tmp/p7-03-results.txt) 2>&1
trap 'echo "FAIL: escenario 07.03 interrumpido en línea $LINENO"; exit 1' ERR

echo "ESCENARIO 07.03 - JOINS, SORT Y AGGREGATE"
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

DO $check$
BEGIN
    IF to_regclass('performance.orders_01') IS NULL THEN
        RAISE EXCEPTION 'Se requiere la tabla validada en 07.01';
    END IF;

    IF (SELECT count(*) FROM performance.orders_01) <> 200000 THEN
        RAISE EXCEPTION 'La tabla orders_01 no contiene 200000 filas';
    END IF;

    IF to_regclass('performance.orders_01_customer_idx') IS NOT NULL THEN
        RAISE EXCEPTION 'El índice experimental de 07.01 sigue presente';
    END IF;

    IF to_regclass('performance.customers_03') IS NOT NULL THEN
        RAISE EXCEPTION 'customers_03 ya existe. No sobrescribir.';
    END IF;
END
$check$;

CREATE TABLE performance.customers_03 (
    id integer PRIMARY KEY,
    name text NOT NULL
);

INSERT INTO performance.customers_03
SELECT g, 'Customer ' || g
FROM generate_series(1, 10000) AS source(g);

ANALYZE performance.customers_03;
ANALYZE performance.orders_01;

-- Conservar el estado original de todos los parámetros que cambiaremos.
CREATE TEMP TABLE original_settings AS
SELECT name, current_setting(name) AS value
FROM pg_settings
WHERE name IN (
    'work_mem',
    'max_parallel_workers_per_gather',
    'enable_hashjoin',
    'enable_mergejoin',
    'enable_nestloop'
);

TABLE original_settings;

CREATE TEMP TABLE measured_plans (
    scenario text PRIMARY KEY,
    sql_text text NOT NULL,
    work_mem text NOT NULL,
    document jsonb NOT NULL
);

CREATE FUNCTION pg_temp.measure(case_name text, query_sql text)
RETURNS void LANGUAGE plpgsql AS $function$
DECLARE
    result_plan jsonb;
BEGIN
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON) ' || query_sql
    INTO result_plan;

    INSERT INTO measured_plans
    VALUES (case_name, query_sql, current_setting('work_mem'), result_plan);

    RAISE NOTICE 'PASS: medición capturada para %', case_name;
END
$function$;

SET max_parallel_workers_per_gather = 0;
SET work_mem = '4MB';

\echo 'JOIN 1: filtro selectivo; observar la elección natural del optimizador.'
SELECT pg_temp.measure(
    '01 Join selectivo',
    'SELECT o.id, c.name
     FROM performance.orders_01 o
     JOIN performance.customers_03 c ON c.id = o.customer_id
     WHERE c.id = 4242'
);

\echo 'JOIN 2: unión completa; observar la elección natural del optimizador.'
SELECT pg_temp.measure(
    '02 Join completo',
    'SELECT o.id, c.name
     FROM performance.orders_01 o
     JOIN performance.customers_03 c ON c.id = o.customer_id'
);

\echo 'JOIN 3: demostración controlada de Merge Join.'
SET enable_hashjoin = off;
SET enable_nestloop = off;

SELECT pg_temp.measure(
    '03 Merge solicitado',
    'SELECT o.id, c.name
     FROM performance.orders_01 o
     JOIN performance.customers_03 c ON c.id = o.customer_id'
);

-- Restaurar las preferencias de join antes de las pruebas de memoria.
SELECT set_config(name, value, false) AS restored_join_setting
FROM original_settings
WHERE name IN ('enable_hashjoin', 'enable_mergejoin', 'enable_nestloop');

\echo 'SORT BEFORE: memoria pequeña; ordenar las 200000 filas.'
SET work_mem = '64kB';

SELECT pg_temp.measure(
    '04 Sort 64kB',
    'SELECT id, description
     FROM performance.orders_01
     ORDER BY description, id'
);

\echo 'SORT AFTER: misma consulta con más memoria de sesión.'
SET work_mem = '64MB';

SELECT pg_temp.measure(
    '05 Sort 64MB',
    'SELECT id, description
     FROM performance.orders_01
     ORDER BY description, id'
);

\echo 'AGGREGATE BEFORE: agrupar con memoria pequeña.'
SET work_mem = '64kB';

SELECT pg_temp.measure(
    '06 Aggregate 64kB',
    'SELECT customer_id, count(*) AS order_count, sum(amount) AS total_amount
     FROM performance.orders_01
     GROUP BY customer_id'
);

\echo 'AGGREGATE AFTER: misma consulta con más memoria de sesión.'
SET work_mem = '64MB';

SELECT pg_temp.measure(
    '07 Aggregate 64MB',
    'SELECT customer_id, count(*) AS order_count, sum(amount) AS total_amount
     FROM performance.orders_01
     GROUP BY customer_id'
);

\echo 'RESUMEN: tiempos y bloques temporales del nodo raíz.'
SELECT
    scenario,
    work_mem,
    document #>> '{0,Plan,Node Type}' AS root_node,
    document #>> '{0,Plan,Plan Rows}' AS estimated_rows,
    document #>> '{0,Plan,Actual Rows}' AS actual_rows,
    document #>> '{0,Plan,Temp Read Blocks}' AS temp_read,
    document #>> '{0,Plan,Temp Written Blocks}' AS temp_written,
    document #>> '{0,Execution Time}' AS execution_ms
FROM measured_plans
ORDER BY scenario;

\echo 'NODOS: estrategias, métodos de sort, memoria y batches.'
WITH RECURSIVE nodes AS (
    SELECT scenario, document -> 0 -> 'Plan' AS node
    FROM measured_plans
    UNION ALL
    SELECT parent.scenario, child.value
    FROM nodes parent
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(parent.node -> 'Plans', '[]'::jsonb)
    ) child(value)
)
SELECT
    scenario,
    node ->> 'Node Type' AS node_type,
    node ->> 'Strategy' AS strategy,
    node ->> 'Actual Rows' AS actual_rows,
    node ->> 'Actual Loops' AS loops,
    node ->> 'Sort Method' AS sort_method,
    node ->> 'Sort Space Type' AS sort_space_type,
    node ->> 'Sort Space Used' AS sort_space_kb,
    node ->> 'Peak Memory Usage' AS peak_memory_kb,
    node ->> 'Hash Batches' AS hash_batches,
    node ->> 'HashAgg Batches' AS hashagg_batches,
    node ->> 'Disk Usage' AS disk_kb
FROM nodes
ORDER BY scenario, node_type;

DO $check$
DECLARE
    sort_low jsonb;
    sort_high jsonb;
    aggregate_low jsonb;
    aggregate_high jsonb;
BEGIN
    IF (SELECT count(*) FROM measured_plans) <> 7 THEN
        RAISE EXCEPTION 'Faltan mediciones';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM measured_plans
        WHERE scenario = '01 Join selectivo'
          AND document::text LIKE '%Nested Loop%'
          AND (document #>> '{0,Plan,Actual Rows}')::numeric = 20
    ) THEN
        RAISE EXCEPTION 'No se observó el Nested Loop selectivo esperado';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM measured_plans
        WHERE scenario = '02 Join completo'
          AND document::text LIKE '%Hash Join%'
          AND (document #>> '{0,Plan,Actual Rows}')::numeric = 200000
    ) THEN
        RAISE EXCEPTION 'No se observó el Hash Join completo esperado';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM measured_plans
        WHERE scenario = '03 Merge solicitado'
          AND document::text LIKE '%Merge Join%'
          AND (document #>> '{0,Plan,Actual Rows}')::numeric = 200000
    ) THEN
        RAISE EXCEPTION 'No se observó el Merge Join solicitado';
    END IF;

    SELECT document INTO STRICT sort_low
    FROM measured_plans WHERE scenario = '04 Sort 64kB';

    SELECT document INTO STRICT sort_high
    FROM measured_plans WHERE scenario = '05 Sort 64MB';

    SELECT document INTO STRICT aggregate_low
    FROM measured_plans WHERE scenario = '06 Aggregate 64kB';

    SELECT document INTO STRICT aggregate_high
    FROM measured_plans WHERE scenario = '07 Aggregate 64MB';

    IF (sort_low #>> '{0,Plan,Actual Rows}')::numeric <> 200000
       OR (sort_high #>> '{0,Plan,Actual Rows}')::numeric <> 200000 THEN
        RAISE EXCEPTION 'El sort no procesó las 200000 filas';
    END IF;

    IF (aggregate_low #>> '{0,Plan,Actual Rows}')::numeric <> 10000
       OR (aggregate_high #>> '{0,Plan,Actual Rows}')::numeric <> 10000 THEN
        RAISE EXCEPTION 'La agregación no produjo los 10000 grupos';
    END IF;

    IF COALESCE((sort_low #>> '{0,Plan,Temp Written Blocks}')::numeric, 0) <= 0
       OR COALESCE((sort_high #>> '{0,Plan,Temp Written Blocks}')::numeric, 0) <> 0 THEN
        RAISE EXCEPTION 'No se obtuvo la comparación esperada de temporales en Sort';
    END IF;

    IF COALESCE((aggregate_low #>> '{0,Plan,Temp Written Blocks}')::numeric, 0) <= 0
       OR COALESCE((aggregate_high #>> '{0,Plan,Temp Written Blocks}')::numeric, 0) <> 0 THEN
        RAISE EXCEPTION 'No se obtuvo la comparación esperada de temporales en Aggregate';
    END IF;

    RAISE NOTICE 'PASS: tres joins, sort y aggregate comprobados';
END
$check$;

\echo 'RESTAURACION: recuperar todos los parámetros originales.'
SELECT name, set_config(name, value, false) AS restored_value
FROM original_settings
ORDER BY name;

DO $check$
BEGIN
    IF EXISTS (
        SELECT 1 FROM original_settings
        WHERE current_setting(name) <> value
    ) THEN
        RAISE EXCEPTION 'No se restauraron todos los parámetros';
    END IF;

    IF (SELECT count(*) FROM performance.orders_01) <> 200000
       OR (SELECT count(*) FROM performance.customers_03) <> 10000 THEN
        RAISE EXCEPTION 'Se alteró la cantidad de datos';
    END IF;

    RAISE NOTICE 'PASS: configuración restaurada y datos conservados';
END
$check$;

-- Conservar los planes completos en la evidencia sin el relleno de tablas.
\echo 'PLANES JSON COMPLETOS'
\pset format unaligned
\pset tuples_only on
SELECT jsonb_build_object(
    'scenario', scenario,
    'sql', sql_text,
    'work_mem', work_mem,
    'explain', document
)
FROM measured_plans
ORDER BY scenario;
SQL

echo ""
echo "PASS: ESCENARIO 07.03 COMPLETADO"
echo "Datos conservados: performance.orders_01 y performance.customers_03"
POSTGRES
