#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/00-env.sh"

BASE="$P5_ROOT/base/physical"
META="$P5_ROOT/metadata"

test -s "$BASE/backup_manifest" || {
  echo "No existe el backup fisico de 05.02."
  exit 1
}

if [[ -e "$META/target-time.txt" ]]; then
  echo "El incidente ya fue preparado."
  exit 1
fi

sql() {
  psql -X -A -t -v ON_ERROR_STOP=1 -c "$1"
}

COUNT=$(sql 'SELECT count(*) FROM backups.pagos;')

if [[ "$COUNT" != "3" ]]; then
  echo "Se esperaban tres pagos antes del incidente."
  exit 1
fi

sql "INSERT INTO backups.pagos
VALUES (201,1,450.00,'DESPUES_BACKUP_A');" >/dev/null

LSN_A=$(sql "SELECT pg_create_restore_point('p5_punto_a');")

sql "INSERT INTO backups.pagos
VALUES (202,2,650.00,'DESPUES_BACKUP_B');" >/dev/null

LSN_B=$(sql "SELECT pg_create_restore_point('p5_antes_error');")

TIME_TARGET=$(sql 'SELECT clock_timestamp()::text;')

printf '%s\n' "$LSN_A" > "$META/lsn-a.txt"
printf '%s\n' "$LSN_B" > "$META/lsn-b.txt"
printf '%s\n' "$TIME_TARGET" > "$META/target-time.txt"

COUNT=$(sql 'SELECT count(*) FROM backups.pagos;')

if [[ "$COUNT" != "5" ]]; then
  echo "Los cinco pagos no estan disponibles."
  exit 1
fi

echo "BEFORE: cinco pagos confirmados."
echo "Punto A: $LSN_A"
echo "Punto B: $LSN_B"
echo "Tiempo PITR: $TIME_TARGET"

psql -X -v ON_ERROR_STOP=1 -c "
SELECT id, cliente_id, monto, estado
FROM backups.pagos
ORDER BY id;"

echo "Ahora ejecute el DROP TABLE desde psql interactivo."
echo "No vuelva a ejecutar este preparador."