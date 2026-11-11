#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/00-env.sh"

ARCH="$P5_ROOT/archive"
SOURCE="$P5_ROOT/source"

sql() {
  psql -X -A -t -v ON_ERROR_STOP=1 -c "$1"
}

wait_archived() {
  local segment="$1"
  local n

  for n in $(seq 1 60); do
    if [[ -s "$ARCH/$segment" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "No se archivo el segmento $segment" >&2
  return 1
}

restore_original() {
  if [[ "${ARCHIVE_CHANGED:-0}" == "1" ]]; then
    sql 'ALTER SYSTEM RESET archive_command;' >/dev/null || true
    sql 'SELECT pg_reload_conf();' >/dev/null || true
  fi
}

trap restore_original EXIT

if [[ -f "$P5_ROOT/restore/standalone/postmaster.pid" ]]; then
  echo "Detenga primero la instancia standalone de 05.02."
  exit 1
fi

EXPECTED="test ! -f $ARCH/%f && cp %p $ARCH/%f"
ORIGINAL=$(sql 'SHOW archive_command;')

if [[ "$ORIGINAL" != "$EXPECTED" ]]; then
  echo "El comando inicial de archivado no coincide con la preparacion."
  echo "Valor observado: $ORIGINAL"
  exit 1
fi

echo "BEFORE: configuracion y estadisticas."
sql "SELECT name || '=' || setting FROM pg_settings
WHERE name IN ('wal_level','archive_mode','archive_command')
ORDER BY name;"

BEFORE=$(sql 'SELECT archived_count FROM pg_stat_archiver;')
SEGMENT=$(sql 'SELECT pg_walfile_name(pg_current_wal_lsn());')

sql 'SELECT pg_switch_wal();' >/dev/null

wait_archived "$SEGMENT"

AFTER="$BEFORE"
for n in $(seq 1 60); do
  AFTER=$(sql 'SELECT archived_count FROM pg_stat_archiver;')
  if (( AFTER > BEFORE )); then
    break
  fi
  sleep 1
done

if (( AFTER <= BEFORE )); then
  echo "El contador archived_count no avanzo." >&2
  exit 1
fi

echo "PASS archivado: $SEGMENT"
echo "archived_count antes=$BEFORE despues=$AFTER"

BEFORE_FAILURE=$(sql 'SELECT failed_count FROM pg_stat_archiver;')

sql "ALTER SYSTEM SET archive_command = '/bin/false';" >/dev/null
ARCHIVE_CHANGED=1
sql 'SELECT pg_reload_conf();' >/dev/null

for n in $(seq 1 30); do
  CURRENT=$(sql 'SHOW archive_command;')
  if [[ "$CURRENT" == '/bin/false' ]]; then
    break
  fi
  sleep 1
done

if [[ "$CURRENT" != '/bin/false' ]]; then
  echo "No se aplico el comando de fallo controlado." >&2
  exit 1
fi

FAILED_SEGMENT=$(sql 'SELECT pg_walfile_name(pg_current_wal_lsn());')
sql 'SELECT pg_switch_wal();' >/dev/null

AFTER_FAILURE="$BEFORE_FAILURE"

for n in $(seq 1 60); do
  AFTER_FAILURE=$(sql 'SELECT failed_count FROM pg_stat_archiver;')
  if (( AFTER_FAILURE > BEFORE_FAILURE )); then
    break
  fi
  sleep 1
done

if (( AFTER_FAILURE <= BEFORE_FAILURE )); then
  echo "No se observo el fallo esperado del archivador." >&2
  exit 1
fi

echo "PASS fallo controlado."
echo "failed_count antes=$BEFORE_FAILURE despues=$AFTER_FAILURE"

sql 'ALTER SYSTEM RESET archive_command;' >/dev/null
sql 'SELECT pg_reload_conf();' >/dev/null

for n in $(seq 1 30); do
  CURRENT=$(sql 'SHOW archive_command;')
  if [[ "$CURRENT" == "$ORIGINAL" ]]; then
    break
  fi
  sleep 1
done

if [[ "$CURRENT" != "$ORIGINAL" ]]; then
  echo "El comando original no fue restaurado." >&2
  exit 1
fi

wait_archived "$FAILED_SEGMENT"

ARCHIVE_CHANGED=0

echo "AFTER: archivado restaurado."
echo "Segmento recuperado: $FAILED_SEGMENT"
echo "Comando restaurado: $CURRENT"

sql "SELECT archived_count || ',' || failed_count
FROM pg_stat_archiver;"