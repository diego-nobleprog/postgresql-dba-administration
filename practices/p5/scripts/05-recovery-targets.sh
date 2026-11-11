#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/00-env.sh"

BASE="$P5_ROOT/base/physical"
ARCH="$P5_ROOT/archive"
META="$P5_ROOT/metadata"
NAMED="$P5_ROOT/recover/name"
LSNDIR="$P5_ROOT/recover/lsn"

test -s "$META/lsn-b.txt" || {
  echo "Faltan los recovery targets."
  exit 1
}

test -f "$P5_ROOT/recover/time/postmaster.pid" || {
  echo "Primero ejecute la recuperacion por tiempo de 05.04."
  exit 1
}

if [[ -e "$NAMED" || -e "$LSNDIR" ]]; then
  echo "Ya existen recuperaciones por nombre o LSN."
  exit 1
fi

LSN_B=$(cat "$META/lsn-b.txt")

wait_state() {
  local port="$1"
  local expected="$2"
  local n state

  for n in $(seq 1 90); do
    if [[ "$expected" == "paused" ]]; then
      state=$(psql -X -A -t -p "$port" \
        -c 'SELECT pg_get_wal_replay_pause_state();' 2>/dev/null || true)
    else
      state=$(psql -X -A -t -p "$port" \
        -c 'SELECT pg_is_in_recovery();' 2>/dev/null || true)
    fi

    if [[ "$state" == "$expected" ]]; then
      return 0
    fi

    sleep 1
  done

  echo "Recovery timeout: puerto=$port estado=$state" >&2
  return 1
}

cp -a "$BASE" "$NAMED"
touch "$NAMED/recovery.signal"

cat >> "$NAMED/postgresql.auto.conf" <<EOF
restore_command = 'cp $ARCH/%f %p'
recovery_target_timeline = 'current'
recovery_target_name = 'p5_punto_a'
recovery_target_action = 'pause'
EOF

pg_ctl -D "$NAMED" \
  -l "$P5_ROOT/log/recover-name.log" \
  -o "-c port=55434 -c archive_mode=off" \
  -w start

wait_state 55434 paused

COUNT_NAME=$(psql -X -A -t -v ON_ERROR_STOP=1 -p 55434 \
  -c 'SELECT count(*) FROM backups.pagos;')

if [[ "$COUNT_NAME" != "4" ]]; then
  echo "El target nombrado no produjo cuatro pagos."
  exit 1
fi

echo "PASS NAME: cuatro pagos, recovery en pausa."

cp -a "$BASE" "$LSNDIR"
touch "$LSNDIR/recovery.signal"

cat >> "$LSNDIR/postgresql.auto.conf" <<EOF
restore_command = 'cp $ARCH/%f %p'
recovery_target_timeline = 'current'
recovery_target_lsn = '$LSN_B'
recovery_target_action = 'promote'
EOF

pg_ctl -D "$LSNDIR" \
  -l "$P5_ROOT/log/recover-lsn.log" \
  -o "-c port=55435 -c archive_mode=off" \
  -w start

wait_state 55435 f

COUNT_LSN=$(psql -X -A -t -v ON_ERROR_STOP=1 -p 55435 \
  -c 'SELECT count(*) FROM backups.pagos;')

if [[ "$COUNT_LSN" != "5" ]]; then
  echo "El target LSN no produjo cinco pagos."
  exit 1
fi

echo "PASS LSN: cinco pagos recuperados."

SOURCE_TLI=$(psql -X -A -t -v ON_ERROR_STOP=1 \
  -c "SELECT substring(pg_walfile_name(pg_current_wal_lsn()),1,8);")

TIME_TLI=$(psql -X -A -t -v ON_ERROR_STOP=1 -p 55433 \
  -c "SELECT substring(pg_walfile_name(pg_current_wal_lsn()),1,8);")

if [[ "$SOURCE_TLI" == "$TIME_TLI" ]]; then
  echo "No se observo una timeline diferente." >&2
  exit 1
fi

test -s "$P5_ROOT/recover/time/pg_wal/$TIME_TLI.history" || {
  echo "No existe el archivo history de la nueva timeline."
  exit 1
}

echo "Timeline origen: $SOURCE_TLI"
echo "Timeline PITR: $TIME_TLI"
echo "History file: $TIME_TLI.history"

psql -X -v ON_ERROR_STOP=1 -p 55433 \
  -c "INSERT INTO backups.pagos
      VALUES (303,1,900.00,'NUEVA_TIMELINE');"

COUNT_TIME=$(psql -X -A -t -v ON_ERROR_STOP=1 -p 55433 \
  -c 'SELECT count(*) FROM backups.pagos;')

COUNT_NAME_AFTER=$(psql -X -A -t -v ON_ERROR_STOP=1 -p 55434 \
  -c 'SELECT count(*) FROM backups.pagos;')

if [[ "$COUNT_TIME" != "6" || "$COUNT_NAME_AFTER" != "4" ]]; then
  echo "Los estados de las recuperaciones no coinciden."
  exit 1
fi

echo "PASS: timeline recuperada con seis pagos."
echo "PASS: recuperacion nombrada conserva cuatro pagos."
echo "Las instancias quedan disponibles para inspeccion."