#!/bin/bash
set -Eeuo pipefail
export LC_ALL=C

SCRIPTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MODE=${1:-manual}

case "$MODE" in
    manual|validate) ;;
    *) echo "FAIL: modo permitido: manual o validate"; exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "FAIL: el lanzador requiere root dentro del contenedor."
    exit 1
fi

for script in "$SCRIPTS"/*.sh; do
    bash -n "$script"
done

unset PGOPTIONS PGSERVICE PGSERVICEFILE

bash "$SCRIPTS/00-prepare-lab.sh"
touch /tmp/nobleprog-p7-lab/.p7-definitivo

if [ "$MODE" = validate ]; then
    exec bash "$SCRIPTS/run-validation.sh"
fi

echo "LABORATORIO MANUAL P7 PREPARADO"
exec sleep infinity
