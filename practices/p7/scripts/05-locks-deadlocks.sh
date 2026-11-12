#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/00-check-lab.sh"
set -Eeuo pipefail
exec > >(tee /tmp/p7-05-results.txt) 2>&1
trap 'echo "FAIL: escenario 07.05 interrumpido en línea $LINENO"; exit 1' ERR

echo "ESCENARIO 07.05 - LOCKS, WAIT EVENTS Y DEADLOCKS"
date -u

runuser -u postgres -- /bin/bash <<'POSTGRES'
set -Eeuo pipefail

export PGHOST=/tmp/nobleprog-p7-lab/socket
export PGPORT=5432
export PGUSER=postgres
export PGDATABASE=nobleprog_performance_scenarios
unset PGOPTIONS

WORK=$(mktemp -d /tmp/nobleprog-p7-lab/05-sessions-XXXXXX)
PREFIX="p7_05_$(basename "$WORK")"
APP_A="${PREFIX}_A"
APP_B="${PREFIX}_B"
export PGAPPNAME="${PREFIX}_observer"

cleanup() {
    local code=$?
    trap - EXIT
    set +e

    # Solo cerrar sesiones creadas por esta ejecución y en esta base.
    psql -X -qAt -v ON_ERROR_STOP=1 \
        -v app_a="$APP_A" -v app_b="$APP_B" <<'SQL'
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = current_database()
  AND application_name IN (:'app_a', :'app_b')
  AND pid <> pg_backend_pid();
SQL

    if [ "$code" -ne 0 ]; then
        echo "DIAGNOSTICO: logs parciales de las sesiones"
        for log in "$WORK"/*.log; do
            if [ -f "$log" ]; then
                echo "$log"
                cat "$log"
            fi
        done
    fi

    echo "Auxiliares conservados: $WORK"
    exit "$code"
}
trap cleanup EXIT

sql_value() {
    psql -X -qAt -v ON_ERROR_STOP=1 -c "$1"
}

wait_until() {
    local query="$1"
    local description="$2"
    local deadline=$((SECONDS + 25))
    local result

    while [ "$SECONDS" -lt "$deadline" ]; do
        result=$(sql_value "$query")
        if [ "$result" = "t" ]; then
            echo "PASS: $description"
            return 0
        fi
        sleep 0.2
    done

    echo "FAIL: tiempo agotado esperando $description"
    return 1
}

start_sessions() {
    local phase="$1"
    mkfifo -m 600 "$WORK/$phase-A.in" "$WORK/$phase-B.in"

    PGAPPNAME="$APP_A" psql -X -v ON_ERROR_STOP=1 -v VERBOSITY=verbose \
        < "$WORK/$phase-A.in" > "$WORK/$phase-A.log" 2>&1 &
    PID_A=$!

    exec 3>"$WORK/$phase-A.in"

    # Cerrar fd 3 en el hijo B para no conservar abierto el FIFO A.
    PGAPPNAME="$APP_B" psql -X -v ON_ERROR_STOP=1 -v VERBOSITY=verbose \
        < "$WORK/$phase-B.in" > "$WORK/$phase-B.log" 2>&1 3>&- &
    PID_B=$!

    exec 4>"$WORK/$phase-B.in"

    printf '%s\n' "SET statement_timeout = '45s'; SET idle_in_transaction_session_timeout = '90s'; SET deadlock_timeout = '5s';" >&3
    printf '%s\n' "SET statement_timeout = '45s'; SET idle_in_transaction_session_timeout = '90s'; SET deadlock_timeout = '5s';" >&4
}

finish_sessions() {
    # Las instrucciones se encolan aunque una sesión esté esperando un lock.
    printf '%s\n' 'ROLLBACK;' '\q' >&3
    printf '%s\n' 'ROLLBACK;' '\q' >&4
    exec 3>&-
    exec 4>&-

    RC_A=0
    RC_B=0
    wait "$PID_A" || RC_A=$?
    wait "$PID_B" || RC_B=$?
}

show_observation() {
    psql -X -v ON_ERROR_STOP=1 -v app_a="$APP_A" -v app_b="$APP_B" <<'SQL'
\pset pager off
SELECT
    pid,
    application_name,
    state,
    wait_event_type,
    wait_event,
    pg_blocking_pids(pid) AS blocked_by,
    query
FROM pg_stat_activity
WHERE datname = current_database()
  AND application_name IN (:'app_a', :'app_b')
ORDER BY application_name;

SELECT
    a.application_name,
    l.locktype,
    l.mode,
    l.granted,
    l.relation::regclass AS relation,
    l.transactionid
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
WHERE a.datname = current_database()
  AND a.application_name IN (:'app_a', :'app_b')
ORDER BY a.application_name, l.granted, l.locktype, l.mode;

SELECT
    state,
    wait_event_type,
    count(*) AS connections
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY state, wait_event_type
ORDER BY state, wait_event_type;

SHOW max_connections;
SQL
}

psql -X -v ON_ERROR_STOP=1 <<'SQL'
\pset pager off
DO $check$
BEGIN
    IF to_regclass('performance.accounts_05') IS NOT NULL THEN
        RAISE EXCEPTION 'accounts_05 ya existe. No sobrescribir.';
    END IF;
END
$check$;

CREATE TABLE performance.accounts_05 (
    id integer PRIMARY KEY,
    balance integer NOT NULL
);

INSERT INTO performance.accounts_05 VALUES (1, 1000), (2, 1000);

SELECT deadlocks AS deadlocks_before
FROM pg_stat_database
WHERE datname = current_database();
SQL

DEADLOCKS_BEFORE=$(sql_value "SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")
printf '%s\n' "$DEADLOCKS_BEFORE" > "$WORK/deadlocks-before.txt"

echo ""
echo "FASE 1: BLOQUEO SIN DEADLOCK"
start_sessions locks

printf '%s\n' 'BEGIN; UPDATE performance.accounts_05 SET balance = balance + 10 WHERE id = 1;' >&3

wait_until \
    "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = '$APP_A' AND datname = current_database() AND state = 'idle in transaction' AND query LIKE 'UPDATE performance.accounts_05%')" \
    "sesión A mantiene su transacción abierta"

printf '%s\n' 'BEGIN; UPDATE performance.accounts_05 SET balance = balance + 20 WHERE id = 1;' >&4

wait_until \
    "SELECT EXISTS (SELECT 1 FROM pg_stat_activity b JOIN pg_stat_activity a ON a.pid = ANY(pg_blocking_pids(b.pid)) WHERE b.application_name = '$APP_B' AND a.application_name = '$APP_A' AND b.datname = current_database() AND b.wait_event_type = 'Lock')" \
    "sesión B espera un lock retenido por A"

show_observation

echo "LIBERACION: rollback de A permite avanzar a B; ambas revierten sus cambios."
finish_sessions

echo "LOG A: bloqueo"
cat "$WORK/locks-A.log"
echo "LOG B: bloqueo"
cat "$WORK/locks-B.log"

if [ "$RC_A" -ne 0 ] || [ "$RC_B" -ne 0 ]; then
    echo "FAIL: una sesión falló en la fase sin deadlock: A=$RC_A B=$RC_B"
    exit 1
fi

if [ "$(sql_value 'SELECT count(*) = 2 AND bool_and(balance = 1000) FROM performance.accounts_05')" != "t" ]; then
    echo "FAIL: balances incorrectos después de la fase de bloqueo"
    exit 1
fi
echo "PASS: bloqueo resuelto y balances restaurados"

echo ""
echo "FASE 2: DEADLOCK POR ORDEN INVERSO"
start_sessions deadlock

printf '%s\n' 'BEGIN; UPDATE performance.accounts_05 SET balance = balance + 10 WHERE id = 1;' >&3
printf '%s\n' 'BEGIN; UPDATE performance.accounts_05 SET balance = balance + 20 WHERE id = 2;' >&4

wait_until \
    "SELECT count(*) = 2 FROM pg_stat_activity WHERE datname = current_database() AND application_name IN ('$APP_A', '$APP_B') AND state = 'idle in transaction' AND query LIKE 'UPDATE performance.accounts_05%'" \
    "A y B mantienen bloqueadas filas diferentes"

printf '%s\n' 'UPDATE performance.accounts_05 SET balance = balance + 10 WHERE id = 2;' >&3

wait_until \
    "SELECT EXISTS (SELECT 1 FROM pg_stat_activity a JOIN pg_stat_activity b ON b.pid = ANY(pg_blocking_pids(a.pid)) WHERE a.application_name = '$APP_A' AND b.application_name = '$APP_B' AND a.datname = current_database() AND a.wait_event_type = 'Lock')" \
    "A espera la fila bloqueada por B"

printf '%s\n' 'UPDATE performance.accounts_05 SET balance = balance + 20 WHERE id = 1;' >&4

wait_until \
    "SELECT count(*) = 2 FROM pg_stat_activity WHERE datname = current_database() AND application_name IN ('$APP_A', '$APP_B') AND wait_event_type = 'Lock' AND cardinality(pg_blocking_pids(pid)) > 0" \
    "ciclo de espera observado antes de la detección del deadlock"

show_observation

# El detector abortará una sesión; la otra podrá terminar y hacer rollback.
finish_sessions

echo "LOG A: deadlock"
cat "$WORK/deadlock-A.log"
echo "LOG B: deadlock"
cat "$WORK/deadlock-B.log"

echo "Codigos de salida: A=$RC_A B=$RC_B"

if ! { [ "$RC_A" -eq 3 ] && [ "$RC_B" -eq 0 ]; } &&
   ! { [ "$RC_A" -eq 0 ] && [ "$RC_B" -eq 3 ]; }; then
    echo "FAIL: se esperaba una víctima SQL y una sesión exitosa"
    exit 1
fi

ERROR_COUNT=$(grep -h -c 'ERROR:  40P01:' "$WORK/deadlock-A.log" "$WORK/deadlock-B.log" | awk '{total += $1} END {print total}')

if [ "$ERROR_COUNT" -ne 1 ]; then
    echo "FAIL: se esperaba exactamente un error SQLSTATE 40P01"
    exit 1
fi
echo "PASS: un deadlock esperado, una víctima y una sesión superviviente"

# Consultar desde conexiones nuevas hasta que se publique el contador.
wait_until \
    "SELECT deadlocks >= $((DEADLOCKS_BEFORE + 1)) FROM pg_stat_database WHERE datname = current_database()" \
    "contador de deadlocks incrementado"

psql -X -v ON_ERROR_STOP=1 \
    -v app_a="$APP_A" -v app_b="$APP_B" <<'SQL'
\pset pager off
TABLE performance.accounts_05;

SELECT deadlocks AS deadlocks_after
FROM pg_stat_database
WHERE datname = current_database();

DO $check$
BEGIN
    IF (SELECT count(*) FROM performance.accounts_05) <> 2
       OR EXISTS (SELECT 1 FROM performance.accounts_05 WHERE balance <> 1000) THEN
        RAISE EXCEPTION 'No se restauraron los balances';
    END IF;
    RAISE NOTICE 'PASS: dos cuentas conservadas con balance original';
END
$check$;

SELECT count(*) AS remaining_test_sessions
FROM pg_stat_activity
WHERE datname = current_database()
  AND application_name IN (:'app_a', :'app_b');
SQL

if [ "$(sql_value "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND application_name IN ('$APP_A', '$APP_B')")" -ne 0 ]; then
    echo "FAIL: quedaron sesiones de prueba abiertas"
    exit 1
fi

echo "PASS: no quedan sesiones A/B ni transacciones de prueba"
echo "NOTA: el contador de deadlocks se conserva; no se reinician estadísticas."
echo ""
echo "PASS: ESCENARIO 07.05 COMPLETADO"
POSTGRES
