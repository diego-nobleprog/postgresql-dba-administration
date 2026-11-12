#!/bin/bash
set -Eeuo pipefail

RESULTS=/tmp/p7-preparation-results.txt
exec > >(tee "$RESULTS") 2>&1
trap 'echo "FAIL: preparación interrumpida en línea $LINENO"; exit 1' ERR

echo "PREPARACION P7"
date -u
postgres --version

LAB=/tmp/nobleprog-p7-lab

if [ -e "$LAB" ]; then
    echo "FAIL: el directorio del laboratorio ya existe."
    exit 1
fi

install -d -m 700 -o postgres -g postgres "$LAB"

runuser -u postgres -- /bin/bash <<'POSTGRES'
set -Eeuo pipefail

LAB=/tmp/nobleprog-p7-lab
DATA="$LAB/data"
SOCKET="$LAB/socket"

mkdir -m 700 "$SOCKET"

initdb -D "$DATA" --encoding=UTF8 --locale=C --auth-local=trust --auth-host=reject > "$LAB/initdb.log"

cat >> "$DATA/postgresql.conf" <<'CONFIG'

# Configuración exclusiva del laboratorio P7.
listen_addresses = ''
port = 5432
unix_socket_directories = '/tmp/nobleprog-p7-lab/socket'
shared_preload_libraries = 'pg_stat_statements'
compute_query_id = on
pg_stat_statements.track = all
track_io_timing = on
track_wal_io_timing = on
shared_buffers = '256MB'
work_mem = '4MB'
maintenance_work_mem = '64MB'
max_connections = 30
max_worker_processes = 8
max_parallel_workers = 4
max_parallel_workers_per_gather = 2
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql.log'
log_line_prefix = '%m [%p] %u@%d '
log_lock_waits = on
deadlock_timeout = '1s'
CONFIG

pg_ctl -D "$DATA" -l "$LAB/startup.log" -w start

export PGHOST="$SOCKET"
export PGPORT=5432
export PGUSER=postgres
export PGDATABASE=postgres

createdb nobleprog_performance_scenarios
export PGDATABASE=nobleprog_performance_scenarios

psql -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION pg_stat_statements;
CREATE SCHEMA performance;

SELECT version();
SELECT current_database(), current_user;
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'pg_stat_statements';

SELECT name, setting, unit, pending_restart
FROM pg_settings
WHERE name IN (
    'shared_preload_libraries',
    'compute_query_id',
    'track_io_timing',
    'track_wal_io_timing',
    'shared_buffers',
    'work_mem',
    'max_connections',
    'max_worker_processes',
    'max_parallel_workers',
    'max_parallel_workers_per_gather',
    'listen_addresses',
    'unix_socket_directories'
)
ORDER BY name;

DO $checks$
BEGIN
    IF current_setting('server_version_num')::integer / 10000 <> 18 THEN
        RAISE EXCEPTION 'Se requiere PostgreSQL 18';
    END IF;

    IF current_setting('shared_preload_libraries') <> 'pg_stat_statements' THEN
        RAISE EXCEPTION 'pg_stat_statements no está precargado';
    END IF;

    IF current_setting('track_io_timing') <> 'on' THEN
        RAISE EXCEPTION 'track_io_timing no está activo';
    END IF;

    IF current_setting('listen_addresses') <> '' THEN
        RAISE EXCEPTION 'El servidor debe utilizar exclusivamente el socket local';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_namespace WHERE nspname = 'performance'
    ) THEN
        RAISE EXCEPTION 'No existe el esquema performance';
    END IF;

    RAISE NOTICE 'PASS: versión, precarga, medición de I/O, socket y esquema';
END
$checks$;

-- Generar una consulta identificable y comprobar su registro.
SELECT count(*) AS objetos_del_catalogo
FROM pg_catalog.pg_class;

DO $checks$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_stat_statements
        WHERE dbid = (
            SELECT oid FROM pg_database
            WHERE datname = current_database()
        )
        AND query LIKE 'SELECT count(*) AS objetos_del_catalogo%'
        AND calls >= 1
    ) THEN
        RAISE EXCEPTION 'No se encontró la consulta de prueba en pg_stat_statements';
    END IF;

    RAISE NOTICE 'PASS: pg_stat_statements registra consultas';
END
$checks$;

SELECT query, calls, rows, total_exec_time, shared_blks_hit, shared_blks_read
FROM pg_stat_statements
WHERE dbid = (
    SELECT oid FROM pg_database WHERE datname = current_database()
)
AND query LIKE 'SELECT count(*) AS objetos_del_catalogo%';
SQL

pg_isready -h "$SOCKET" -p 5432 -d "$PGDATABASE"

echo ""
echo "PASS: PREPARACION P7 COMPLETADA"
echo "Base: nobleprog_performance_scenarios"
echo "Socket: $SOCKET"
echo "Datos: $DATA"
POSTGRES
