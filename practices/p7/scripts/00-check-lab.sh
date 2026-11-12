#!/bin/bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "FAIL: ejecutar este script como root dentro del contenedor P7."
    exit 1
fi

LAB=/tmp/nobleprog-p7-lab

if [ ! -f "$LAB/.p7-definitivo" ]; then
    echo "FAIL: falta la marca del laboratorio definitivo P7."
    exit 1
fi

unset PGOPTIONS PGSERVICE PGSERVICEFILE
export PGHOST="$LAB/socket"
export PGPORT=5432
export PGUSER=postgres
export PGDATABASE=nobleprog_performance_scenarios

actual_data=$(
    runuser -u postgres -- psql -X -qAt -v ON_ERROR_STOP=1 \
        -c 'SHOW data_directory'
)

if [ "$actual_data" != "$LAB/data" ]; then
    echo "FAIL: la conexión no corresponde al clúster P7."
    exit 1
fi
