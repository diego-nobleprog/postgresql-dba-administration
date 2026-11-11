#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/00-env.sh"

BASE="$P5_ROOT/base/physical"
DEST="$P5_ROOT/recover/time"
ARCH="$P5_ROOT/archive"
META="$P5_ROOT/metadata"

test -s "$META/drop-segment.txt" || {
  echo "Falta finalizar el incidente."
  exit 1
}

if [[ -e "$DEST" ]]; then
  echo "Ya existe la recuperacion PITR por tiempo."
  exit 1
fi

TIME_TARGET=$(cat "$META/target-time.txt")

cp -a "$BASE" "$DEST"
touch "$DEST/recovery.signal"

cat >> "$DEST/postgresql.auto.conf" <<EOF
restore_command = 'cp $ARCH/%f %p'
recovery_target_timeline = 'current'
recovery_target_time = '$TIME_TARGET'
recovery_target_action = 'promote'
EOF

pg_ctl -D "$DEST" \
  -l "$P5_ROOT/log/recover-time.log" \
  -o "-c port=55433 -c archive_mode=off" \
  -w start

STATE=t

for n in $(seq 1 90); do
  STATE=$(psql -X -A -t -v ON_ERROR_STOP=1 -p 55433 \
    -c 'SELECT pg_is_in_recovery();' 2>/dev/null || true)

  if [[ "$STATE" == "f" ]]; then
    break
  fi
  sleep 1
done

if [[ "$STATE" != "f" ]]; then
  echo "La instancia no termino la recuperacion." >&2
  exit 1
fi

COUNT=$(psql -X -A -t -v ON_ERROR_STOP=1 -p 55433 \
  -c 'SELECT count(*) FROM backups.pagos;')

if [[ "$COUNT" != "5" ]]; then
  echo "PITR no recupero los cinco pagos esperados."
  exit 1
fi

echo "PITR completado."
echo "Target: $TIME_TARGET"
echo "Pagos recuperados: $COUNT"
echo "pg_is_in_recovery: $STATE"
echo "Instancia recuperada disponible en puerto interno 55433."

psql -X -v ON_ERROR_STOP=1 -p 55433 -c "
SELECT id, cliente_id, monto, estado
FROM backups.pagos
ORDER BY id;"