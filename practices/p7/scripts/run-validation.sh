#!/bin/bash
set -Eeuo pipefail

SCRIPTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPTS/00-check-lab.sh"

EVIDENCE=/tmp/nobleprog-p7-lab/validation-evidence
mkdir -m 700 "$EVIDENCE"
exec > >(tee "$EVIDENCE/validation.txt") 2>&1

finish() {
    code=$?
    trap - EXIT
    set +e

    if [ "$code" -ne 0 ]; then
        echo "FAIL: validación interrumpida; conservar el contenedor."
        if [ -e /tmp/nobleprog-p7-lab/data/postmaster.pid ]; then
            runuser -u postgres -- pg_ctl \
                -D /tmp/nobleprog-p7-lab/data -m fast -w stop
        fi
    fi

    exit "$code"
}
trap finish EXIT

scripts=(
    01-query-diagnosis.sh
    02-indexes.sh
    03-joins-sort-aggregate.sh
    04-parallel-query.sh
    05-locks-deadlocks.sh
    06-troubleshooting-benchmark.sh
)

for script in "${scripts[@]}"; do
    number=${script:0:2}
    log="$EVIDENCE/$number-results.txt"

    bash "$SCRIPTS/$script" 2>&1 | tee "$log"

    if ! grep -Fxq "PASS: ESCENARIO 07.$number COMPLETADO" "$log"; then
        echo "FAIL: falta confirmación final de $script"
        exit 1
    fi

    echo "$number: PASS"
done

bash "$SCRIPTS/99-cleanup-lab.sh"

echo "ESCENARIOS COMPLETADOS: 6"
echo "TOTAL FAIL: 0"
echo "RESULTADO: VALIDACION P7 EXITOSA"
echo "=== FIN VALIDACION P7 ==="
