#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/00-check-lab.sh"
set -Eeuo pipefail
exec > >(tee /tmp/p7-04-results.txt) 2>&1
trap 'echo "FAIL: escenario 07.04 interrumpido en línea $LINENO"; exit 1' ERR

echo "ESCENARIO 07.04 - PARALLEL QUERY"
date -u

echo "LIMITES Y CONTADORES CPU DEL CONTENEDOR: BEFORE"
for file in /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.stat; do
    if [ -f "$file" ]; then
        echo "$file"
        cat "$file"
    fi
done

runuser -u postgres -- /bin/bash <<'POSTGRES'
set -Eeuo pipefail
export PGHOST=/tmp/nobleprog-p7-lab/socket
export PGPORT=5432
export PGUSER=postgres
export PGDATABASE=nobleprog_performance_scenarios
unset PGOPTIONS

LAB=/tmp/nobleprog-p7-lab

psql -X -v ON_ERROR_STOP=1 <<'SQL'
\pset pager off

DO $check$
BEGIN
    IF to_regclass('performance.parallel_data_04') IS NOT NULL
       OR to_regclass('performance.parallel_results_04') IS NOT NULL
       OR to_regclass('performance.parallel_settings_04') IS NOT NULL THEN
        RAISE EXCEPTION 'Ya existen recursos de 07.04. No sobrescribir.';
    END IF;
END
$check$;

CREATE TABLE performance.parallel_settings_04 AS
SELECT name, current_setting(name) AS value
FROM pg_settings
WHERE name IN (
    'max_parallel_workers_per_gather',
    'max_parallel_workers',
    'max_worker_processes',
    'parallel_setup_cost',
    'parallel_tuple_cost',
    'min_parallel_table_scan_size',
    'work_mem'
);

TABLE performance.parallel_settings_04;

CREATE TABLE performance.parallel_data_04 (
    id bigint PRIMARY KEY,
    payload text NOT NULL
);

INSERT INTO performance.parallel_data_04
SELECT g, repeat(md5(g::text), 3)
FROM generate_series(1, 600000) AS source(g);

ANALYZE performance.parallel_data_04;

CREATE TABLE performance.parallel_results_04 (
    case_name text PRIMARY KEY,
    document jsonb NOT NULL
);

SELECT
    count(*) AS loaded_rows,
    pg_size_pretty(pg_relation_size('performance.parallel_data_04')) AS table_size
FROM performance.parallel_data_04;
SQL

QUERY='SELECT count(*) AS row_count, sum(id) AS id_sum, sum(length(md5(payload))) AS digest_length_sum FROM performance.parallel_data_04'

measure() {
    local case_name="$1"
    local workers="$2"
    local file="$LAB/04-$case_name.json"

    echo ""
    echo "MEDICION: $case_name; max_parallel_workers_per_gather=$workers"

    PGOPTIONS="-c max_parallel_workers_per_gather=$workers" \
        psql -X -qAt -v ON_ERROR_STOP=1 \
        -c "EXPLAIN (ANALYZE, BUFFERS, SETTINGS, TIMING OFF, FORMAT JSON) $QUERY" \
        > "$file"

    # Leer el JSON del archivo sin convertirlo mediante texto de PowerShell.
    psql -X -v ON_ERROR_STOP=1 \
        -v case_name="$case_name" -v plan_file="$file" <<'SQL'
INSERT INTO performance.parallel_results_04
VALUES (:'case_name', pg_read_file(:'plan_file')::jsonb);
SQL

    # Verificar también los valores calculados por la consulta directa.
    local actual
    actual=$(
        PGOPTIONS="-c max_parallel_workers_per_gather=$workers" \
            psql -X -qAt -v ON_ERROR_STOP=1 -c "$QUERY"
    )

    echo "Resultado directo: $actual"

    if [ "$actual" != '600000|180000300000|19200000' ]; then
        echo "FAIL: resultado inesperado en $case_name"
        return 1
    fi

    echo "PASS: resultado correcto en $case_name"
}

# Alternar el orden para no favorecer siempre la segunda configuración.
measure serial_1 0
measure parallel_1 2
measure parallel_2 2
measure serial_2 0

echo ""
echo "CONSULTA SELECTIVA: permitir paralelismo no obliga a utilizarlo."
PGOPTIONS='-c max_parallel_workers_per_gather=2' \
    psql -X -qAt -v ON_ERROR_STOP=1 \
    -c 'EXPLAIN (ANALYZE, BUFFERS, SETTINGS, TIMING OFF, FORMAT JSON) SELECT id FROM performance.parallel_data_04 WHERE id = 4242' \
    > "$LAB/04-selective.json"

psql -X -v ON_ERROR_STOP=1 <<'SQL'
\pset pager off

INSERT INTO performance.parallel_results_04
VALUES (
    'selective',
    pg_read_file('/tmp/nobleprog-p7-lab/04-selective.json')::jsonb
);

CREATE TEMP VIEW parallel_nodes AS
WITH RECURSIVE nodes AS (
    SELECT case_name, document -> 0 -> 'Plan' AS node
    FROM performance.parallel_results_04
    UNION ALL
    SELECT parent.case_name, child.value
    FROM nodes parent
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(parent.node -> 'Plans', '[]'::jsonb)
    ) child(value)
)
SELECT * FROM nodes;

\echo 'RESUMEN: resultados, tiempo y trabajadores reales.'
SELECT
    r.case_name,
    r.document #>> '{0,Plan,Node Type}' AS root_node,
    r.document #>> '{0,Plan,Actual Rows}' AS root_rows,
    r.document #>> '{0,Execution Time}' AS execution_ms,
    r.document #>> '{0,Plan,Shared Hit Blocks}' AS shared_hit,
    r.document #>> '{0,Plan,Shared Read Blocks}' AS shared_read,
    (
        SELECT max((node ->> 'Workers Planned')::integer)
        FROM parallel_nodes n WHERE n.case_name = r.case_name
    ) AS workers_planned,
    (
        SELECT max((node ->> 'Workers Launched')::integer)
        FROM parallel_nodes n WHERE n.case_name = r.case_name
    ) AS workers_launched
FROM performance.parallel_results_04 r
ORDER BY CASE r.case_name
    WHEN 'serial_1' THEN 1
    WHEN 'parallel_1' THEN 2
    WHEN 'parallel_2' THEN 3
    WHEN 'serial_2' THEN 4
    ELSE 5
END;

\echo 'NODOS: agregación parcial, Gather y participación de procesos.'
SELECT
    case_name,
    node ->> 'Node Type' AS node_type,
    node ->> 'Partial Mode' AS partial_mode,
    node ->> 'Parallel Aware' AS parallel_aware,
    node ->> 'Actual Rows' AS rows_per_loop,
    node ->> 'Actual Loops' AS loops,
    node ->> 'Workers Planned' AS workers_planned,
    node ->> 'Workers Launched' AS workers_launched
FROM parallel_nodes
ORDER BY case_name, node_type;

DO $check$
BEGIN
    IF (SELECT count(*) FROM performance.parallel_results_04) <> 5 THEN
        RAISE EXCEPTION 'Faltan mediciones';
    END IF;

    IF EXISTS (
        SELECT 1 FROM parallel_nodes
        WHERE case_name LIKE 'serial_%'
          AND node ->> 'Node Type' IN ('Gather', 'Gather Merge')
    ) THEN
        RAISE EXCEPTION 'Se obtuvo un Gather en una ejecución serial';
    END IF;

    IF (
        SELECT count(DISTINCT case_name)
        FROM parallel_nodes
        WHERE case_name LIKE 'parallel_%'
          AND (node ->> 'Workers Launched')::integer >= 1
    ) <> 2 THEN
        RAISE EXCEPTION 'No se lanzaron trabajadores en ambas pruebas paralelas';
    END IF;

    IF EXISTS (
        SELECT 1 FROM parallel_nodes
        WHERE case_name = 'selective'
          AND node ->> 'Node Type' IN ('Gather', 'Gather Merge')
    ) THEN
        RAISE EXCEPTION 'La consulta selectiva produjo un Gather inesperado';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM parallel_nodes
        WHERE case_name = 'selective'
          AND node ->> 'Index Name' = 'parallel_data_04_pkey'
    ) THEN
        RAISE EXCEPTION 'La consulta selectiva no utilizó la clave primaria';
    END IF;

    IF EXISTS (
        SELECT 1 FROM performance.parallel_settings_04
        WHERE current_setting(name) <> value
    ) THEN
        RAISE EXCEPTION 'La configuración final no coincide con la inicial';
    END IF;

    IF (SELECT count(*) FROM performance.parallel_data_04) <> 600000 THEN
        RAISE EXCEPTION 'Se alteró la cantidad de datos';
    END IF;

    RAISE NOTICE 'PASS: serial, paralelismo real, consulta selectiva y configuración comprobados';
END
$check$;

\echo 'CONFIGURACION FINAL: PGOPTIONS afectó solo a cada conexión de medición.'
SELECT name, value AS original_value, current_setting(name) AS final_value
FROM performance.parallel_settings_04
ORDER BY name;

\echo 'PLANES JSON COMPLETOS'
\pset format unaligned
\pset tuples_only on
SELECT jsonb_build_object('case', case_name, 'explain', document)
FROM performance.parallel_results_04
ORDER BY case_name;
SQL

echo ""
echo "PASS: ESCENARIO 07.04 COMPLETADO"
echo "Datos, planes y configuración inicial conservados en tablas performance.*_04"
POSTGRES

echo ""
echo "CONTADORES CPU DEL CONTENEDOR: AFTER"
if [ -f /sys/fs/cgroup/cpu.stat ]; then
    cat /sys/fs/cgroup/cpu.stat
fi
