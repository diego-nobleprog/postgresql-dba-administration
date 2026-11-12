#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/00-check-lab.sh"
set -Eeuo pipefail
exec > >(tee /tmp/p7-02-results.txt) 2>&1
trap 'echo "FAIL: escenario 07.02 interrumpido en línea $LINENO"; exit 1' ERR

echo "ESCENARIO 07.02 - SELECCION DE INDICES"
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
    IF to_regclass('performance.index_cases_02') IS NOT NULL THEN
        RAISE EXCEPTION 'La tabla del escenario ya existe. No sobrescribir.';
    END IF;
END
$check$;

CREATE TABLE performance.index_cases_02 (
    id bigint PRIMARY KEY,
    customer_id integer NOT NULL,
    status text NOT NULL,
    created_at timestamp NOT NULL,
    tags text[] NOT NULL,
    location point NOT NULL,
    description text NOT NULL
);

INSERT INTO performance.index_cases_02
SELECT
    g,
    (g % 10000 + 1)::integer,
    CASE WHEN g % 20 = 0 THEN 'pending' ELSE 'closed' END,
    timestamp '2026-01-01' + g * interval '1 minute',
    ARRAY['tag' || (g % 100)::text, 'common'],
    point((g % 1000)::double precision, (g / 1000)::double precision),
    repeat(md5(g::text), 3)
FROM generate_series(1, 240000) AS source(g);

ANALYZE performance.index_cases_02;

SELECT
    count(*) AS total_rows,
    count(*) FILTER (WHERE status = 'pending') AS pending_rows,
    pg_size_pretty(pg_relation_size('performance.index_cases_02')) AS table_size
FROM performance.index_cases_02;

SELECT name, setting, unit
FROM pg_settings
WHERE name IN (
    'max_parallel_workers_per_gather',
    'enable_seqscan',
    'enable_indexscan',
    'enable_bitmapscan',
    'work_mem'
)
ORDER BY name;

-- Mantener comparables las mediciones de esta sesión.
SET max_parallel_workers_per_gather = 0;

CREATE TEMP TABLE index_measurements (
    scenario text NOT NULL,
    phase text NOT NULL,
    plan jsonb NOT NULL,
    result_rows bigint NOT NULL,
    result_id_sum numeric,
    index_bytes bigint,
    build_ms numeric,
    PRIMARY KEY (scenario, phase)
);

-- Esta función temporal crea, comprueba y elimina UN índice por caso.
-- Si falla, la llamada revierte sus cambios; ON_ERROR_STOP detiene el ejecutor.
CREATE FUNCTION pg_temp.check_index_case(
    case_name text,
    index_name text,
    index_ddl text,
    query_sql text
) RETURNS void
LANGUAGE plpgsql AS $function$
DECLARE
    before_plan jsonb;
    after_plan jsonb;
    before_count bigint;
    after_count bigint;
    before_sum numeric;
    after_sum numeric;
    started_at timestamptz;
    build_duration numeric;
    index_size bigint;
BEGIN
    IF to_regclass('performance.' || index_name) IS NOT NULL THEN
        RAISE EXCEPTION 'El índice % ya existe', index_name;
    END IF;

    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || query_sql
    INTO before_plan;

    EXECUTE 'SELECT count(*), sum(id) FROM (' || query_sql || ') AS result'
    INTO before_count, before_sum;

    IF before_count = 0 THEN
        RAISE EXCEPTION 'El caso % no devuelve filas', case_name;
    END IF;

    started_at := clock_timestamp();
    EXECUTE index_ddl;
    build_duration := extract(epoch FROM clock_timestamp() - started_at) * 1000;

    SELECT pg_relation_size(to_regclass('performance.' || index_name))
    INTO index_size;

    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || query_sql
    INTO after_plan;

    EXECUTE 'SELECT count(*), sum(id) FROM (' || query_sql || ') AS result'
    INTO after_count, after_sum;

    IF before_count <> after_count OR before_sum IS DISTINCT FROM after_sum THEN
        RAISE EXCEPTION 'Cambió el resultado en %', case_name;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_path_query(
            after_plan,
            '$.**."Index Name"'
        ) AS names(value)
        WHERE value #>> '{}' = index_name
    ) THEN
        RAISE EXCEPTION 'El plan no utilizó el índice %: %',
            index_name, after_plan;
    END IF;

    INSERT INTO index_measurements
    VALUES
        (case_name, 'BEFORE', before_plan, before_count, before_sum, NULL, NULL),
        (case_name, 'AFTER', after_plan, after_count, after_sum, index_size, build_duration);

    EXECUTE format('DROP INDEX performance.%I', index_name);

    IF to_regclass('performance.' || index_name) IS NOT NULL THEN
        RAISE EXCEPTION 'No se eliminó el índice %', index_name;
    END IF;

    RAISE NOTICE 'PASS: %; índice utilizado, resultado conservado e índice eliminado',
        case_name;
END
$function$;

\echo 'CASO 1: B-tree para igualdad selectiva.'
SELECT pg_temp.check_index_case(
    '01 B-tree',
    'p7_02_btree_idx',
    'CREATE INDEX p7_02_btree_idx ON performance.index_cases_02 USING btree (customer_id)',
    'SELECT id FROM performance.index_cases_02 WHERE customer_id = 4242'
);

\echo 'CASO 2: compuesto, igualdad en primera columna y rango en segunda.'
SELECT pg_temp.check_index_case(
    '02 Compuesto',
    'p7_02_composite_idx',
    'CREATE INDEX p7_02_composite_idx ON performance.index_cases_02 (customer_id, created_at)',
    'SELECT id FROM performance.index_cases_02
     WHERE customer_id = 4242
       AND created_at >= timestamp ''2026-01-01'' + interval ''100000 minutes'''
);

\echo 'CASO 3: parcial, la consulta incluye el predicado del índice.'
SELECT pg_temp.check_index_case(
    '03 Parcial',
    'p7_02_partial_idx',
    'CREATE INDEX p7_02_partial_idx ON performance.index_cases_02 (customer_id)
     WHERE status = ''pending''',
    'SELECT id FROM performance.index_cases_02
     WHERE status = ''pending'' AND customer_id = 4241'
);

\echo 'CASO 4: GIN para pertenencia en un array.'
SELECT pg_temp.check_index_case(
    '04 GIN',
    'p7_02_gin_idx',
    'CREATE INDEX p7_02_gin_idx ON performance.index_cases_02 USING gin (tags)',
    'SELECT id FROM performance.index_cases_02 WHERE tags @> ARRAY[''tag42'']'
);

\echo 'CASO 5: GiST para los diez puntos más cercanos.'
SELECT pg_temp.check_index_case(
    '05 GiST',
    'p7_02_gist_idx',
    'CREATE INDEX p7_02_gist_idx ON performance.index_cases_02 USING gist (location)',
    'SELECT id FROM performance.index_cases_02
     ORDER BY location <-> point(100.1, 100.2) LIMIT 10'
);

\echo 'CASO 6: BRIN para un rango temporal con orden físico correlacionado.'
SELECT pg_temp.check_index_case(
    '06 BRIN',
    'p7_02_brin_idx',
    'CREATE INDEX p7_02_brin_idx ON performance.index_cases_02
     USING brin (created_at) WITH (pages_per_range = 16)',
    'SELECT id FROM performance.index_cases_02
     WHERE created_at >= timestamp ''2026-01-01'' + interval ''120000 minutes''
       AND created_at < timestamp ''2026-01-01'' + interval ''120050 minutes'''
);

\echo 'RESUMEN: nodo raíz, resultados, buffers, tiempo y tamaño del índice.'
SELECT
    scenario,
    phase,
    plan #>> '{0,Plan,Node Type}' AS root_node,
    result_rows,
    plan #>> '{0,Plan,Shared Hit Blocks}' AS shared_hit,
    plan #>> '{0,Plan,Shared Read Blocks}' AS shared_read,
    plan #>> '{0,Execution Time}' AS execution_ms,
    pg_size_pretty(index_bytes) AS index_size,
    round(build_ms, 3) AS build_ms
FROM index_measurements
ORDER BY scenario, CASE phase WHEN 'BEFORE' THEN 1 ELSE 2 END;

\echo 'PLANES COMPLETOS AFTER: observar nodos hijos, rechecks y buffers.'
SELECT scenario, jsonb_pretty(plan) AS execution_plan
FROM index_measurements
WHERE phase = 'AFTER'
ORDER BY scenario;

DO $check$
BEGIN
    IF (SELECT count(*) FROM index_measurements) <> 12 THEN
        RAISE EXCEPTION 'No se completaron las seis comparaciones';
    END IF;

    IF (SELECT count(*) FROM performance.index_cases_02) <> 240000 THEN
        RAISE EXCEPTION 'Se alteró la cantidad de datos';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_class AS c
        JOIN pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = 'performance'
          AND c.relname IN (
              'p7_02_btree_idx',
              'p7_02_composite_idx',
              'p7_02_partial_idx',
              'p7_02_gin_idx',
              'p7_02_gist_idx',
              'p7_02_brin_idx'
          )
    ) THEN
        RAISE EXCEPTION 'Quedaron índices experimentales';
    END IF;

    RAISE NOTICE 'PASS: seis casos completos; datos conservados e índices eliminados';
END
$check$;

RESET max_parallel_workers_per_gather;
SHOW max_parallel_workers_per_gather;
SQL

echo ""
echo "PASS: ESCENARIO 07.02 COMPLETADO"
echo "Datos conservados: performance.index_cases_02"
POSTGRES
