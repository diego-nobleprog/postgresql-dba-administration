#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/00-env.sh"

ARCH="$P5_ROOT/archive"

test -s "$P5_ROOT/metadata/target-time.txt" || {
  echo "Falta la preparacion del incidente."
  exit 1
}

sql() {
  psql -X -A -t -v ON_ERROR_STOP=1 -c "$1"
}

RESULT=$(sql "SELECT COALESCE(to_regclass('backups.pagos')::text,'AUSENTE');")

if [[ "$RESULT" != "AUSENTE" ]]; then
  echo "El DROP TABLE no se ha confirmado."
  exit 1
fi

SEGMENT=$(sql 'SELECT pg_walfile_name(pg_current_wal_lsn());')
sql 'SELECT pg_switch_wal();' >/dev/null

FOUND=0

for n in $(seq 1 60); do
  if [[ -s "$ARCH/$SEGMENT" ]]; then
    FOUND=1
    break
  fi
  sleep 1
done

if [[ "$FOUND" != "1" ]]; then
  echo "No se archivo el WAL posterior al DROP TABLE." >&2
  exit 1
fi

printf '%s\n' "$SEGMENT" > "$P5_ROOT/metadata/drop-segment.txt"

echo "PASS: tabla eliminada en el origen."
echo "PASS: WAL archivado: $SEGMENT"
echo "El archivo WAL esta disponible para PITR."