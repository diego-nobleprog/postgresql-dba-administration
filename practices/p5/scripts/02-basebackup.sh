#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/00-env.sh"

BASE="$P5_ROOT/base/physical"
DEST="$P5_ROOT/restore/standalone"

if [[ -e "$BASE" || -e "$DEST" ]]; then
  echo "Ya existe un backup o restauracion fisica P5."
  echo "No se sobrescribiran archivos existentes."
  exit 1
fi

COUNT=$(psql -X -A -t -v ON_ERROR_STOP=1 \
  -c 'SELECT count(*) FROM backups.pagos;')

if [[ "$COUNT" != "3" ]]; then
  echo "La base no tiene los tres pagos iniciales."
  echo "La practica 05.02 requiere el estado posterior a 05.01."
  exit 1
fi

echo "BEFORE: $COUNT pagos en el origen."

pg_basebackup \
  -h "$PGHOST" \
  -p "$PGPORT" \
  -U postgres \
  -D "$BASE" \
  -Fp \
  -Xs \
  --checkpoint=fast

test -s "$BASE/backup_manifest"

pg_verifybackup "$BASE"

echo "Backup fisico verificado."

cp -a "$BASE" "$DEST"

pg_ctl -D "$DEST" \
  -l "$P5_ROOT/log/standalone.log" \
  -o "-c port=55432 -c archive_mode=off" \
  -w start

echo "Instancia restaurada en puerto interno 55432."

psql -X -v ON_ERROR_STOP=1 -p 55432 -c "
SELECT current_database(),
       pg_is_in_recovery(),
       count(*) AS pagos
FROM backups.pagos
GROUP BY 1,2;"

echo "La restauracion permanece encendida para inspeccion."
echo "Debe detenerse antes de comenzar 05.03."