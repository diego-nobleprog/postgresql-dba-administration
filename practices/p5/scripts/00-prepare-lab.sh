#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/00-env.sh"

DATA="$P5_ROOT/source"

if [[ -e "$DATA" ]]; then
  echo "El cluster P5 ya existe. No se sobrescribira."
  exit 1
fi

mkdir -p \
  "$P5_ROOT/base" \
  "$P5_ROOT/restore" \
  "$P5_ROOT/recover" \
  "$P5_ROOT/logical" \
  "$P5_ROOT/archive" \
  "$P5_ROOT/metadata" \
  "$P5_ROOT/log" \
  "$PGHOST"

initdb -D "$DATA" -U postgres \
  --auth-local=trust \
  --auth-host=reject \
  --no-instructions > "$P5_ROOT/log/initdb.log" 2>&1

cat >> "$DATA/postgresql.conf" <<'EOF'
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /tmp/nobleprog-p5-lab/archive/%f && cp %p /tmp/nobleprog-p5-lab/archive/%f'
max_wal_senders = 5
listen_addresses = ''
unix_socket_directories = '/tmp/nobleprog-p5-lab/socket'
port = 55431
EOF

pg_ctl -D "$DATA" -l "$P5_ROOT/log/source.log" -w start

psql -X -v ON_ERROR_STOP=1 -d postgres \
  -c "CREATE DATABASE $PGDATABASE"

psql -X -v ON_ERROR_STOP=1 \
  -f /tmp/p5-scripts/00-load-data.sql

echo "Estado inicial:"
psql -X -v ON_ERROR_STOP=1 -c "
SELECT current_database() AS base,
       count(*) AS pagos_iniciales
FROM backups.pagos;"

echo "Configuracion de backup:"
psql -X -v ON_ERROR_STOP=1 -c "
SELECT name, setting, context, source
FROM pg_settings
WHERE name IN
('wal_level', 'archive_mode', 'archive_command', 'max_wal_senders')
ORDER BY name;"

echo "Laboratorio P5 preparado."