#!/bin/bash
set -euo pipefail
exec 2>&1

ROOT=/tmp/nobleprog-p6-lab
MODE=${1:-manual}

case "$MODE" in
    manual|validate) ;;
    *)
        echo "Uso: 00-start-container.sh manual|validate"
        exit 1
        ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: el lanzador requiere root dentro del contenedor."
    exit 1
fi

if [ -e "$ROOT" ]; then
    echo "ERROR: el directorio del laboratorio ya existe."
    exit 1
fi

for script in /tmp/p6-scripts/*.sh; do
    /usr/bin/bash -n "$script"
done

mkdir -p "$ROOT/evidence" "$ROOT/socket"
chown -R postgres:postgres "$ROOT"

if [ "$MODE" = validate ]; then
    exec /usr/sbin/runuser -u postgres -- \
        /usr/bin/bash /tmp/p6-scripts/run-validation.sh
fi

/usr/sbin/runuser -u postgres -- \
    /usr/bin/bash /tmp/p6-scripts/00-prepare-lab.sh

echo "LABORATORIO MANUAL PREPARADO"
echo "La instancia permanece disponible para las sesiones psql."
echo "Ejecutar 99-cleanup-lab.sh antes de eliminar el contenedor."

exec /usr/bin/sleep infinity
