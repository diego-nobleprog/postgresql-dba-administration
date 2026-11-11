#!/bin/bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/00-env.sh"

if [ "$(id -un)" != postgres ]; then
    echo "ERROR: ejecutar como usuario postgres."
    exit 1
fi

trap 'printf "ERROR: linea=%s comando=%s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
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


printf '\nCOMPROBACIONES DEL SCRIPT: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "PREPARACION COMPLETADA. PostgreSQL permanece iniciado."
