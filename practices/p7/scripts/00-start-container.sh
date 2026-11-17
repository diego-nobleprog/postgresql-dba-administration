#!/bin/bash
set -Eeuo pipefail
exec 2>&1
export PATH=/usr/bin:/usr/sbin:/bin:/sbin

R=/tmp/nobleprog-p7-integrado
S=/tmp/p7-integrado-scripts
MODE=${1:-manual}

case "$MODE" in manual|validate) ;; *) exit 1;; esac

test "$(id -u)" -eq 0
test ! -e "$R"

for file in "$S"/*.sh; do
    bash -n "$file"
done

mkdir -p "$R"
chown postgres:postgres "$R"

if [ "$MODE" = validate ]; then
    exec /usr/sbin/runuser -u postgres -- \
        timeout --signal=TERM --kill-after=30s 600 \
        bash "$S/run-validation.sh"
fi

if ! /usr/sbin/runuser -u postgres -- \
    bash "$S/00-prepare-lab.sh"; then
    /usr/sbin/runuser -u postgres -- \
        bash "$S/99-cleanup-lab.sh" || exit 1
    exit 1
fi

echo 'LABORATORIO INTEGRADO PREPARADO; EJERCICIOS SIN EJECUTAR.'
exec sleep infinity
