#!/bin/bash
set -Eeuo pipefail

SCRIPTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPTS/00-check-lab.sh"

active=$(
    runuser -u postgres -- psql -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT count(*)
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND pid <> pg_backend_pid();
SQL
)

if [ "$active" -ne 0 ]; then
    echo "FAIL: hay otras conexiones cliente. Cerrarlas antes del cierre."
    exit 1
fi

runuser -u postgres -- pg_ctl \
    -D /tmp/nobleprog-p7-lab/data -m fast -w stop

if [ -e /tmp/nobleprog-p7-lab/data/postmaster.pid ]; then
    echo "FAIL: aún existe postmaster.pid."
    exit 1
fi

echo "PASS: CLUSTER P7 DETENIDO"
echo "Datos, estadísticas y evidencias conservados dentro del contenedor."
