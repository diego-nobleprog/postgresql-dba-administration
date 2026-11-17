#!/bin/bash
source /tmp/p7-integrado-scripts/00-env.sh

TAG=${1:-inicial}
case "$TAG" in inicial|restaurado) ;; *) exit 1;; esac

test "$(id -un)" = postgres
test ! -e "$R/A"
test ! -e "$R/B"
mkdir -p "$E" "$R/socket"

initdb -D "$R/A" --auth-local=trust --auth-host=trust \
    --encoding=UTF8 --no-locale > "$E/initdb-$TAG.log" 2>&1

cat >> "$R/A/postgresql.conf" <<CONF
listen_addresses='127.0.0.1'
port=5547
unix_socket_directories='$R/socket'
shared_buffers='128MB'
work_mem='4MB'
max_connections=20
wal_level=replica
max_wal_senders=4
max_replication_slots=4
max_slot_wal_keep_size='512MB'
shared_preload_libraries='pg_stat_statements'
compute_query_id=on
track_io_timing=on
hot_standby=on
CONF

pg_ctl -D "$R/A" -l "$E/A-$TAG.log" -w -t 60 start

psql -X -h 127.0.0.1 -p 5547 -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "CREATE DATABASE $DB"

sql 5547 -e -f "$S/00-load-data.sql"

pg_basebackup \
    -d 'host=127.0.0.1 port=5547 user=postgres application_name=integrado_B' \
    -D "$R/B" -X stream -R -C -S integrado_b --checkpoint=fast

printf '\nport=5548\n' >> "$R/B/postgresql.conf"

pg_ctl -D "$R/B" -l "$E/B-$TAG.log" -w -t 60 start

guard 5547 A
guard 5548 B
sync_replica

check 'A principal' 5547 'SELECT pg_is_in_recovery()' f
check 'B standby' 5548 'SELECT pg_is_in_recovery()' t
check 'Carga inicial A' 5547 \
    'SELECT count(*) FROM negocio.pedidos' 50004
check 'Carga inicial B' 5548 \
    'SELECT count(*) FROM negocio.pedidos' 50004
check 'Total inicial A' 5547 "$total_sql" 900
check 'Total inicial B' 5548 "$total_sql" 900
check 'Indice experimental ausente' 5547 \
    "SELECT to_regclass('negocio.pedidos_estado_fecha_idx') IS NULL" t
